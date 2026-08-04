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
    # What this machine last told the platform its producer registry was. A
    # throttle, not a record: the platform holds the report, this only answers
    # "has anything changed, or has it been long enough to re-report".
    def registry_report_file = File.join(state_dir, "agent-registry-report.json")
    def work_lock      = File.join(state_dir, "agent-tick.lock")
    def vitals_lock    = File.join(state_dir, "agent-vitals.lock")

    def tick_log(date)      = File.join(log_root, "tick", "#{date.strftime('%Y-%m-%d')}.log")
    def producers_log(date) = File.join(log_root, "producers", "#{date.strftime('%Y-%m-%d')}.log")
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

    # The standing prompt and the producer registry, versioned in git beside the
    # code that reads them.
    def agent_dir           = File.join(devops_repo, "agent")
    def instructions_file   = File.join(agent_dir, "instructions.md")
    def producers_file      = File.join(agent_dir, "producers.yml")
    def githooks_dir        = File.join(agent_dir, "githooks")

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
  end
end
