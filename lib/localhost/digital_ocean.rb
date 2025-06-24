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
        @client.load_balancers.remove_droplets([droplet.id], id: @load_balancer.id)
      end
    end

    def add_droplet_by_ip_address(ip)
      droplets_by_ip_address(ip).each do |droplet|
        @client.load_balancers.add_droplets([droplet.id], id: @load_balancer.id)
      end
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
