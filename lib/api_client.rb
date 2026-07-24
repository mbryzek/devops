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

  # Each app (and tenant login) gets its own session file + session header.
  # Platform's session cookie is named `session_id`; acumen's is
  # `acumen_session_id`. `playbook` is not a deployable app (it is a tenant admin
  # surface on the platform host, so it is deliberately absent from ENDPOINTS)
  # but gets its own persisted session via `dev login --app playbook`, on the
  # platform `session_id` header.
  SESSION_CONFIG = {
    "platform" => { file: File.expand_path("~/.platform/devops"),         header: "session_id" },
    "acumen"   => { file: File.expand_path("~/.platform/devops_acumen"),  header: "acumen_session_id" },
    "playbook" => { file: File.expand_path("~/.platform/devops_playbook"), header: "session_id" },
  }.freeze

  # Prod and localhost are different servers with disjoint session stores, so a
  # session id from one is simply invalid on the other. Suffix the file so
  # logging in to one target never clobbers or gets misread as the other -
  # previously a single prod playbook session id would get silently replayed
  # against localhost and rejected with a generic "session expired" error.
  def self.session_file(app, use_localhost)
    cfg = SESSION_CONFIG.fetch(app) { raise "ApiClient: no session config for app=#{app.inspect} (known: #{SESSION_CONFIG.keys.inspect})" }
    use_localhost ? "#{cfg[:file]}_localhost" : cfg[:file]
  end

  def self.session_id_for(app, use_localhost:)
    file = session_file(app, use_localhost)
    return nil unless File.exist?(file)
    id = File.read(file).strip
    id.empty? ? nil : id
  end

  def self.write_session_id_for(app, id, use_localhost:)
    file = session_file(app, use_localhost)
    dir = File.dirname(file)
    FileUtils.mkdir_p(dir, mode: 0700)
    tmp = "#{file}.tmp.#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0600) { |f| f.write(id) }
    File.rename(tmp, file)
  end

  def self.clear_session_id_for(app, use_localhost:)
    file = session_file(app, use_localhost)
    File.delete(file) if File.exist?(file)
  end

  def self.endpoints(use_localhost:, app_filter: nil)
    list = app_filter ? ENDPOINTS.select { |e| e[:app] == app_filter.downcase } : ENDPOINTS
    list.map { |e| e.merge(active_url: use_localhost ? e[:localhost] : e[:url], use_localhost: use_localhost) }
  end

  # An endpoint for a tenant login that lives on the platform host but is not a
  # deployable app in ENDPOINTS (e.g. `playbook`). Carries the platform host but
  # the tenant's own `app` so request/session lookups use its SESSION_CONFIG.
  def self.tenant_endpoint(app, use_localhost:)
    platform = endpoints(use_localhost: use_localhost, app_filter: "platform").first
    { name: app.capitalize, app: app, active_url: platform[:active_url], use_localhost: use_localhost }
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

    use_localhost = endpoint.fetch(:use_localhost)
    login_cmd = "dev login#{endpoint[:app] == 'platform' ? '' : " --app #{endpoint[:app]}"}#{use_localhost ? ' --localhost' : ''}"

    req = klass.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    if auth_required
      cfg = SESSION_CONFIG.fetch(endpoint[:app])
      sid = session_id_for(endpoint[:app], use_localhost: use_localhost) or
        raise SessionExpired, "No session for #{endpoint[:app]}#{use_localhost ? ' (localhost)' : ''}. Run '#{login_cmd}'."
      req[cfg[:header]] = sid
    end
    req.body = body.is_a?(String) ? body : JSON.generate(body) if body

    res = http.request(req)
    code = res.code.to_i
    case code
    when 200..299
      res.body && !res.body.empty? ? JSON.parse(res.body) : nil
    when 401
      raise SessionExpired, "Session expired or invalid for #{endpoint[:app]}#{use_localhost ? ' (localhost)' : ''}. Run '#{login_cmd}'."
    else
      raise ApiError, "HTTP #{code} #{method.to_s.upcase} #{path}: #{res.body}"
    end
  end
end
