require 'json'
require 'shellwords'
require 'time'
require 'agent/paths'

# The only local state the executor keeps: "is this pid alive".
#
# ~/.platform/agent-jobs/<issue>.json is a CACHE, not a source of truth. Delete
# every one of them and the cost is some orphaned Claude processes whose leases
# expire within ten minutes, returning their issues to `open`. That is what makes
# the tick a stateless function and crash-proofing structural rather than
# engineered: a tick that dies halfway costs 30 seconds.
#
# The same record is written into the log tree as meta.json so "what happened on
# ISS-120" is a path rather than a search — one writer, so the two cannot drift.
module Agent
  module Jobs
    # Long enough for a full platform clone + sbt + test cycle. Anything longer
    # is a hang, not work. Stamped as an absolute `timeout_at` at spawn so Phase
    # A enforces it even when the platform is unreachable — an API outage must
    # not be able to produce an immortal job.
    TIMEOUT_SECONDS = 4 * 3600

    module_function

    def all
      dir = Agent::Paths.jobs_dir
      return [] unless Dir.exist?(dir)
      Dir.glob(File.join(dir, "*.json")).sort.filter_map { |f| Agent::Paths.read_json(f) }
    end

    def find(number)
      Agent::Paths.read_json(Agent::Paths.job_file(number))
    end

    def write(record)
      number = record.fetch("issue")
      Agent::Paths.write_json(Agent::Paths.job_file(number), record, mode: 0600)
      Agent::Paths.write_json(Agent::Paths.meta_file(number), record)
      record
    end

    def delete(number)
      file = Agent::Paths.job_file(number)
      File.delete(file) if File.exist?(file)
    end

    # Record the outcome in the log tree while REMOVING the pid file. The pid
    # file answers exactly one question ("is a job running for this issue") and
    # keeping a finished one around would make the next tick re-reap it.
    def finish(record, outcome)
      merged = record.merge("finished_at" => Time.now.utc.iso8601, "outcome" => outcome)
      Agent::Paths.write_json(Agent::Paths.meta_file(record.fetch("issue")), merged)
      delete(record.fetch("issue"))
      merged
    end

    def alive?(pid)
      return false if pid.nil?
      Process.kill(0, pid.to_i)
      true
    rescue Errno::ESRCH, Errno::EPERM, TypeError
      false
    end

    def timed_out?(record, now: Time.now)
      at = record["timeout_at"]
      return false if at.nil?
      now >= Time.parse(at)
    rescue ArgumentError
      false
    end

    # SIGTERM, then SIGKILL. To the process GROUP, because the session spawns
    # sbt, docker and gh children of its own and killing only the leader would
    # leave a 12G sbt JVM behind holding the machine's memory.
    def kill(pid, grace: 10)
      return false unless alive?(pid)
      signal_group(pid, "TERM")
      deadline = Time.now + grace
      sleep(0.2) while alive?(pid) && Time.now < deadline
      signal_group(pid, "KILL") if alive?(pid)
      true
    end

    def signal_group(pid, signal)
      Process.kill("-#{signal}", pid.to_i)
    rescue Errno::ESRCH, Errno::EPERM
      begin
        Process.kill(signal, pid.to_i)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    # Spawn the session detached, prompt on stdin, cwd the workspace.
    #
    # Detached and never waited on: this tick exits in seconds and the session
    # runs for hours. The next tick finds it again from the pid file and renews
    # its lease — which is the whole answer to "who heartbeats a detached
    # process" and the reason there is no daemon.
    #
    # The prompt is written to prompt.md and redirected in rather than piped:
    # a detached child on the far end of a pipe this process is about to close
    # would race, and the file doubles as the exact record of what was sent.
    #
    # The session runs under a one-line `sh -c` wrapper whose only job is
    # `echo $? > exit_code`. The tick that REAPS this job is a different process
    # from the one that spawned it, so it cannot waitpid for a status — without
    # the wrapper the third signal in outcome classification (§4.4) simply would
    # not exist, and a session that crashed would be indistinguishable from one
    # that finished with nothing to do.
    def spawn_session(argv:, prompt:, workspace:, number:, env: {})
      dir = Agent::Paths.mkdir_p(Agent::Paths.issue_dir(number))
      prompt_file = File.join(dir, "prompt.md")
      Agent::Paths.write_atomic(prompt_file, prompt)
      File.delete(exit_code_file(number)) if File.exist?(exit_code_file(number))

      script = "#{Shellwords.join(argv)} < #{Shellwords.escape(prompt_file)} " \
               ">> #{Shellwords.escape(Agent::Paths.claude_log(number))} 2>&1; " \
               "echo $? > #{Shellwords.escape(exit_code_file(number))}"
      pid = Process.spawn(env.transform_keys(&:to_s), "/bin/sh", "-c", script,
                          chdir: workspace, pgroup: true)
      Process.detach(pid)
      pid
    end

    def exit_code_file(number) = File.join(Agent::Paths.issue_dir(number), "exit_code")

    # nil when the wrapper never got to write one — the process was killed, or
    # the machine rebooted under it. Classified as a failure, not a clean exit.
    def exit_code(number)
      file = exit_code_file(number)
      return nil unless File.file?(file)
      value = File.read(file).strip
      value.empty? ? nil : value.to_i
    end
  end
end
