require 'json'

# "Has this merge commit actually shipped?" — the one question a single-PR merge
# check cannot answer, and the whole reason `dev prs group` exists (ISS-758).
#
# A consumer regen merged against a producer that merged but has not DEPLOYED is
# the playbook-admin #760 failure: the frontend calls a field the running backend
# does not serve yet, the 404 is swallowed, and the page renders "No data". Merge
# state is visible to every check in the fleet; deploy state is not.
#
# ## What "deployed" means here, per repo class
#
# - a **deployable app** — what production is RUNNING, from the same probe
#   `dev deploy status` uses (`/_internal_/version` or the live k8s image tag).
#   Not the latest tag: "tagged but the deploy never ran" is precisely the state
#   this must not read as shipped.
# - **everything else** (schema repos, libraries, anything with no prod probe) —
#   the newest release tag. A migration ships with its repo's release, and a
#   library ships when it is published; neither has a version to ask.
#
# Then one question to GitHub: is the merge commit contained in that ref?
# `compare/<ref>...<sha>` answers `identical` or `behind` when it is.
#
# ## Unknown is a HOLD, never a pass
#
# Every failure path here returns nil — no probe, no tag, an unparseable
# response, `gh` missing or rate-limited. `Prs::Group` reads nil as "cannot tell"
# and holds the PR. The alternative fails open on exactly the case the module
# exists to catch.
module Prs
  module Deploy
    # Long enough for a cold prod probe, short enough that a wedged connection
    # cannot outlast a caller's patience. Same reasoning as
    # Agent::Github::TIMEOUT_SECONDS.
    TIMEOUT_SECONDS = 30

    OWNER = "mbryzek".freeze

    # `compare/BASE...HEAD` statuses meaning HEAD is already contained in BASE.
    # `behind` = the sha is an ancestor of the deployed ref; `identical` = it is
    # the deployed ref. `ahead` and `diverged` both mean not shipped.
    CONTAINED = %w[behind identical].freeze

    # A release tag we are willing to treat as "the newest release": leading
    # digits, dot-separated. Anything else in a repo's tag list — the
    # `explore_stuff_backup_snapshot` shape — is not a release and must not be
    # picked as one.
    RELEASE_TAG = /\A[vV]?\d+(\.\d+)*\z/

    module_function

    # A `deployed` lambda for `Prs::Group.build`, memoised per (repo, sha) so a
    # group of four consumers all waiting on one producer asks once.
    #
    # `live_version` is injected: the CLI passes the registry-backed prod probe,
    # and a test passes a hash. It returns the version string production is
    # running for a repo, or nil when that repo has no probe (which falls back to
    # the newest release tag).
    def oracle(live_version:, capture: method(:capture))
      cache = {}
      lambda do |repo, sha|
        cache.fetch([repo.to_s, sha.to_s]) do
          cache[[repo.to_s, sha.to_s]] = contains?(repo, sha, live_version: live_version, capture: capture)
        end
      end
    end

    # true / false / nil (unknown).
    def contains?(repo, sha, live_version:, capture: method(:capture))
      return nil if repo.to_s.empty? || sha.to_s.empty?
      ref = deployed_ref(repo, live_version: live_version, capture: capture)
      return nil if ref.to_s.empty?
      status = compare_status(repo, ref, sha, capture: capture)
      return nil if status.nil?
      CONTAINED.include?(status)
    end

    # What production is running, expressed as something GitHub can compare
    # against: the running version when there is a probe, else the newest release
    # tag.
    def deployed_ref(repo, live_version:, capture: method(:capture))
      running = live_version.call(bare(repo)).to_s.strip
      return running unless running.empty?
      latest_release_tag(repo, capture: capture)
    end

    def latest_release_tag(repo, capture: method(:capture))
      out = capture.call(["gh", "api", "repos/#{OWNER}/#{bare(repo)}/tags", "--paginate",
                          "--jq", ".[].name"])
      return nil if out.nil?
      out.split("\n").map(&:strip).select { |t| t.match?(RELEASE_TAG) }.max_by { |t| version_key(t) }
    end

    # Numeric, component-wise — so `0.19.13` beats `0.19.9`, which sorting the
    # strings does not.
    def version_key(tag) = tag.to_s.sub(/\A[vV]/, "").split(".").map(&:to_i)

    def compare_status(repo, ref, sha, capture: method(:capture))
      out = capture.call(["gh", "api", "repos/#{OWNER}/#{bare(repo)}/compare/#{ref}...#{sha}", "--jq", ".status"])
      return nil if out.nil?
      status = out.strip
      status.empty? ? nil : status
    end

    def bare(repo) = repo.to_s.split("/").last.to_s

    def capture(cmd)
      require 'agent/shell'
      # `:merge` rather than `:inherit`: a `gh api` 404 — comparing against a ref
      # that does not exist — is an expected answer here, not something to print
      # at whoever is reading the table. It lands in `output`, which is discarded
      # because the call failed.
      result = Agent::Shell.capture(*cmd, timeout: TIMEOUT_SECONDS, stderr: :merge)
      result.ok? ? result.output : nil
    rescue Errno::ENOENT
      nil
    end
  end
end
