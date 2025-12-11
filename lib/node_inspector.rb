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
      puts "Node #{ns.uri}"
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

  # Full inspection output (details + summary)
  def print_all
    puts ""
    puts Util.underline("Current state of all nodes")
    puts ""
    print_details
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

  # Find extra instances that should be stopped.
  # Logic: Job server nodes should only run their designated job server app.
  # Any OTHER app running on a job server node is extra and should be removed.
  # Only mark as extra if removing would leave at least 2 instances of that app.
  # Returns hash of { app_name => [node_uris] }
  def extra_instances
    ensure_discovered

    extra = {}

    # Find all job server nodes
    job_server_nodes = @node_states.select { |ns| ns.apps.any?(&:job_server) }

    job_server_nodes.each do |ns|
      # Find the job server app for this node
      job_server_app = ns.apps.find(&:job_server)

      # Any other app on this node is a candidate for removal
      other_apps = ns.apps.reject { |app| app.name == job_server_app.name }

      other_apps.each do |app|
        # Count how many other nodes are running this app
        other_nodes_running_app = @node_states.count { |other|
          other != ns && other.running_app?(app.name)
        }

        # Only mark as extra if at least 2 instances would remain
        if other_nodes_running_app >= 2
          extra[app.name] ||= []
          extra[app.name] << ns.uri
        end
      end
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
