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
#   restarter = NodeRestarter.new(app_name, port, node_uri, global_nodes, digital_ocean_client: client)
#   result = restarter.deploy_with_lb(drain_required: true, add_to_lb: true) do
#     # Custom deployment logic here
#     # Return true if successful, false otherwise
#   end

class NodeRestarter
  # Width used to clear terminal status lines
  TERMINAL_CLEAR_WIDTH = 50

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
  # @param digital_ocean_client [DigitalOcean::Client, nil] Optional pre-initialized DO client
  def initialize(app_name, port, node_uri, global_nodes, digital_ocean_client: nil)
    @app_name = app_name
    @port = port
    @node_uri = node_uri
    @global_nodes = global_nodes
    @digital_ocean_client = digital_ocean_client
    @digital_ocean_client_initialized = !digital_ocean_client.nil?
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

    # Step 0: Signal instance to drain (marks healthcheck unhealthy)
    # This gives DO time to detect the node is unhealthy while it continues to serve traffic
    if drain_required
      puts "  Signaling #{@node_uri} to drain..."
      if drain_instance
        puts "  Instance draining, waiting #{DeploymentConfig::INSTANCE_DRAIN_WAIT_SECONDS}s for DO healthcheck detection..."
        sleep DeploymentConfig::INSTANCE_DRAIN_WAIT_SECONDS
      else
        # Still wait on failure - instance may be draining despite failed response
        reduced_wait = DeploymentConfig::INSTANCE_DRAIN_WAIT_SECONDS / 2
        puts "  Warning: Instance drain signal failed. Waiting reduced period (#{reduced_wait}s)..."
        sleep reduced_wait
      end
    end

    # Step 1: Drain from LB (if required and node is in LB)
    if drain_required && lb_available?
      was_in_lb = digital_ocean_client.droplet_in_lb?(@node_uri)
      if was_in_lb
        puts "  Draining #{@node_uri} from load balancer..."
        success = digital_ocean_client.drain_and_wait(
          @node_uri,
          drain_wait: DeploymentConfig::DRAIN_WAIT_SECONDS,
          max_poll: DeploymentConfig::LB_REMOVAL_POLL_TIMEOUT
        )
        unless success
          puts "  Re-adding node to load balancer (drain timeout)..."
          digital_ocean_client.add_droplet_by_ip_address(@node_uri)
          return Result.new(success: false, message: "Failed to drain from load balancer. Node re-added to LB. Manual investigation required.")
        end
      else
        puts "  Node #{@node_uri} not in load balancer, skipping drain"
      end
    end

    # Step 2: Execute deployment logic
    deploy_success = yield
    unless deploy_success
      if was_in_lb
        # Check health before re-adding failed deployment to LB
        puts "  Deployment failed, checking node health before re-adding to load balancer..."
        healthy = wait_for_health
        if healthy
          puts "  Node is healthy, re-adding #{@node_uri} to load balancer..."
          safe_add_to_lb(@node_uri)
        else
          puts "  WARNING: Node is unhealthy after failed deployment. Node remains out of load balancer rotation until manually resolved."
        end
      end
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
        puts "  WARNING: Re-adding unhealthy node to load balancer (was previously serving traffic). Manual investigation recommended."
        safe_add_to_lb(@node_uri)
      else
        puts "  WARNING: Not adding unhealthy borrowed node to load balancer. Deployment will continue but this node requires manual investigation."
      end
    end

    if healthy
      Result.new(success: true, message: "Node #{@node_uri} deployed successfully")
    else
      Result.new(success: false, message: "Node #{@node_uri} did not become healthy within timeout")
    end
  end

  # Kill the application process
  # @return [Boolean] true if successful, false otherwise
  def kill_app
    cmd = remote_cmd("./deploy/kill.rb --app #{@app_name}")
    result = system(cmd)
    if result.nil?
      puts "  ERROR: Command execution failed: #{cmd}"
      return false
    end
    $?.success?
  end

  # Start the application
  # @return [Boolean] true if successful, false otherwise
  def start_app(deploy_dir, run_script, logfile)
    cmd = remote_cmd("cd #{deploy_dir} && nohup ./#{run_script} > ../#{logfile} 2>&1 &")
    result = system(cmd)
    if result.nil?
      puts "  ERROR: Command execution failed: #{cmd}"
      return false
    end
    $?.success?
  end

  # Wait for healthcheck to return healthy
  # @return [Boolean] true if healthy, false if timeout
  def wait_for_health
    DeploymentConfig::HEALTHCHECK_MAX_POLLS.times do |i|
      dots = (i % 3) + 1
      print "\r  Checking health#{('.' * dots).ljust(3)}"
      $stdout.flush

      if check_health
        clear_terminal_line
        return true
      end

      sleep 1 unless i == DeploymentConfig::HEALTHCHECK_MAX_POLLS - 1
    end

    clear_terminal_line
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

  # Signal the instance to start draining (marks healthcheck as unhealthy)
  # The instance continues to serve traffic but healthcheck returns unhealthy
  # Uses longer timeout (5s) than healthcheck since drain may be heavier operation
  # @return [Boolean] true if successful, false otherwise
  def drain_instance
    cmd = remote_cmd("curl -s --connect-timeout 5 -X POST http://localhost:#{@port}/_internal_/drain")
    result = `#{cmd}`.strip
    exit_success = $?.success?
    return false unless exit_success

    begin
      data = JSON.parse(result)
      data['status'] == 'draining'
    rescue JSON::ParserError
      # Fallback: accept HTTP success but log for monitoring
      puts "  Note: Drain endpoint returned non-JSON response, assuming success"
      exit_success
    end
  end

  # Check if load balancer is available
  def lb_available?
    digital_ocean_client&.has_load_balancer?
  end

  private

  # Clear the current terminal line (for status animations)
  def clear_terminal_line
    print "\r" + " " * TERMINAL_CLEAR_WIDTH + "\r"
    $stdout.flush
  end

  # Get the DigitalOcean client, initializing lazily if needed
  # @return [DigitalOcean::Client, nil] The client, or nil if unavailable
  def digital_ocean_client
    return @digital_ocean_client if @digital_ocean_client_initialized

    @digital_ocean_client_initialized = true
    begin
      @digital_ocean_client = DigitalOcean::Client.new(@app_name, node_ips: @global_nodes, require_lb: false)
    rescue Errno::ENOENT => e
      # Token file doesn't exist - LB features unavailable
      puts "  Note: DigitalOcean not configured (#{e.message}). Load balancer operations will be skipped."
      @digital_ocean_client = nil
    rescue => e
      # Unexpected error - should be visible
      puts Util.warning("Failed to initialize DigitalOcean client: #{e.message}. Load balancer operations will be skipped.")
      @digital_ocean_client = nil
    end
    @digital_ocean_client
  end

  def re_add_to_lb
    return unless lb_available? && digital_ocean_client
    puts "  Re-adding #{@node_uri} to load balancer (recovery)..."
    safe_add_to_lb(@node_uri)
  end

  def safe_add_to_lb(node_uri)
    return unless digital_ocean_client
    begin
      digital_ocean_client.add_droplet_by_ip_address(node_uri)
    rescue => e
      puts Util.warning("Failed to add node to load balancer: #{e.message}. Manual intervention may be required.")
    end
  end

  def remote_cmd(cmd)
    "ssh -o ConnectTimeout=5 root@#{@node_uri} '#{cmd}'"
  end
end
