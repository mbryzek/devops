require 'fileutils'
require 'agent/github'
require 'agent/paths'
require 'agent/shell'

# Workspace materialization (design §4.3).
#
# The slug AND the branch are the same executor-assigned name, and it is DERIVED
# FROM THE ISSUE rather than drawn at random (ISS-767):
#
#   i<issue>            a standalone issue          — `i746`
#   i<epic>_c<nn>       child <nn> of an epic       — `i682_c07`
#
# Three things ride on that:
#
#  - It is comfortably inside the 19-character ceiling CLAUDE.md documents for a
#    feature dir, which exists because macOS caps a unix socket path at 104
#    bytes and sbt builds `<feature>/<repo>/project/.sbtboot/server/<hash>/sock`
#    underneath it. A long slug does not fail loudly; sbt just cannot start.
#  - The name is BYTE-IDENTICAL across every repo one logical change touches,
#    which is the whole join key `dev prs group` runs on. The `i<epic>_` prefix
#    adds a second, coarser join: every child of an epic is discoverable as one
#    set, which nothing gave us while the suffix was random.
#  - Because it is derived, a second attempt on an issue computes the SAME name
#    the first one did — so resume is the default rather than something that has
#    to be recorded and looked up. The lease's `branch` column is still honoured
#    when it is set and differs (Tick#start_job), but nothing depends on it.
#
# `c<nn>` IS CREATION ORDER AND NEVER MERGE ORDER. Nothing here, in Prs::Group,
# or anywhere downstream may parse the suffix to decide what merges first: a lane
# that read c1-before-c2 as a dependency would be right most of the time and
# silently wrong the moment a child is added late. Grouping comes from the name;
# ordering comes from explicit `blocked_by` edges.
#
# Every job gets its own directory and its own clones. Nothing shares a
# checkout, which is the CLAUDE.md workspace rule enforced structurally rather
# than by a session remembering it.
module Agent
  module Workspace
    # Feature dir / branch name ceiling from CLAUDE.md.
    MAX_SLUG_LENGTH = 19

    # Zero-padded to a FIXED width, and that is not cosmetic. GitHub's `head:`
    # search qualifier is a PREFIX match on the whole branch name — measured, not
    # assumed: `head:i735_te` returns every `i735_tej*` PR — so an unpadded
    # `i682_c1` would match `i682_c10` and the reap of child 1 could adopt child
    # 10's pull request. Two digits makes no child's branch a prefix of another's
    # up to 99 children, which is an order of magnitude past the largest epic
    # anyone has filed.
    CHILD_INDEX_WIDTH = 2

    # Exactly what `slug` below generates, PLUS the `i<issue>_<rand3>` form every
    # workspace minted before ISS-767 carries. Stated as a pattern so the
    # consumers can check rather than assume, and defined HERE, at the producer,
    # because this is the only thing that mints a slug -- Agent::Gc matches
    # directories under ~/code/ai against it to decide what the executor created
    # and may therefore rm -rf, and `dev aidirs prune` matches it to decide what
    # it must NOT touch.
    #
    # The legacy arm is accepted and never minted: dropping it would strand every
    # in-flight workspace outside both collectors at once — invisible to
    # Agent::Gc, and fair game for the aggressive `dev aidirs prune` that skips
    # exactly what this matches.
    #
    # Admitting the bare `i<issue>` form widens what gc may delete, deliberately:
    # a hand-made feature dir named for its FEATURE (`cr-backfill-coord`,
    # `iss226-rev-src`) is still nothing like `i746`, and the alternative — a
    # standalone form carrying a separator it has no second component for — buys
    # nothing.
    SLUG = /\Ai\d+(?:_(?:c\d+|[a-z0-9]{3}))?\z/

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

    # THE name, derived and never drawn (ISS-767). Pass `parent_number` and
    # `child_index` for a child of an epic; omit both for a standalone issue.
    #
    # Deterministic on purpose, and the two consequences are both wanted:
    # a retry lands on the branch its predecessor left behind instead of opening
    # a second PR nobody asked for, and every child of one epic shares a prefix
    # so the whole set is one `git branch --list 'i682_*'` away. The random
    # suffix this replaced bought exactly one thing — two attempts never
    # collided — and colliding with YOURSELF is the behaviour we want.
    def slug(issue_number, parent_number: nil, child_index: nil)
      name = if parent_number.to_s.empty? || child_index.nil?
               "i#{issue_number}"
             else
               "i#{parent_number}_c#{child_index.to_i.to_s.rjust(CHILD_INDEX_WIDTH, '0')}"
             end
      raise "generated slug #{name.inspect} exceeds the #{MAX_SLUG_LENGTH}-char limit" if name.length > MAX_SLUG_LENGTH
      name
    end

    # Where `number` sits among an epic's children, 1-based, ordered by issue
    # NUMBER ascending — or nil when it is not in the list, which the caller
    # reads as "no epic position" and falls back to the standalone form.
    #
    # Numeric order, not the order the server happened to return, and not
    # created_at: it has to give the same answer on every runner and on every
    # retry, and issue numbers are monotonic, so a child appended later cannot
    # renumber the children that came before it.
    #
    # EVERY child counts, including dismissed ones. Filtering by status would
    # make the index move under an issue whose sibling was dismissed while it was
    # queued, which is precisely the drift this ordering exists to prevent.
    #
    # Base 10 EXPLICITLY. `Integer("0767")` is 503 in Ruby — a leading zero means
    # octal — and the tracker stores its numbers zero-padded, so a padded value
    # reaching here without the base would silently reorder the children and give
    # a retry a different branch than the attempt it is resuming.
    def child_index(child_numbers, number)
      target = Integer(number.to_s.strip, 10, exception: false)
      return nil if target.nil?
      ordered = Array(child_numbers).filter_map { |n| Integer(n.to_s.strip, 10, exception: false) }.uniq.sort
      position = ordered.index(target)
      position && position + 1
    end

    def path(slug) = Agent::Paths.workspace(slug)

    def create(slug)
      raise "refusing to materialize a workspace for slug #{slug.inspect}" unless valid_slug?(slug)
      dir = path(slug)
      FileUtils.mkdir_p(dir)
      dir
    end

    # Resume a prior attempt's branch (design §4.4.1): find the repo whose open
    # PR is on this branch, clone it, check the branch out, and bring the latest
    # origin/main under it so the session starts green against what has shipped.
    #
    # MERGE, not rebase (ISS-771). A rebase rewrites every commit on the branch,
    # so the checkout the session opens into has diverged from `origin/<branch>`
    # and its only way to reach the PR at all — even for a one-line review fix
    # that has nothing to do with the drift — is a force-push, which
    # `agent/instructions.md` §3 forbids flat. This path was therefore handing
    # every resumed session a branch it could not push, and §6's "push to the
    # existing branch and the PR updates in place" was not achievable. A merge
    # leaves an ordinary fast-forwardable push and the identical tree; these
    # repos squash-merge, so the merge commit never reaches main.
    #
    # The branch IS the slug — one executor-assigned name, used for both — so
    # this takes one argument rather than two copies of the same string.
    #
    # Returns the repo slug it resumed, or nil when no open PR exists. Since
    # ISS-767 that nil no longer means "start over on a fresh name": the name is
    # derived, so there is no other name to start over on. It means only that
    # this path found nothing to clone, and `prepare` goes on to materialize the
    # repos the issue names — reporting, through Prepared#continued, whether the
    # branch was already there.
    def resume(branch)
      slug = branch
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
      # A merge conflict is normal work, not an executor failure: leave the
      # conflicted tree in place and let the session resolve it — it has the
      # context, the branch is its own, and unlike a half-finished rebase this
      # is a state a session can read with `git status` and finish with a commit.
      # `--no-edit` because nothing here can answer an editor.
      run(["git", "merge", "--no-edit", "origin/main"], chdir: checkout)
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
    # What `prepare` answers: the repo names actually materialized, in the order
    # given, and the subset whose branch ALREADY EXISTED.
    #
    # `continued` is not bookkeeping. Since ISS-767 the branch is derived from the
    # issue, so a second attempt necessarily arrives at the name the first one
    # pushed — and a session told "here is your fresh branch" while the checkout
    # actually carries a predecessor's commits will open a second PR on work that
    # already has one. This is the signal the prompt turns into "check for your
    # own PR first", and it costs nothing: it is the `rev-parse` prepare_one
    # already runs.
    Prepared = Struct.new(:repos, :continued, keyword_init: true) do
      def any? = repos.any?
    end

    # Every failure is silent-but-skipped ON PURPOSE: a repo that will not clone
    # is a slower session, not a failed attempt, and refusing to start the session
    # over it would turn a transient network blip into a burned attempt.
    #
    # `already_prepared` is the resume path's repo, which [[resume]] has just
    # cloned and checked out onto the EXISTING branch. Re-preparing it here would
    # be the one destructive case in this method — see the branch handling below.
    def prepare(slug, repositories, branch:, already_prepared: nil)
      names = Array(repositories).map { |r| r.to_s.strip }.reject(&:empty?).uniq
      return Prepared.new(repos: [], continued: []) if names.empty?

      dir = create(slug)
      skip = already_prepared.to_s.split("/").last
      repos = []
      continued = []
      names.each do |repo|
        next if repo == skip
        case prepare_one(dir, repo, branch)
        when :continued then repos << repo; continued << repo
        when :created then repos << repo
        end
      end
      Prepared.new(repos: repos, continued: continued)
    end

    # :created (a new branch off origin/main), :continued (the branch was already
    # there and carries somebody's commits), or nil (this repo is not prepared).
    def prepare_one(dir, repo, branch)
      checkout = File.join(dir, repo)
      unless File.directory?(File.join(checkout, ".git"))
        return nil unless run(["gh", "repo", "clone", "#{OWNER}/#{repo}", checkout], chdir: dir)
      end
      return nil unless run(["git", "fetch", "origin"], chdir: checkout)

      # NEVER `checkout -B` here. A branch that already exists carries an earlier
      # attempt's commits, and resetting it to origin/main would destroy work that
      # is already in a PR — the one irreversible thing this code could do. That
      # guard mattered rarely while the suffix was random; with a derived name it
      # is on the ordinary retry path, which is why the outcome is REPORTED now
      # rather than merely survived.
      if run(["git", "rev-parse", "--verify", "--quiet", branch], chdir: checkout)
        run(["git", "checkout", branch], chdir: checkout) ? :continued : nil
      else
        run(["git", "checkout", "-b", branch, "origin/main"], chdir: checkout) ? :created : nil
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
