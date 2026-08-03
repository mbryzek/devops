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

    # The open PR on `branch` in one repo, or nil. Asked repo-by-repo rather than
    # through search because `gh pr list` reads the API directly: GitHub's search
    # index lags by up to a minute or two, which is exactly the window in which a
    # session opens a PR and exits and the next tick reaps it. Classifying a
    # just-opened PR as "no PR" would fail a successful job.
    def open_pr(repo, branch)
      out = capture(["gh", "pr", "list", "--repo", repo, "--head", branch, "--state", "open",
                     "--json", "url,isDraft,number,title", "--limit", "1"])
      return nil if out.nil?
      JSON.parse(out).first
    rescue JSON::ParserError
      nil
    end

    # The open PR on `branch` across a workspace's clones. Returns the PR hash
    # with "repository" filled in so callers can report where it lives.
    def open_pr_in_workspace(workspace, branch)
      repos_in_workspace(workspace).each do |repo|
        pr = open_pr(repo, branch)
        return pr.merge("repository" => repo) if pr
      end
      nil
    end

    # Fallback lookup when the workspace is gone (a resume, or a GC'd failure):
    # GitHub search across the account. Index lag is acceptable here because the
    # branch is minutes-to-days old by the time this path runs.
    def search_open_pr(branch, owner: "mbryzek")
      out = capture(["gh", "search", "prs", "head:#{branch}", "--owner", owner, "--state", "open",
                     "--json", "url,isDraft,repository,number", "--limit", "5"])
      return nil if out.nil?
      JSON.parse(out).map { |pr| pr.merge("repository" => pr.dig("repository", "nameWithOwner") || pr["repository"]) }.first
    rescue JSON::ParserError
      nil
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
