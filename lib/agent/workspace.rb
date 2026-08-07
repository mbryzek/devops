require 'fileutils'
require 'securerandom'
require 'agent/github'
require 'agent/paths'
require 'agent/shell'

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

    # Exactly what `slug` below generates, stated as a pattern so the consumers
    # can check rather than assume. Defined HERE, at the producer, because this
    # is the only thing that mints a slug -- Agent::Gc matches directories under
    # ~/code/ai against it to decide what the executor created and may therefore
    # rm -rf.
    SLUG = /\Ai\d+_[a-z0-9]{3}\z/

    module_function

    # A slug this module could have produced.
    #
    # Worth checking rather than trusting, because not every slug reaching
    # `create` came from `slug`: resuming a prior attempt passes
    # `lease["branch"]` straight through (Tick#claim), which is a value the
    # PLATFORM supplied. Today that value always originated here, but nothing on
    # this side enforces it, and what the unchecked path does is mkdir_p -- and
    # later rm_rf -- a caller-controlled path under the developer's ~/code/ai.
    #
    # The length ceiling is re-checked too, not only asserted in the generator:
    # an over-long slug does not fail loudly, sbt just cannot open its socket.
    def valid_slug?(slug)
      s = slug.to_s
      s.length <= MAX_SLUG_LENGTH && s.match?(SLUG)
    end

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
      raise "refusing to materialize a workspace for slug #{slug.inspect}" unless valid_slug?(slug)
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

    # GitHub owner every repo an issue can name lives under. One constant rather
    # than accepting `owner/repo` on the issue: `dev issues create --repo` takes a
    # bare name, and a slug arriving here would clone something nobody validated.
    OWNER = "mbryzek".freeze

    # Hard deadline for ONE git/gh call below. The whole point of pre-cloning is
    # that the session does not have to; a clone wedged on a network read that
    # never returns would instead hold the tick — and therefore the heartbeat —
    # until the lease expires under it. A repo that misses the deadline is simply
    # not prepared, and the session clones it itself exactly as it does today.
    CLONE_TIMEOUT_SECONDS = 180

    # Materializes the repos the issue names (design: ISS-562, and the CLAUDE.md
    # "Auto-filing dev issues" instruction that has always described this): each
    # one cloned into the workspace with the attempt's branch already created off
    # the latest `origin/main`, so the session opens into a checkout on the branch
    # the executor recorded rather than cloning for itself and naming its own
    # branch — the ISS-365 failure, where good work landed on a branch the
    # executor could not find and read as no work at all.
    #
    # Returns the repo names actually prepared, in the order given. Every failure
    # is silent-but-skipped ON PURPOSE: a repo that will not clone is a slower
    # session, not a failed attempt, and refusing to start the session over it
    # would turn a transient network blip into a burned attempt.
    #
    # `already_prepared` is the resume path's repo, which [[resume]] has just
    # cloned and checked out onto the EXISTING branch. Re-preparing it here would
    # be the one destructive case in this method — see the branch handling below.
    def prepare(slug, repositories, branch:, already_prepared: nil)
      names = Array(repositories).map { |r| r.to_s.strip }.reject(&:empty?).uniq
      return [] if names.empty?

      dir = create(slug)
      skip = already_prepared.to_s.split("/").last
      names.filter_map do |repo|
        next if repo == skip
        prepare_one(dir, repo, branch) ? repo : nil
      end
    end

    def prepare_one(dir, repo, branch)
      checkout = File.join(dir, repo)
      unless File.directory?(File.join(checkout, ".git"))
        return false unless run(["gh", "repo", "clone", "#{OWNER}/#{repo}", checkout], chdir: dir)
      end
      return false unless run(["git", "fetch", "origin"], chdir: checkout)

      # NEVER `checkout -B` here. A branch that already exists carries an earlier
      # attempt's commits, and resetting it to origin/main would destroy work that
      # is already in a PR — the one irreversible thing this code could do.
      if run(["git", "rev-parse", "--verify", "--quiet", branch], chdir: checkout)
        run(["git", "checkout", branch], chdir: checkout)
      else
        run(["git", "checkout", "-b", branch, "origin/main"], chdir: checkout)
      end
    end

    def run(cmd, chdir:)
      Agent::Shell.capture(*cmd, timeout: CLONE_TIMEOUT_SECONDS,
                           env: { "GIT_TERMINAL_PROMPT" => "0" }, chdir: chdir).ok?
    rescue Errno::ENOENT
      false
    end

    def delete(slug)
      return false unless valid_slug?(slug)
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
