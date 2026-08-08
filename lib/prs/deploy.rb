require 'json'
require 'release_tag'

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
      case state(repo, sha, live_version: live_version, capture: capture)
      when :shipped then true
      when :unshipped then false
      end
    end

    # Where a merge commit has got to, as four answers rather than three:
    #
    #   :shipped      — contained in what production is running (or, with no
    #                   probe, in the newest release tag)
    #   :unshipped    — demonstrably not contained in it
    #   :unreleasable — the repo publishes no releases AT ALL, so there is no
    #                   release for it to be contained in
    #   :unknown      — every read that did not answer
    #
    # `contains?` folds the last two together, because both mean "I cannot say
    # this shipped" and holding is the only safe act for a merge check. The
    # dependency gate (Agent::Dependency, ISS-1097) needs them apart: a repo that
    # never releases — devops, where merging IS deploying — must not park a
    # dependent issue forever waiting for a tag nobody is ever going to cut.
    def state(repo, sha, live_version:, capture: method(:capture))
      return :unknown if repo.to_s.empty? || sha.to_s.empty?
      ref = deployed_ref(repo, live_version: live_version, capture: capture)
      return ref if ref.is_a?(Symbol)
      status = compare_status(repo, ref, sha, capture: capture)
      return :unknown if status.nil?
      CONTAINED.include?(status) ? :shipped : :unshipped
    end

    # What production is running, expressed as something GitHub can compare
    # against: the running version when there is a probe, else the newest release
    # tag — or the SYMBOL saying which kind of nothing there is instead, since
    # "this repo has no releases" and "this repo could not be read" are opposite
    # answers to every caller above.
    #
    # ReleaseTag is the one definition of "this repo's releases", shared with the
    # version probe `dev issues reconcile` reads for an app with no HTTP endpoint
    # (ISS-904). Two notions of which tag is the release would disagree exactly
    # where it matters — on the repos with nothing else to ask.
    def deployed_ref(repo, live_version:, capture: method(:capture))
      running = live_version.call(bare(repo)).to_s.strip
      return running unless running.empty?
      tags = ReleaseTag.tags(bare(repo), capture: capture)
      return :unknown if tags.nil?
      ReleaseTag.newest(tags) || :unreleasable
    end

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
