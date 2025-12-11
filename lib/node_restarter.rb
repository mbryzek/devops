# Handles application restart on a single node with load balancer management.
# Provides zero-downtime restarts when load balancer is configured.
#
# Usage:
#   restarter = NodeRestarter.new(app_name, port, node_uri, global_nodes)
#   result = restarter.restart(deploy_dir: dir, run_script: script)
#   result.success?  # true/false
#   result.message   # status message

class NodeRestarter
  # Configuration constants (match deploy script)
  DRAIN_WAIT_SECONDS = 10
  HEALTHCHECK_MAX_RETRIES = 25
  LB_REMOVAL_POLL_TIMEOUT = 30

  Result = Struct.new(:success, :message, keyword_init: true) do
    def success?
      success
    end
  end

  attr_reader :app_name, :port, :node_uri

  def initialize(app_name, port, node_uri, global_nodes)
    @app_name = app_name
    @port = port
    @node_uri = node_uri
    @global_nodes = global_nodes
    @do_client = nil  # Lazy-loaded
  end

  # Full restart sequence with zero-downtime (if LB available)
  # Options:
  #   deploy_dir: Directory containing the run script
  #   run_script: Name of the run script file
  #   logfile: Log file name (defaults to "#{app_name}.log")
  def restart(deploy_dir:, run_script:, logfile: nil)
    logfile ||= "#{@app_name}.log"
    was_in_lb = false

    # Step 1: Drain from LB (if available and node is in LB)
    if lb_available?
      was_in_lb = do_client.droplet_in_lb?(@node_uri)
      if was_in_lb
        puts "  Draining #{@node_uri} from load balancer..."
        success = do_client.drain_and_wait(
          @node_uri,
          drain_wait: DRAIN_WAIT_SECONDS,
          max_poll: LB_REMOVAL_POLL_TIMEOUT
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

    # Step 2: Kill existing process
    puts "  Stopping #{@app_name}..."
    unless kill_app
      # If kill fails but we drained, try to re-add to LB
      re_add_to_lb if was_in_lb
      return Result.new(success: false, message: "Failed to stop application")
    end

    # Step 3: Start application
    puts "  Starting #{@app_name}..."
    unless start_app(deploy_dir, run_script, logfile)
      re_add_to_lb if was_in_lb
      return Result.new(success: false, message: "Failed to start application")
    end

    # Step 4: Wait for healthcheck
    puts "  Waiting for healthcheck..."
    healthy = wait_for_health

    # Step 5: Re-add to LB (if was in LB)
    if lb_available? && was_in_lb
      if healthy
        puts "  Adding #{@node_uri} back to load balancer..."
        do_client.add_droplet_by_ip_address(@node_uri)
      else
        puts "  WARNING: Not adding unhealthy node back to load balancer"
      end
    end

    if healthy
      Result.new(success: true, message: "Node #{@node_uri} restarted successfully")
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
    HEALTHCHECK_MAX_RETRIES.times do |i|
      dots = (i % 3) + 1
      print "\r  Checking health#{('.' * dots).ljust(3)}"
      $stdout.flush

      if check_health
        print "\r" + " " * 40 + "\r"
        $stdout.flush
        return true
      end

      sleep 1 unless i == HEALTHCHECK_MAX_RETRIES - 1
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

  private

  def lb_available?
    do_client&.has_load_balancer?
  end

  def do_client
    return @do_client if @do_client

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
    do_client.add_droplet_by_ip_address(@node_uri)
  end

  def remote_cmd(cmd)
    "ssh -o ConnectTimeout=5 root@#{@node_uri} '#{cmd}'"
  end
end
