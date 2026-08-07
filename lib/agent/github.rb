require 'json'
require 'agent/paths'
require 'agent/shell'

# The `gh` and `git` reads outcome classification and resume depend on.
#
# Everything here is a QUERY. Nothing in this file pushes, merges, or mutates a
# remote — that is the session's job, under the safety rules in
# devops/agent/instructions.md.
module Agent
  module Github
    module_function

    # Every read here is a `gh` call to GitHub, on the reap path of a phase that
    # holds the work lock — so an unbounded one against a stalled connection
    # stops this runner claiming anything on every later tick, silently
    # (ISS-740). A deadline turns that into the answer every caller here already
    # handles: nil, read as UNKNOWN and never as "no PR", so a timeout leaves an
    # issue unclassified for one tick rather than misclassifying it.
    #
    # 60 seconds is far longer than a healthy `gh pr list` and short enough that
    # the reap of one repo cannot outlast the lease heartbeats.
    TIMEOUT_SECONDS = 60

    def capture(cmd, chdir: nil)
      result = Agent::Shell.capture(*cmd, timeout: TIMEOUT_SECONDS, chdir: chdir, stderr: :inherit)
      result.ok? ? result.output : nil
    rescue Errno::ENOENT
      nil
    end

    # `owner/repo` for a checkout, from its origin remote.
    def repo_slug(dir)
      url = capture(["git", "remote", "get-url", "origin"], chdir: dir)&.strip
      return nil if url.nil? || url.empty?
      url[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?\z}, 1]
    end

    # Every git checkout directly inside a workspace, as `owner/repo`.
    def repos_in_workspace(workspace)
      return [] unless Dir.exist?(workspace)
      Dir.children(workspace).sort.filter_map do |name|
        dir = File.join(workspace, name)
        next unless File.directory?(File.join(dir, ".git"))
        repo_slug(dir)
      end.uniq
    end

    PR_FIELDS = "url,isDraft,number,title,state,headRefName,mergedAt".freeze

    # The same fields MINUS the head branch, because `gh search prs` does not
    # have it: asking anyway is "Unknown JSON field" on stderr, a non-zero exit,
    # and — since `capture` reads a failure as no output — a search path that
    # silently finds NOTHING. Two field lists is the price of one command not
    # supporting what the other does; collapsing them back into one breaks the
    # fallback lookup with no error anywhere.
    SEARCH_FIELDS = "url,isDraft,number,title,state".freeze

    # How far back to scan a repo's PR list when matching on the `ISS-<n>: `
    # title prefix or a sibling branch. Bounded because this is a per-repo,
    # per-reap API call.
    TITLE_SCAN_LIMIT = 100

    # What separates the assigned branch from a sibling's suffix: `i651_irv` is
    # the assigned branch, `i651_irv_sig` is one of its siblings (ISS-657).
    #
    # A run that produces several INDEPENDENT PRs — the weekly-review playbook is
    # the standing case — cannot put them all on one branch without stacking them,
    # which these squash-merge repos forbid. So the assigned branch is a
    # NAMESPACE: the first PR is on it exactly, and every additional one is on
    # `<branch>_<suffix>`. That makes "did this session deliver, and what did it
    # deliver" a prefix match rather than a guess.
    SIBLING_SEPARATOR = "_".freeze

    # MERGED beats OPEN beats CLOSED. A merged PR is the single strongest
    # evidence a session delivered, so it must never lose to a stale open PR on
    # some other branch, and a closed-unmerged PR must never beat either.
    PR_RANK = { "MERGED" => 3, "OPEN" => 2, "CLOSED" => 1 }.freeze

    def pr_rank(pr) = PR_RANK.fetch(pr["state"].to_s.upcase, 0)

    def merged?(pr) = !!(pr && pr["state"].to_s.casecmp?("merged"))

    def open?(pr) = !!(pr && pr["state"].to_s.casecmp?("open"))

    # Closed WITHOUT merging — rejected, abandoned, or superseded. Deliberately
    # not "everything that is not open": a state this file does not recognise is
    # an UNKNOWN, and every caller here reads an unknown as fail-open rather than
    # as a negative answer.
    def closed?(pr) = !!(pr && pr["state"].to_s.casecmp?("closed"))

    # When this PR merged, as the ISO-8601 UTC string `gh` returns, or nil for one
    # that has not merged (or a lookup that did not ask for the field).
    #
    # The floor `dev issues reconcile` compares a release against: an issue reaches
    # `fixed` when its PR is READY, which can be a day before the code is on main,
    # so "released since the fix" is only honest when it means "released since the
    # fix MERGED" (ISS-737).
    def merged_at(pr) = merged?(pr) ? pr["mergedAt"] : nil

    # Ready for review: open and not a draft.
    def ready?(pr) = open?(pr) && !pr["isDraft"]

    def draft?(pr) = open?(pr) && !!pr["isDraft"]

    # THE PR a run is classified from, and whose url the issue records: the
    # highest-ranked one, then the one on the ASSIGNED branch, then the newest
    # number. Pass `nil` for the branch when there is no assigned branch to
    # prefer and this is a plain rank-then-newest pick.
    #
    # The middle tie-break is ISS-657: once a run can leave several equally-open
    # PRs, "newest wins" makes the url an issue carries depend on which sibling
    # happened to be opened last. The session put its most significant work on
    # the assigned branch by contract, so that one is the answer — but never over
    # a stronger state, because a merged sibling is delivered work and an open
    # primary is not.
    def primary_pr(prs, branch = nil)
      prs.compact.max_by do |pr|
        [pr_rank(pr), pr["headRefName"].to_s == branch.to_s ? 1 : 0, pr["number"].to_i]
      end
    end

    # ONE pull request, named by its url. Distinguished from everything else here
    # by taking a url rather than a repo: what an issue records as a `fix` is a
    # url, so this is the lookup that answers "has the fix on that issue actually
    # merged" without first re-deriving the repo from the link.
    #
    # nil when `gh` is missing, unauthenticated, rate-limited, or the url names no
    # PR — every caller reads that as UNKNOWN, never as "not merged".
    def pr_by_url(url)
      out = capture(["gh", "pr", "view", url.to_s, "--json", PR_FIELDS])
      return nil if out.nil?
      JSON.parse(out)
    rescue JSON::ParserError
      nil
    end

    def list_prs(repo, *args)
      out = capture(["gh", "pr", "list", "--repo", repo, "--state", "all", "--json", PR_FIELDS, *args])
      return [] if out.nil?
      JSON.parse(out).map { |pr| pr.merge("repository" => repo) }
    rescue JSON::ParserError
      []
    end

    # Every PR on `branch` in one repo, in ANY state. Asked repo-by-repo rather
    # than through search because `gh pr list` reads the API directly: GitHub's
    # search index lags by up to a minute or two, which is exactly the window in
    # which a session opens a PR and exits and the next tick reaps it.
    # Classifying a just-opened PR as "no PR" would fail a successful job.
    #
    # `--state all`, not `--state open`, because a PR merged between the push and
    # the reap is a SUCCESS, and looking only at open PRs made the fastest-
    # reviewed work the one case that read as failure (ISS-364).
    def prs_on_branch(repo, branch)
      list_prs(repo, "--head", branch, "--limit", "10")
    end

    # Is this PR on the assigned branch, or on one of its `<branch>_<suffix>`
    # siblings? See SIBLING_SEPARATOR — a name that merely CONTAINS the branch
    # (`x_i651_irv`) is not in the family, because the contract is a prefix.
    def in_branch_family?(pr, branch)
      head = pr["headRefName"].to_s
      return false if head.empty? || branch.to_s.empty?
      head == branch.to_s || head.start_with?("#{branch}#{SIBLING_SEPARATOR}")
    end

    # `ISS-<n>` at the start of a title, or nil when the number is not one.
    def title_prefix(number)
      /\AISS-#{Integer(number)}\b/
    rescue ArgumentError, TypeError
      nil
    end

    # The issue number a PR's title claims, or nil for a title that claims none.
    # Zero-padding is not significant — `ISS-035` and `ISS-35` are one issue.
    def titled_issue_number(pr)
      digits = pr["title"].to_s[/\AISS-(\d+)\b/, 1]
      digits && digits.to_i
    end

    # Does this PR belong to the issue being reaped, or to another one?
    #
    # ISS-759: a run that finds several INDEPENDENT changes now gives each its own
    # issue number (`dev issues split`), and each of those PRs is on a branch in
    # THIS run's family — that is the contract, and it is what makes them findable
    # at all. Without this they would be recorded as extra fixes on the parent
    # issue as well as on their own, which is the bookkeeping ISS-759 exists to
    # undo: five urls behind one number, none of them separately closable.
    #
    # A title naming a DIFFERENT issue is the only thing that disqualifies a PR,
    # and never the exact assigned branch. That asymmetry is deliberate: the
    # branch is assigned by the executor and recorded on the lease, so a PR on it
    # is this run's primary work by construction, while a title is typed by the
    # session. If the two ever disagree, the lookup that cannot be mistyped wins —
    # the alternative is a delivered fix classified as `nothing_to_do` and, for a
    # producer-filed issue, dismissed with its PR sitting ready on GitHub.
    # An issue number this cannot parse disqualifies nothing: with no number to
    # compare against, "titled for somebody else" is not a question that has an
    # answer, and answering it anyway would drop PRs the branch family found.
    def belongs_to_issue?(pr, branch, number)
      return true if !branch.to_s.empty? && pr["headRefName"].to_s == branch.to_s
      mine = number.to_s[/\A0*(\d+)\z/, 1]
      return true if mine.nil?
      titled = titled_issue_number(pr)
      titled.nil? || titled == mine.to_i
    end

    # Every PR in one repo that belongs to this issue: on a branch in the
    # assigned branch's family, or carrying the issue's `ISS-<n>: ` title prefix.
    #
    # The exact-branch lookup above is the primary path, but it is only as good
    # as the session's obedience and only ever finds ONE branch. Two things it
    # misses: a session that renamed its branch (ISS-365), and a run that
    # legitimately split into several PRs on sibling branches (ISS-657). The
    # title prefix is mandated by devops/agent/instructions.md and is already
    # what `dev issues reconcile` uses as a backstop; the branch family is the
    # second, independent handle, so a session that titled a PR wrong is still
    # found by its branch and vice versa. Matched locally over the direct list
    # API rather than through `--search` so it does not reintroduce index lag.
    def prs_for_issue(repo, branch, number)
      prefix = title_prefix(number)
      list_prs(repo, "--limit", TITLE_SCAN_LIMIT.to_s).select do |pr|
        in_branch_family?(pr, branch) || (prefix && pr["title"].to_s.match?(prefix))
      end
    end

    # EVERY PR a session left behind across its workspace's clones, deduped by
    # url — the branch family and the title prefix overlap by design, and the
    # exact-branch call repeats what the broad scan already saw.
    #
    # All of them, not just the best one: classification only needs the strongest
    # PR, but the ISSUE needs all of them recorded, or five sixths of a run's work
    # is invisible to everything downstream (ISS-657).
    #
    # Minus the ones a session split onto their OWN issue numbers (ISS-759): those
    # are on sibling branches by contract, so the family lookup finds them, and
    # they are already tracked, closed out and verified where they belong.
    def prs_in_workspace(workspace, branch, number)
      repos_in_workspace(workspace).flat_map do |repo|
        prs_on_branch(repo, branch) + prs_for_issue(repo, branch, number)
      end.uniq { |pr| pr["url"] }.select { |pr| belongs_to_issue?(pr, branch, number) }
    end

    # Fallback lookup when the workspace is gone (a resume, or a GC'd failure):
    # GitHub search across the account. Index lag is acceptable here because the
    # branch is minutes-to-days old by the time this path runs.
    #
    # Siblings ARE found here — `head:i651_irv` matches `i651_irv_sig` too, since
    # search matches the qualifier loosely — and the title half finds them again
    # by contract. What this path CANNOT do is tell which of them is on the
    # assigned branch: search does not return headRefName (see SEARCH_FIELDS) and
    # the loose head match cannot stand in for it, so `primary_pr` falls back to
    # newest-wins here. That is the workspace-is-gone path, where the alternative
    # is no PR at all.
    # A PR titled for another issue is filtered here too (ISS-759). The exact-branch
    # exemption `belongs_to_issue?` makes cannot apply on this path — search does
    # not return headRefName — but nothing is lost by it: a PR reaches this list
    # either through the loose `head:` match, which is exactly how a split sibling
    # arrives, or through the title search, which only ever finds this issue's own.
    def search_prs(branch, number = nil, owner: "mbryzek")
      hits = search("head:#{branch}", owner: owner)
      hits += search("ISS-#{Integer(number)}", owner: owner, match: "title") if number
      hits.uniq { |pr| pr["url"] }.select { |pr| belongs_to_issue?(pr, nil, number) }
    rescue ArgumentError, TypeError
      search("head:#{branch}", owner: owner)
    end

    def search(query, owner:, match: nil)
      cmd = ["gh", "search", "prs", query, "--owner", owner, "--json", "#{SEARCH_FIELDS},repository", "--limit", "10"]
      cmd += ["--match", match] if match
      out = capture(cmd)
      return [] if out.nil?
      JSON.parse(out).map { |pr| pr.merge("repository" => pr.dig("repository", "nameWithOwner") || pr["repository"]) }
    rescue JSON::ParserError
      []
    end

    # The resume path (§4.4.1) wants only a branch whose PR is still OPEN: a
    # merged or closed PR is finished, and pushing more commits to it is worse
    # than starting over on a fresh branch.
    def search_open_pr(branch, owner: "mbryzek")
      search("head:#{branch} state:open", owner: owner).find { |pr| open?(pr) }
    end

    # Did the session land commits under ~/code/claude/plans/ during its run?
    # Scoped to the job's own window and to that one path, so unrelated commits
    # (Mike's, another job's) do not read as this job's design document.
    def plans_committed_since?(since, repo: Agent::Paths.claude_repo)
      return false unless Dir.exist?(File.join(repo, ".git"))
      out = capture(["git", "log", "--since=#{since.utc.iso8601}", "--format=%H", "--", "plans/"], chdir: repo)
      !out.nil? && !out.strip.empty?
    end
  end
end
