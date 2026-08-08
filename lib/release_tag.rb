require 'json'

# A repo's release tags, read from GitHub rather than from a checkout.
#
# `release` cuts an annotated tag (`git tag -a`, Tag.ask) and pushes it before it
# builds or deploys anything, so the newest tag and the moment it was cut are the
# release record every repo keeps — including the ones that ship nothing a
# machine can probe. This is the ONE place that knows how to read it: which tags
# count as releases, which of them is newest, and when it went out.
#
# Read over `gh api` on purpose. The two callers run where a checkout may not
# exist (`dev issues reconcile` on an agent runner) and where cluster access
# certainly does not (ISS-904), and every runner already has an authenticated
# `gh`.
#
# Every failure path answers nil — `gh` missing, unauthenticated, rate-limited, a
# repo with no tags, an unparseable response. Both callers read nil as "cannot
# tell" and hold, never as an answer.
module ReleaseTag
  # Long enough for a cold GitHub read, short enough that a wedged connection
  # cannot outlast a caller's patience. Same reasoning as
  # Agent::Github::TIMEOUT_SECONDS.
  TIMEOUT_SECONDS = 30

  OWNER = "mbryzek".freeze

  # A tag we are willing to treat as a release: leading digits, dot-separated.
  # Anything else in a repo's tag list — the `explore_stuff_backup_snapshot`
  # shape workers carries — is not a release and must not be picked as one.
  RELEASE_TAG = /\A[vV]?\d+(\.\d+)*\z/

  module_function

  # `owner/name`, from either form. A bare name is one of ours.
  def slug(repo)
    name = repo.to_s
    name.include?("/") ? name : "#{OWNER}/#{name}"
  end

  # Every release tag a repo has, or nil when the list could not be read.
  #
  # `nil` and `[]` are DIFFERENT ANSWERS and that is the whole reason this is
  # separate from `latest`, which collapses both to nil because neither gives it
  # a tag to return. A repo with no release tags at all is not an unknown: it is
  # a repo that does not release, and devops is the standing case — nothing
  # builds or ships it, the checkout at ~/code/devops IS the deployment, and
  # every runner fast-forwards it at the top of every tick. A caller deciding
  # "has this merge shipped" must read that as "there is no release to wait for"
  # rather than as "cannot tell", or it waits forever on evidence that will never
  # exist (ISS-1097).
  def tags(repo, capture: method(:capture))
    out = capture.call(["gh", "api", "repos/#{slug(repo)}/tags", "--paginate", "--jq", ".[].name"])
    return nil if out.nil?
    out.split("\n").map(&:strip).select { |t| t.match?(RELEASE_TAG) }
  end

  # The newest release tag in a repo, or nil.
  def latest(repo, capture: method(:capture))
    newest(tags(repo, capture: capture))
  end

  # The newest of an already-read tag list, or nil for an empty one.
  def newest(tags) = Array(tags).max_by { |t| version_key(t) }

  # Numeric, component-wise — so `0.19.13` beats `0.19.9`, which sorting the
  # strings does not.
  def version_key(tag) = tag.to_s.sub(/\A[vV]/, "").split(".").map(&:to_i)

  # When `tag` was CUT, as the ISO-8601 string GitHub returns, or nil.
  #
  # The tagger date, not the tagged commit's date: the commit is whatever was on
  # main when the release ran, so its timestamp is the last MERGE and not the
  # release. Reading it instead would make "released since the fix merged" false
  # for the very release that shipped the fix — the one comparison this exists to
  # answer (`dev issues reconcile`).
  #
  # A lightweight tag has no object of its own to date, so its commit is the
  # closest thing there is. Our releases are annotated; this is for the hand-made
  # tag that predates or bypasses `release`.
  def cut_at(repo, tag, capture: method(:capture))
    ref = api_json(["gh", "api", "repos/#{slug(repo)}/git/ref/tags/#{tag}"], capture: capture)
    object = ref && ref["object"]
    sha = object && object["sha"]
    return nil if sha.nil? || sha.to_s.empty?

    if object["type"] == "tag"
      annotated = api_json(["gh", "api", "repos/#{slug(repo)}/git/tags/#{sha}"], capture: capture)
      return annotated && annotated.dig("tagger", "date")
    end
    commit = api_json(["gh", "api", "repos/#{slug(repo)}/commits/#{sha}"], capture: capture)
    commit && commit.dig("commit", "committer", "date")
  end

  def api_json(cmd, capture: method(:capture))
    out = capture.call(cmd)
    return nil if out.nil? || out.strip.empty?
    JSON.parse(out)
  rescue JSON::ParserError
    nil
  end

  def capture(cmd)
    require 'agent/shell'
    # `:merge` rather than `:inherit`: a `gh api` 404 — a repo with no tags — is
    # an expected answer here, not something to print at whoever is reading a
    # reconcile report. It lands in `output`, which is discarded because the call
    # failed. Leaking a probe's stderr into that report is half of ISS-904.
    result = Agent::Shell.capture(*cmd, timeout: TIMEOUT_SECONDS, stderr: :merge)
    result.ok? ? result.output : nil
  rescue Errno::ENOENT
    nil
  end
end
