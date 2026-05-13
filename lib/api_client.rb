require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

class SessionExpired < StandardError; end
class ApiError < StandardError; end

class ApiClient
  ENDPOINTS = [
    { name: "Acumen",   url: "https://api.trueacumen.com", localhost: "http://localhost:9200", app: "acumen" },
    { name: "Platform", url: "https://idempotent.io",      localhost: "http://localhost:9300", app: "platform" }
  ].freeze

  # Each app gets its own session file + session header. Platform's session
  # cookie is named `session_id`; acumen's is `acumen_session_id`.
  SESSION_CONFIG = {
    "platform" => { file: File.expand_path("~/.platform/devops"),        header: "session_id" },
    "acumen"   => { file: File.expand_path("~/.platform/devops_acumen"), header: "acumen_session_id" },
  }.freeze

  def self.session_id_for(app)
    cfg = SESSION_CONFIG.fetch(app) { raise "ApiClient: no session config for app=#{app.inspect} (known: #{SESSION_CONFIG.keys.inspect})" }
    return nil unless File.exist?(cfg[:file])
    id = File.read(cfg[:file]).strip
    id.empty? ? nil : id
  end

  def self.write_session_id_for(app, id)
    cfg = SESSION_CONFIG.fetch(app) { raise "ApiClient: no session config for app=#{app.inspect} (known: #{SESSION_CONFIG.keys.inspect})" }
    dir = File.dirname(cfg[:file])
    FileUtils.mkdir_p(dir, mode: 0700)
    tmp = "#{cfg[:file]}.tmp.#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0600) { |f| f.write(id) }
    File.rename(tmp, cfg[:file])
  end

  def self.clear_session_id_for(app)
    cfg = SESSION_CONFIG.fetch(app) { raise "ApiClient: no session config for app=#{app.inspect} (known: #{SESSION_CONFIG.keys.inspect})" }
    File.delete(cfg[:file]) if File.exist?(cfg[:file])
  end

  def self.endpoints(use_localhost:, app_filter: nil)
    list = app_filter ? ENDPOINTS.select { |e| e[:app] == app_filter.downcase } : ENDPOINTS
    list.map { |e| e.merge(active_url: use_localhost ? e[:localhost] : e[:url]) }
  end

  def self.request(endpoint, method, path, body: nil, auth_required: true)
    uri = URI.parse("#{endpoint[:active_url]}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    klass = {
      get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put,
      patch: Net::HTTP::Patch, delete: Net::HTTP::Delete
    }.fetch(method.to_sym)

    req = klass.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    if auth_required
      cfg = SESSION_CONFIG.fetch(endpoint[:app])
      sid = session_id_for(endpoint[:app]) or
        raise SessionExpired, "No session for #{endpoint[:app]}. Run 'dev login'."
      req[cfg[:header]] = sid
    end
    req.body = body.is_a?(String) ? body : JSON.generate(body) if body

    res = http.request(req)
    code = res.code.to_i
    case code
    when 200..299
      res.body && !res.body.empty? ? JSON.parse(res.body) : nil
    when 401
      raise SessionExpired, "Session expired or invalid. Run 'dev login'."
    else
      raise ApiError, "HTTP #{code} #{method.to_s.upcase} #{path}: #{res.body}"
    end
  end
end
