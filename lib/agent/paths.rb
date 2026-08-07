require 'fileutils'
require 'json'

# Every path the autonomous dispatcher reads or writes, in one place.
#
# Two roots and nothing else (design §4.3, §4.3.1):
#
#   ~/.platform/            local CACHE — identity, job pid files, throttles.
#                           None of it is a source of truth; deleting all of it
#                           costs one re-registration.
#   ~/Library/Logs/dev-agent/  every log the agent writes. No process writes
#                           anywhere else — not /tmp, not a per-command dir.
#
# The `DEV_AGENT_*` overrides exist so the tests can exercise the real code
# against a temp dir instead of the developer's home. They are a test seam, not
# a configuration surface: nothing in production sets them.
module Agent
  module Paths
    module_function

    def state_dir
      File.expand_path(ENV["DEV_AGENT_STATE_DIR"] || "~/.platform")
    end

    def log_root
      File.expand_path(ENV["DEV_AGENT_LOG_ROOT"] || "~/Library/Logs/dev-agent")
    end

    # Where a job's feature directory is materialized. Same root every Claude
    # session already uses, so `dev aidirs` and the CLAUDE.md workspace rule
    # apply unchanged.
    def workspace_root
      File.expand_path(ENV["DEV_AGENT_WORKSPACE_ROOT"] || "~/code/ai")
    end

    # The one repo an autonomous session may write to outside its workspace, and
    # then only under plans/ (design §4.6). Overridable so the push guard can be
    # tested against a throwaway checkout.
    def claude_repo
      File.expand_path(ENV["DEV_AGENT_CLAUDE_REPO"] || "~/code/claude")
    end

    def identity_file  = File.join(state_dir, "agent.identity")
    def jobs_dir       = File.join(state_dir, "agent-jobs")
    def heartbeat_file = File.join(state_dir, "agent-heartbeat")
    def notified_file  = File.join(state_dir, "agent-notified.json")
    # A small bounded rolling log of recent failures (Agent::Errors), keyed by
    # source. Local cache only, same as everything else under state_dir: it
    # exists because `dev agent tick` is one-shot with no in-memory continuity
    # across invocations, so "how many times in a row has X failed" has nowhere
    # else to live between ticks.
    def errors_file = File.join(state_dir, "agent-errors.json")
    # When this machine last ran its own housekeeping, what triggered it, and how
    # it went (Agent::Maintenance, ISS-520). A throttle in the same sense as
    # heartbeat_file: the cadence is decided here, on the machine, with no
    # platform involvement, so hygiene keeps happening while the platform is
    # unreachable. What the platform gets is a REPORT of it, on the registry
    # report — which is how "this machine stopped pruning" becomes visible
    # somewhere other than the machine that stopped.
    def maintenance_file = File.join(state_dir, "agent-maintenance.json")
    # When this machine last compared itself to Agent::Toolchain::TOOLS, and what
    # was missing (ISS-531). A throttle in exactly the sense maintenance_file is:
    # the check costs a `zsh -lc` and a toolchain does not change between ticks,
    # so it runs on a cadence — but a machine that has never checked is due
    # immediately, which is what gives a freshly provisioned runner its answer on
    # the first tick instead of a day later.
    def toolchain_file = File.join(state_dir, "agent-toolchain.json")
    def work_lock      = File.join(state_dir, "agent-tick.lock")
    def vitals_lock    = File.join(state_dir, "agent-vitals.lock")
    # agent-errors.json's own lock, held across Agent::Errors' read-modify-write
    # (ISS-742). It belongs to the FILE rather than to a phase, because neither
    # phase lock excludes the other: the tick records failures from Phase A under
    # vitals_lock and from Phase B under work_lock, and Phase B is designed to
    # overlap the NEXT tick's Phase A — so a Phase A `clear` reading the log
    # before a Phase B `record` wrote it silently dropped that failure. Nothing
    # corrupts (write_atomic renames), what is lost is a row, and a lost row is
    # a shortened streak.
    def errors_lock    = File.join(state_dir, "agent-errors.lock")

    # How this box's capacity is split between agent sessions and CI jobs
    # (Agent::Ci, ISS-763). Written by `dev ci install`, read by `dev ci run` and
    # by the tick's admission control.
    #
    # LOCAL rather than a field on the platform's runner row, and the distinction
    # is the same one state_dir draws everywhere else: the registry derives
    # max_concurrency from reported HARDWARE, which is a fact about the machine.
    # How that capacity is divided is an operator's decision about this machine,
    # taken when a runner is installed on it — and the tick has to be able to read
    # it while the platform is unreachable, because the alternative is a box that
    # oversubscribes itself for the length of an outage.
    def ci_config_file = File.join(state_dir, "ci.json")

    # The CI slot semaphore: one lock file per reserved slot, held by `flock` for
    # as long as the build process lives. Nothing is ever read out of them — the
    # pid inside is for a human running `lsof` — so there is no state here to
    # leak or expire, which is the property that keeps this off Agent::Tick's
    # "there is no daemon" ledger.
    def ci_slots_dir = File.join(state_dir, "ci-slots")

    def tick_log(date)      = File.join(log_root, "tick", "#{date.strftime('%Y-%m-%d')}.log")
    def issues_dir          = File.join(log_root, "issues")
    def issue_dir(number)   = File.join(issues_dir, "ISS-#{number}")
    def claude_log(number)  = File.join(issue_dir(number), "claude.log")
    def meta_file(number)   = File.join(issue_dir(number), "meta.json")

    def job_file(number) = File.join(jobs_dir, "#{number}.json")

    def workspace(slug) = File.join(workspace_root, slug)

    # The devops checkout the tick runs out of, and the one it fast-forwards
    # itself (Agent::Checkout). Everything below hangs off it rather than off
    # __dir__ so the two can never drift: what a machine READS after a pull has
    # to be what the pull WROTE.
    def devops_repo
      File.expand_path(ENV["DEV_AGENT_DEVOPS_REPO"] || File.expand_path("../..", __dir__))
    end

    # The standing prompt, versioned in git beside the code that reads it. The
    # producer registry and the playbooks used to live here too; both are platform
    # rows now (ISS-521, ISS-523) and the file that held them is deleted --
    # a definition split across two systems, only one of which is queryable, is
    # what ISS-526 ended.
    def agent_dir           = File.join(devops_repo, "agent")
    def instructions_file   = File.join(agent_dir, "instructions.md")
    def githooks_dir        = File.join(agent_dir, "githooks")

    # THIS checkout's executables, never whatever is on PATH, for the same reason
    # everything else here hangs off `devops_repo`: the tick fast-forwards that
    # checkout on every Phase A and then runs out of it, so a chore that shelled
    # out to a different copy would be running code nothing here updates.
    def dev_bin             = File.join(devops_repo, "bin", "dev")
    def claude_db_bin       = File.join(devops_repo, "bin", "claude-db")

    # ---- small IO helpers, atomic where a half-written file would confuse a
    # later tick (identity, job records, meta).

    def mkdir_p(dir, mode: nil)
      FileUtils.mkdir_p(dir)
      FileUtils.chmod(mode, dir) if mode
      dir
    end

    def write_atomic(path, content, mode: 0644)
      mkdir_p(File.dirname(path), mode: path.start_with?(state_dir) ? 0700 : nil)
      tmp = "#{path}.tmp.#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, mode) { |f| f.write(content) }
      File.rename(tmp, path)
      path
    end

    def write_json(path, hash, mode: 0644)
      write_atomic(path, "#{JSON.pretty_generate(hash)}\n", mode: mode)
    end

    # nil rather than an exception for a missing or corrupt file: every one of
    # these is a cache, and a tick that dies because a pid file got truncated is
    # a worse failure than one that re-derives the state.
    def read_json(path)
      return nil unless File.file?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def append_log(path, line)
      mkdir_p(File.dirname(path))
      File.open(path, "a") { |f| f.puts(line) }
    end

    # ---- locking
    #
    # Ruby's File#flock, NOT the flock(1) command — see the header of Agent::Tick
    # for why that utility is not an option on these machines. Always on a
    # DEDICATED lock file and never on the file being protected: every write here
    # goes through write_atomic, which replaces the path by rename, so a lock
    # taken on the data file would be held on an inode no later reader can see.
    #
    # NON-BLOCKING by default: flock returns false immediately instead of
    # waiting, which is what stops ticks piling up behind a slow predecessor — a
    # tick that cannot get the work lock skips its work phase, and that is the
    # design (Agent::Tick §4.3), not a failure.
    #
    # `blocking: true` is for a critical section short enough that waiting costs
    # less than skipping, and it is safe ONLY for one: Agent::Errors' read-modify-
    # write is a JSON read and one rename, with no shell-out, no network and no
    # nested lock inside it. Never give it to anything that clones, prunes or
    # calls the platform — waiting on one of those behind a lock is precisely the
    # inversion the two-phase split exists to prevent.
    #
    # The lock is released when the process exits, INCLUDING on a crash, so a
    # killed tick cannot wedge anything.
    def with_lock(path, blocking: false)
      mkdir_p(File.dirname(path), mode: 0700)
      file = File.open(path, File::CREAT | File::RDWR, 0600)
      # flock returns 0 on success, and false only when LOCK_NB would have blocked.
      acquired = file.flock(blocking ? File::LOCK_EX : (File::LOCK_EX | File::LOCK_NB)) != false
      yield acquired
    ensure
      file&.flock(File::LOCK_UN) if acquired
      file&.close
    end
  end
end
