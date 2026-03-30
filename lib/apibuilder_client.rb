require 'net/http'
require 'uri'
require 'json'
require 'base64'

class ApibuilderClient

  class Error < StandardError; end

  DEFAULT_API_URI = "https://api.apibuilder.io"
  GLOBAL_CONFIG_DIR = File.join(Dir.home, ".apibuilder")
  CONFIG_PATH = File.join(GLOBAL_CONFIG_DIR, "config")

  attr_reader :base_uri, :token

  def initialize(profile = nil, allow_no_token: false)
    config = load_config(profile, allow_no_token: allow_no_token)
    @base_uri = config[:api_uri]
    @token = config[:token]
  end

  # Performs an authenticated HTTP request and returns the parsed response body.
  # Raises ApibuilderClient::Error on non-success responses.
  def request(method, path, body = nil)
    response = raw_request(method, path, body)
    handle_response(response, "#{method.upcase} #{path}")
  end

  # Performs an authenticated HTTP request and returns the raw Net::HTTP response.
  def raw_request(method, path, body = nil)
    uri = URI.parse("#{@base_uri}#{path}")
    http = build_http(uri)

    req = build_request(method, uri)
    req.body = JSON.generate(body) if body

    http.request(req)
  rescue Errno::ECONNREFUSED
    Util.exit_with_error("Cannot connect to #{@base_uri}. Is the server running?")
  rescue SocketError => e
    Util.exit_with_error("Cannot connect to #{@base_uri}: #{e.message}")
  end

  # Downloads a file from an absolute URL (no auth) and returns the raw body.
  # Returns nil for 404/410 (expired).
  def download(url)
    uri = URI.parse(url)
    http = build_http(uri)
    response = http.request(Net::HTTP::Get.new(uri.request_uri))

    code = response.code.to_i
    if code == 200
      response.body
    elsif code == 404 || code == 410
      nil
    else
      Util.exit_with_error("Failed to download #{url}: HTTP #{code}")
    end
  end

  # Create an anonymous org and token (no auth sent).
  # POST /apibuilder/anonymous
  def anonymous_init
    uri = URI.parse("#{@base_uri}/apibuilder/anonymous")
    http = build_http(uri)
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    response = http.request(req)
    handle_response(response, "POST /apibuilder/anonymous")
  end

  # Upload a spec file as a new version.
  # POST /apibuilder/{org}/{app}
  def upload_version(org, app, spec_path)
    data = IO.read(spec_path)
    body = {
      "original_form" => {
        "type" => "api_json",
        "data" => data,
      }
    }
    request(:post, "/apibuilder/#{org}/#{app}", body)
  end

  # Get generated code for a specific generator.
  # GET /apibuilder/{org}/{app}/{version}/{generator_key}
  def get_code(org, app, version, generator_key, attributes = nil)
    path = "/apibuilder/#{org}/#{app}/#{version}/#{generator_key}"
    if attributes && !attributes.empty?
      encoded = URI.encode_www_form_component(JSON.generate(attributes))
      path = "#{path}?attributes=#{encoded}"
    end
    request(:get, path)
  end

  # Get latest version for an app.
  # GET /apibuilder/{org}/{app}?limit=1
  def get_latest_version(org, app)
    path = "/apibuilder/#{org}/#{app}?limit=1"
    response = raw_request(:get, path)
    case response.code.to_i
    when 200
      JSON.parse(response.body).first
    when 404
      nil
    when 401
      Util.warning("Unauthorized fetching #{org}/#{app} versions; skipping version guard")
      nil
    else
      Util.warning("HTTP #{response.code.to_i} fetching #{org}/#{app} versions; skipping version guard")
      nil
    end
  end

  # Reads a value from the global config for a given profile and key.
  # Returns nil if the config file, profile, or key is not found.
  def self.read_config_value(profile, key)
    return nil unless File.exist?(CONFIG_PATH)

    target_section = profile ? "profile #{profile}" : "default"
    current_section = nil

    IO.readlines(CONFIG_PATH).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      if md = line.match(/^\[(.+)\]$/)
        current_section = md[1]
      elsif current_section == target_section
        k, v = line.split("=", 2).map(&:strip)
        return v if k == key
      end
    end

    nil
  end

  # Writes or updates a profile section in the global config file.
  # Returns true if written, false if the user declined to replace an existing section.
  def self.write_config_section(profile, entries)
    section_header = profile ? "[profile #{profile}]" : "[default]"
    section_content = entries.map { |k, v| "#{k} = #{v}" }.join("\n")
    full_section = "#{section_header}\n#{section_content}\n"

    FileUtils.mkdir_p(GLOBAL_CONFIG_DIR)

    if File.exist?(CONFIG_PATH)
      existing = IO.read(CONFIG_PATH)
      if existing.include?(section_header)
        profile_name = profile || "default"
        $stderr.print "Profile '#{profile_name}' already exists in #{CONFIG_PATH}. Replace it? [y/N] "
        answer = $stdin.gets&.strip&.downcase
        if answer != "y"
          puts "==> Aborted"
          return false
        end
        updated = remove_config_section(existing, section_header)
        write_config_file(updated.rstrip + "\n\n" + full_section)
      else
        write_config_file(existing.rstrip + "\n\n" + full_section)
      end
    else
      write_config_file(full_section)
    end

    true
  end

  private

  def self.remove_config_section(content, section_header)
    in_section = false
    content.lines.reject do |line|
      if line.strip == section_header
        in_section = true
        true
      elsif in_section && line.match?(/^\[/)
        in_section = false
        false
      else
        in_section
      end
    end.join
  end
  private_class_method :remove_config_section

  def self.write_config_file(content)
    tmp_path = "#{CONFIG_PATH}.tmp"
    IO.write(tmp_path, content)
    File.rename(tmp_path, CONFIG_PATH)
  end
  private_class_method :write_config_file

  HTTP_METHODS = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    put: Net::HTTP::Put,
    delete: Net::HTTP::Delete,
  }.freeze

  def build_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 30
    http.read_timeout = 300
    http
  end

  def build_request(method, uri)
    klass = HTTP_METHODS.fetch(method) { Util.exit_with_error("Unsupported HTTP method: #{method}") }
    req = klass.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    if @token && !@token.empty?
      req["Authorization"] = "Basic " + Base64.strict_encode64("#{@token}:")
    end
    req
  end

  def handle_response(response, context)
    code = response.code.to_i
    case code
    when 200, 201, 204
      code == 204 ? nil : JSON.parse(response.body)
    when 404
      raise Error, "#{context}: Not found (404)"
    when 401
      raise Error, "#{context}: Unauthorized. Check your API token in ~/.apibuilder/config"
    when 422
      errors = JSON.parse(response.body)
      messages = errors.map { |e| e["message"] || e.to_s }.join("\n  ")
      raise Error, "#{context}: Validation errors:\n  #{messages}"
    else
      message = begin
                  parsed = JSON.parse(response.body)
                  parsed["message"] || response.body
                rescue JSON::ParserError
                  response.body
                end
      raise Error, "#{context}: HTTP #{code}\n#{message}"
    end
  end

  def load_config(profile, allow_no_token: false)
    if !File.exist?(CONFIG_PATH)
      if allow_no_token
        return { api_uri: DEFAULT_API_URI, token: nil }
      end
      Util.exit_with_error("API Builder config not found at #{CONFIG_PATH}")
    end

    api_uri = self.class.read_config_value(profile, "api_uri") || DEFAULT_API_URI
    token = self.class.read_config_value(profile, "token")

    if token.nil? && !allow_no_token
      target = profile ? "profile #{profile}" : "default"
      if profile
        Util.exit_with_error("Profile '#{profile}' not found in #{CONFIG_PATH}")
      end
    end

    { api_uri: api_uri, token: token }
  end

end
