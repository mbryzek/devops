require 'net/http'
require 'uri'
require 'json'
require 'base64'

class ApibuilderClient

  DEFAULT_API_URI = "https://api.apibuilder.io"
  CONFIG_PATH = File.join(Dir.home, ".apibuilder", "config")

  attr_reader :base_uri, :token

  def initialize(profile = nil)
    config = load_config(profile)
    @base_uri = config[:api_uri]
    @token = config[:token]
  end

  # Upload a spec file as a new version
  # PUT /apibuilder/{org}/{app}/{version}
  def upload_version(org, app, version, spec_path)
    data = IO.read(spec_path)
    body = {
      "original_form" => {
        "type" => "api_json",
        "data" => data,
      }
    }
    path = "/apibuilder/#{org}/#{app}/#{version}"
    response = request(:put, path, body)
    handle_response(response, "Upload #{org}/#{app} version #{version}")
  end

  # Get generated code for a specific generator
  # GET /apibuilder/{org}/{app}/{version}/{generator_key}
  def get_code(org, app, version, generator_key, attributes = nil)
    path = "/apibuilder/#{org}/#{app}/#{version}/#{generator_key}"
    if attributes && !attributes.empty?
      encoded = URI.encode_www_form_component(JSON.generate(attributes))
      path = "#{path}?attributes=#{encoded}"
    end
    response = request(:get, path)
    handle_response(response, "Generate #{generator_key} for #{org}/#{app}@#{version}")
  end

  # Get latest version for an app
  # GET /apibuilder/{org}/{app}?limit=1
  def get_latest_version(org, app)
    path = "/apibuilder/#{org}/#{app}?limit=1"
    response = request(:get, path)
    case response.code.to_i
    when 200
      versions = JSON.parse(response.body)
      versions.first
    when 404
      nil
    when 401
      $stderr.puts "WARNING: Unauthorized fetching #{org}/#{app} versions; skipping version guard"
      nil
    else
      $stderr.puts "WARNING: HTTP #{response.code.to_i} fetching #{org}/#{app} versions; skipping version guard"
      nil
    end
  end

  private

  def request(method, path, body = nil)
    uri = URI.parse("#{@base_uri}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 300

    req = case method
          when :get then Net::HTTP::Get.new(uri.request_uri)
          when :put then Net::HTTP::Put.new(uri.request_uri)
          when :post then Net::HTTP::Post.new(uri.request_uri)
          when :delete then Net::HTTP::Delete.new(uri.request_uri)
          end

    req["Content-Type"] = "application/json"
    if @token
      req["Authorization"] = "Basic " + Base64.strict_encode64("#{@token}:")
    end
    req.body = JSON.generate(body) if body

    http.request(req)
  end

  def handle_response(response, context)
    code = response.code.to_i
    case code
    when 200, 201, 204
      code == 204 ? nil : JSON.parse(response.body)
    when 404
      Util.exit_with_error("#{context}: Not found (404)")
    when 401
      Util.exit_with_error("#{context}: Unauthorized. Check your API token in ~/.apibuilder/config")
    when 422
      errors = JSON.parse(response.body)
      messages = errors.map { |e| e["message"] || e.to_s }.join("\n  ")
      Util.exit_with_error("#{context}: Validation errors:\n  #{messages}")
    else
      Util.exit_with_error("#{context}: HTTP #{code}\n#{response.body}")
    end
  end

  def load_config(profile)
    if !File.exist?(CONFIG_PATH)
      Util.exit_with_error("API Builder config not found at #{CONFIG_PATH}")
    end

    api_uri = DEFAULT_API_URI
    token = nil
    current_section = nil
    target_section = profile ? "profile #{profile}" : "default"

    IO.readlines(CONFIG_PATH).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      if md = line.match(/^\[(.+)\]$/)
        current_section = md[1]
      elsif current_section == target_section
        key, value = line.split("=", 2).map(&:strip)
        case key
        when "api_uri" then api_uri = value
        when "token" then token = value
        end
      end
    end

    if token.nil? && target_section != "default"
      Util.exit_with_error("Profile '#{profile}' not found in #{CONFIG_PATH}")
    end

    { api_uri: api_uri, token: token }
  end

end
