require 'fileutils'
require 'securerandom'
require 'agent/github'
require 'agent/paths'

# Workspace materialization (design §4.3).
#
# The slug AND the branch are the same executor-assigned name, `i<issue>_<rand>`
# — e.g. `i120_x4q`. Two things ride on that:
#
#  - It is comfortably inside the 19-character ceiling CLAUDE.md documents for a
#    feature dir, which exists because macOS caps a unix socket path at 104
#    bytes and sbt builds `<feature>/<repo>/project/.sbtboot/server/<hash>/sock`
#    underneath it. A long slug does not fail loudly; sbt just cannot start.
#  - The branch is recorded on the lease, so outcome classification is a LOOKUP
#    (§4.4) and a later attempt can find the PR it left behind (§4.4.1).
#
# Every job gets its own directory and its own clones. Nothing shares a
# checkout, which is the CLAUDE.md workspace rule enforced structurally rather
# than by a session remembering it.
module Agent
  module Workspace
    # Feature dir / branch name ceiling from CLAUDE.md.
    MAX_SLUG_LENGTH = 19

    module_function

    # Random suffix, not a sequence: two attempts on one issue must not collide,
    # and a counter would need durable local state, which this design does not
    # have. 3 chars of [a-z0-9] over an issue that gets at most 3 attempts.
    def slug(issue_number, suffix: SecureRandom.alphanumeric(3).downcase)
      name = "i#{issue_number}_#{suffix}"
      raise "generated slug #{name.inspect} exceeds the #{MAX_SLUG_LENGTH}-char limit" if name.length > MAX_SLUG_LENGTH
      name
    end

    def path(slug) = Agent::Paths.workspace(slug)

    def create(slug)
      dir = path(slug)
      FileUtils.mkdir_p(dir)
      dir
    end

    # Resume a prior attempt's branch (design §4.4.1): find the repo whose open
    # PR is on this branch, clone it, check the branch out, and rebase onto
    # origin/main so the session starts from the same state a human would.
    #
    # Returns the repo slug it resumed, or nil when no open PR exists — in which
    # case the caller treats this as a fresh attempt on a fresh branch, because
    # resuming a branch whose PR was closed would push commits nobody is
    # reviewing.
    def resume(slug, branch)
      pr = Agent::Github.search_open_pr(branch)
      return nil if pr.nil?
      repo = pr["repository"]
      return nil if repo.to_s.empty?

      dir = create(slug)
      checkout = File.join(dir, repo.split("/").last)
      return repo if File.directory?(File.join(checkout, ".git"))

      return nil unless run(["gh", "repo", "clone", repo, checkout], chdir: dir)
      return nil unless run(["git", "fetch", "origin"], chdir: checkout)
      return nil unless run(["git", "checkout", branch], chdir: checkout)
      # A rebase conflict is normal work, not an executor failure: leave the
      # branch as-is and let the session resolve it — it has the context.
      run(["git", "rebase", "origin/main"], chdir: checkout)
      repo
    end

    def run(cmd, chdir:)
      system(*cmd, chdir: chdir, out: File::NULL, err: File::NULL)
    end

    def delete(slug)
      dir = path(slug)
      return false unless File.directory?(dir)
      # Refuse to remove anything that is not under the workspace root — this
      # runs unattended with rm -rf semantics, so the guard is not paranoia.
      return false unless File.expand_path(dir).start_with?("#{Agent::Paths.workspace_root}/")
      FileUtils.rm_rf(dir)
      true
    end
  end
end
