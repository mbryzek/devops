require 'droplet_kit'

module DigitalOcean

  class Client
    TOKEN_FILE = '~/.digitalocean/token' unless defined?(TOKEN_FILE)

    def initialize(app, node_ips:, require_lb: true)
      @app = app
      @node_ips = node_ips
      @require_lb = require_lb
      token = Util.read_file(TOKEN_FILE)
      @client = DropletKit::Client.new(access_token: token)
      @load_balancer = find_load_balancer
      @droplets = find_droplets
    end

    def has_load_balancer?
      !@load_balancer.nil?
    end

    def remove_droplet_by_ip_address(ip)
      return unless has_load_balancer?
      return unless droplet_in_lb?(ip)

      droplets_by_ip_address(ip).each do |droplet|
        @client.load_balancers.remove_droplets([droplet.id], id: @load_balancer.id)
      end
    end

    def add_droplet_by_ip_address(ip)
      return unless has_load_balancer?
      return if droplet_in_lb?(ip)

      droplets_by_ip_address(ip).each do |droplet|
        @client.load_balancers.add_droplets([droplet.id], id: @load_balancer.id)
      end
    end

    # Check if a droplet is currently in the load balancer
    def droplet_in_lb?(ip)
      return false unless has_load_balancer?

      droplet = droplets_by_ip_address(ip).first
      return false unless droplet

      # Refresh load balancer state
      lb = @client.load_balancers.find(id: @load_balancer.id)
      lb.droplet_ids.include?(droplet.id)
    end

    # Remove droplet from LB and wait for it to be fully removed
    # Returns true if successfully removed (or wasn't in LB), false if timeout
    def drain_and_wait(ip, drain_wait: 10, max_poll: 30, poll_interval: 2)
      return true unless has_load_balancer?

      # Check if already not in LB - nothing to do
      if !droplet_in_lb?(ip)
        puts "Node #{ip} is not in load balancer, skipping drain"
        return true
      end

      puts "Removing node #{ip} from load balancer"
      droplets_by_ip_address(ip).each do |droplet|
        @client.load_balancers.remove_droplets([droplet.id], id: @load_balancer.id)
      end

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
      all_droplets = @client.droplets.all().map { |droplet| Droplet.new(droplet) }
      all_droplets.select { |droplet|
        (@node_ips & droplet.ip_addresses).any?
      }
    end

    def find_load_balancer
      all = @client.load_balancers.all().map { |lb| LoadBalancer.new(lb) }
      load_balancers = all.select { |lb|
        lb.name.include?(@app)
      }

      if load_balancers.empty?
        return nil unless @require_lb

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
    attr_reader :id, :name

    def initialize(lb)
      @id = lb.id
      @name = lb.name
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
