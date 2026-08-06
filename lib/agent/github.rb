require 'json'
require 'open3'
require 'agent/paths'

# The `gh` and `git` reads outcome classification and resume depend on.
#
# Everything here is a QUERY. Nothing in this file pushes, merges, or mutates a
# remote — that is the session's job, under the safety rules in
# devops/agent/instructions.md.
module Agent
  module Github
    module_function

    def capture(cmd, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      out, status = Open3.capture2(*cmd, **opts)
      status.success? ? out : nil
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

    PR_FIELDS = "url,isDraft,number,title,state".freeze

    # How far back to scan a repo's PR list when matching on the `ISS-<n>: `
    # title prefix. Bounded because this is a per-repo, per-reap API call.
    TITLE_SCAN_LIMIT = 100

    # MERGED beats OPEN beats CLOSED. A merged PR is the single strongest
    # evidence a session delivered, so it must never lose to a stale open PR on
    # some other branch, and a closed-unmerged PR must never beat either.
    PR_RANK = { "MERGED" => 3, "OPEN" => 2, "CLOSED" => 1 }.freeze

    def pr_rank(pr) = PR_RANK.fetch(pr["state"].to_s.upcase, 0)

    def merged?(pr) = !!(pr && pr["state"].to_s.casecmp?("merged"))

    def open?(pr) = !!(pr && pr["state"].to_s.casecmp?("open"))

    # Ready for review: open and not a draft.
    def ready?(pr) = open?(pr) && !pr["isDraft"]

    def draft?(pr) = open?(pr) && !!pr["isDraft"]

    # Highest-ranked PR out of a candidate list, newest number breaking ties.
    def best_pr(prs)
      prs.compact.max_by { |pr| [pr_rank(pr), pr["number"].to_i] }
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

    # Every PR in one repo whose title carries this issue's `ISS-<n>: ` prefix.
    #
    # The branch lookup above is the primary path, but it is only as good as the
    # session's obedience: a session that renamed its branch is invisible to it
    # (ISS-365). The title prefix is mandated by devops/agent/instructions.md and
    # is already what `dev issues reconcile` uses as a backstop — this promotes
    # the same signal to the reap, so a renamed branch is harmless rather than
    # silently misclassified. Matched locally over the direct list API rather
    # than through `--search` so it does not reintroduce index lag.
    def prs_for_issue(repo, number)
      prefix = /\AISS-#{Integer(number)}\b/
      list_prs(repo, "--limit", TITLE_SCAN_LIMIT.to_s).select { |pr| pr["title"].to_s.match?(prefix) }
    rescue ArgumentError, TypeError
      []
    end

    # The PR a session left behind, by branch or by issue-number title prefix,
    # across a workspace's clones. Returns the PR hash with "repository" filled
    # in so callers can report where it lives.
    def find_pr_in_workspace(workspace, branch, number)
      best_pr(repos_in_workspace(workspace).flat_map do |repo|
        prs_on_branch(repo, branch) + prs_for_issue(repo, number)
      end)
    end

    # Fallback lookup when the workspace is gone (a resume, or a GC'd failure):
    # GitHub search across the account. Index lag is acceptable here because the
    # branch is minutes-to-days old by the time this path runs.
    def search_pr(branch, number = nil, owner: "mbryzek")
      hits = search("head:#{branch}", owner: owner)
      hits += search("ISS-#{Integer(number)}", owner: owner, match: "title") if number
      best_pr(hits)
    rescue ArgumentError, TypeError
      best_pr(search("head:#{branch}", owner: owner))
    end

    def search(query, owner:, match: nil)
      cmd = ["gh", "search", "prs", query, "--owner", owner, "--json", "#{PR_FIELDS},repository", "--limit", "10"]
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
