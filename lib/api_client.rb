require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

class SessionExpired < StandardError; end

# `code` carries the HTTP status, because several callers have to BRANCH on it
# rather than just report it: the agent dispatcher treats 429 on a claim as
# "fleet daily cap reached, back off" and 409 on a lease heartbeat as "this
# lease is gone, kill the job". Parsing the status back out of the message would
# be the same information one layer less reliably.
class ApiError < StandardError
  attr_reader :code

  def initialize(msg = nil, code: nil)
    super(msg)
    @code = code
  end
end

class ApiClient
  ENDPOINTS = [
    { name: "Acumen",   url: "https://api.trueacumen.com", localhost: "http://localhost:9200", app: "acumen" },
    { name: "Platform", url: "https://idempotent.io",      localhost: "http://localhost:9300", app: "platform" }
  ].freeze

  # Each app (and tenant login) gets its own session file + session header.
  # Platform's session cookie is named `session_id`; acumen's is
  # `acumen_session_id`. `playbook` is not a deployable app (it is a tenant admin
  # surface on the platform host, so it is deliberately absent from ENDPOINTS)
  # but gets its own persisted session via `dev auth login --app playbook`, on the
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

  # The AI actor's own API token ("Otto AI", user id `ai`). Kept beside the session files, one per
  # target, since a prod token is meaningless against localhost.
  AI_TOKEN_FILE = File.expand_path("~/.platform/devops_ai").freeze

  def self.ai_token_file(use_localhost)
    use_localhost ? "#{AI_TOKEN_FILE}_localhost" : AI_TOKEN_FILE
  end

  def self.write_ai_token(token, use_localhost:)
    file = ai_token_file(use_localhost)
    FileUtils.mkdir_p(File.dirname(file), mode: 0700)
    tmp = "#{file}.tmp.#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0600) { |f| f.write(token) }
    File.rename(tmp, file)
  end

  def self.clear_ai_token(use_localhost:)
    file = ai_token_file(use_localhost)
    File.delete(file) if File.exist?(file)
  end

  def self.ai_token(use_localhost:)
    from_env = ENV["PLATFORM_AI_API_TOKEN"].to_s.strip
    return from_env unless from_env.empty?

    file = ai_token_file(use_localhost)
    return nil unless File.exist?(file)
    token = File.read(file).strip
    token.empty? ? nil : token
  end

  # Whether this process is a Claude session rather than Mike at a keyboard. Only the AI borrows
  # the AI's identity: a human running the same command stays themselves, which is the whole point
  # of the separate account.
  def self.ai_session?
    !ENV["CLAUDECODE"].to_s.strip.empty?
  end

  # The credential this process should present for `app`: the AI's token inside a Claude session
  # (when one has been stored), otherwise the logged-in human's session id.
  #
  # Only the platform host honours these tokens, and only `platform`/`playbook` ride on it; acumen
  # keeps its own session. A Claude session with no stored token falls back to the human session —
  # the same behaviour as before this existed, so nothing breaks before the token is provisioned.
  def self.auth_header_for(app, use_localhost:)
    if ai_session? && app != "acumen"
      token = ai_token(use_localhost: use_localhost)
      return ["Authorization", "Basic #{Base64.strict_encode64("#{token}:")}"] if token
    end
    nil
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

  # `as_token` presents a specific API token as HTTP Basic instead of resolving a credential from
  # disk. Provisioning uses it to prove the token it just minted actually authenticates, before
  # reporting success.
  def self.request(endpoint, method, path, body: nil, auth_required: true, as_token: nil)
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
    login_cmd = "dev auth login#{endpoint[:app] == 'platform' ? '' : " --app #{endpoint[:app]}"}#{use_localhost ? ' --localhost' : ''}"

    req = klass.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    if auth_required && as_token
      req["Authorization"] = "Basic #{Base64.strict_encode64("#{as_token}:")}"
    elsif auth_required
      header, value = auth_header_for(endpoint[:app], use_localhost: use_localhost)
      if header
        req[header] = value
      else
        cfg = SESSION_CONFIG.fetch(endpoint[:app])
        sid = session_id_for(endpoint[:app], use_localhost: use_localhost) or
          raise SessionExpired, "No session for #{endpoint[:app]}#{use_localhost ? ' (localhost)' : ''}. Run '#{login_cmd}'."
        req[cfg[:header]] = sid
      end
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
      raise ApiError.new("HTTP #{code} #{method.to_s.upcase} #{path}: #{res.body}", code: code)
    end
  end
end
