# Custom exception for when zero-downtime deployment is not possible
class ZeroDowntimeNotPossible < StandardError; end

class DeploymentPlanner
  # Represents a single step in the deployment plan
  DeploymentStep = Struct.new(:node_state, :action, :reason, keyword_init: true) do
    def to_s
      "#{action.to_s.capitalize} on #{node_state.uri} (#{reason})"
    end
  end

  # Actions that can be performed
  DEPLOY = :deploy
  STOP = :stop

  def initialize(target_app, target_port, node_states)
    @target_app = target_app
    @target_port = target_port
    @node_states = node_states
  end

  # Generate the deployment plan
  # Returns array of DeploymentStep objects
  # Raises an error if zero-downtime deployment is not possible
  def plan
    steps = []

    # Categorize nodes
    nodes_with_app = @node_states.select { |ns| ns.running_app?(@target_app) }
    nodes_without_app = @node_states.reject { |ns| ns.running_app?(@target_app) }

    # Check for down nodes running target app (optimization: deploy there first, no borrowing)
    down_nodes = nodes_with_app.select { |ns| !ns.healthy_app?(@target_app) }

    # Track borrowed node for cleanup
    borrowed_node = nil

    # Step 1: Find first deployment target (down node or borrowed node)
    if down_nodes.any?
      # Deploy to down node first - no drain needed
      first_node = down_nodes.first
      steps << DeploymentStep.new(
        node_state: first_node,
        action: DEPLOY,
        reason: "down node - no drain needed"
      )
      nodes_with_app = nodes_with_app - [first_node]
    elsif nodes_without_app.any?
      # Borrow a node that doesn't have this app - no drain needed for this app's port
      borrowed_node = nodes_without_app.first
      steps << DeploymentStep.new(
        node_state: borrowed_node,
        action: DEPLOY,
        reason: "borrowed node - no #{@target_app} running"
      )
    elsif nodes_with_app.length >= 2
      # All nodes running the app - drain one first, deploy to it, then it becomes the buffer
      job_servers = nodes_with_app.select { |ns| ns.job_server_for?(@target_app) }
      non_job_servers = nodes_with_app.reject { |ns| ns.job_server_for?(@target_app) }

      # If multiple job servers exist (misconfiguration), pick one of them first
      # since they're redundant. Otherwise pick a non-job-server.
      first_node = if job_servers.length > 1
        job_servers.first
      elsif non_job_servers.length > 1
        non_job_servers.first
      else
        non_job_servers.first || job_servers.first
      end

      if first_node
        steps << DeploymentStep.new(
          node_state: first_node,
          action: DEPLOY,
          reason: "first node - drain required, then serves as buffer"
        )
        nodes_with_app = nodes_with_app - [first_node]
      end
    end

    # Step 2: Deploy to regular (non-job-server) nodes
    regular_nodes = nodes_with_app.reject { |ns| ns.job_server_for?(@target_app) }
    regular_nodes.each do |ns|
      steps << DeploymentStep.new(
        node_state: ns,
        action: DEPLOY,
        reason: "regular instance - drain required"
      )
    end

    # Step 3: Deploy to job server(s) LAST
    job_nodes = nodes_with_app.select { |ns| ns.job_server_for?(@target_app) }
    job_nodes.each do |ns|
      steps << DeploymentStep.new(
        node_state: ns,
        action: DEPLOY,
        reason: "job server - drain required, deploy last"
      )
    end

    # Step 4: Clean up borrowed node (stop the app we temporarily deployed)
    if borrowed_node
      steps << DeploymentStep.new(
        node_state: borrowed_node,
        action: STOP,
        reason: "return borrowed node - drain and stop"
      )
    end

    # Validate we have at least one deploy step
    deploy_steps = steps.select { |s| s.action == DEPLOY }
    if deploy_steps.empty?
      raise ZeroDowntimeNotPossible, "No nodes available for deployment of #{@target_app}"
    end

    steps
  end

  # Pretty print the deployment plan
  def print_plan
    steps = plan
    puts ""
    puts Util.underline("Deployment Plan for #{@target_app}")
    steps.each_with_index do |step, i|
      puts "  #{i + 1}. #{step}"
    end
    puts ""
  end

  # Check if borrowing is needed
  def requires_borrowing?
    nodes_with_app = @node_states.select { |ns| ns.running_app?(@target_app) }
    down_nodes = nodes_with_app.select { |ns| !ns.healthy_app?(@target_app) }

    # No borrowing needed if there's a down node
    return false if down_nodes.any?

    # Borrowing needed if all nodes with the app are healthy
    nodes_without_app = @node_states.reject { |ns| ns.running_app?(@target_app) }
    nodes_without_app.any?
  end

  # Get the borrowed node (if any)
  def borrowed_node
    return nil unless requires_borrowing?
    @node_states.reject { |ns| ns.running_app?(@target_app) }.first
  end
end
