# Handles application restart on a single node with load balancer management.
# Provides zero-downtime restarts when load balancer is configured.
#
# Usage (restart script):
#   restarter = NodeRestarter.new(app_name, port, node_uri, global_nodes)
#   result = restarter.restart(deploy_dir: dir, run_script: script)
#   result.success?  # true/false
#   result.message   # status message
#
# Usage (deploy script with custom execution):
#   restarter = NodeRestarter.new(app_name, port, node_uri, global_nodes, do_client: client)
#   result = restarter.deploy_with_lb(drain_required: true, add_to_lb: true) do
#     # Custom deployment logic here
#     # Return true if successful, false otherwise
#   end

class NodeRestarter
  Result = Struct.new(:success, :message, keyword_init: true) do
    def success?
      success
    end
  end

  attr_reader :app_name, :port, :node_uri

  # Initialize a NodeRestarter
  # @param app_name [String] Application name
  # @param port [Integer] Application port for healthcheck
  # @param node_uri [String] Node URI (IP address)
  # @param global_nodes [Array<String>] All node URIs for LB client
  # @param do_client [DigitalOcean::Client, nil] Optional pre-initialized DO client
  def initialize(app_name, port, node_uri, global_nodes, do_client: nil)
    @app_name = app_name
    @port = port
    @node_uri = node_uri
    @global_nodes = global_nodes
    @do_client = do_client
    @do_client_initialized = !do_client.nil?
  end

  # Full restart sequence with zero-downtime (if LB available)
  # Used by restart script for simple kill/start restarts
  # Options:
  #   deploy_dir: Directory containing the run script
  #   run_script: Name of the run script file
  #   logfile: Log file name (defaults to "#{app_name}.log")
  def restart(deploy_dir:, run_script:, logfile: nil)
    logfile ||= "#{@app_name}.log"

    deploy_with_lb(drain_required: true, add_to_lb: true) do
      # Kill existing process
      puts "  Stopping #{@app_name}..."
      unless kill_app
        next false
      end

      # Start application
      puts "  Starting #{@app_name}..."
      unless start_app(deploy_dir, run_script, logfile)
        next false
      end

      true
    end
  end

  # Deploy with load balancer handling
  # Used by deploy script with custom deployment logic
  # @param drain_required [Boolean] Whether to drain from LB before deployment
  # @param add_to_lb [Boolean] Whether to add to LB after deployment (for borrowed nodes)
  # @yield Block containing deployment logic, should return true on success
  # @return [Result] Result of the deployment
  def deploy_with_lb(drain_required:, add_to_lb:)
    was_in_lb = false

    # Step 1: Drain from LB (if required and node is in LB)
    if drain_required && lb_available?
      was_in_lb = do_client.droplet_in_lb?(@node_uri)
      if was_in_lb
        puts "  Draining #{@node_uri} from load balancer..."
        success = do_client.drain_and_wait(
          @node_uri,
          drain_wait: DeploymentConfig::DRAIN_WAIT_SECONDS,
          max_poll: DeploymentConfig::LB_REMOVAL_POLL_TIMEOUT
        )
        unless success
          puts "  Re-adding node to load balancer (drain timeout)..."
          do_client.add_droplet_by_ip_address(@node_uri)
          return Result.new(success: false, message: "Failed to drain from load balancer")
        end
      else
        puts "  Node #{@node_uri} not in load balancer, skipping drain"
      end
    end

    # Step 2: Execute deployment logic
    deploy_success = yield
    unless deploy_success
      re_add_to_lb if was_in_lb
      return Result.new(success: false, message: "Deployment failed")
    end

    # Step 3: Wait for healthcheck
    puts "  Waiting for healthcheck..."
    healthy = wait_for_health

    # Step 4: Add to LB (if was in LB, or if add_to_lb requested for borrowed nodes)
    should_add_to_lb = was_in_lb || add_to_lb
    if lb_available? && should_add_to_lb
      if healthy
        puts "  Adding #{@node_uri} to load balancer..."
        safe_add_to_lb(@node_uri)
      elsif was_in_lb
        # Re-add unhealthy nodes that were previously serving traffic to preserve capacity
        puts "  WARNING: Re-adding unhealthy node to load balancer (was previously serving traffic)"
        safe_add_to_lb(@node_uri)
      else
        puts "  WARNING: Not adding unhealthy borrowed node to load balancer"
      end
    end

    if healthy
      Result.new(success: true, message: "Node #{@node_uri} deployed successfully")
    else
      Result.new(success: false, message: "Node #{@node_uri} did not become healthy within timeout")
    end
  end

  # Kill the application process
  def kill_app
    cmd = remote_cmd("./deploy/kill.rb --app #{@app_name}")
    system(cmd)
  end

  # Start the application
  def start_app(deploy_dir, run_script, logfile)
    cmd = remote_cmd("cd #{deploy_dir} && nohup ./#{run_script} > ../#{logfile} 2>&1 &")
    system(cmd)
  end

  # Wait for healthcheck to return healthy
  # Returns true if healthy, false if timeout
  def wait_for_health
    DeploymentConfig::HEALTHCHECK_MAX_RETRIES.times do |i|
      dots = (i % 3) + 1
      print "\r  Checking health#{('.' * dots).ljust(3)}"
      $stdout.flush

      if check_health
        print "\r" + " " * 40 + "\r"
        $stdout.flush
        return true
      end

      sleep 1 unless i == DeploymentConfig::HEALTHCHECK_MAX_RETRIES - 1
    end

    print "\r" + " " * 40 + "\r"
    $stdout.flush
    false
  end

  # Check if node is currently healthy
  def check_health
    cmd = remote_cmd("curl -s --connect-timeout 2 http://localhost:#{@port}/_internal_/healthcheck")
    result = `#{cmd}`.strip
    return false unless $?.success?

    begin
      data = JSON.parse(result)
      data['status'] == 'healthy'
    rescue JSON::ParserError
      false
    end
  end

  # Check if load balancer is available
  def lb_available?
    do_client&.has_load_balancer?
  end

  private

  def do_client
    return @do_client if @do_client_initialized

    @do_client_initialized = true
    begin
      @do_client = DigitalOcean::Client.new(@app_name, node_ips: @global_nodes, require_lb: false)
    rescue Errno::ENOENT => e
      # Token file doesn't exist - LB features unavailable
      puts "  Note: DigitalOcean not configured (#{e.message})"
      @do_client = nil
    rescue => e
      # Unexpected error - should be visible
      puts Util.warning("Failed to initialize DigitalOcean client: #{e.message}")
      @do_client = nil
    end
    @do_client
  end

  def re_add_to_lb
    return unless lb_available? && do_client
    puts "  Re-adding #{@node_uri} to load balancer (recovery)..."
    safe_add_to_lb(@node_uri)
  end

  def safe_add_to_lb(node_uri)
    return unless do_client
    begin
      do_client.add_droplet_by_ip_address(node_uri)
    rescue => e
      puts Util.warning("Failed to add node to load balancer: #{e.message}")
    end
  end

  def remote_cmd(cmd)
    "ssh -o ConnectTimeout=5 root@#{@node_uri} '#{cmd}'"
  end
end
