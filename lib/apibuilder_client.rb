require 'net/http'
require 'openssl'
require 'uri'
require 'json'
require 'base64'

class ApibuilderClient

  class Error < StandardError; end

  DEFAULT_API_URI = "https://api.apibuilder.io"
  GLOBAL_CONFIG_DIR = File.join(Dir.home, ".apibuilder")
  CONFIG_PATH = File.join(GLOBAL_CONFIG_DIR, "config")

  # Transport failures that are worth another attempt: a TLS connection dropped
  # mid-response, a reset, a backend that went away while we were talking to it.
  # These say nothing about whether the request was valid - only that this
  # particular connection did not survive.
  RETRYABLE_ERRORS = [
    OpenSSL::SSL::SSLError,
    IOError, # includes EOFError
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::EPIPE,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    Net::OpenTimeout,
    Net::ReadTimeout,
    SocketError,
  ].freeze

  # Gateway statuses: the load balancer answered because a backend was rolling
  # or unreachable, so the app never saw the request. Same class of problem as a
  # dropped connection, same response.
  RETRYABLE_STATUSES = [502, 503, 504].freeze

  MAX_ATTEMPTS = 3
  RETRY_BACKOFF_SECONDS = [1, 3].freeze

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

    execute("#{method.to_s.upcase} #{path}") do
      req = build_request(method, uri)
      req.body = JSON.generate(body) if body
      build_http(uri).request(req)
    end
  end

  # Downloads a file from an absolute URL (no auth) and returns the raw body.
  # Returns nil for 404/410 (expired). Follows up to 5 redirects (301/302/303/307/308)
  # by re-GETting the Location header — the server serves batch zips via a 302 to a
  # signed DigitalOcean Spaces URL. build_http is rebuilt per iteration for the new
  # uri's host/port, so cross-host redirects (idempotent.io → Spaces) work.
  def download(url)
    original_url = url
    5.times do
      uri = URI.parse(url)
      response = execute("GET #{url}") { build_http(uri).request(Net::HTTP::Get.new(uri.request_uri)) }
      code = response.code.to_i
      case code
      when 200
        return response.body
      when 404, 410
        return nil
      when 301, 302, 303, 307, 308
        location = response['location']
        Util.exit_with_error("Redirect (#{code}) with no Location for #{url}") if location.nil? || location.empty?
        url = location
      else
        Util.exit_with_error("Failed to download #{url}: HTTP #{code}")
      end
    end
    Util.exit_with_error("Too many redirects downloading #{original_url}")
  end

  # Create an anonymous org and token (no auth sent).
  # POST /apibuilder/anonymous
  def anonymous_init
    uri = URI.parse("#{@base_uri}/apibuilder/anonymous")
    response = execute("POST /apibuilder/anonymous") do
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      build_http(uri).request(req)
    end
    handle_response(response, "POST /apibuilder/anonymous")
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

  # Runs one HTTP call, retrying transient transport failures and gateway
  # statuses with backoff, and returns the final response. Anything the app
  # itself answered (including 4xx/5xx that are not RETRYABLE_STATUSES) is
  # returned untouched for handle_response to interpret.
  #
  # Why retry rather than fail: the batch endpoints are slow enough (a ~150KB
  # spec payload, seconds on the wire) to be a real target for a dropped
  # connection, and by the time the connection dies the server has usually
  # already accepted the request. Aborting there discarded work the server had
  # done and dumped a Ruby backtrace on the user, whose only recourse was to
  # re-run the identical command by hand - which is exactly what this does,
  # only faster and without the stack trace.
  def execute(description)
    attempt = 0
    response = nil
    error = nil

    while attempt < MAX_ATTEMPTS
      attempt += 1
      error = nil

      begin
        response = yield
      rescue *RETRYABLE_ERRORS => e
        error = e
      end

      return response if error.nil? && !RETRYABLE_STATUSES.include?(response.code.to_i)
      break if attempt == MAX_ATTEMPTS

      delay = RETRY_BACKOFF_SECONDS[attempt - 1] || RETRY_BACKOFF_SECONDS.last
      reason = error ? "#{error.class}: #{error.message}" : "HTTP #{response.code}"
      $stderr.puts "==> WARNING: #{description} failed (#{reason}); retrying in #{delay}s (attempt #{attempt + 1} of #{MAX_ATTEMPTS})"
      sleep_for(delay)
    end

    return response if error.nil?

    Util.exit_with_error(connection_failure_message(description, error, attempt))
  end

  def connection_failure_message(description, error, attempts)
    case error
    when Errno::ECONNREFUSED, SocketError
      "Cannot connect to #{@base_uri} after #{attempts} attempts (#{error.message}). Is the server running?"
    else
      "#{description} failed after #{attempts} attempts: #{error.class}: #{error.message}\n" \
        "The connection to #{@base_uri} dropped mid-request. The server may still have accepted it - re-run the command to continue."
    end
  end

  # Seam for tests: they assert on the backoff schedule without waiting for it.
  def sleep_for(seconds)
    sleep(seconds)
  end

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
      message = extract_error_message(response.body)
      raise Error, "#{context}: HTTP #{code}\n#{message}"
    end
  end

  # Best-effort extraction of a human-readable error message from a server
  # response body. Handles JSON, Play's HTML error page (whose useful payload
  # lives inside <p id="detail" class="pre">...</p>), and falls back to raw text.
  def extract_error_message(body)
    return "(empty response)" if body.nil? || body.strip.empty?

    begin
      parsed = JSON.parse(body)
      msg = parsed.is_a?(Hash) ? (parsed["message"] || parsed["error"]) : nil
      return msg if msg
    rescue JSON::ParserError
      # fall through to HTML / text handling
    end

    if body =~ /<html/i
      detail = body[/<p[^>]*id=["']detail["'][^>]*>(.*?)<\/p>/im, 1]
      text = detail || body
      text = text.gsub(/<[^>]+>/, "")
      text = text.gsub("&quot;", '"').gsub("&lt;", "<").gsub("&gt;", ">").gsub("&amp;", "&").gsub("&nbsp;", " ")
      text = text.strip
      # Trim verbose Guice/Java stack-trace-ish noise but keep first ~40 lines
      lines = text.lines.map(&:rstrip).reject(&:empty?)
      summary = lines.first(40).join("\n")
      summary << "\n... (truncated; #{lines.size - 40} more lines)" if lines.size > 40
      return summary.empty? ? "(unparseable HTML error page)" : summary
    end

    body.strip
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
