require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

class SessionExpired < StandardError; end

# `code` carries the HTTP status, because several callers have to BRANCH on it
# rather than just report it: the agent dispatcher treats 422 on a claim as "the
# platform does not know this runner, re-register" and 409 on a lease heartbeat
# as "this lease is gone, kill the job". Parsing the status back out of the
# message would be the same information one layer less reliably.
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

  # The AI actor. Claude sessions authenticate as "Otto AI" (user id `ai`) with an API token instead
  # of borrowing Mike's session, so anything the AI writes is attributed to the AI.
  #
  # These live here, beside the token file and `ai_session?`, rather than in `bin/dev` where they
  # started: `unauthorized_message` has to name the identity it authenticated as, and a top-level
  # constant in `bin/dev` only resolves in processes that loaded `bin/dev` -- every other entry point
  # requiring this library would have raised NameError on the error path, which is the one path that
  # never gets exercised before it ships.
  AI_USER_ID = "ai".freeze
  AI_USER_LABEL = "Otto AI".freeze

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

  # Whether `request` can authenticate as `app` at all — either arm of `auth_header_for`'s fallback:
  # the AI's token inside a Claude session, or a logged-in human's session id. For callers that gate
  # optional work on having a credential, rather than letting it 401 mid-way.
  #
  # It exists because asking for only the session half is a live bug that reads as correct. A Claude
  # session never has a session file, so `session_id_for(...).nil?` is TRUE for the identity that is
  # perfectly well authenticated — which is how `dev changelog build` came to skip ISS enrichment on
  # every agent-driven release, quietly dropping the issue links from notes it went on to write
  # anyway (ISS-736).
  def self.credential_for?(app, use_localhost:)
    return true unless auth_header_for(app, use_localhost: use_localhost).nil?
    !session_id_for(app, use_localhost: use_localhost).nil?
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
    # Which credential we actually presented. A 401 means something different for each, and only
    # the caller knows which one went out -- see `unauthorized_message`.
    credential = :none
    if auth_required && as_token
      req["Authorization"] = "Basic #{Base64.strict_encode64("#{as_token}:")}"
      credential = :explicit_token
    elsif auth_required
      header, value = auth_header_for(endpoint[:app], use_localhost: use_localhost)
      if header
        req[header] = value
        credential = :ai_token
      else
        cfg = SESSION_CONFIG.fetch(endpoint[:app])
        sid = session_id_for(endpoint[:app], use_localhost: use_localhost) or
          raise SessionExpired, "No session for #{endpoint[:app]}#{use_localhost ? ' (localhost)' : ''}. Run '#{login_cmd}'."
        req[cfg[:header]] = sid
        credential = :session
      end
    end
    req.body = body.is_a?(String) ? body : JSON.generate(body) if body

    res = http.request(req)
    code = res.code.to_i
    case code
    when 200..299
      res.body && !res.body.empty? ? JSON.parse(res.body) : nil
    when 401
      raise SessionExpired, unauthorized_message(
        credential: credential, endpoint: endpoint, use_localhost: use_localhost,
        login_cmd: login_cmd, body: res.body
      )
    else
      raise ApiError.new("HTTP #{code} #{method.to_s.upcase} #{path}: #{res.body}", code: code)
    end
  end

  # What a 401 means depends on the credential that went out, and the server says which of the two
  # kinds it is -- so both go into the message.
  #
  # This used to report "Session expired or invalid ... Run 'dev auth login'" for every 401 and drop
  # the response body on the floor. That is what kept ISS-474 invisible: an autonomous session
  # authenticates as Otto AI with an API token, never a session, so it was being told to run an
  # interactive login it has no terminal for, about a credential it was not using, when the server
  # had plainly said `User ai does not belong to platform` -- an authorization failure, not an
  # expired one. `dev queries top` and `dev invariants check` both failed this way for months and
  # read as a routine auth hiccup.
  #
  # No attempt is made to classify authn-vs-authz by pattern-matching the server's text. The body is
  # quoted verbatim and the remedy is chosen from the credential, which we know for certain; a
  # brittle string match on messages the platform is free to reword would be a worse guess than the
  # server's own words.
  def self.unauthorized_message(credential:, endpoint:, use_localhost:, login_cmd:, body:)
    target = "#{endpoint[:app]}#{use_localhost ? ' (localhost)' : ''}"
    said = server_message(body)
    remedy =
      case credential
      when :ai_token
        "This process authenticates as #{AI_USER_LABEL} (user `#{AI_USER_ID}`) with the API token in " \
          "#{ai_token_file(use_localhost)}, not with a session, so `#{login_cmd}` is not the fix and there is " \
          "nobody to run it. Either the endpoint does not admit the AI identity (an authorization failure -- " \
          "the server's message above says which), or the token was revoked and a human must re-run " \
          "`dev auth ai provision --rotate#{use_localhost ? ' --localhost' : ''}`."
      when :explicit_token
        "The API token presented for this call was rejected."
      when :session
        "Session expired or invalid. Run '#{login_cmd}'."
      else
        "The request was sent with no credential."
      end
    ["HTTP 401 for #{target}", said && "server said: #{said}", remedy].compact.join(" -- ")
  end

  # The `message` out of the platform's error envelope, e.g.
  # `{"discriminator":"unauthorized","message":"User ai does not belong to platform"}`. Falls back to
  # the raw body for anything that is not that shape (a proxy's HTML 401, say), and to nil for an
  # empty one, so the caller can omit the clause entirely rather than print "server said: ".
  def self.server_message(body)
    text = body.to_s.strip
    return nil if text.empty?

    parsed = begin
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
    message = parsed.is_a?(Hash) ? parsed["message"].to_s.strip : ""
    message.empty? ? text : message
  end
end
