#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The tick itself. It is heavily side-effectful Ruby, so the tests here prove the
# two things a pure-function test cannot:
#
#   1. `--dry-run` walks a FULL tick — vitals, producers, claim — and executes
#      nothing. That is also the provisioning smoke test on a new machine, so a
#      dry run that quietly stopped short would be worse than useless.
#   2. The Phase A / Phase B lock split actually delivers what §4.3 claims:
#      vitals keep running when a previous tick still holds the work lock.
class TestDevAgentTick < Minitest::Test
  include DevTestSupport

  RUNNER_ID = "rnr-1".freeze

  def with_agent_home
    Dir.mktmpdir do |root|
      overrides = {
        "DEV_AGENT_STATE_DIR" => File.join(root, "state"),
        "DEV_AGENT_LOG_ROOT" => File.join(root, "logs"),
        "DEV_AGENT_WORKSPACE_ROOT" => File.join(root, "ai"),
        "DEV_AGENT_CLAUDE_REPO" => File.join(root, "claude"),
        # A stand-in devops checkout: it carries a real copy of `agent/` (so
        # the standing prompt and the githooks resolve) but is NOT a git repo, so no
        # test can reach out and `git pull` the developer's own checkout. The
        # tests that exercise the pull point this at a throwaway clone instead.
        "DEV_AGENT_DEVOPS_REPO" => File.join(root, "devops"),
        "DEV_AGENT_NO_NOTIFY" => "1",
      }
      FileUtils.mkdir_p(File.join(root, "devops"))
      FileUtils.cp_r(File.expand_path("../agent", __dir__), File.join(root, "devops"))
      original = overrides.keys.to_h { |k| [k, ENV[k]] }
      overrides.each { |k, v| ENV[k] = v }
      FileUtils.mkdir_p(ENV["DEV_AGENT_WORKSPACE_ROOT"])
      begin
        yield root
      ensure
        original.each { |k, v| ENV[k] = v }
      end
    end
  end

  def register_identity
    Agent::Paths.write_json(Agent::Paths.identity_file, { "runner_id" => RUNNER_ID, "token" => "tok" }, mode: 0600)
  end

  def runner_row(id: RUNNER_ID, paused: false, max_concurrency: 2, is_stale: false, hostname: "mini.local")
    { "id" => id, "hostname" => hostname, "max_concurrency" => max_concurrency, "paused" => paused,
      "is_stale" => is_stale, "last_heartbeat_at" => Time.now.utc.iso8601 }
  end

  def fleet_responses(paused: false, max_concurrency: 2, runs: [], runners: nil)
    {
      "GET /agent/runners" => runners || [runner_row(paused: paused, max_concurrency: max_concurrency)],
      "GET /agent/producers/runs?limit=100&offset=0" => runs,
    }
  end

  # NetworkGuard reads every credential as absent, which is right for the default
  # but would stop a producer at its token check before it ever files. Anything
  # exercising an issue write opts back in here.
  def with_ai_token
    original = ApiClient.method(:ai_token)
    ApiClient.define_singleton_method(:ai_token) { |use_localhost:| "ai-token" }
    yield
  ensure
    ApiClient.define_singleton_method(:ai_token, original)
  end

  def tick(dry_run: true, now: Time.now)
    Agent::Tick.new(use_localhost: false, claude_argv: headless_claude_argv,
                    dry_run: dry_run, now: now, verbose: true)
  end

  # ---- the environment a session is spawned with ----

  # The credential plumbing, asserted at the tick rather than only inside
  # Agent::Credentials: `resolve` returning the right hash is worth nothing if
  # nothing merges it into the spawn, which is exactly the state ISS-570 found —
  # the key sat in the env repo beside the checkout for the whole history of the
  # fleet and no session ever received it.
  #
  # The value is CredentialsGuard's stand-in, not a real secret.
  def test_a_spawned_session_is_given_the_external_api_credentials
    with_agent_home do
      env = tick.send(:child_env, "i707_abc")
      assert_equal "stub-PLAYBOOK_CLAUDE_KEY", env["PLAYBOOK_CLAUDE_KEY"]
      refute_includes env.keys, "ANTHROPIC_API_KEY",
                      "that variable reconfigures the `claude` CLI the session runs as"
      # ...without displacing what was already there.
      assert_equal Agent::Paths.githooks_dir, env["GIT_CONFIG_VALUE_0"]
    end
  end

  # The runner NAMES the session it spawns, and that name is the whole mechanism
  # the post-session database reclamation below rests on (ISS-588): `claude-db`
  # derives a session's database names from CLAUDE_SESSION_ID, so a runner that
  # set it can drop exactly that session's databases when the process dies —
  # with no age cutoff, and no way to reach another session's data.
  def test_a_spawned_session_is_named_after_its_workspace
    with_agent_home do
      assert_equal "i707_abc", tick.send(:child_env, "i707_abc")["CLAUDE_SESSION_ID"]
    end
  end

  # ---- what a dead session leaves behind ----

  # The line this replaces was `claude-db gc` with NO `--apply`, and gc has been
  # dry-run-by-default since e87d89e: it sampled, wrote a plan to /dev/null and
  # exited 0, so no runner in the fleet ever reclaimed a session database
  # (ISS-588). `--apply` would have been the wrong repair here — gc reaps on AGE
  # across every session on the machine, and the database this session just
  # abandoned is minutes old. `end` names one session and takes only its data.
  def test_a_dead_session_has_its_own_databases_dropped_by_name
    with_agent_home do
      seen = []
      stub_singleton(Open3, :capture2e, lambda { |*args|
        seen << args
        ["", Struct.new(:success?, :exitstatus).new(true, 0)]
      }) do
        capture_stdout { tick(dry_run: false).send(:drop_session_databases, "i707_abc") }
      end

      env, *cmd = seen.fetch(0)
      assert_equal "i707_abc", env["CLAUDE_SESSION_ID"], "the reap must name the session that died"
      assert_equal [Agent::Paths.claude_db_bin, "end"], cmd
      refute_includes cmd, "gc", "gc reaps on age across every session — never from this call site"
    end
  end

  # Everything `cleanup` reclaims is keyed by the slug, and the slug is reused
  # verbatim when the issue is resumed — so a lease released first opens a window
  # in which the next claim starts a session on that slug while this reap is
  # still dropping its database and deleting its working tree underneath it.
  def test_the_reap_reclaims_before_it_releases_the_lease
    with_agent_home do
      register_identity
      order = []
      subject = tick(dry_run: false)
      record = Agent::Jobs.write("issue" => 707, "pid" => 999_999, "slug" => "i707_abc", "branch" => "i707_abc",
                                 "lease_id" => "lse-1", "started_at" => (Time.now - 60).utc.iso8601,
                                 "timeout_at" => (Time.now + 3600).utc.iso8601)
      stubs = {
        Agent::Github => { find_pr_in_workspace: ->(*) { nil }, search_pr: ->(*) { nil },
                           plans_committed_since?: ->(*) { false } },
        Agent::Api => { issue_lease_history: ->(*) { [] } },
        subject => { cleanup: ->(*) { order << :cleanup }, apply_outcome: ->(*) { order << :apply_outcome } },
      }
      with_stubbed_methods(stubs) do
        capture_stdout { subject.send(:reap_one, record, Agent::Host.cached_identity) }
      end
      assert_equal %i[cleanup apply_outcome], order
    end
  end

  # stub_singleton, applied to a whole table at once — six nested blocks say
  # nothing the table does not.
  def with_stubbed_methods(table, &block)
    stub_each(table.flat_map { |obj, methods| methods.map { |name, impl| [obj, name, impl] } }, &block)
  end

  def stub_each(pairs, &block)
    return block.call if pairs.empty?
    obj, name, impl = pairs.first
    stub_singleton(obj, name, impl) { stub_each(pairs.drop(1), &block) }
  end

  # A machine with no Docker running still has an outcome to record and a lease
  # to release, and the hourly `claude-db gc` is the backstop for whatever this
  # could not drop. What must NOT happen is the tick dying here.
  def test_a_failing_database_reap_is_logged_and_does_not_stop_the_reap
    with_agent_home do
      stub_singleton(Open3, :capture2e, ->(*) { raise Errno::ENOENT, "claude-db" }) do
        out = capture_stdout { tick(dry_run: false).send(:drop_session_databases, "i707_abc") }
        assert_match(/claude-db end for i707_abc failed/, out)
      end
    end
  end

  # ---- dry run, end to end ----

  def test_dry_run_walks_every_phase_and_executes_nothing
    with_agent_home do
      register_identity
      out = nil
      decisions = nil
      with_stubbed_api(fleet_responses) do
        out = capture_stdout { decisions = tick.run }
      end

      # Phase A: it says what it WOULD send rather than sending it. The stub
      # would flunk the test on an unstubbed request, so "no heartbeat was sent"
      # is proven by the test still passing.
      assert_match(/would POST \/agent\/runners\/#{RUNNER_ID}\/heartbeat/, out)

      # Phase B: maintenance, the toolchain check, and the claim. NO producer
      # phase — ISS-526 moved scheduling, checking and filing entirely into the
      # platform, so a producer is not something a tick has an opinion about
      # anymore. This assertion is the verification the issue asks for.
      kinds = decisions.map(&:first)
      refute_includes kinds, "producer", "the tick must not evaluate, run or file producers (ISS-526)"
      assert_includes kinds, "claim"
      assert_match(/would POST \/playbook\/issue\/leases/, out)

      # ...and nothing happened.
      assert_empty Dir.children(Agent::Paths.workspace_root), "dry run materialized a workspace"
      refute File.exist?(Agent::Paths.heartbeat_file), "dry run recorded a heartbeat"
      assert_empty Agent::Jobs.all, "dry run wrote a job record"
    end
  end

  def test_dry_run_reports_a_machine_that_has_not_registered
    with_agent_home do
      out = with_stubbed_api({}) { capture_stdout { tick.run } }
      assert_match(/would self-register this machine/, out)
      assert_match(/no runner identity yet/, out)
    end
  end

  def test_dry_run_still_logs_to_the_tick_log
    with_agent_home do
      register_identity
      with_stubbed_api(fleet_responses) { capture_stdout { tick.run } }
      log = Agent::Paths.tick_log(Time.now)
      assert File.file?(log), "expected a tick log at #{log}"
      assert_match(/tick start/, File.read(log))
    end
  end

  # ---- the lock split (§4.3): vitals must never sit behind the work lock ----

  def test_work_phase_is_skipped_when_a_previous_tick_holds_the_lock
    with_agent_home do
      register_identity
      Agent::Paths.mkdir_p(Agent::Paths.state_dir, mode: 0700)
      holder = File.open(Agent::Paths.work_lock, File::CREAT | File::RDWR, 0600)
      assert holder.flock(File::LOCK_EX | File::LOCK_NB), "could not take the lock to simulate a slow tick"

      # No fleet stubs at all: if Phase B ran, it would reach the network and the
      # helper would flunk. Vitals must still run.
      out = with_stubbed_api({}) { capture_stdout { tick.run } }
      assert_match(/work phase busy/, out)
      assert_match(/would POST \/agent\/runners\/#{RUNNER_ID}\/heartbeat/, out,
                   "vitals must not sit behind the work lock")
    ensure
      holder&.close
    end
  end

  def test_paused_runner_claims_nothing
    with_agent_home do
      register_identity
      out = with_stubbed_api(fleet_responses(paused: true)) { capture_stdout { tick.run } }
      assert_match(/runner is paused/, out)
      refute_match(/would POST \/playbook\/issue\/leases/, out)
    end
  end

  # ---- the job census (ISS-454) ----
  #
  # The platform knows what it LEASED; only this side knows whether the process working that lease
  # still exists. These prove the census says so, and that reporting it does not turn the heartbeat
  # into a per-tick write on an idle machine.

  # A pid that is alive for certain, without spawning anything: this test process itself.
  def live_pid = Process.pid

  # A pid that is dead for certain: a child we reap before looking at it.
  def dead_pid
    pid = Process.spawn("/bin/sh", "-c", "exit 0")
    Process.wait(pid)
    pid
  end

  def heartbeat_once(now: Time.now)
    body = nil
    stubs = { "POST /agent/runners/#{RUNNER_ID}/heartbeat" => ->(b) { body = b; runner_row } }
    with_stubbed_api(stubs) do
      capture_stdout { tick(dry_run: false, now: now).heartbeat_runner(Agent::Host.cached_identity) }
    end
    body
  end

  def test_the_census_reports_pid_liveness_which_is_the_whole_point
    with_agent_home do
      register_identity
      Agent::Jobs.write("issue" => 451, "pid" => live_pid, "branch" => "i451_h3o",
                        "started_at" => Time.now.utc.iso8601)
      Agent::Jobs.write("issue" => 452, "pid" => dead_pid, "branch" => "i452_eat",
                        "started_at" => Time.now.utc.iso8601)

      jobs = heartbeat_once.fetch(:jobs)
      assert_equal %w[451 452], jobs.map { |j| j["issue_number"] }
      assert_equal "running", jobs[0]["state"]
      assert_equal "i451_h3o", jobs[0]["branch"]
      assert_equal live_pid, jobs[0]["pid"]

      # The state the admin fleet view could not see before: the lease may already be closed while
      # this row still exists, and vice versa.
      assert_equal "finished_unreaped", jobs[1]["state"]
    end
  end

  def test_an_idle_machine_reports_an_empty_census_rather_than_omitting_it
    with_agent_home do
      register_identity
      assert_equal [], heartbeat_once.fetch(:jobs)
    end
  end

  def test_a_census_change_reports_immediately_instead_of_waiting_out_the_ten_minute_floor
    with_agent_home do
      register_identity
      refute_nil heartbeat_once, "the first heartbeat always sends"

      # Nothing changed and the floor has not elapsed: silence, which is what keeps an idle machine
      # as cheap as it was before the census existed.
      assert_nil heartbeat_once, "an unchanged census re-sent inside the floor"

      # A session starts. That must not wait up to ten minutes to become visible.
      Agent::Jobs.write("issue" => 454, "pid" => live_pid, "branch" => "i454_job_census",
                        "started_at" => Time.now.utc.iso8601)
      assert_equal %w[454], heartbeat_once.fetch(:jobs).map { |j| j["issue_number"] }

      # ...and so must its ending.
      Agent::Jobs.delete(454)
      assert_equal [], heartbeat_once.fetch(:jobs)
    end
  end

  def test_the_ten_minute_floor_still_fires_on_a_machine_where_nothing_changes
    with_agent_home do
      register_identity
      start = Time.now
      refute_nil heartbeat_once(now: start)
      assert_nil heartbeat_once(now: start + 60), "sent inside the floor with no change"
      refute_nil heartbeat_once(now: start + Agent::Tick::RUNNER_HEARTBEAT_SECONDS + 1),
                 "an idle machine must still prove it is alive"
    end
  end

  # ---- the machine's error log on the heartbeat (ISS-527) ----
  #
  # It used to ride the registry report, which is a surface that goes away entirely once scheduling
  # moves server-side (ISS-526). The error log is about the MACHINE, and the machine survives that
  # cutover, so it belongs on the heartbeat.

  def test_the_error_log_rides_the_heartbeat_rather_than_the_registry_report
    with_agent_home do
      register_identity
      Agent::Errors.record("checkout_pull", "pull failed")

      errors = heartbeat_once.fetch(:errors)
      assert_equal ["checkout_pull"], errors.map { |e| e["source"] }
      assert_equal ["pull failed"], errors.map { |e| e["message"] }
    end
  end

  def test_a_machine_with_nothing_wrong_reports_an_empty_error_log_rather_than_omitting_it
    with_agent_home do
      register_identity
      assert_equal [], heartbeat_once.fetch(:errors)
    end
  end

  # The point of the whole re-home. The ten-minute floor is a rate limit, and an infra failure that
  # sits unreported for up to ten minutes is exactly the failure someone is trying to see. The
  # registry report this used to ride was not rate-limited the same way, so moving it naively would
  # have introduced a delay that did not exist before.
  def test_a_new_error_reports_immediately_instead_of_waiting_out_the_ten_minute_floor
    with_agent_home do
      register_identity
      start = Time.now
      refute_nil heartbeat_once(now: start), "the first heartbeat always sends"
      assert_nil heartbeat_once(now: start + 60), "nothing changed inside the floor"

      Agent::Errors.record("checkout_pull", "pull failed")
      sent = heartbeat_once(now: start + 61)
      refute_nil sent, "an error recorded inside the floor must not wait for the next window"
      assert_equal ["checkout_pull"], sent.fetch(:errors).map { |e| e["source"] }
    end
  end

  # Recovery is news too. Agent::Errors.clear on success is the ONLY way a machine says "this
  # stopped failing" and the platform replaces the list wholesale, so a clear that waited out the
  # floor would leave a fixed machine looking broken on the fleet board.
  def test_clearing_a_source_reports_immediately_too
    with_agent_home do
      register_identity
      Agent::Errors.record("checkout_pull", "pull failed")
      start = Time.now
      assert_equal 1, heartbeat_once(now: start).fetch(:errors).size

      Agent::Errors.clear("checkout_pull")
      sent = heartbeat_once(now: start + 60)
      refute_nil sent, "a recovery inside the floor must not wait for the next window"
      assert_equal [], sent.fetch(:errors)
    end
  end

  # ---- the machine's housekeeping vitals on the heartbeat (ISS-528) ----
  #
  # Same re-home as the error log above, one issue later, and for the same reason: the subject is
  # the MACHINE. This half is the one an error channel structurally cannot cover — errors describe
  # runs that BROKE, and from off the box a run that never happened and a clean night are the same
  # silence.

  def test_the_maintenance_vitals_ride_the_heartbeat_rather_than_the_registry_report
    now = Time.utc(2026, 8, 5, 12)
    with_agent_home do |root|
      with_devops_clone(root) do |_origin, _checkout|
        register_identity
        sent = nil
        stub_singleton(Agent::Maintenance, :disk, ->(*) { [11, 22] }) do
          capture_stdout { with_stubbed_api({}) { tick(dry_run: false, now: now).run_maintenance } }
          sent = heartbeat_once(now: now)
        end
        assert_equal "2026-08-05T12:00:00Z", sent[:last_maintenance_at]
        assert_equal 11, sent[:disk_free_bytes]
        assert_equal 22, sent[:disk_total_bytes]
      end
    end
  end

  # A machine that has never pruned sends no timestamp at all, rather than one that would make it
  # look current. The ABSENCE is the signal agent_runner_maintenance_stale reads, so it has to
  # survive the wire as an omitted key rather than a defaulted value.
  def test_a_machine_that_has_never_pruned_reports_no_maintenance_time
    with_agent_home do
      register_identity
      sent = heartbeat_once
      refute sent.key?(:last_maintenance_at)
      refute sent.key?(:maintenance_reclaimed_bytes)
    end
  end

  # A machine whose `df` cannot be read reports nothing rather than 0. A reported 0 would read as a
  # full disk on a machine whose only problem is an unreadable df, and the platform would file about
  # headroom that is probably fine.
  def test_an_unreadable_disk_reports_nothing_rather_than_zero
    with_agent_home do
      register_identity
      sent = nil
      stub_singleton(Agent::Maintenance, :disk, ->(*) { nil }) { sent = heartbeat_once }
      refute sent.key?(:disk_free_bytes)
      refute sent.key?(:disk_total_bytes)
    end
  end

  # The vitals are deliberately NOT part of the change test that forces an early send. Free disk
  # moves on almost every tick, so gating on it would turn a ten-minute heartbeat into a 30-second
  # one — for a signal whose staleness threshold is 48 hours.
  def test_a_disk_that_moved_does_not_force_an_early_heartbeat
    with_agent_home do
      register_identity
      start = Time.now
      free = 900
      stub_singleton(Agent::Maintenance, :disk, ->(*) { [free, 1000] }) do
        refute_nil heartbeat_once(now: start), "the first heartbeat always sends"
        free = 400
        assert_nil heartbeat_once(now: start + 60), "free disk moving is not news worth a send"
        assert_equal 400, heartbeat_once(now: start + Agent::Tick::RUNNER_HEARTBEAT_SECONDS + 1)[:disk_free_bytes],
                     "...but the next scheduled heartbeat carries the current number"
      end
    end
  end

  # Escalation is local — it fires out of update_checkout, not out of the reporting path — so it
  # must cross 3-in-a-row on the tick that gets there regardless of when the heartbeat window falls.
  # update_checkout also runs BEFORE heartbeat_runner in phase_a, so the third failure is reported
  # by the same tick that escalates it rather than by the next one.
  def test_escalation_at_three_in_a_row_does_not_wait_on_the_heartbeat_window
    with_agent_home do
      register_identity
      2.times { Agent::Errors.record("checkout_pull", "pull failed") }
      start = Time.now
      assert_equal 2, heartbeat_once(now: start).fetch(:errors).size

      # The third failure, recorded well inside the floor.
      Agent::Errors.record("checkout_pull", "pull failed")
      assert_equal Agent::Tick::ERROR_ESCALATE_AT, Agent::Errors.count("checkout_pull")
      assert_equal 3, heartbeat_once(now: start + 5).fetch(:errors).size,
                   "the streak that triggers escalation must be visible on the platform at once"
    end
  end

  def test_a_failed_heartbeat_leaves_the_change_pending_so_the_next_tick_retries_it
    with_agent_home do
      register_identity
      Agent::Jobs.write("issue" => 454, "pid" => live_pid, "started_at" => Time.now.utc.iso8601)

      down = { "POST /agent/runners/#{RUNNER_ID}/heartbeat" => ->(_b) { raise ApiError.new("HTTP 503", code: 503) } }
      assert_raises(ApiError) do
        with_stubbed_api(down) do
          capture_stdout { tick(dry_run: false).heartbeat_runner(Agent::Host.cached_identity) }
        end
      end

      # Comparing against what was SENT rather than against the last tick's census is what makes
      # this a retry instead of a silently dropped report.
      assert_equal %w[454], heartbeat_once.fetch(:jobs).map { |j| j["issue_number"] }
    end
  end

  # ---- the hard timeout, enforced with no platform involved ----

  def test_timed_out_job_is_killed_even_when_the_platform_is_unreachable
    with_agent_home do
      register_identity
      # A live pid we control, already past its deadline.
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid)
      Agent::Jobs.write("issue" => 120, "pid" => pid, "slug" => "i120_abc", "branch" => "i120_abc",
                        "lease_id" => "lease-1", "started_at" => (Time.now - 5 * 3600).utc.iso8601,
                        "timeout_at" => (Time.now - 3600).utc.iso8601)

      # The platform is DOWN: the runner heartbeat blows up. The timeout must
      # still be enforced — an API outage cannot be allowed to produce an
      # immortal job. It is now enforced on the ORDINARY path rather than the
      # degraded one: the runner heartbeat carries its own rescue, so phase_a
      # runs on to heartbeat_leases, which checks every record's deadline before
      # it renews anything. `enforce_timeouts` stays the backstop for an outage
      # that takes out ensure_identity too.
      unreachable = {
        "POST /agent/runners/#{RUNNER_ID}/heartbeat" => ->(_body) { raise ApiError.new("HTTP 503", code: 503) },
      }
      out = with_stubbed_api(unreachable) { capture_stdout { tick(dry_run: false).phase_a } }
      assert_match(/runner heartbeat failed/, out)
      assert_match(/exceeded its 4h hard timeout/, out)
      # Give the kill a moment to land.
      20.times { break unless Agent::Jobs.alive?(pid); sleep 0.1 }
      refute Agent::Jobs.alive?(pid), "the hard timeout must kill the session"
    ensure
      Process.kill("KILL", pid) rescue nil
    end
  end

  # ISS-364 #2. The killer is the only thing that knows a kill happened: it
  # destroys the exit_code file the reap would otherwise read. So it writes what
  # it did onto the job record, BEFORE signalling, and the reap reads it back.
  def test_a_timeout_kill_is_recorded_on_the_job_record
    with_agent_home do
      register_identity
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid)
      Agent::Jobs.write("issue" => 120, "pid" => pid, "slug" => "i120_abc", "branch" => "i120_abc",
                        "lease_id" => "lease-1", "started_at" => (Time.now - 5 * 3600).utc.iso8601,
                        "timeout_at" => (Time.now - 3600).utc.iso8601)
      with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).enforce_timeouts } }
      assert_equal "timeout", Agent::Jobs.find(120).dig("killed", "reason")
    ensure
      Process.kill("KILL", pid) rescue nil
    end
  end

  # A 409 on the lease heartbeat means the lease expired or was reassigned, so
  # this process must die rather than race another machine. It was then reaped as
  # "session completed with nothing to do" — the reap reporting a completion for
  # a session the tick had killed five seconds earlier.
  def test_a_lost_lease_kill_is_recorded_and_classifies_as_a_kill
    with_agent_home do
      register_identity
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid)
      record = Agent::Jobs.write("issue" => 121, "pid" => pid, "slug" => "i121_abc", "branch" => "i121_abc",
                                 "lease_id" => "lease-9", "started_at" => Time.now.utc.iso8601,
                                 "timeout_at" => (Time.now + 3600).utc.iso8601)
      gone = { "POST /playbook/issue/leases/lease-9/heartbeat" => ->(_body) { raise ApiError.new("HTTP 409", code: 409) } }
      out = with_stubbed_api(fleet_responses.merge(gone)) do
        capture_stdout { tick(dry_run: false).heartbeat_leases(Agent::Host.cached_identity) }
      end
      assert_match(/lease_lost/, out)
      assert_equal "lease_lost", Agent::Jobs.find(121).dig("killed", "reason")

      # ...and that record is what stops the reap from calling it a completion.
      result = Agent::Outcome.classify(pr: nil, plans_committed: false, exit_code: nil, producer_filed: false,
                                       killed: Agent::Jobs.find(121)["killed"])
      assert_equal "open", result.status, "a killed attempt returns to the queue, it does not park for a human"
      assert_match(/KILLED by the tick/, result.reason)
      refute_match(/completed/, result.reason)
      assert_equal record["issue"], 121
    ensure
      Process.kill("KILL", pid) rescue nil
    end
  end

  # The two heartbeats do different jobs and only one of them keeps live work
  # alive. The runner heartbeat is REPORTING — a machine that misses one looks
  # briefly quiet on the fleet page. The lease heartbeats are what stop
  # `expire_issue_leases` pulling an issue back to `open` underneath a session
  # that is still running it: the "machine competes with itself" failure this
  # module's header is written around.
  #
  # They used to be one unrescued sequence, so a single 500 on the registry POST
  # aborted phase_a and every running job went that tick without a renewal —
  # the failure arriving through the code built to prevent it. These pin the
  # ordering guarantee in both directions.
  def test_a_failed_runner_heartbeat_does_not_cost_the_lease_heartbeats
    with_agent_home do
      register_identity
      beat = []
      stubs = fleet_responses.merge(
        "POST /agent/runners/#{RUNNER_ID}/heartbeat" => ->(_body) { raise ApiError.new("HTTP 503", code: 503) },
        "POST /playbook/issue/leases/lease-1/heartbeat" => ->(_body) { beat << "lease-1"; {} },
      )
      Agent::Jobs.write("issue" => 130, "pid" => Process.pid, "slug" => "i130_abc", "branch" => "i130_abc",
                        "lease_id" => "lease-1", "started_at" => Time.now.utc.iso8601,
                        "timeout_at" => (Time.now + 3600).utc.iso8601)
      out = with_stubbed_api(stubs) { capture_stdout { tick(dry_run: false).phase_a } }
      assert_match(/runner heartbeat failed/, out)
      assert_equal ["lease-1"], beat, "a reporting failure must not stop the renewals that keep work alive"
    end
  end

  # ...and one job's lease failing must not starve the others. The loop walks
  # every record, so an ApiError that escaped it took every job after this one
  # in iteration order down with it — silently, tick after tick, for as long as
  # the first job's error persisted. Only a 409 is a verdict about the lease
  # (it is gone, kill the session); anything else is the platform having a bad
  # moment and is per-record.
  def test_one_lease_heartbeat_failing_does_not_starve_the_others
    with_agent_home do
      register_identity
      beat = []
      stubs = fleet_responses.merge(
        "POST /playbook/issue/leases/lease-a/heartbeat" => ->(_body) { raise ApiError.new("HTTP 500", code: 500) },
        "POST /playbook/issue/leases/lease-b/heartbeat" => ->(_body) { beat << "lease-b"; {} },
      )
      Agent::Jobs.write("issue" => 131, "pid" => Process.pid, "slug" => "i131_abc", "branch" => "i131_abc",
                        "lease_id" => "lease-a", "started_at" => Time.now.utc.iso8601,
                        "timeout_at" => (Time.now + 3600).utc.iso8601)
      Agent::Jobs.write("issue" => 132, "pid" => Process.pid, "slug" => "i132_abc", "branch" => "i132_abc",
                        "lease_id" => "lease-b", "started_at" => Time.now.utc.iso8601,
                        "timeout_at" => (Time.now + 3600).utc.iso8601)
      out = with_stubbed_api(stubs) do
        capture_stdout { tick(dry_run: false).heartbeat_leases(Agent::Host.cached_identity) }
      end
      assert_equal ["lease-b"], beat, "ISS-132's lease must still be renewed when ISS-131's call fails"
      assert_match(/lease heartbeat failed/, out)
      # A non-409 says nothing about whether the lease is still ours, so the
      # session keeps running — only a 409 kills it.
      assert_nil Agent::Jobs.find(131)["killed"]
    end
  end

  def test_timed_out_job_is_only_reported_in_a_dry_run
    with_agent_home do
      register_identity
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid)
      Agent::Jobs.write("issue" => 120, "pid" => pid, "slug" => "i120_abc", "branch" => "i120_abc",
                        "lease_id" => "lease-1", "started_at" => (Time.now - 5 * 3600).utc.iso8601,
                        "timeout_at" => (Time.now - 3600).utc.iso8601)
      with_stubbed_api(fleet_responses) { capture_stdout { tick.run } }
      assert Agent::Jobs.alive?(pid), "a dry run must not kill anything"
    ensure
      Process.kill("KILL", pid) rescue nil
    end
  end

  # ---- the claim contract ----
  #
  # API Builder refuses to let a resource vary its type across 2xx codes, so
  # "nothing claimable" is a 200 whose `lease` is ABSENT rather than a 204. The
  # tick must read the wrapper, and must keep the one genuine failure — 422 —
  # out of that quiet path.

  def claim_with(response)
    out = nil
    with_agent_home do
      register_identity
      with_stubbed_api({ "POST /playbook/issue/leases" => response }) do
        out = capture_stdout do
          tick(dry_run: false).claim(Agent::Host.cached_identity, runner_row)
        end
      end
      yield if block_given?
    end
    out
  end

  def test_an_empty_claim_wrapper_is_the_quiet_idle_case
    workspaces = nil
    out = claim_with({}) { workspaces = Dir.children(Agent::Paths.workspace_root) } # 200, `lease` absent
    refute_match(/REJECTED/, out)
    assert_empty workspaces, "nothing claimable must not materialize a workspace"
  end

  # An unknown runner_id is a client bug, not "no work". Swallowing it would
  # leave a machine looking healthy and claiming nothing forever.
  def test_unknown_runner_is_loud_and_clears_the_identity_cache
    identity_file = nil
    out = claim_with(->(_body) { raise ApiError.new("HTTP 422 POST /playbook/issue/leases: unknown runner", code: 422) }) do
      identity_file = File.exist?(Agent::Paths.identity_file)
    end
    assert_match(/REJECTED \(422\)/, out)
    assert_match(/re-registers/, out)
    refute identity_file, "a 422 must drop the stale identity cache so the next tick re-registers"
  end

  def test_an_unexpected_claim_error_is_not_swallowed
    assert_raises(ApiError) do
      claim_with(->(_body) { raise ApiError.new("HTTP 500", code: 500) })
    end
  end

  # ---- claim-time playbook resolution (ISS-505, ISS-526) ----
  #
  # The platform files a POINTER; the runner resolves it against
  # `GET /agent/playbooks/:key` when it claims. That is the entire point — an issue
  # filed on Friday and claimed on Tuesday must run TUESDAY's procedure — so what
  # these prove is that the read happens HERE, that what was read is recorded, and
  # that a pointer which does not resolve stops the claim instead of starting a
  # session that would do something else.
  #
  # The pointer used to be a path into this runner's devops checkout, which is why
  # the staleness warnings that used to live here are gone: the playbook no longer
  # comes off the machine, so this machine's checkout being behind cannot make it
  # stale.

  PLAYBOOK_KEY = "weekly-review".freeze

  PLAYBOOK_VERSION = "2026-08-05T14:04:20.055Z".freeze

  PLAYBOOK_BODY = "# Weekly code review\n\nPosture: full-auto. Review the week's merges.".freeze

  # Drives one real claim with Jobs.spawn_session stubbed: everything up to and
  # including the prompt is exercised, and no `claude` is launched.
  def claim_one(body:, number: 707, errors: [], playbooks: nil)
    seen = { comments: [], statuses: [], released: [], prompt: nil, spawned: false }
    with_agent_home do
      register_identity
      Agent::Errors.write(errors) unless errors.empty?
      with_ai_token do
        stubs = {
          "POST /playbook/issue/leases" => { "lease" => { "id" => "lse-1", "issue_number" => number } },
          "GET /playbook/issues/#{number}" =>
            { "number" => number, "title" => "Weekly code review: platform", "category" => "infrastructure",
              "body" => body },
          "GET /playbook/issues/#{number}/comments?limit=101&offset=0" => [],
          "POST /playbook/issues/#{number}/comments" => ->(b) { seen[:comments] << b[:body]; {} },
          "PUT /playbook/issues/#{number}/status" => ->(b) { seen[:statuses] << b; {} },
          "DELETE /playbook/issue/leases/lse-1" => ->(_b) { seen[:released] << "lse-1"; {} },
        }
        # The playbook store, as this claim will see it. nil for a key means the
        # platform has never heard of it — a 404, which Agent::Api turns into nil.
        (playbooks || { PLAYBOOK_KEY => { "key" => PLAYBOOK_KEY, "body" => PLAYBOOK_BODY,
                                          "created_at" => PLAYBOOK_VERSION } }).each do |key, row|
          stubs["GET /agent/playbooks/#{key}"] = row
        end
        spawn = lambda do |argv:, prompt:, workspace:, number:, env: {}|
          seen[:prompt] = prompt
          seen[:spawned] = true
          Process.pid
        end
        stub_singleton(Agent::Jobs, :spawn_session, spawn) do
          with_stubbed_api(stubs) do
            seen[:out] = capture_stdout do
              tick(dry_run: false).claim(Agent::Host.cached_identity, runner_row(max_concurrency: 1))
            end
          end
        end
      end
    end
    seen
  end

  POINTER = "Playbook: `#{PLAYBOOK_KEY}`".freeze

  def test_the_session_is_handed_the_playbook_read_at_claim_time
    seen = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n")
    assert seen[:spawned], "the session must still start"
    assert_match(/^# Playbook — #{PLAYBOOK_KEY} @ #{Regexp.escape(PLAYBOOK_VERSION)}$/, seen[:prompt],
                 "the prompt gets the resolved playbook, labelled with the version it was read at")
    assert_match(/Posture: full-auto/, seen[:prompt], "the FULL procedure reaches the session")
    assert_operator seen[:prompt].index("# Playbook —"), :<, seen[:prompt].index("# Issue comments"),
                    "comments stay last so the most recent instruction is read last"
  end

  # Requirement 2: the run has to stay reproducible after the playbook changes, so
  # WHAT was read and at WHICH version go on the timeline. The version is worth
  # naming because the store is append-only (ISS-523) — the row it names is still
  # there after any number of later edits.
  def test_the_first_comment_records_the_playbook_and_the_version_it_was_read_at
    seen = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n")
    comment = seen[:comments].first
    assert_match(/^Claimed by /, comment, "the claim line still leads")
    assert_match(/^Playbook: #{PLAYBOOK_KEY} @ #{Regexp.escape(PLAYBOOK_VERSION)}$/, comment)
  end

  # ISS-360: a producer ported without its playbook silently fell back to generic
  # triage and filed issues instead of shipping PRs for a week. A pointer that
  # does not resolve reintroduces exactly that, so it must be a HARD stop.
  def test_a_pointer_that_does_not_resolve_starts_no_session_at_all
    seen = claim_one(body: "Filed by a producer.\n\nPlaybook: `never-existed`\n",
                     playbooks: { "never-existed" => nil })
    refute seen[:spawned], "a session without its playbook does a different job than the one scheduled"
    assert_equal ["needs_input"], seen[:statuses].map { |s| s[:status] },
                 "a human has to fix it — releasing would just be re-claimed and re-fail every 30s"
    assert_match(/does not exist in the platform/, seen[:statuses].first[:comment])
    assert_equal ["lse-1"], seen[:released], "the lease must not be left held by a session that never started"
    assert_match(/no session started/, seen[:out])
  end

  # Every issue a human wrote, and every issue filed before pointers existed,
  # carries its brief inline. Those must be completely untouched.
  def test_an_issue_with_no_pointer_claims_exactly_as_before
    seen = claim_one(body: "Mike wrote this one by hand. The fix is in TaskDao.")
    assert seen[:spawned]
    assert_empty seen[:statuses], "nothing to resolve means nothing to fail on"
    refute_match(/^Playbook:/, seen[:comments].first)
    refute_match(/# Playbook/, seen[:prompt])
  end

  # ---- runner staleness is the PLATFORM's alert, not a runner's ----

  # Restores the real method rather than removing it — Notify.event is a
  # module_function, so remove_method would delete it for every later test in
  # the file rather than just undoing the stub.
  def capturing_events
    captured = []
    original = Agent::Notify.method(:event)
    Agent::Notify.define_singleton_method(:event) do |kind, text|
      captured << [kind, text]
      Agent::Notify::DELIVERED
    end
    no_notify = ENV.delete("DEV_AGENT_NO_NOTIFY")
    yield captured
    captured
  ensure
    Agent::Notify.define_singleton_method(:event, original)
    ENV["DEV_AGENT_NO_NOTIFY"] = no_notify
  end

  # ISS-535. The tick used to push an openclaw event for every OTHER runner the
  # fleet response called stale, and that is the wrong place for this alert by
  # construction: it needs a peer to be awake, so the machine that matters most —
  # the only one, or the last one standing — reports nothing. It also never
  # delivered, because `openclaw` is not on the runners.
  #
  # `CheckAgentRunnerHealthProcessor` (platform, every 15 minutes, emails on the
  # crossing tick) owns it, off the same AgentInvariants.StaleAfterHours that
  # produced the `is_stale` below. This test is the guard against someone helpfully
  # re-adding the local copy.
  def test_a_stale_peer_produces_no_runner_local_notification
    events = with_agent_home do
      register_identity
      capturing_events do
        fleet = fleet_responses(runners: [runner_row,
                                          runner_row(id: "rnr-2", hostname: "mini-2.local", is_stale: true),
                                          runner_row(id: "rnr-3", hostname: "mini-3.local", is_stale: false)])
        with_stubbed_api(fleet) { capture_stdout { tick.run } }
      end
    end
    assert_empty events, "runner-offline is the platform's alert (CheckAgentRunnerHealthProcessor), not a peer runner's"
  end

  # ---- the ~/code/claude push guard is ENFORCED, not merely instructed ----

  def test_pre_push_hook_refuses_a_claude_repo_push_outside_plans
    Dir.mktmpdir do |root|
      repo = File.join(root, "claude")
      init_repo(repo)
      write_commit(repo, "plans/a.md", "ok")
      base = `git -C #{repo} rev-parse HEAD`.strip
      write_commit(repo, "CLAUDE.md", "persisted!")
      head = `git -C #{repo} rev-parse HEAD`.strip

      out, status = run_hook(repo, "refs/heads/main #{head} refs/heads/main #{base}")
      refute status.success?, "a push touching CLAUDE.md must be refused"
      assert_match(/REFUSED/, out)
      assert_match(/CLAUDE\.md/, out)
    end
  end

  def test_pre_push_hook_allows_a_plans_only_push
    Dir.mktmpdir do |root|
      repo = File.join(root, "claude")
      init_repo(repo)
      write_commit(repo, "plans/a.md", "ok")
      base = `git -C #{repo} rev-parse HEAD`.strip
      write_commit(repo, "plans/b.md", "also ok")
      head = `git -C #{repo} rev-parse HEAD`.strip

      _out, status = run_hook(repo, "refs/heads/main #{head} refs/heads/main #{base}")
      assert status.success?, "a plans/-only push must go through"
    end
  end

  def test_pre_push_hook_ignores_every_other_repo
    Dir.mktmpdir do |root|
      repo = File.join(root, "platform")
      init_repo(repo)
      write_commit(repo, "build.sbt", "x")
      base = `git -C #{repo} rev-parse HEAD`.strip
      write_commit(repo, "app/Main.scala", "y")
      head = `git -C #{repo} rev-parse HEAD`.strip

      # Guarded repo is a DIFFERENT path, so the hook must not interfere.
      _out, status = run_hook(repo, "refs/heads/main #{head} refs/heads/main #{base}",
                              guarded: File.join(root, "claude"))
      assert status.success?, "the hook must never be the reason a normal push fails"
    end
  end

  # ---- ISS-393: the tick pulls its own devops checkout ----
  #
  # One push to devops has to reach the whole fleet. Before this, a producer
  # prompt change meant logging into every machine, so "the prompt in git is
  # the registry" was true only of the file, never of what a machine was running.

  # An `origin` with one commit, and a clone of it pointed at by
  # DEV_AGENT_DEVOPS_REPO. Returns [origin, checkout].
  def with_devops_clone(root)
    origin = File.join(root, "devops-origin")
    init_repo(origin)
    write_commit(origin, "agent/instructions.md", "# standing prompt\n")
    checkout = File.join(root, "devops-checkout")
    system("git", "clone", "-q", origin, checkout, out: File::NULL, err: File::NULL)
    previous = ENV["DEV_AGENT_DEVOPS_REPO"]
    ENV["DEV_AGENT_DEVOPS_REPO"] = checkout
    yield origin, checkout
  ensure
    ENV["DEV_AGENT_DEVOPS_REPO"] = previous
  end

  def head_of(dir) = `git -C #{dir} rev-parse HEAD`.strip

  def test_the_tick_fast_forwards_its_devops_checkout
    with_agent_home do |root|
      with_devops_clone(root) do |origin, checkout|
        write_commit(origin, "agent/instructions.md", "# standing prompt\n# newer\n")
        register_identity
        with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).update_checkout } }
        assert_equal head_of(origin), head_of(checkout), "one push to devops must reach the machine"
      end
    end
  end

  # A checkout that has diverged with a CLEAN tree on main has no local
  # explanation left for the refused fast-forward — the only remaining cause is
  # upstream history that no longer fast-forwards from here (a rebase, a
  # force-push). `pull` recovers automatically via fetch + reset --hard, so this
  # is NOT reported as a failure at all.
  def test_a_clean_diverged_checkout_on_main_recovers_via_reset
    with_agent_home do |root|
      with_devops_clone(root) do |origin, checkout|
        write_commit(origin, "agent/instructions.md", "# theirs\n")
        write_commit(checkout, "agent/instructions.md", "# ours\n")
        register_identity
        out = with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).update_checkout } }
        refute_match(/devops pull failed/, out)
        assert_equal head_of(origin), head_of(checkout), "a clean, diverged checkout on main must recover onto origin/main"
      end
    end
  end

  # A DIRTY tree must never be touched, no matter what the pull refused for —
  # that's Mike (or a claimed session) doing interactive work in this exact
  # checkout, and the fallback reset would bulldoze it.
  def test_a_dirty_checkout_is_left_completely_alone
    with_agent_home do |root|
      with_devops_clone(root) do |origin, checkout|
        write_commit(origin, "agent/instructions.md", "# theirs\n")
        File.write(File.join(checkout, "agent/instructions.md"), "# uncommitted local edit\n")
        local = head_of(checkout)
        register_identity
        out = with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).update_checkout } }
        assert_match(/devops pull failed/, out)
        assert_equal local, head_of(checkout), "a dirty checkout must never be reset"
        assert_equal "# uncommitted local edit\n", File.read(File.join(checkout, "agent/instructions.md")),
                     "a dirty checkout's working tree must be left exactly as the human left it"
        assert_empty Agent::Errors.list, "a benign skip (dirty tree) must never be recorded as a reportable failure"
      end
    end
  end

  # A checkout on a branch other than main, with a refused fast-forward, is the
  # same story as a dirty tree — interactive work in progress — and must be
  # left alone rather than reset. (A clean checkout out on some other branch
  # name that CAN fast-forward is not this case at all: `git pull origin main`
  # merges into whatever branch is checked out, so that just succeeds.)
  def test_a_checkout_not_on_main_is_left_completely_alone
    with_agent_home do |root|
      with_devops_clone(root) do |origin, checkout|
        write_commit(origin, "agent/instructions.md", "# theirs\n")
        system("git", "-C", checkout, "checkout", "-qb", "feature", out: File::NULL, err: File::NULL)
        write_commit(checkout, "agent/instructions.md", "# ours, on feature\n")
        local = head_of(checkout)
        register_identity
        out = with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).update_checkout } }
        assert_match(/devops pull failed/, out)
        assert_equal local, head_of(checkout), "a checkout on another branch must never be reset"
        assert_empty Agent::Errors.list, "a benign skip (wrong branch) must never be recorded as a reportable failure"
      end
    end
  end

  # A real failure — clean, on main, and even the fetch+reset fallback fails
  # (no remote reachable) — must be durably recorded, and must escalate exactly
  # once it crosses 3 consecutive failures.
  def test_three_consecutive_real_pull_failures_notify_and_file_an_issue
    with_agent_home do |root|
      origin = File.join(root, "devops-origin")
      init_repo(origin)
      write_commit(origin, "agent/instructions.md", "# standing prompt\n")
      checkout = File.join(root, "devops-checkout")
      system("git", "clone", "-q", origin, checkout, out: File::NULL, err: File::NULL)
      previous = ENV["DEV_AGENT_DEVOPS_REPO"]
      ENV["DEV_AGENT_DEVOPS_REPO"] = checkout
      # A remote that no longer exists: `git pull --ff-only` AND the fetch+reset
      # fallback both fail, for a reason that has nothing to do with the local
      # tree — exactly the "real failure" case.
      system("git", "-C", checkout, "remote", "set-url", "origin", File.join(root, "does-not-exist"))
      register_identity
      filed = nil
      with_ai_token do
        stubs = fleet_responses.merge("POST /playbook/issues" => ->(body) { filed = body; { "number" => 999, "occurrence_count" => 1 } })
        with_stubbed_api(stubs) do
          capture_stdout { tick(dry_run: false).update_checkout }
          capture_stdout { tick(dry_run: false).update_checkout }
          assert_nil filed, "must not escalate before the 3rd consecutive failure"
          capture_stdout { tick(dry_run: false).update_checkout }
        end
      end
      assert_equal 3, Agent::Errors.count("checkout_pull")
      refute_nil filed, "the 3rd consecutive failure must file an issue"
      assert_equal "bug", filed[:category]
      assert_match(/checkout_pull:\d{4}-\d{2}-\d{2}/, filed[:fingerprint])
      refute filed[:claim_on_create]
    ensure
      ENV["DEV_AGENT_DEVOPS_REPO"] = previous
    end
  end

  # A success after a streak — even one short of escalation — must clear it, so
  # a machine that recovers on its own never accumulates toward a stale streak.
  def test_a_successful_pull_clears_a_prior_failure_streak
    with_agent_home do |root|
      with_devops_clone(root) do |origin, checkout|
        register_identity
        Agent::Errors.record("checkout_pull", "prior failure", now: Time.now)
        assert_equal 1, Agent::Errors.count("checkout_pull")
        with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).update_checkout } }
        assert_equal 0, Agent::Errors.count("checkout_pull"), "a clean success must clear the streak"
      end
    end
  end

  def test_a_dry_run_never_pulls
    with_agent_home do |root|
      with_devops_clone(root) do |origin, checkout|
        write_commit(origin, "agent/instructions.md", "# newer\n")
        before = head_of(checkout)
        out = capture_stdout { tick.update_checkout }
        assert_match(/would pull/, out)
        assert_equal before, head_of(checkout), "a dry run must not move the checkout"
      end
    end
  end

  # ---- ISS-520: housekeeping is runner-local, not a producer ----
  #
  # The bug: agent-gc, aidirs-prune and docker-prune were producers, so they ran
  # behind the fleet-wide daily compare-and-set. With N runners exactly one
  # machine won each lock per day and N-1 machines never collected a log, never
  # pruned a feature dir and never pruned an image — silently, on the box nobody
  # watches, until the disk filled and took Docker with it.

  # No stubs at all: every platform call in this test would flunk on the
  # unstubbed-request guard. That is the assertion — housekeeping takes no lock,
  # starts no producer run, and asks nobody for permission, so two runners both
  # prune on the same day and neither writes an agent_producer_run row.
  def test_maintenance_runs_with_no_platform_call_at_all
    with_agent_home do
      register_identity
      ran = []
      stub_singleton(Agent::Maintenance, :run_shell, lambda { |source, trigger|
        ran << source
        Agent::Maintenance::Outcome.new(source: source, label: source, ok: true, message: "ok")
      }) do
        with_stubbed_api({}) { capture_stdout { tick(dry_run: false).run_maintenance } }
      end
      assert_equal Agent::Maintenance::SHELL_SOURCES, ran
      refute_nil Agent::Maintenance.last_run_at, "the pass must stamp its own marker"
    end
  end

  # Hygiene must not depend on the control plane. If the platform is unreachable
  # for a week every machine must still prune — the moment you most need disk
  # headroom is the moment things are already broken — so maintenance runs BEFORE
  # the identity check and before anything that can raise ApiError.
  def test_maintenance_runs_on_a_machine_the_platform_has_never_heard_of
    with_agent_home do
      out = with_stubbed_api({}) { capture_stdout { tick(dry_run: false).phase_b } }
      assert_match(/no runner identity yet/, out)
      refute_nil Agent::Maintenance.last_run_at, "an unregistered machine still has to collect its own disk"
    end
  end

  def test_a_dry_run_says_what_it_would_prune_and_prunes_nothing
    with_agent_home do
      register_identity
      out = with_stubbed_api({}) { capture_stdout { tick.run_maintenance } }
      assert_match(/maintenance: first_run — would run: /, out)
      assert_match(/docker prune --days 7 --apply/, out)
      assert_nil Agent::Maintenance.last_run_at, "a dry run must not claim the machine was pruned"
    end
  end

  # A chore that keeps failing must reach a human, and before ISS-520 it could
  # not: the 3-in-a-row escalation was hard-coded to `checkout_pull`. Agent::Errors
  # already derives the streak by counting a source's entries, so the threshold
  # was the only thing that was source-specific.
  def test_three_consecutive_maintenance_failures_escalate_like_any_other_source
    with_agent_home do
      register_identity
      filed = nil
      stub_singleton(Agent::Maintenance, :run_shell, lambda { |source, _trigger|
        Agent::Maintenance::Outcome.new(source: source, label: source, ok: source != Agent::Maintenance::DOCKER_SOURCE,
                                        message: "`docker prune` exited 1: Cannot connect to the Docker daemon")
      }) do
        with_ai_token do
          stubs = { "POST /playbook/issues" => ->(body) { filed = body; { "number" => 42, "occurrence_count" => 1 } } }
          with_stubbed_api(stubs) do
            3.times do |i|
              # The marker is what stops a failing chore re-running every tick,
              # so each pass has to be separately due.
              File.delete(Agent::Paths.maintenance_file) if File.exist?(Agent::Paths.maintenance_file)
              capture_stdout { tick(dry_run: false).run_maintenance }
              assert_nil filed, "must not escalate before the 3rd consecutive failure" if i < 2
            end
          end
        end
      end
      assert_equal 3, Agent::Errors.count(Agent::Maintenance::DOCKER_SOURCE)
      assert_equal 0, Agent::Errors.count(Agent::Maintenance::AIDIRS_SOURCE),
                   "a chore that succeeded must have no streak, whatever its neighbours did"
      refute_nil filed, "the 3rd consecutive failure must file an issue"
      assert_match(/docker_prune:\d{4}-\d{2}-\d{2}/, filed[:fingerprint])
      assert_match(/docker_prune failing on /, filed[:title])
      refute filed[:claim_on_create]
    end
  end

  def test_a_successful_pass_clears_a_prior_maintenance_streak
    with_agent_home do
      register_identity
      Agent::Errors.record(Agent::Maintenance::DOCKER_SOURCE, "prior failure", now: Time.now)
      with_stubbed_api({}) { capture_stdout { tick(dry_run: false).run_maintenance } }
      assert_equal 0, Agent::Errors.count(Agent::Maintenance::DOCKER_SOURCE)
    end
  end

  # ---- ISS-531: a missing host binary has to be LOUD ----
  #
  # The bug: `depsguard` was never installed on the runner, so the weekly
  # supply-chain scan exited 2, the producer recorded `check_failed`, and
  # `check_failed` is deliberately indistinguishable from a clean week. The
  # producer had run once in its entire history and filed nothing, and from
  # inside any single tick that reads as a producer with nothing to say.

  # A result with `missing` absent from the agent's PATH and everything else
  # present, without depending on what is installed on the box running the suite.
  def toolchain_result(missing:, now: Time.now, tools: Agent::Toolchain::TOOLS)
    found = tools.map do |tool|
      present = !missing.include?(tool.name)
      Agent::Toolchain::Found.new(tool: tool, path: present ? "/stub/bin/#{tool.name}" : nil, version: nil)
    end
    Agent::Toolchain::Result.new(at: now, path: "/stub/bin", found: found)
  end

  # Built eagerly: stub_singleton rebinds the block to the module, so anything
  # the lambda calls on the test instance is gone by the time the tick runs it.
  def with_toolchain(missing:, tools: Agent::Toolchain::TOOLS, &block)
    result = toolchain_result(missing: missing, tools: tools)
    stub_singleton(Agent::Toolchain, :check, ->(**_opts) { result }, &block)
  end

  def test_a_missing_required_binary_files_an_issue_naming_the_producers_it_blocks
    filed = nil
    with_agent_home do
      register_identity
      with_toolchain(missing: %w[depsguard]) do
        stub_singleton(Agent::Api, :create_issue, ->(form, **_opts) { filed = form; { "number" => 1 } }) do
          with_ai_token { capture_stdout { tick(dry_run: false).check_toolchain } }
        end
      end
    end
    refute_nil filed, "a producer that cannot run on this machine has to reach a human somehow"
    assert_includes filed[:title], "depsguard"
    assert_includes filed[:body], "brew install depsguard"
    assert_includes filed[:body], "`depsguard`"
    assert_equal false, filed[:claim_on_create]
  end

  # A healthy machine files nothing. Anything that fires on a healthy idle box
  # trains Mike to ignore the channel, which costs the alerts that matter — the
  # same reasoning Agent::Notify is built on.
  def test_a_complete_toolchain_files_nothing
    with_agent_home do
      register_identity
      with_toolchain(missing: []) do
        # No create_issue stub: reaching the platform at all would flunk on the
        # unstubbed-request guard, which is the assertion.
        with_stubbed_api({}) { capture_stdout { tick(dry_run: false).check_toolchain } }
      end
      assert_equal [], Agent::Toolchain.state["missing"]
    end
  end

  # An optional tool is best-effort by construction, so its absence is reported
  # and never escalated. An optional tool that filed would make the required
  # ones unreadable. `TOOLS` currently ships no optional entry (see
  # toolchain.rb — `openclaw` was the only one and doctor no longer tracks
  # it), so this exercises the tick against a synthetic optional tool rather
  # than depending on production TOOLS shipping one.
  def test_a_missing_optional_tool_is_recorded_and_not_filed
    optional_tool = Agent::Toolchain::Tool.new(
      name: "optional-thing", required_by: "nothing load-bearing", producers: [],
      install: "brew install optional-thing", required: false,
    )
    with_agent_home do
      register_identity
      with_toolchain(missing: %w[optional-thing], tools: [optional_tool]) do
        with_stubbed_api({}) { capture_stdout { tick(dry_run: false).check_toolchain } }
      end
      assert_equal [], Agent::Toolchain.state["missing"]
      assert_equal %w[optional-thing], Agent::Toolchain.state["missing_optional"]
    end
  end

  # The daily marker is what stops a permanently-broken machine filing every 30
  # seconds. It is written on the FAILING path too — a check that only stamped
  # its marker on success would re-probe and re-notify on every tick forever.
  def test_the_check_is_throttled_after_it_files
    with_agent_home do
      register_identity
      calls = 0
      with_toolchain(missing: %w[depsguard]) do
        stub_singleton(Agent::Api, :create_issue, ->(_form, **_opts) { calls += 1; { "number" => 1 } }) do
          with_ai_token do
            capture_stdout { tick(dry_run: false).check_toolchain }
            capture_stdout { tick(dry_run: false).check_toolchain }
          end
        end
      end
      assert_equal 1, calls, "a machine that is missing a tool today is missing it 30 seconds from now"
    end
  end

  # An unregistered machine is the one MOST likely to be missing tools, which is
  # why this runs before the identity check — the same placement, for the same
  # reason, as ISS-520's housekeeping.
  def test_the_toolchain_is_checked_on_a_machine_the_platform_has_never_heard_of
    with_agent_home do
      with_toolchain(missing: []) do
        out = with_stubbed_api({}) { capture_stdout { tick(dry_run: false).phase_b } }
        assert_match(/no runner identity yet/, out)
      end
      refute_nil Agent::Toolchain.last_check_at
    end
  end

  def test_a_dry_run_says_what_it_would_file_and_files_nothing
    with_agent_home do
      register_identity
      with_toolchain(missing: %w[depsguard]) do
        out = with_stubbed_api({}) { capture_stdout { tick.check_toolchain } }
        assert_match(/toolchain: MISSING depsguard — would file an issue/, out)
      end
      assert_nil Agent::Toolchain.last_check_at, "a dry run must not stamp the marker either"
    end
  end


  def init_repo(dir)
    FileUtils.mkdir_p(dir)
    system("git", "-C", dir, "init", "-q", "-b", "main", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "config", "user.email", "t@example.com")
    system("git", "-C", dir, "config", "user.name", "Test")
  end

  def write_commit(dir, path, body)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
    system("git", "-C", dir, "add", "-A", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "commit", "-qm", "add #{path}", out: File::NULL, err: File::NULL)
  end

  def run_hook(repo, stdin_line, guarded: nil)
    hook = File.join(Agent::Paths.githooks_dir, "pre-push")
    out, status = Open3.capture2e({ "DEV_AGENT_CLAUDE_REPO" => guarded || repo },
                                  hook, "origin", "git@github.com:mbryzek/x.git",
                                  chdir: repo, stdin_data: "#{stdin_line}\n")
    [out, status]
  end
end
