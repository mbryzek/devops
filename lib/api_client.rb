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

  SESSION_FILE = File.expand_path("~/.platform/devops")

  def self.session_id
    return nil unless File.exist?(SESSION_FILE)
    id = File.read(SESSION_FILE).strip
    id.empty? ? nil : id
  end

  def self.write_session_id(id)
    dir = File.dirname(SESSION_FILE)
    FileUtils.mkdir_p(dir, mode: 0700)
    tmp = "#{SESSION_FILE}.tmp.#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0600) { |f| f.write(id) }
    File.rename(tmp, SESSION_FILE)
  end

  def self.clear_session_id
    File.delete(SESSION_FILE) if File.exist?(SESSION_FILE)
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
      sid = session_id or raise SessionExpired, "No session. Run 'dev login'."
      req["session_id"] = sid
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
