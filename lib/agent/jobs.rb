require 'json'
require 'shellwords'
require 'time'
require 'agent/outcome'
require 'agent/paths'
require 'agent/processes'

# The only local state the executor keeps: "is this pid alive", plus the two
# things a later process cannot re-derive once the act of handling them has
# destroyed the evidence — that the TICK killed this session (`mark_killed`), and
# what the reap decided about it (`mark_reaped`).
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

    # Record that the TICK killed this session, before killing it.
    #
    # The kill destroys every artifact classification would otherwise read: the
    # wrapper never reaches `echo $? > exit_code`, and claude.log stops wherever
    # it stopped. The killer is the only thing that knows, and the reap runs in a
    # different process minutes later, so the knowledge has to be written down
    # (ISS-364). Written FIRST, so a tick that dies between the write and the
    # signal still leaves the truth behind.
    def mark_killed(record, reason:, now: Time.now)
      write(record.merge("killed" => { "reason" => reason, "at" => now.utc.iso8601 }))
    end

    # Record the reap's VERDICT, before the reap acts on it (ISS-741).
    #
    # The same shape and the same reason as `mark_killed` above: handling an
    # outcome destroys the evidence for it. The kill destroys the exit code and
    # the log; the reap deletes the workspace whose clones are where the
    # session's PRs are found. And the reap's platform write can fail AFTER that
    # deletion, leaving this job record to be reaped again 30 seconds later with
    # nothing left to read — which is how a ready PR came to be re-classified as
    # `nothing_to_do` and its issue dismissed underneath it. Written FIRST, so
    # the retry applies the verdict rather than inventing a new one.
    #
    # It survives into meta.json through `finish`, which is where it earns its
    # second keep: `reap.at` is when the verdict was reached and `finished_at` is
    # when it was finally written, and on a reap that had to retry the gap
    # between them is the post-mortem.
    def mark_reaped(record, result:, prs:, now: Time.now)
      write(record.merge("reap" => { "result" => Agent::Outcome.to_h(result),
                                     "prs" => prs,
                                     "at" => now.utc.iso8601 }))
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

    # SIGTERM, then SIGKILL — to the session's own group AND to every descendant
    # of it, which are two different sets of processes (ISS-782).
    #
    # This used to signal only the group, on the stated grounds that "the session
    # spawns sbt, docker and gh children of its own and killing only the leader
    # would leave a 12G sbt JVM behind holding the machine's memory". The
    # intention was right and the mechanism never worked: `spawn_session` puts the
    # wrapper in its own group, so the group contains the wrapper and the `claude`
    # CLI and nothing else — because the CLI runs EVERY Bash tool call in a NEW
    # process group of its own. So the sbt JVM this comment is about was never in
    # the group being signalled, and neither was anything else the session
    # started. Killing a timed-out session reached the CLI and left its work
    # running; twenty orphaned spin loops held a runner at load ~50 for thirteen
    # hours that way.
    #
    # The descendant TREE is the set that is actually right, and parentage proves
    # membership rather than assuming it. Collected BEFORE the first signal, since
    # killing the CLI reparents everything below it to init and destroys the very
    # links this needs to read.
    def kill(pid, grace: 10)
      return false unless alive?(pid)
      doomed = Agent::Processes.descendants(pid).map(&:pid)
      signal_group(pid, "TERM")
      Agent::Processes.signal(doomed, "TERM")
      deadline = Time.now + grace
      sleep(0.2) while alive?(pid) && Time.now < deadline
      signal_group(pid, "KILL") if alive?(pid)
      Agent::Processes.signal(doomed.select { |p| Agent::Processes.alive?(p) }, "KILL")
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
