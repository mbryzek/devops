require 'droplet_kit'

module DigitalOcean

  class Client
    TOKEN_FILE = '~/.digitalocean/token' unless defined?(TOKEN_FILE)

    def initialize(app)
      @app = app
      token = Util.read_file(TOKEN_FILE)
      @client = DropletKit::Client.new(access_token: token)
      @load_balancer = find_load_balancer
      @droplets = find_droplets
    end

    def remove_droplet_by_ip_address(ip)
      droplets_by_ip_address(ip).each do |droplet|
        if @load_balancer.tag_based?
          # For tag-based LBs, remove the tag from the droplet
          @client.tags.untag_resources(
            name: @load_balancer.tag,
            resources: [{ resource_id: droplet.id.to_s, resource_type: 'droplet' }]
          )
        else
          # For droplet-based LBs, remove directly
          @client.load_balancers.remove_droplets([droplet.id], id: @load_balancer.id)
        end
      end
    end

    def add_droplet_by_ip_address(ip)
      droplets_by_ip_address(ip).each do |droplet|
        if @load_balancer.tag_based?
          # For tag-based LBs, add the tag back to the droplet
          @client.tags.tag_resources(
            name: @load_balancer.tag,
            resources: [{ resource_id: droplet.id.to_s, resource_type: 'droplet' }]
          )
        else
          # For droplet-based LBs, add directly
          @client.load_balancers.add_droplets([droplet.id], id: @load_balancer.id)
        end
      end
    end

    # Check if a droplet is currently in the load balancer
    def droplet_in_lb?(ip)
      droplet = droplets_by_ip_address(ip).first
      return false unless droplet

      # Refresh load balancer state
      lb = @client.load_balancers.find(id: @load_balancer.id)

      if @load_balancer.tag_based?
        # For tag-based LBs, check if droplet has the tag
        droplet_info = @client.droplets.find(id: droplet.id)
        droplet_info.tags.include?(@load_balancer.tag)
      else
        # For droplet-based LBs, check if droplet is in the list
        lb.droplet_ids.include?(droplet.id)
      end
    end

    # Remove droplet from LB and wait for it to be fully removed
    # Returns true if successfully removed, false if timeout
    def drain_and_wait(ip, drain_wait: 10, max_poll: 30, poll_interval: 2)
      puts "Removing node #{ip} from load balancer"
      remove_droplet_by_ip_address(ip)

      # Poll until droplet is confirmed removed from LB
      start = Time.now
      while Time.now - start < max_poll
        if !droplet_in_lb?(ip)
          puts "Node #{ip} confirmed removed from load balancer"
          puts "Waiting #{drain_wait} seconds for connections to drain..."
          sleep drain_wait
          return true
        end
        sleep poll_interval
      end

      puts Util.warning("Timeout waiting for node #{ip} to be removed from load balancer")
      false
    end

    private
    def droplets_by_ip_address(ip)
      @droplets.filter { |d| d.ip_addresses.include?(ip) }
    end

    def find_droplets
      @client.droplets.all().select { |droplet|
        droplet.tags.include?(@app)
      }.map { |droplet| Droplet.new(droplet) }
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
