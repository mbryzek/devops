#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/processes'

# Agent::Processes — finding what an agent session left running (ISS-782).
#
# The failure this guards is a machine nobody is looking at. Twenty orphaned
# `while :; do :; done` subshells — a session's own synthetic load, whose
# trailing `kill $HOGS` was never reached — held a ten-core Mac mini at load ~50
# for thirteen hours and burned 122 CPU-hours, and nothing on the box reaped
# them. Sessions that landed there afterwards competed 1-against-20 at the same
# nice level and could not tell an oversubscribed machine from a wedged command.
#
# Every fixture below is a REAL `ps` line off that runner, kept verbatim rather
# than tidied. The predicate is a licence to SIGKILL unattended, so what it must
# be tested against is the exact text it will actually see — a regex that stops
# matching because the CLI changed its snapshot path by one character is a
# reaper that silently never fires again, which reads identically to a clean box.
class TestDevAgentProcesses < Minitest::Test
  P = Agent::Processes

  SNAPSHOT = "/Users/athena/.claude/shell-snapshots/snapshot-zsh-1786036868124-zq45w8.sh".freeze

  # One of the twenty, verbatim. Its command line is the PARENT zsh's, because a
  # `( ... ) &` subshell never execs and so keeps it — which is exactly why
  # matching the tool-shell shape finds the spin loops themselves.
  HOG = "/bin/zsh -c source #{SNAPSHOT} 2>/dev/null || true && setopt NO_EXTENDED_GLOB " \
        "&& eval 'NCPU=$(sysctl -n hw.ncpu); for i in $(seq 1 $((NCPU*2))); " \
        "do (while :; do :; done) & done; kill $HOGS 2>/dev/null'".freeze

  WRAPPER = "/bin/sh -c claude --print --dangerously-skip-permissions --model claude-opus-5\\[1m\\] " \
            "< /Users/athena/Library/Logs/dev-agent/issues/ISS-782/prompt.md".freeze
  CLI = "claude --print --dangerously-skip-permissions --model claude-opus-5[1m]".freeze

  def entry(pid:, ppid:, pgid:, command:, elapsed: 48_000.0, cpu: 22_000.0)
    P::Entry.new(pid: pid, ppid: ppid, pgid: pgid, command: command,
                 elapsed_seconds: elapsed, cpu_seconds: cpu)
  end

  # The twenty, as they actually stood: orphaned to init, all in the process
  # group of the tool-call shell that forked them, that shell long gone.
  def hogs
    (32_683..32_702).map { |pid| entry(pid: pid, ppid: 1, pgid: 32_496, command: HOG) }
  end

  # A healthy running session. The wrapper is spawned DETACHED, so it too has
  # ppid 1 and is its own group leader — every structural clause the leak
  # predicate applies is satisfied by a live session, and only the `claude` guard
  # keeps it alive. This fixture is the reason that guard exists.
  def live_session(pid: 6734)
    [entry(pid: pid, ppid: 1, pgid: pid, command: WRAPPER),
     entry(pid: pid + 1, ppid: pid, pgid: pid, command: CLI)]
  end

  # ---- parsing ----

  def test_parses_real_ps_output
    procs = P.parse(<<~PS)
      32683     1 32496    13:29:31 367:01.95 #{HOG}
       6734     1  6734       05:01   0:00.01 #{WRAPPER}
    PS
    assert_equal 2, procs.length
    hog = procs.first
    assert_equal [32_683, 1, 32_496], [hog.pid, hog.ppid, hog.pgid]
    assert_in_delta 48_571, hog.elapsed_seconds, 1
    assert_in_delta 22_021.95, hog.cpu_seconds, 0.01
    assert hog.orphan?
  end

  # `command=` is last in PS_FORMAT precisely because it contains spaces, and the
  # split has to stop at five fields or every command is truncated at its first
  # argument — which would silently unmatch every regex here.
  def test_command_keeps_its_spaces
    assert_equal HOG, P.parse("32683 1 32496 13:29:31 367:01.95 #{HOG}\n").first.command
  end

  def test_duration_formats
    assert_in_delta 22_021.95, P.duration("367:01.95"), 0.01  # cpu time, mmm:ss.ss
    assert_in_delta 48_571, P.duration("13:29:31"), 0.01      # etime, hh:mm:ss
    assert_in_delta 301, P.duration("05:01"), 0.01            # etime, mm:ss
    assert_in_delta 183_845, P.duration("2-03:04:05"), 0.01   # etime, dd-hh:mm:ss
    assert_equal 0.0, P.duration(nil)
    assert_equal 0.0, P.duration("?")
  end

  def test_parse_skips_header_and_junk
    assert_empty P.parse("  PID  PPID  PGID     ELAPSED TIME COMMAND\n\n")
  end

  # ---- the leak predicate ----

  def test_finds_the_twenty_orphans
    groups = P.leaked(hogs)
    assert_equal 1, groups.length
    assert_equal 20, groups.first.length
    assert_equal 32_496, groups.first.first.pgid
  end

  # The one that matters most. A live session is structurally identical to a leak
  # — detached wrapper, ppid 1, own group — so without the `claude` guard the
  # hourly sweep would SIGKILL every running session on the machine, including
  # the one that ran it.
  def test_never_reaps_a_live_session
    assert_empty P.leaked(live_session)
    assert_empty P.leaked(live_session + live_session(pid: 6047))
  end

  # A tool call belonging to a live session: its parent is the `claude` process,
  # which is outside the group, so the group is not self-contained.
  def test_never_reaps_a_running_tool_call
    live = live_session
    running = entry(pid: 7871, ppid: 6735, pgid: 7871,
                    command: "/bin/zsh -c source #{SNAPSHOT} 2>/dev/null || true && eval 'sbt test'")
    assert_empty P.leaked(live + [running])
  end

  # Backgrounded work a live session is still using: orphaned to init, but the
  # tool shell that owns it is alive and parented to `claude`.
  def test_never_reaps_a_backgrounded_child_of_a_live_tool_call
    live = live_session
    shell = entry(pid: 7871, ppid: 6735, pgid: 7871, command: "/bin/zsh -c source #{SNAPSHOT} && eval 'x'")
    backgrounded = entry(pid: 7900, ppid: 1, pgid: 7871, command: "/bin/zsh -c source #{SNAPSHOT} && eval 'x'")
    assert_empty P.leaked(live + [shell, backgrounded])
  end

  # `claude-db` is a different binary that appears all over these command lines,
  # and the snapshot PATH itself contains `/.claude/`. Either one matching the
  # live-session guard would disarm the reaper permanently and invisibly.
  def test_claude_guard_does_not_match_claude_db_or_the_snapshot_path
    refute_match P::CLAUDE_SESSION, "/opt/homebrew/bin/claude-db gc --days 3 --apply"
    refute_match P::CLAUDE_SESSION, HOG
    assert_match P::CLAUDE_SESSION, CLI
    assert_match P::CLAUDE_SESSION, WRAPPER
  end

  # The CLI's preamble around the snapshot is its own private business and will
  # change. If a tightened shape ever stops matching, the sweep finds nothing and
  # a runner buried in leaked processes reports exactly what a clean one does —
  # so the pattern pins only "a shell, referencing the snapshot directory".
  def test_tool_shell_survives_a_reordered_preamble
    assert_match P::TOOL_SHELL, "/bin/zsh -c setopt NO_EXTENDED_GLOB && source #{SNAPSHOT} && eval 'x'"
    assert_match P::TOOL_SHELL, "/bin/bash -lc '. #{SNAPSHOT}; make test'"
    assert_match P::TOOL_SHELL, HOG
  end

  # It still has to be a SHELL. Something merely mentioning the path — an editor,
  # a grep, a tail — is not a tool call and is not the sweep's business.
  def test_tool_shell_does_not_match_a_mere_mention_of_the_path
    refute_match P::TOOL_SHELL, "/usr/bin/grep -r foo #{SNAPSHOT}"
    refute_match P::TOOL_SHELL, "/opt/homebrew/bin/rg --files /Users/athena/.claude/shell-snapshots/"
  end

  def test_ignores_processes_that_are_not_agent_sessions
    shell = entry(pid: 33_327, ppid: 33_326, pgid: 33_327, command: "-/bin/zsh")
    postgres = entry(pid: 1567, ppid: 1566, pgid: 1566, command: "postgres: io worker 0")
    assert_empty P.leaked([shell, postgres])
  end

  # A group still owned by something outside it is not abandoned, whatever it
  # looks like otherwise.
  def test_group_with_a_live_owner_outside_it_is_not_leaked
    owned = hogs.map { |p| p.pid == 32_683 ? entry(pid: p.pid, ppid: 999, pgid: 32_496, command: HOG) : p }
    assert_empty P.leaked(owned)
  end

  # The age floor is not about confidence in the verdict — it refuses to race a
  # session that is tearing down right now, where a child can show ppid 1 for a
  # moment while its siblings are still exiting.
  def test_young_orphans_are_left_alone
    young = hogs.map { |p| entry(pid: p.pid, ppid: 1, pgid: p.pgid, command: HOG, elapsed: 30.0) }
    assert_empty P.leaked(young)
    assert_equal 1, P.leaked(young, min_age: 10).length
  end

  # ---- the kill path ----

  # What `Agent::Jobs.kill` was missing: the CLI runs every tool call in its OWN
  # process group, so signalling the session's group reaches the wrapper and the
  # CLI and nothing whatsoever that the session started.
  def test_descendants_crosses_process_group_boundaries
    procs = live_session + [
      entry(pid: 7871, ppid: 6735, pgid: 7871, command: "/bin/zsh -c source #{SNAPSHOT}"),
      entry(pid: 7900, ppid: 7871, pgid: 7871, command: "java -Xmx12G -jar sbt-launch.jar"),
      entry(pid: 7901, ppid: 7900, pgid: 7871, command: "postgres"),
    ]
    found = P.descendants(6734, procs).map(&:pid)
    assert_equal [6735, 7871, 7900, 7901].sort, found.sort
    refute_includes found, 6734, "the leader is signalled through its own group, not walked into"
  end

  # Leaves before parents, so a caller signalling in order never orphans a
  # grandchild by killing its parent first.
  def test_descendants_are_ordered_deepest_first
    procs = [entry(pid: 2, ppid: 1, pgid: 2, command: "a"),
             entry(pid: 3, ppid: 2, pgid: 2, command: "b"),
             entry(pid: 4, ppid: 3, pgid: 2, command: "c")]
    assert_equal [4, 3, 2], P.descendants(1, procs).map(&:pid)
  end

  def test_descendants_of_a_childless_pid_is_empty
    assert_empty P.descendants(6734, live_session(pid: 99).first(1))
  end

  # A ppid cycle is not supposed to happen; a reaper that infinite-loops on one
  # would hang the tick's work phase forever, which is worse than the leak. And
  # the walk must not hand its own starting pid back through the cycle — this
  # feeds a SIGKILL loop running inside the tick.
  def test_descendants_terminates_on_a_parent_cycle_without_returning_the_root
    procs = [entry(pid: 2, ppid: 3, pgid: 2, command: "a"),
             entry(pid: 3, ppid: 2, pgid: 2, command: "b")]
    assert_equal [3], P.descendants(2, procs).map(&:pid)
  end

  # ---- load ----

  def test_load_per_cpu_divides_by_cores
    assert_in_delta 4.919, P.load_per_cpu([49.19, 53.83, 52.06], 10), 0.001
    assert_nil P.load_per_cpu(nil, 10)
    assert_nil P.load_per_cpu([1.0, 1.0, 1.0], nil)
  end
end
