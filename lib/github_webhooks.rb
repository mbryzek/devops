require 'json'
require 'open3'
require 'securerandom'
require 'uri'

# The GitHub merge webhook: provisioning it, and noticing when it is not there.
#
# platform ships `POST /webhooks/github` (ISS-132) — a merged PR titled
# `ISS-<n>: ...` is what moves that issue out of `claimed`. The endpoint is only
# half the mechanism. The other half is telling GitHub to call it, once per
# repository, because `mbryzek` is a USER account: the "org-level webhook" that
# design assumed does not exist to configure.
#
# That half was never done. For a month the documented primary mover of
# `claimed -> fixed` moved zero issues, and nothing said so, because a webhook
# that was never configured fails by doing nothing — which reads exactly like a
# quiet queue (ISS-537).
#
# So the deliverable is not "add the hooks once", which would rot the same way.
# It is a command that can answer what the hooks ARE, on demand and without a
# credential beyond `gh`, and put them back when they drift. Everything above
# the `--- io ---` line is pure and tested directly; everything below it shells
# out to `gh`.
module GithubWebhooks
  class Error < StandardError; end

  OWNER = "mbryzek".freeze

  # The platform's public load balancer — `platform-lb` terminates TLS for
  # idempotent.io (devops/k8s/apps/platform.pkl) — plus the route itself
  # (platform/api/conf/manual.routes).
  DEFAULT_URL = "https://idempotent.io/webhooks/github".freeze

  # A hook is ours if it delivers HERE, whatever the host. Matching on the path
  # rather than the whole URL is what makes a host change a PATCH of the hook
  # that already exists instead of a second hook shouting at an address nobody
  # is listening on.
  PATH = "/webhooks/github".freeze

  # `pull_request` and nothing else. The processor acts on merged pull requests
  # only, so every other event is a delivery the platform persists, queues a
  # task for, and discards. (Reviewable's hook on the same repos subscribes to
  # `*`; that is its design, not a precedent for this one.)
  EVENTS = %w[pull_request].freeze

  # Where the shared HMAC secret lives, and the config key it feeds
  # (`github.webhook.secret` in platform's base.conf). One value: GitHub signs
  # with it and `GithubWebhookParsers.verifySignature` verifies against it, so a
  # hook configured with a different string is a hook whose every delivery is
  # rejected.
  SECRET_KEY = "GITHUB_WEBHOOK_SECRET".freeze
  SECRET_APP = "platform".freeze
  SECRET_ENVIRONMENT = "production".freeze

  module_function

  # ---- pure ----

  # One repository's answer. `status` is :ok, :drifted, :absent or :unreadable,
  # and `problems` is empty only when :ok.
  State = Struct.new(:repo, :hook_id, :status, :problems, keyword_init: true) do
    def ok? = status == :ok
    def absent? = status == :absent
    def drifted? = status == :drifted
    def unreadable? = status == :unreadable
    def summary = problems.join("; ")
  end

  def unreadable(repo, message)
    State.new(repo: repo, status: :unreadable, problems: [message])
  end

  def hook_path(hook)
    URI.parse(hook.dig("config", "url").to_s).path
  rescue URI::InvalidURIError
    nil
  end

  def ours?(hook, url)
    hook.dig("config", "url").to_s == url || hook_path(hook) == PATH
  end

  # What is wrong with `repo`'s merge webhook, given the hooks GitHub reports.
  #
  # Every check here is a way the hook can exist and still deliver nothing
  # useful, which is the failure mode worth naming: "a hook is present" was
  # never the question.
  def evaluate(repo:, hooks:, url: DEFAULT_URL)
    mine = Array(hooks).select { |h| ours?(h, url) }
    return State.new(repo: repo, status: :absent, problems: ["no webhook delivers to #{url}"]) if mine.empty?

    hook = mine.first
    problems = []
    # Two hooks on the same path deliver every merge twice. The processor is
    # idempotent so nothing breaks, but it is drift, and a `sync` that only ever
    # looked at the first one would repair it forever without noticing.
    problems << "#{mine.length} hooks deliver to the platform (want 1)" if mine.length > 1
    actual_url = hook.dig("config", "url").to_s
    problems << "delivers to #{actual_url}, not #{url}" unless actual_url == url
    problems << "disabled" unless hook["active"]

    events = Array(hook["events"]).sort
    problems << "subscribes to #{events.join(', ')} (want #{EVENTS.join(', ')})" unless events == EVENTS.sort

    content_type = hook.dig("config", "content_type").to_s
    problems << "content_type is #{content_type.empty? ? 'unset' : content_type} (want json)" unless content_type == "json"

    # GitHub masks a configured secret as "********" and omits the key entirely
    # when there is none. Absent here is the quiet catastrophe: deliveries leave
    # GitHub, arrive, and are rejected unsigned at the HMAC check.
    problems << "no signing secret — deliveries would fail the HMAC check" if hook.dig("config", "secret").to_s.empty?
    problems << "insecure_ssl is on" if hook.dig("config", "insecure_ssl").to_s == "1"

    failure = delivery_failure(hook["last_response"])
    problems << failure if failure

    State.new(repo: repo, hook_id: hook["id"],
              status: problems.empty? ? :ok : :drifted, problems: problems)
  end

  # GitHub records the last delivery's HTTP result on the hook object itself,
  # which is the only credential-free way to answer "is it actually working" —
  # rollout step 3, "confirm a real merge lands", without waiting for a merge.
  # A nil code is a hook that has never fired, which is not a fault.
  def delivery_failure(last_response)
    return nil if last_response.nil?
    code = last_response["code"]
    return nil if code.nil?
    return nil if (200..299).cover?(code.to_i)
    detail = last_response["message"].to_s
    "last delivery failed: #{code} #{last_response['status']}#{detail.empty? ? '' : " (#{detail})"}"
  end

  def config(url:, secret:)
    { "url" => url, "content_type" => "json", "insecure_ssl" => "0", "secret" => secret }
  end

  def create_payload(url:, secret:)
    { "name" => "web", "active" => true, "events" => EVENTS, "config" => config(url: url, secret: secret) }
  end

  # No `name` on the update path: GitHub treats it as read-only there, and the
  # config is replaced wholesale rather than merged, so the secret has to be
  # resent or a repair would strip it.
  def update_payload(url:, secret:)
    { "active" => true, "events" => EVENTS, "config" => config(url: url, secret: secret) }
  end

  # A candidate value for a human to paste into the env file. Suggested, never
  # written: this command does not put secrets into the git-crypt'd repo.
  def suggested_secret = SecureRandom.hex(32)

  # ---- io ----

  def capture(cmd, stdin: nil)
    out, err, status = Open3.capture3(*cmd, stdin_data: stdin.to_s)
    [status.success?, status.success? ? out : err]
  rescue Errno::ENOENT
    [false, "#{cmd.first} is not on PATH"]
  end

  # Every non-archived source repository under the owner.
  #
  # In scope by default, deliberately: forks and archives never ship a fix, but
  # anything else might, and a repo left off the list is a repo whose merges
  # silently do not move their issue. That omission IS this bug — narrowing the
  # set is how it would come back.
  def repos(owner: OWNER, limit: 200)
    ok, out = capture(["gh", "repo", "list", owner, "--no-archived", "--source",
                       "--limit", limit.to_s, "--json", "name", "--jq", ".[].name"])
    raise Error, "could not list #{owner}'s repositories: #{out.strip}" unless ok
    names = out.split("\n").map(&:strip).reject(&:empty?).sort
    # A truncated list is the one failure this command must never have: the repos
    # past the cut would report as fine by never being asked, which is the exact
    # shape of "configured on no repo and nothing said so".
    if names.length >= limit
      raise Error, "#{owner} has at least #{limit} repositories and the listing was capped there — " \
                   "raise GithubWebhooks.repos' limit rather than provisioning a truncated list"
    end
    names
  end

  def hooks(repo)
    ok, out = capture(["gh", "api", "/repos/#{repo}/hooks"])
    raise Error, "could not read #{repo}'s webhooks: #{out.strip}" unless ok
    JSON.parse(out)
  rescue JSON::ParserError => e
    raise Error, "could not parse #{repo}'s webhooks: #{e.message}"
  end

  def create(repo, url:, secret:)
    write(["gh", "api", "--method", "POST", "/repos/#{repo}/hooks", "--input", "-"],
          create_payload(url: url, secret: secret), repo)
  end

  def update(repo, hook_id, url:, secret:)
    write(["gh", "api", "--method", "PATCH", "/repos/#{repo}/hooks/#{hook_id}", "--input", "-"],
          update_payload(url: url, secret: secret), repo)
  end

  def write(cmd, payload, repo)
    ok, out = capture(cmd, stdin: JSON.generate(payload))
    raise Error, "#{repo}: #{out.strip}" unless ok
    true
  end

  # [:present, value] / [:missing, nil] / [:locked, nil]. Never unlocks
  # git-crypt to answer — see EnvironmentVariables.lookup.
  def secret
    EnvironmentVariables.lookup(SECRET_APP, SECRET_ENVIRONMENT, SECRET_KEY)
  end

  def secret_file = EnvironmentVariables.file_path(SECRET_APP, SECRET_ENVIRONMENT)
end
