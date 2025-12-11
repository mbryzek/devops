require 'json'
require 'net/http'
require 'uri'

class NodeDiscovery
  # Represents the state of a single application on a node
  AppState = Struct.new(:name, :port, :healthy, :job_server, keyword_init: true)

  # Represents the complete state of a node
  NodeState = Struct.new(:uri, :apps, keyword_init: true) do
    def healthy_apps
      apps.select(&:healthy).map(&:name)
    end

    def job_server_apps
      apps.select(&:job_server).map(&:name)
    end

    def running_app?(app_name)
      apps.any? { |a| a.name == app_name }
    end

    def healthy_app?(app_name)
      healthy_apps.include?(app_name)
    end

    def job_server_for?(app_name)
      job_server_apps.include?(app_name)
    end
  end

  # Load scala apps from config files
  # Returns hash of { app_name => port }
  def self.known_apps
    @known_apps ||= begin
      dist_dir = File.join(File.dirname(__FILE__), "../dist")
      apps = {}
      Dir.glob(File.join(dist_dir, "*.config.json")).each do |path|
        json = JSON.parse(IO.read(path))
        app = json['app']
        next unless app && app['scala']  # Only scala apps
        apps[app['name']] = app['port']
      end
      apps.freeze
    end
  end

  # Timeout for healthcheck requests (seconds)
  PROBE_TIMEOUT = 5

  def initialize(node_uris)
    @node_uris = node_uris
    @known_apps = self.class.known_apps
  end

  # Discover what's running on all nodes
  # Returns array of NodeState objects
  def discover
    threads = @node_uris.map do |uri|
      Thread.new { probe_node(uri) }
    end
    threads.map(&:value)
  end

  private

  def probe_node(node_uri)
    apps = @known_apps.map do |app_name, port|
      probe_app(node_uri, app_name, port)
    end.compact

    NodeState.new(uri: node_uri, apps: apps)
  end

  # Probe a single app on a node
  # Returns:
  #   - AppState with healthy=true if app is running and healthy
  #   - AppState with healthy=false if app is running but unhealthy
  #   - nil if app is not running on this port
  def probe_app(node_uri, app_name, port)
    url = "http://#{node_uri}:#{port}/_internal_/healthcheck"

    begin
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = PROBE_TIMEOUT
      http.read_timeout = PROBE_TIMEOUT
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)

      if response.code == '200'
        data = JSON.parse(response.body)
        AppState.new(
          name: app_name,
          port: port,
          healthy: data['status'] == 'healthy',
          job_server: data['job_server'] == true
        )
      else
        # App responded but not with 200 - treat as running but unhealthy
        make_unhealthy_app(app_name, port)
      end
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout, Net::ReadTimeout, SocketError
      # Connection refused or timeout means app is not running on this port
      nil
    rescue JSON::ParserError => e
      # App is running (we got a response) but response was malformed - treat as unhealthy
      puts "WARNING: Failed to parse healthcheck from #{url}: #{e.message}"
      make_unhealthy_app(app_name, port)
    rescue StandardError => e
      # Unexpected error - log and treat as app not running
      puts "WARNING: Error probing #{url}: #{e.class} - #{e.message}"
      nil
    end
  end

  def make_unhealthy_app(app_name, port)
    AppState.new(
      name: app_name,
      port: port,
      healthy: false,
      job_server: false
    )
  end
end
