# NodeInspector provides functionality to inspect and display
# the state of applications running across deployment nodes.

class NodeInspector
  attr_reader :node_states

  def initialize(node_uris = nil)
    @node_uris = node_uris || load_global_nodes
    @node_states = nil
  end

  # Discover what's running on all nodes
  # Returns self for chaining
  def discover
    discovery = NodeDiscovery.new(@node_uris)
    @node_states = discovery.discover
    self
  end

  # Print detailed node information
  def print_details
    ensure_discovered

    @node_states.each do |ns|
      puts "Node: #{ns.uri}"
      if ns.apps.empty?
        puts "  No applications running"
      else
        ns.apps.each do |app|
          status = app.healthy ? "healthy" : "DOWN"
          role = app.job_server ? " (job server)" : ""
          puts "  - #{app.name} (port #{app.port}): #{status}#{role}"
        end
      end
      puts ""
    end
  end

  # Print summary for all known apps
  def print_summary
    ensure_discovered

    puts Util.underline("Summary")
    NodeDiscovery::KNOWN_APPS.each do |app_name, port|
      print_app_summary(app_name, port)
    end
    puts ""
  end

  # Print summary for a specific app
  def print_app_summary(app_name, port = nil)
    ensure_discovered

    port ||= NodeDiscovery::KNOWN_APPS[app_name]
    running_nodes = @node_states.select { |ns| ns.running_app?(app_name) }
    healthy_nodes = @node_states.select { |ns| ns.healthy_app?(app_name) }
    job_servers = @node_states.select { |ns| ns.job_server_for?(app_name) }

    puts ""
    puts "#{app_name} (port #{port}):"
    puts "  Running on: #{running_nodes.length} node(s)"
    puts "  Healthy: #{healthy_nodes.length} node(s)"
    puts "  Job servers: #{job_servers.length} (#{job_servers.map(&:uri).join(', ')})"

    if healthy_nodes.length == 0 && running_nodes.length > 0
      puts Util.warning("  WARNING: All instances are unhealthy!")
    end
  end

  # Full inspection output (details + summary)
  def print_all
    puts ""
    puts Util.underline("Discovering current state of all nodes")
    puts ""
    print_details
    print_summary
  end

  # Get summary data for a specific app (for programmatic use)
  def app_summary(app_name)
    ensure_discovered

    {
      running_nodes: @node_states.select { |ns| ns.running_app?(app_name) },
      healthy_nodes: @node_states.select { |ns| ns.healthy_app?(app_name) },
      job_servers: @node_states.select { |ns| ns.job_server_for?(app_name) }
    }
  end

  # Find extra instances of an app that should be stopped.
  # With N scala apps and M nodes, we expect:
  #   - 1 shared node running all apps (not as job server)
  #   - N dedicated job server nodes (one per app)
  # Extra = nodes running ONLY this app as non-job-server (borrowed nodes not returned)
  # Returns array of node URIs
  def extra_nodes_for_app(app_name)
    ensure_discovered

    running_nodes = @node_states.select { |ns| ns.running_app?(app_name) }
    job_server_node = @node_states.find { |ns| ns.job_server_for?(app_name) }

    extra = []
    running_nodes.each do |ns|
      next if ns == job_server_node  # Keep the job server
      next if ns.apps.length > 1     # Keep shared nodes (running multiple apps)

      # This node runs ONLY this app and is not a job server - it's extra
      extra << ns.uri
    end

    extra
  end

  private

  def ensure_discovered
    discover if @node_states.nil?
  end

  def load_global_nodes
    global_nodes_path = File.join(File.dirname(__FILE__), "../dist/nodes.json")
    if !File.exist?(global_nodes_path)
      Util.exit_with_error("Nodes config not found at #{global_nodes_path}. Run ./generate-json.rb first.")
    end
    JSON.parse(IO.read(global_nodes_path))['nodes'].map { |n| n['uri'] }
  end
end
