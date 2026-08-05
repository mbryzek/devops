require 'open3'
require 'time'
require 'agent/gc'
require 'agent/paths'

# Runner-local housekeeping (ISS-520): collect this machine's agent logs, prune
# this machine's feature dirs, prune this machine's Docker images.
#
# WHY THIS IS NOT A PRODUCER. `agent-gc`, `aidirs-prune` and `docker-prune` were
# registered in agent/producers.yml, which means they ran behind the platform's
# daily compare-and-set in POST /agent/producers/:key/runs. That arbitration is
# exactly right for a producer — a producer FILES an issue, and one issue for the
# fleet is the whole point of deduplicating it — and exactly wrong for these,
# because they DELETE FILES ON THE MACHINE THEY RUN ON. With N runners exactly
# one machine won each lock per day, so N-1 machines never collected a log, never
# pruned a feature dir and never pruned an image, until their disk filled. A full
# disk kills Docker and then surfaces as unrelated spec failures on a box nobody
# is looking at.
#
# So: no registry row, no server call, no lock. Cadence is a constant here and
# the last-run marker is a file, the same shape the tick's own heartbeat throttle
# uses. That independence is deliberate rather than incidental — if the platform
# is unreachable for a week every machine must still prune, because the moment
# you most need disk headroom is the moment things are already broken.
#
# TWO TRIGGERS, and the second is the point:
#
#   cadence   the routine path — once an hour (ISS-555).
#   pressure  free space under PRESSURE_FLOOR_BYTES. Runs with the retention
#             windows shortened, subject only to a cooldown. Waiting a day to
#             react to a disk that is already full is waiting through the exact
#             failure this exists to prevent.
#
# The cooldown matters as much as the floor: a machine genuinely out of space
# stays under the floor after a prune that reclaimed everything reclaimable, and
# without it that machine would run a full `docker prune` every 30 seconds
# forever. Pressure buys shorter windows, not a spin loop.
#
# LIVENESS IS REPORTED, NOT INFERRED. Every run stamps a marker file, and the
# tick's RUNNER HEARTBEAT carries `last_maintenance_at` plus this machine's disk
# headroom (ISS-528 — on the machine's own heartbeat rather than its registry
# report, because the subject is the machine and the reported registry goes away
# with server-side scheduling). An error channel can only ever report a run that
# BROKE; it cannot report one that NEVER HAPPENED (a crashed tick, an unloaded
# launchd job, a cadence bug), and "never ran" and "ran clean" are the same
# silence — which is the failure this whole issue is about. The server-side
# invariant (AgentInvariants.agent_runner_maintenance_stale) is what notices.
module Agent
  module Maintenance
    # Once an hour (ISS-555). It was a day, matching the producer schedules this
    # replaced (agent-gc 4:00am, docker-prune 5:08am, aidirs-prune 6:00am), and a
    # day is the wrong unit for the thing being defended: a runner at
    # max_concurrency can put several GB on disk between two passes, so the gap
    # between "started filling" and "noticed" was up to 24 hours of a machine
    # that is still claiming work. Hourly bounds it at one.
    #
    # Cost is bounded by the same reasoning. A pass an hour after the last one
    # finds an hour's worth of aged images, feature dirs and logs — the first
    # pass after this ships is the expensive one and every later pass is nearly
    # empty — and it runs at the top of the tick's work phase, so what an
    # occasional slow pass delays is that tick's claim, not any running job.
    #
    # Still no wall-clock hour: a runner-local marker gives a machine that was
    # asleep its run when it wakes, which is a strict improvement on missing the
    # window entirely.
    CADENCE_SECONDS = 60 * 60

    # Below this much free space, prune now rather than at the next cadence.
    # Sized off what one job actually costs: a platform clone plus sbt's ivy/
    # coursier caches plus a session Postgres container runs to several GB, and a
    # machine at max_concurrency holds a few of those at once. 50G is roughly
    # "enough headroom for every slot to start", not "nearly empty".
    PRESSURE_FLOOR_BYTES = 50 * 1_000_000_000

    # The floor is a reason to shorten the windows, never a reason to run
    # continuously.
    #
    # It equals CADENCE_SECONDS since ISS-555, and that is deliberate rather than
    # an oversight to be tidied up: a full disk now gets its pass at the next
    # hourly cadence anyway, so what `:pressure` still buys is the SHORTENED
    # RETENTION WINDOWS (feature dirs and images to a day), not an earlier run.
    # Dropping it below the cadence would buy minutes at the cost of a machine
    # that is genuinely full — one that stays under the floor after reclaiming
    # everything reclaimable — running a full `docker prune` several times an
    # hour in front of every claim. `due` checks pressure FIRST, so when the two
    # fire together the run is correctly labelled `:pressure` and takes the short
    # windows.
    PRESSURE_COOLDOWN_SECONDS = 3600

    # Age windows for the two shell chores. The routine numbers are the flags the
    # retired producers passed (`dev aidirs prune --apply` defaults to 3 days;
    # docker-prune passed --days 7). Under pressure both drop to a day, on the
    # same reasoning `dev aidirs prune` is already written around: everything
    # these two delete is reproducible, so a short window costs a slow rebuild,
    # not work.
    ROUTINE_AIDIRS_DAYS = 3
    ROUTINE_DOCKER_DAYS = 7
    PRESSURE_AIDIRS_DAYS = 1
    PRESSURE_DOCKER_DAYS = 1

    # Agent::Errors sources. Fixed strings rather than derived, for the same
    # reason CHECKOUT_PULL_ERROR_SOURCE is: the recorder, the streak count and
    # the escalation must all agree on what they are counting.
    GC_SOURCE = "agent_gc".freeze
    AIDIRS_SOURCE = "aidirs_prune".freeze
    DOCKER_SOURCE = "docker_prune".freeze

    # One chore's result. `ok` false is what the tick records against
    # Agent::Errors and eventually escalates; `message` is the operator-facing
    # one-liner, and for a failure it carries the command's own output.
    Outcome = Struct.new(:source, :label, :ok, :message, keyword_init: true)

    # One maintenance pass. `reclaimed_bytes` is MEASURED, not claimed: free
    # space after the pass minus free space before it. That is a lower bound (a
    # concurrent session writing to disk eats into it) and it is deliberately
    # preferred to parsing each command's own "Total reclaimed" line — those
    # formats belong to docker and to `dev aidirs prune`, they differ from each
    # other, and a regex over them would report a confident zero the day either
    # one changes wording. Free disk is this job's whole output, so free disk is
    # what gets counted.
    Result = Struct.new(:trigger, :at, :outcomes, :free_before, :free_after, :reclaimed_bytes,
                        :disk_total_bytes, keyword_init: true)

    module_function

    # ---- disk ----

    # [free_bytes, total_bytes] for the volume the workspaces live on, or nil if
    # `df` could not answer. nil rather than zero throughout: a machine whose
    # disk cannot be read must report "unknown", because a reported 0 free would
    # trip every pressure path at once and a reported 0 total would look healthy.
    #
    # -P is POSIX output: one record per filesystem on ONE line. Without it a
    # long device name wraps and the columns below read off the wrong line.
    def disk(path = Agent::Paths.workspace_root)
      target = existing_ancestor(path) or return nil
      out, status = Open3.capture2("df", "-Pk", target)
      return nil unless status.success?
      cols = out.lines[1].to_s.split
      return nil if cols.length < 4
      total = cols[1].to_i * 1024
      free = cols[3].to_i * 1024
      return nil if total.zero?
      [free, total]
    rescue Errno::ENOENT
      nil
    end

    # ~/code/ai does not exist on a machine that has never claimed anything, and
    # `df` on a missing path is an error rather than an answer about its volume.
    def existing_ancestor(path)
      current = File.expand_path(path)
      loop do
        return current if File.exist?(current)
        parent = File.dirname(current)
        return nil if parent == current
        current = parent
      end
    end

    # ---- cadence ----

    def state = Agent::Paths.read_json(Agent::Paths.maintenance_file)

    def last_run_at(record = state)
      at = record && record["at"]
      at && (Time.parse(at) rescue nil)
    end

    # :first_run, :pressure, :cadence, or nil when nothing is due. The symbol is
    # carried through to the marker and the log so "why did this run at 11:04"
    # is answerable from the machine.
    def due(now: Time.now, free_bytes: nil)
      last = last_run_at
      return :first_run if last.nil?
      since = now - last
      return :pressure if free_bytes && free_bytes < PRESSURE_FLOOR_BYTES && since >= PRESSURE_COOLDOWN_SECONDS
      return :cadence if since >= CADENCE_SECONDS
      nil
    end

    def pressure?(trigger) = trigger == :pressure

    def aidirs_days(trigger) = pressure?(trigger) ? PRESSURE_AIDIRS_DAYS : ROUTINE_AIDIRS_DAYS
    def docker_days(trigger) = pressure?(trigger) ? PRESSURE_DOCKER_DAYS : ROUTINE_DOCKER_DAYS

    def workspace_days(trigger)
      pressure?(trigger) ? Agent::Gc::PRESSURE_WORKSPACE_DAYS : Agent::Gc::WORKSPACE_DAYS
    end

    # What a run would do, as human-readable lines. Used by --dry-run and by the
    # tick's dry run, so a provisioning smoke test says precisely what the real
    # thing would execute.
    def plan(trigger, now: Time.now)
      entries = Agent::Gc.plan(now: now, workspace_days: workspace_days(trigger))
      ["#{GC_SOURCE}: collect #{entries.length} path(s) (workspaces kept #{workspace_days(trigger)} day(s))",
       "#{AIDIRS_SOURCE}: #{shell_command(AIDIRS_SOURCE, trigger).join(' ')}",
       "#{DOCKER_SOURCE}: #{shell_command(DOCKER_SOURCE, trigger).join(' ')}"]
    end

    # ---- running ----

    # THIS checkout's `dev`, never whatever `dev` is on PATH. The tick
    # fast-forwards Agent::Paths.devops_repo on every Phase A and then runs out
    # of it; a chore that shelled out to a different copy would be running code
    # nothing here updates.
    def dev_bin = File.join(Agent::Paths.devops_repo, "bin", "dev")

    def shell_command(source, trigger)
      case source
      when AIDIRS_SOURCE then [dev_bin, "aidirs", "prune", "--days", aidirs_days(trigger).to_s, "--apply"]
      when DOCKER_SOURCE then [dev_bin, "docker", "prune", "--days", docker_days(trigger).to_s, "--apply"]
      end
    end

    # Runs every chore, and keeps going when one fails: three independent chores
    # on three independent resources, so a broken Docker daemon must not also
    # stop the log collection. Each failure is reported on its own source, which
    # is what lets Agent::Errors count a streak per chore rather than per run.
    #
    # Ordered cheapest-first so a pass that dies partway (the tick is killed, the
    # machine sleeps) has still done the free work.
    def run(now: Time.now, trigger: :cadence)
      free_before, total = disk
      outcomes = [run_gc(now, trigger), run_shell(AIDIRS_SOURCE, trigger), run_shell(DOCKER_SOURCE, trigger)]
      free_after, total_after = disk
      result = Result.new(
        trigger: trigger, at: now, outcomes: outcomes,
        free_before: free_before, free_after: free_after,
        reclaimed_bytes: free_before && free_after ? [free_after - free_before, 0].max : nil,
        disk_total_bytes: total_after || total,
      )
      record(result)
      result
    end

    def run_gc(now, trigger)
      entries = Agent::Gc.plan(now: now, workspace_days: workspace_days(trigger))
      removed = Agent::Gc.apply(entries)
      Outcome.new(source: GC_SOURCE, label: "agent gc", ok: true, message: "collected #{removed} path(s)")
    rescue StandardError => e
      Outcome.new(source: GC_SOURCE, label: "agent gc", ok: false, message: "#{e.class}: #{e.message}")
    end

    def run_shell(source, trigger)
      cmd = shell_command(source, trigger)
      label = cmd.drop(1).reject { |a| a.start_with?("--") || a =~ /\A\d+\z/ }.join(" ")
      out, status = Open3.capture2e({ "LC_ALL" => "en_US.UTF-8" }, *cmd)
      return Outcome.new(source: source, label: label, ok: true, message: "ok") if status.success?

      Outcome.new(source: source, label: label, ok: false,
                  message: "`#{cmd.join(' ')}` exited #{status.exitstatus}: #{tail(out)}")
    rescue Errno::ENOENT => e
      Outcome.new(source: source, label: label, ok: false, message: "could not run #{cmd.first}: #{e.message}")
    end

    # Enough of a failing command's output to diagnose it, bounded because this
    # string is written to a capped on-disk log AND sent to the platform on every
    # runner heartbeat.
    TAIL_LINES = 10

    def tail(output)
      lines = output.to_s.strip.lines.map(&:chomp).reject(&:empty?)
      lines.last(TAIL_LINES).join(" | ")
    end

    # The marker is written for EVERY pass, including one where a chore failed.
    # "This machine attempted maintenance" and "maintenance succeeded" are
    # different facts with different homes: the marker answers the first (and is
    # what stops a failing chore from re-running every 30 seconds), Agent::Errors
    # answers the second.
    def record(result)
      Agent::Paths.write_json(
        Agent::Paths.maintenance_file,
        {
          "at" => result.at.utc.iso8601,
          "trigger" => result.trigger.to_s,
          "reclaimed_bytes" => result.reclaimed_bytes,
          "disk_free_bytes" => result.free_after,
          "disk_total_bytes" => result.disk_total_bytes,
          "outcomes" => result.outcomes.map { |o| { "source" => o.source, "ok" => o.ok, "message" => o.message } },
        },
        mode: 0600,
      )
    end

    # What the tick sends with its runner heartbeat. Disk is re-read here rather
    # than taken from the marker: headroom is a fact about the machine RIGHT NOW,
    # and a report that quoted yesterday's number would be at its least accurate
    # exactly while the disk was filling.
    #
    # Keys are omitted rather than sent as null when unknown — a machine that has
    # never run maintenance has no last_maintenance_at, and that absence is the
    # signal the staleness invariant reads.
    def report(now: Time.now)
      record = state
      free, total = disk
      {
        last_maintenance_at: last_run_at(record)&.utc&.iso8601,
        maintenance_reclaimed_bytes: record && record["reclaimed_bytes"],
        disk_free_bytes: free,
        disk_total_bytes: total,
      }.compact
    end
  end
end
