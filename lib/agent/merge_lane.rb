require 'json'
require 'agent/github'
require 'agent/shell'

# The per-repo merge lane (ISS-754). ONE pull request per repo at a time, merged
# only after CI has passed **on the exact commit that will land**, and only with
# an `auto_approved` from the autonomy ledger.
#
# WHY A LANE AND NOT AUTO-MERGE. Two PRs each green against `main@X` can be
# broken in combination — A renames a method B calls, and neither PR was ever
# wrong. Squash-merge makes it worse: B's green was measured against a commit
# that no longer exists after A lands. So a green that predates the current tip
# of `main` proves nothing about what is about to be merged, and the lane's whole
# job is to refuse it.
#
# The two invariants that make "verified in the state it lands in" true, both
# enforced in `verdict` and both re-checked immediately before the merge:
#
#   FRESH   the `ci` check ran on `headRefOid` — the very commit `gh pr merge
#           --squash` will replay onto main. A check attached to an earlier push
#           is `:ci_stale`, not a pass.
#   AHEAD   `head` contains the current tip of `main` (`compare/main...head` is
#           `ahead` or `identical`). A PR that does not is `:needs_rebase`, and
#           rebasing is what re-triggers CI at the new base.
#
# Together those say: the tree CI ran on is main-plus-this-PR, and nothing has
# moved since. That is a merge queue, built out of two API reads instead of a
# ruleset — GitHub's own merge queue needs branch protection, which this account
# is deliberately not adopting (ISS-755).
#
# WHY THIS IS CODE AND NOT PLAYBOOK PROSE. Nothing at the GitHub layer enforces
# any of it: with no branch protection, `gh pr merge` on a red PR succeeds. The
# lane is the only merger, so the lane is the only enforcement — and every skip
# the `pr-auto-merge` playbook accumulated (never devops, never a draft, never a
# PR with a review in flight) was added only after the loop nearly merged
# something it should not have (ISS-660, ISS-663). A list like that has no
# natural end while it stays advisory. Here it is a `case` with a test per arm.
#
# WHAT IS DELIBERATELY LEFT TO THE SESSION. `verdict` never guesses about work
# that needs judgment; it names it and stops:
#
#   :conflicts     resolving a merge conflict is authorship, not bookkeeping.
#   :ci_failed     none of these repos had CI until ISS-754, so `main` itself can
#                  be red. Whether a red suite is this PR's fault or was already
#                  red on main is a question only something that can read the
#                  failure can answer.
#   :needs_rebase  the rebase itself is a push, and a push can conflict.
#
# NOTHING HERE MERGES EXCEPT `merge!`, and `merge!` is unreachable without a
# `:mergeable` verdict computed from a FRESH read plus a ledger approval — see
# `cmd_agent_merge_lane_merge` in bin/dev, which is the only caller.
module Agent
  module MergeLane
    # Repos whose merge IS a deploy, and which therefore never enter a lane.
    #
    # devops is the standing case and the reason this list exists rather than a
    # comment: every runner fast-forwards its `~/code/devops` checkout at the top
    # of every tick, 30 seconds apart, so a merged commit is running fleet-wide
    # before anyone could look at it — on the code that runs the fleet (ISS-660).
    # `gh pr revert` only OPENS a revert PR, so there is no undo either.
    #
    # Checked FIRST in `verdict`, and again in `merge!`, because the only
    # reliable way never to merge something is never to reach the merge call.
    SELF_DEPLOYING_REPOS = %w[devops].freeze

    # The ONE check name the lane reads, per ISS-763's check contract: shard the
    # work however is convenient, then have a single gate job that depends on
    # every shard and reports the aggregate. The lane reads one rollup entry and
    # stays ignorant of the sharding scheme, so re-sharding a workflow never
    # needs a change here.
    CI_CHECK = "ci".freeze

    # Reviewable posts this context once a human opens the PR there. It is NOT a
    # test result and must never be conflated with one (ISS-763): a pending
    # review means Mike is mid-pass over the diff, and merging out from under him
    # destroys the pass rather than the code — reverting gives back the diff, not
    # the eleven files he had already read (ISS-663).
    REVIEW_CONTEXT = "code-review/reviewable".freeze

    OWNER = "mbryzek".freeze

    # THE PERMISSION BOUNDARY: the repos the lane may act on at all.
    #
    # Deliberately a list, and deliberately NOT derived from `gh repo list`. The
    # `pr_auto_merge` envelope has `repos: unrestricted`, and "unrestricted" means
    # the ledger will not narrow the work list — it is not an instruction to walk
    # every repo under the account. A loop that chose its own boundary is how a
    # devops PR ended up in front of one in the first place (ISS-660).
    #
    # This is the playbook's §4 verify table minus the self-deploying repos, and
    # it is a CEILING rather than a work list: a repo is only a candidate if it is
    # here AND its PRs carry a `ci` check (see NO_CI). Adding a repo here is a
    # deliberate act; adding a `.github/workflows/ci.yml` is what actually enrols
    # it.
    LANE_REPOS = %w[
      playbook-admin
      playbook-app
      playbook-www
      michaelbryzek
      lakeviewsummit-ui
      apibuilder-ui
      rallyd
      hackathon
      acumen-ui
      hoa-frontend
      platform
      acumen
    ].freeze

    # THE ENROLMENT RULE, and it is deliberately not a list.
    #
    # A repo is in the lane exactly when its PRs carry a `ci` check. There is no
    # second registry of "repos that have CI" to drift out of step with the
    # `.github/workflows` that actually exist: adding a workflow enrols the repo,
    # deleting one withdraws it, and a repo that never had CI reports
    # `:no_ci_verdict` on every PR and merges nothing.
    #
    # That is a real narrowing versus the playbook loop this replaces, which ran
    # the suite in-session and could therefore act on any repo. It is the correct
    # narrowing: a suite run by the party asking for permission is exactly the
    # unverified assertion the ledger's own spec says it does not defend against.
    NO_CI = :no_ci_verdict

    # What the caller should DO about a verdict. The playbook loops on these
    # rather than on prose, which is the point of returning them.
    #
    #   :merge   act now — this is the head of the line
    #   :rebase  work: rebase onto main and push, which re-triggers CI
    #   :resolve work: a human-grade merge conflict
    #   :wait    CI is in flight; come back
    #   :park    a red suite, which needs a judgment about WHOSE fault it is
    #   :defer   a human is mid-review; leave it for them and NAME it
    #   :skip    not a candidate at all, and will not become one on its own
    ACTIONS = %i[merge rebase resolve wait park defer skip].freeze

    # code    — a stable symbol, safe to branch on
    # action  — one of ACTIONS
    # message — one line, written for a human reading the run summary
    Verdict = Struct.new(:code, :action, :message, keyword_init: true) do
      def mergeable? = code == :mergeable
      def to_h = { "code" => code.to_s, "action" => action.to_s, "message" => message }
    end

    # One PR plus everything computed about it. `review_in_flight` is carried
    # SEPARATELY from the verdict on purpose: the playbook has to name every PR
    # it deferred for a review, individually, and a PR that is also red would
    # otherwise lose that fact to the higher-priority verdict.
    Candidate = Struct.new(:repo, :number, :title, :url, :head_sha, :created_at,
                           :verdict, :review_in_flight, :diff_lines, :changed_paths,
                           keyword_init: true) do
      def mergeable? = verdict.mergeable?
      def label = "#{repo}##{number}"

      def to_h
        {
          "repo" => repo, "number" => number, "title" => title, "url" => url,
          "head_sha" => head_sha, "created_at" => created_at,
          "review_in_flight" => !!review_in_flight,
          "diff_lines" => diff_lines, "changed_paths" => changed_paths,
        }.compact.merge(verdict.to_h)
      end
    end

    # The fields `gh pr list` / `gh pr view` must return for `verdict` to have
    # anything to decide from. Kept as one constant so the list view and the
    # single-PR re-read cannot drift into asking for different facts — a re-read
    # missing `statusCheckRollup` would silently re-verdict every PR as
    # `:no_ci_verdict` right before the merge.
    PR_FIELDS = %w[number title url state isDraft isCrossRepository createdAt
                   headRefName headRefOid baseRefName mergeStateStatus
                   statusCheckRollup additions deletions files].freeze

    # `gh pr view --json files` is the only field here that is expensive on a
    # large PR, and it is the one the reversibility classification cannot do
    # without. The list view drops it (see LIST_FIELDS) and the single-PR read
    # keeps it.
    LIST_FIELDS = (PR_FIELDS - %w[files additions deletions]).freeze

    # Same reasoning as Agent::Github::TIMEOUT_SECONDS, one level up: these calls
    # run inside a session that holds a lease, and an unbounded `gh` against a
    # stalled connection is a hang rather than a failure.
    TIMEOUT_SECONDS = 60

    # The merge itself gets longer. GitHub takes its time squashing a large PR,
    # and a merge that times out CLIENT-side may still have happened — which is
    # the one outcome this whole module is built to be able to report honestly.
    MERGE_TIMEOUT_SECONDS = 180

    module_function

    # `playbook-admin` and `mbryzek/playbook-admin` both name the same repo, and
    # every caller here mixes them: LANE_REPOS is bare names, `gh --repo` wants
    # the slug, and a session typing the command by hand will use either.
    def qualify(repo)
      name = repo.to_s.strip
      name.include?("/") ? name : "#{OWNER}/#{name}"
    end

    def bare(repo) = repo.to_s.split("/").last.to_s

    # Is this repo inside the permission boundary? Asked of the BARE name, so a
    # slug under a different owner (`someoneelse/platform`) is not smuggled in by
    # a repo that happens to share a name.
    def in_lane?(repo)
      slug = repo.to_s.include?("/") ? repo.to_s : qualify(repo)
      slug.split("/").first == OWNER && LANE_REPOS.include?(bare(slug))
    end

    # ---------------- reads ----------------

    def capture(cmd)
      result = Agent::Shell.capture(*cmd, timeout: TIMEOUT_SECONDS)
      result.ok? ? result.output : nil
    rescue Errno::ENOENT
      nil
    end

    # Every open PR in one repo, oldest first — which IS the lane order. A merge
    # queue is first-in-first-out; picking by anything else (smallest diff, most
    # recently updated) is how the oldest branch keeps losing and going staler,
    # which is the cost this epic exists to remove (ISS-755).
    def open_prs(repo)
      out = capture(["gh", "pr", "list", "--repo", repo, "--state", "open",
                     "--limit", "100", "--json", LIST_FIELDS.join(",")])
      return [] if out.nil?
      JSON.parse(out).sort_by { |pr| [pr["createdAt"].to_s, pr["number"].to_i] }
    rescue JSON::ParserError
      []
    end

    # ONE pull request, re-read fresh. This is what the merge path uses: the list
    # above may be minutes old by the time a session has rebased and waited for
    # CI, and every fact the verdict rests on can have changed in that window.
    def pr(repo, number)
      out = capture(["gh", "pr", "view", number.to_s, "--repo", repo,
                     "--json", PR_FIELDS.join(",")])
      return nil if out.nil?
      JSON.parse(out)
    rescue JSON::ParserError
      nil
    end

    # Where `head` stands relative to `base`, as GitHub computes it:
    # "identical", "ahead", "behind" or "diverged". nil when the call failed —
    # read as UNKNOWN by `verdict`, never as "ahead", so a `gh` blip holds a PR
    # rather than merging one whose base has moved.
    #
    # `per_page=1` because only `status` is wanted and the default response
    # carries every commit in the range.
    def compare_status(repo, base, head)
      out = capture(["gh", "api", "repos/#{repo}/compare/#{base}...#{head}?per_page=1", "--jq", ".status"])
      value = out&.strip
      value.nil? || value.empty? ? nil : value
    end

    # The tip of the base branch, recorded on the ledger decision as `base_sha`.
    # It is the answer to "which main was this verified against", which is the
    # one question a human auditing a merge after the fact cannot reconstruct:
    # the squash commit's parent is that sha, but only until somebody else
    # merges.
    def base_sha(repo, base)
      out = capture(["gh", "api", "repos/#{repo}/commits/#{base}", "--jq", ".sha"])
      value = out&.strip
      value.nil? || value.empty? ? nil : value
    end

    # ---------------- pure decisions ----------------

    # A `statusCheckRollup` entry, normalised. GitHub returns two shapes through
    # the same array and they name their fields differently:
    #
    #   CheckRun       {"name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"}
    #   StatusContext  {"context": "code-review/reviewable", "state": "PENDING"}
    #
    # Reading only one shape is a silent failure in both directions — a lane that
    # looked for `name` would never see the Reviewable context, and one that
    # looked for `context` would never see its own CI.
    def check_name(entry) = (entry["name"] || entry["context"]).to_s

    # nil while a CheckRun is still queued or running: a check with no conclusion
    # has not answered yet, and "no conclusion" must never collapse into the same
    # bucket as "concluded, not success".
    def check_state(entry)
      return entry["state"].to_s.upcase if entry["state"]
      return nil unless entry["status"].to_s.casecmp?("completed")
      entry["conclusion"].to_s.upcase
    end

    def rollup(pr) = Array(pr["statusCheckRollup"])

    def ci_entry(pr) = rollup(pr).find { |e| check_name(e).casecmp?(CI_CHECK) }

    # Is a human mid-review? True when Reviewable's context is present and has
    # not settled on success.
    #
    # Read from the named context, NOT from `mergeStateStatus`. `UNSTABLE` is the
    # same fact, but that field also reports `DIRTY` for a conflict, `BEHIND` for
    # a branch about to be rebased anyway, and `UNKNOWN` while GitHub is still
    # computing — deferring on "not CLEAN" would silently fold three unrelated
    # states into "Mike is reading this".
    def review_in_flight?(pr)
      entry = rollup(pr).find { |e| check_name(e).casecmp?(REVIEW_CONTEXT) }
      return false if entry.nil?
      state = check_state(entry)
      state.nil? || state != "SUCCESS"
    end

    # `ISS-<n>: ` — the prefix every fleet PR carries by contract
    # (agent/instructions.md §1). It is what ties a merge back to a tracked issue
    # for `dev issues reconcile` and the deploy reconcilers, and a PR without one
    # has nothing they can follow, so the lane will not land it.
    ISSUE_PREFIX = /\AISS-\d+:\s/.freeze

    # THE decision. Pure: everything it needs is in `pr` plus `base_status`, so
    # every arm below is a unit test rather than a live PR.
    #
    # Order is not arbitrary — each check answers "is this a candidate at all"
    # before the next one asks a more expensive question, and the message a
    # reader gets is the FIRST real reason rather than the last. `review_in_flight`
    # is the one fact deliberately computed outside this ordering (see Candidate).
    def verdict(pr, repo:, base_status: nil)
      repo_name = repo.to_s.split("/").last
      if SELF_DEPLOYING_REPOS.include?(repo_name)
        return v(:self_deploying_repo, :skip,
                 "#{repo_name} deploys itself — every runner fast-forwards its checkout within 30s, " \
                 "so merging here ships it fleet-wide with no revert window (ISS-660)")
      end
      unless pr["state"].to_s.casecmp?("open")
        return v(:not_open, :skip, "state is #{pr['state']}, not OPEN")
      end
      return v(:draft, :skip, "draft — the author has not said it is ready") if pr["isDraft"]
      if pr["isCrossRepository"]
        return v(:fork, :skip, "opened from a fork — the lane only lands branches in this repo")
      end
      unless pr["title"].to_s.match?(ISSUE_PREFIX)
        return v(:no_issue_prefix, :skip,
                 "title does not start with `ISS-<n>: `, so nothing downstream can tie the merge " \
                 "back to a tracked issue")
      end
      if pr["mergeStateStatus"].to_s.casecmp?("dirty")
        return v(:conflicts, :resolve, "conflicts with #{pr['baseRefName']} — needs a human-grade resolution")
      end

      # CI BEFORE THE REVIEW DEFERRAL, and the order is load-bearing rather than
      # aesthetic. The deferred list in the run summary is described to its
      # reader as "PRs this loop would have merged and deliberately left you", so
      # a PR that is ALSO red must not appear in it — it would not have merged,
      # and saying it would misrepresents what the lane is holding back. The fact
      # that a review is open is not lost either way: `review_in_flight` is
      # carried on the Candidate independently of the verdict (ISS-663).
      ci = ci_state(pr)
      return ci unless ci.nil?

      if review_in_flight?(pr)
        return v(:review_in_flight, :defer,
                 "#{REVIEW_CONTEXT} is not SUCCESS — a human is mid-review, and merging destroys the " \
                 "pass rather than the code")
      end

      base_verdict(pr, base_status)
    end

    # The CI half of `verdict`, split out because it is the half with four
    # distinct not-yet answers and they must not blur together. Returns nil when
    # CI is a clean pass on the exact head commit — the only case that falls
    # through to the base check.
    def ci_state(pr)
      entry = ci_entry(pr)
      if entry.nil?
        return v(NO_CI, :skip,
                 "no `#{CI_CHECK}` check on this PR. The lane merges only what an independent party " \
                 "verified, so a repo with no CI workflow merges nothing here — that is the enrolment " \
                 "rule, not a bug")
      end

      state = check_state(entry)
      return v(:ci_pending, :wait, "`#{CI_CHECK}` is still running") if state.nil?
      unless state == "SUCCESS"
        return v(:ci_failed, :park,
                 "`#{CI_CHECK}` concluded #{state}. Establish whether this PR caused it or `main` was " \
                 "already red before holding it")
      end

      # The FRESH invariant. A check is attached to the sha it ran on; a later
      # push leaves the old green sitting on the PR, and `gh pr merge` would
      # replay the NEW commits. Comparing the two is the whole difference between
      # "CI passed" and "CI passed on what is about to land".
      ran_on = (entry["headSha"] || entry["commit"]).to_s
      head = pr["headRefOid"].to_s
      return nil if ran_on.empty? || ran_on == head

      v(:ci_stale, :wait,
        "`#{CI_CHECK}` passed on #{short(ran_on)} but the head is now #{short(head)} — that green was " \
        "measured on a tree nobody is about to merge")
    end

    # The AHEAD invariant. `nil` (the call failed) is UNKNOWN and holds the PR:
    # a `gh` blip must never read as "up to date".
    def base_verdict(pr, base_status)
      base = pr["baseRefName"].to_s
      case base_status
      when "ahead", "identical"
        v(:mergeable, :merge, "`#{CI_CHECK}` green on #{short(pr['headRefOid'])}, which contains the current tip of #{base}")
      when "behind", "diverged"
        v(:needs_rebase, :rebase,
          "head is #{base_status} #{base} — its green was measured against a base that has since moved, " \
          "so it must be rebased and re-verified before it can land")
      else
        v(:base_unknown, :wait,
          "could not compare the head against #{base}, so whether the tested tree contains the current " \
          "tip of #{base} is unknown — holding rather than assuming")
      end
    end

    def v(code, action, message) = Verdict.new(code: code, action: action, message: message)

    def short(sha) = sha.to_s[0, 8]

    # Reversibility, from the paths a PR actually changes — never from what the
    # PR says about itself.
    #
    # Deliberately CONSERVATIVE at the spec boundary: every apibuilder spec change
    # is `costly` here, including a purely additive one that is not breaking at
    # all. Classifying those precisely is ISS-757's job and it needs apibuilder's
    # own `diff_breaking` / `diff_non_breaking`; guessing at it from a path grep
    # is exactly the imprecision that issue exists to remove. Over-classifying
    # costs a merge that waits for a human. Under-classifying ships a broken
    # client to a consumer that regenerates tomorrow.
    def reversibility(changed_paths, repo:)
      paths = Array(changed_paths).map(&:to_s)
      repo_name = repo.to_s.split("/").last
      return "irreversible" if SELF_DEPLOYING_REPOS.include?(repo_name)
      return "irreversible" if paths.any? { |p| migration?(p) }
      return "costly" if paths.any? { |p| spec?(p) }
      return "trivial" if !paths.empty? && paths.all? { |p| documentation?(p) }
      "reversible"
    end

    # A migration has ALREADY RUN by the time anyone would revert it. Reverting
    # the PR gives back the code and does not un-drop a column, so the effect is
    # not contained in undeployed code and no revert window covers it.
    def migration?(path)
      path.match?(%r{\Ascripts/.*\.sql\z}) ||
        path.match?(%r{(\A|/)(migrations|schema)/.*\.sql\z}) ||
        path.match?(%r{(\A|/)dao/.*\.json\z})
    end

    def spec?(path) = path.match?(%r{(\A|/)spec/[^/]+\.json\z})

    def documentation?(path)
      path.match?(/\.(md|txt)\z/i) || path.match?(%r{(\A|/)docs/})
    end

    # Reported to the ledger as `touches_secrets`, which the envelope can gate on.
    # A path grep is a weak test and it is the right one here: it costs nothing,
    # it never says "no" about a file it did not look at, and the ledger — not
    # this — is where the policy about a true answer lives.
    def secrets?(path)
      path.match?(%r{(\A|/)\.env(\.|\z)}) ||
        path.match?(%r{(\A|/)(secrets?|credentials?)(\.|/|\z)}i) ||
        path.match?(/\.(pem|p12|key|keystore)\z/i)
    end

    # Every fact the autonomy ledger is asked to evaluate, computed from the
    # diff and the checks rather than from anything the PR claims about itself.
    #
    # That distinction is the entire trust model: the ledger "does not defend
    # against a loop that reports false facts", so a merge bot that repeated a
    # PR author's "tests pass" would be exactly that loop. `suite_passed` here is
    # not a session's word for it — it is the `ci` check, run by GitHub Actions
    # on the sha named beside it.
    def assertions(candidate, base_sha: nil)
      paths = Array(candidate.changed_paths)
      {
        "repo" => bare(candidate.repo),
        "diff_lines" => candidate.diff_lines,
        "touches_migration" => paths.any? { |p| migration?(p) },
        "touches_spec" => paths.any? { |p| spec?(p) },
        "touches_secrets" => paths.any? { |p| secrets?(p) },
        "suite_passed_post_rebase" => true,
        "verified_by" => "github_actions:#{CI_CHECK}",
        "ci_head_sha" => candidate.head_sha,
        "base_sha" => base_sha,
      }.compact
    end

    # ---------------- assembly ----------------

    # Every open PR in one repo with its verdict, oldest first.
    #
    # `base_status` is asked for ONLY once a PR has survived every cheaper check.
    # It is one API call per PR, and a repo with 23 open PRs of which 20 are
    # drafts or unverified has no reason to make 23.
    def candidates(repo)
      open_prs(repo).map { |raw| candidate(repo, raw) }
    end

    def candidate(repo, raw)
      cheap = verdict(raw, repo: repo, base_status: nil)
      final =
        if cheap.code == :base_unknown
          verdict(raw, repo: repo, base_status: compare_status(repo, raw["baseRefName"], raw["headRefOid"]))
        else
          cheap
        end
      Candidate.new(
        repo: repo, number: raw["number"], title: raw["title"], url: raw["url"],
        head_sha: raw["headRefOid"], created_at: raw["createdAt"],
        verdict: final, review_in_flight: review_in_flight?(raw),
        diff_lines: diff_lines(raw), changed_paths: changed_paths(raw),
      )
    end

    def diff_lines(raw)
      return nil if raw["additions"].nil? && raw["deletions"].nil?
      raw["additions"].to_i + raw["deletions"].to_i
    end

    def changed_paths(raw)
      return nil if raw["files"].nil?
      Array(raw["files"]).map { |f| f["path"].to_s }
    end

    # THE head of the line: the oldest PR that may merge right now.
    #
    # Not "the oldest PR" — a lane that stopped dead behind a PR whose CI is red
    # would merge nothing for as long as its author took to fix it, and the
    # PRs behind it are independently green. Serial means one merge at a time,
    # not one QUEUE POSITION at a time.
    def head_of_line(candidates) = candidates.find(&:mergeable?)

    # One PR, re-read from GitHub and re-verdicted from scratch. This is the read
    # the merge path uses and it is deliberately NOT reusing anything computed
    # earlier: a candidate list is a snapshot, and the session that acts on it has
    # since rebased branches, waited on CI and merged other PRs — each of which
    # can have invalidated it.
    def assess(repo, number)
      raw = pr(repo, number)
      return nil if raw.nil?
      candidate(repo, raw)
    end

    # The merge. The ONLY mutation in this file, and it re-states two of the
    # module's guarantees at the last possible moment:
    #
    #   the repo guard, again — `verdict` already refuses a self-deploying repo,
    #   and this refuses it a second time from a different code path, because a
    #   future caller that forgets to check the verdict must still not be able to
    #   deploy the fleet;
    #   `--match-head-commit`, which makes the whole lane atomic against the one
    #   race it cannot otherwise close: a push landing between the verdict and
    #   the merge. GitHub rejects the merge rather than squashing a commit
    #   nothing verified.
    #
    # `--squash --delete-branch` matches how every one of these repos is merged
    # by hand, which is what makes the reversibility argument hold: one revert
    # commit undoes one PR.
    def merge!(repo, number, head_sha:)
      repo_name = repo.to_s.split("/").last
      if SELF_DEPLOYING_REPOS.include?(repo_name)
        raise ArgumentError, "#{repo} deploys itself and is never merged by the lane"
      end
      raise ArgumentError, "a head sha is required to merge #{repo}##{number}" if head_sha.to_s.empty?

      Agent::Shell.capture("gh", "pr", "merge", number.to_s, "--repo", repo,
                           "--squash", "--delete-branch",
                           "--match-head-commit", head_sha.to_s,
                           timeout: MERGE_TIMEOUT_SECONDS)
    end
  end
end
