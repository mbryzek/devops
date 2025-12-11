require 'droplet_kit'

module DigitalOcean

  class Client
    TOKEN_FILE = '~/.digitalocean/token' unless defined?(TOKEN_FILE)
    MAX_RETRIES = 3

    def initialize(app)
      @app = app
      token = Util.read_file(TOKEN_FILE)
      @client = DropletKit::Client.new(access_token: token)
      @load_balancer = find_load_balancer
      @all_droplets = load_all_droplets
    end

    # Retry wrapper for API calls
    def with_retry(operation_name)
      retries = 0
      begin
        yield
      rescue DropletKit::Error, Faraday::Error, Net::OpenTimeout => e
        retries += 1
        if retries < MAX_RETRIES
          wait_time = 2 ** retries
          puts "  #{operation_name} failed, retrying in #{wait_time}s... (#{e.message})"
          sleep(wait_time)
          retry
        else
          raise "#{operation_name} failed after #{MAX_RETRIES} retries: #{e.message}"
        end
      end
    end

    def remove_droplet_by_ip_address(ip)
      with_retry("Remove droplet from LB") do
        droplets_by_ip_address(ip).each do |droplet|
          if @load_balancer.tag_based?
            @client.tags.untag_resources(
              name: @load_balancer.tag,
              resources: [{ resource_id: droplet.id.to_s, resource_type: 'droplet' }]
            )
          else
            @client.load_balancers.remove_droplets([droplet.id], id: @load_balancer.id)
          end
        end
      end
    end

    def add_droplet_by_ip_address(ip)
      with_retry("Add droplet to LB") do
        droplets_by_ip_address(ip).each do |droplet|
          if @load_balancer.tag_based?
            @client.tags.tag_resources(
              name: @load_balancer.tag,
              resources: [{ resource_id: droplet.id.to_s, resource_type: 'droplet' }]
            )
          else
            @client.load_balancers.add_droplets([droplet.id], id: @load_balancer.id)
          end
        end
      end
    end

    def droplet_has_tag?(ip, tag_name)
      with_retry("Check droplet tag") do
        droplets_by_ip_address(ip).any? do |droplet|
          droplet_obj = @client.droplets.find(id: droplet.id)
          droplet_obj.tags.include?(tag_name)
        end
      end
    end

    def droplet_tags(ip)
      with_retry("Get droplet tags") do
        droplets_by_ip_address(ip).flat_map do |droplet|
          droplet_obj = @client.droplets.find(id: droplet.id)
          droplet_obj.tags
        end.uniq
      end
    end

    def add_tag_to_droplet(ip, tag_name)
      with_retry("Add tag to droplet") do
        begin
          @client.tags.create(DropletKit::Tag.new(name: tag_name))
        rescue DropletKit::Error
          # Tag already exists
        end

        droplets_by_ip_address(ip).each do |droplet|
          @client.tags.tag_resources(
            name: tag_name,
            resources: [{ resource_id: droplet.id.to_s, resource_type: 'droplet' }]
          )
        end
      end
    end

    def remove_tag_from_droplet(ip, tag_name)
      with_retry("Remove tag from droplet") do
        droplets_by_ip_address(ip).each do |droplet|
          @client.tags.untag_resources(
            name: tag_name,
            resources: [{ resource_id: droplet.id.to_s, resource_type: 'droplet' }]
          )
        end
      end
    end

    def droplet_healthy_in_lb?(ip)
      droplet_ids = droplets_by_ip_address(ip).map(&:id)
      return false if droplet_ids.empty?

      # Fetch current LB to check droplet membership
      lb_id = @load_balancer.id
      response = @client.load_balancers.find(id: lb_id)

      # Check if all droplets for this IP are in the LB
      droplet_ids.all? do |droplet_id|
        response.droplet_ids.include?(droplet_id)
      end
    end

    def health_check_wait_seconds
      # Get the LB health check interval to know how long to wait
      lb = @client.load_balancers.find(id: @load_balancer.id)
      hc = lb.health_check
      # DropletKit uses check_interval_seconds and unhealthy_threshold
      interval = hc&.check_interval_seconds || 10
      threshold = hc&.unhealthy_threshold || 3
      wait = interval * threshold
      puts "   (LB health check: interval=#{interval}s, unhealthy_threshold=#{threshold})"
      wait
    end

    # Returns the current target port from the LB forwarding rules
    def current_target_port
      lb = @client.load_balancers.find(id: @load_balancer.id)
      # Find the HTTPS rule (entry port 443) - this is the main production rule
      rule = lb.forwarding_rules.find { |r| r.entry_port == 443 }
      rule&.target_port
    end

    # Switches the LB to route traffic to a new target port
    # Updates both the forwarding rule and health check
    def switch_to_port(new_port)
      lb = @client.load_balancers.find(id: @load_balancer.id)

      # Update forwarding rules - change target port for HTTPS rule
      new_rules = lb.forwarding_rules.map do |rule|
        if rule.entry_port == 443
          DropletKit::ForwardingRule.new(
            entry_protocol: rule.entry_protocol,
            entry_port: rule.entry_port,
            target_protocol: rule.target_protocol,
            target_port: new_port,
            certificate_id: rule.certificate_id,
            tls_passthrough: rule.tls_passthrough
          )
        else
          rule
        end
      end

      # Update health check to point to new port
      new_health_check = DropletKit::HealthCheck.new(
        protocol: lb.health_check.protocol,
        port: new_port,
        path: lb.health_check.path,
        check_interval_seconds: lb.health_check.check_interval_seconds,
        response_timeout_seconds: lb.health_check.response_timeout_seconds,
        unhealthy_threshold: lb.health_check.unhealthy_threshold,
        healthy_threshold: lb.health_check.healthy_threshold
      )

      # Create updated LB object - only include tag OR droplet_ids, not both
      tag_based = lb.tag && !lb.tag.empty?
      updated_lb = DropletKit::LoadBalancer.new(
        id: lb.id,
        name: lb.name,
        region: lb.region.slug,
        forwarding_rules: new_rules,
        health_check: new_health_check,
        algorithm: lb.algorithm,
        sticky_sessions: lb.sticky_sessions,
        redirect_http_to_https: lb.redirect_http_to_https
      )

      # Set only one of tag or droplet_ids
      if tag_based
        updated_lb.tag = lb.tag
      else
        updated_lb.droplet_ids = lb.droplet_ids
      end

      @client.load_balancers.update(updated_lb, id: lb.id)
    end

    private
    def droplets_by_ip_address(ip)
      @all_droplets.filter { |d| d.ip_addresses.include?(ip) }
    end

    def load_all_droplets
      @client.droplets.all().map { |droplet| Droplet.new(droplet) }
    end

    def find_load_balancer
      all = @client.load_balancers.all().map { |lb| LoadBalancer.new(lb) }
      load_balancers = all.select { |lb|
        lb.name.include?(@app)
      }

      if load_balancers.empty?
        if all.empty?
          Util.exit_with_error("Could not find any load balancers")
        end
        names = all.map { |lb| lb.name }.join(", ")
        Util.exit_with_error("Could not find any load balancers whose name includes: #{@app}.\n LB Names: #{names}")
      end

      if load_balancers.length > 1
        names = load_balancers.map { |lb| lb.name }.join(", ")
        Util.exit_with_error("Expected 1 load balancer but found #{load_balancers.length} whose name includes: #{@app}.\n LB Names: #{names}")
      end

      load_balancers.first
    end

  end

  class LoadBalancer
    attr_reader :id, :name, :tag

    def initialize(lb)
      @id = lb.id
      @name = lb.name
      @tag = lb.tag
    end

    def tag_based?
      !@tag.nil? && !@tag.empty?
    end
  end

  class Droplet

      attr_reader :id, :ip_addresses

      def initialize(droplet)
        @id = droplet.id
        @ip_addresses = droplet.networks.v4.map { |network| network.ip_address }
      end
  end

end
