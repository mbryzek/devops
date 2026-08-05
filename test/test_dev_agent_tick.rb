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
        # producers.yml and the githooks resolve) but is NOT a git repo, so no
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

      # Phase B: every due producer is named, with its schedule.
      kinds = decisions.map(&:first)
      assert_includes kinds, "producer"
      assert_includes kinds, "claim"
      assert_match(/invariants-platform is due \(every 1 hour\)/, out)
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
      # immortal job.
      unreachable = {
        "POST /agent/runners/#{RUNNER_ID}/heartbeat" => ->(_body) { raise ApiError.new("HTTP 503", code: 503) },
      }
      out = with_stubbed_api(unreachable) { capture_stdout { tick(dry_run: false).phase_a } }
      assert_match(/platform error/, out)
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

  # ---- claim-time playbook resolution (ISS-505) ----
  #
  # The producer files a POINTER; the runner reads the playbook off its own
  # checkout when it claims. That is the entire point — an issue filed on Friday
  # and claimed on Tuesday must run TUESDAY's procedure — so what these prove is
  # that the read happens here, that what was read is recorded, and that a
  # pointer which does not resolve stops the claim instead of starting a session
  # that would do something else.

  CLAIM_SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678".freeze

  # Drives one real claim with Jobs.spawn_session stubbed: everything up to and
  # including the prompt is exercised, and no `claude` is launched.
  def claim_one(body:, number: 707, errors: [], branch: "main", dirty: false)
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
        spawn = lambda do |argv:, prompt:, workspace:, number:, env: {}|
          seen[:prompt] = prompt
          seen[:spawned] = true
          Process.pid
        end
        # The stand-in devops checkout is deliberately not a git repo, so what
        # `git` would answer about it is stubbed rather than reached for.
        stub_singleton(Agent::Checkout, :head_sha, ->(*_args) { CLAIM_SHA }) do
          stub_singleton(Agent::Checkout, :current_branch, ->(*_args) { branch }) do
            stub_singleton(Agent::Checkout, :dirty?, ->(*_args) { dirty }) do
              stub_singleton(Agent::Jobs, :spawn_session, spawn) do
                with_stubbed_api(stubs) do
                  seen[:out] = capture_stdout do
                    tick(dry_run: false).claim(Agent::Host.cached_identity, runner_row(max_concurrency: 1))
                  end
                end
              end
            end
          end
        end
      end
    end
    seen
  end

  POINTER = "Playbook: `agent/bodies/weekly-review.md`".freeze

  def test_the_session_is_handed_the_playbook_read_at_claim_time
    seen = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n")
    assert seen[:spawned], "the session must still start"
    assert_match(/^# Playbook — agent\/bodies\/weekly-review\.md @ #{CLAIM_SHA[0, 8]}$/, seen[:prompt],
                 "the prompt gets the resolved playbook, labelled with the sha it was read at")
    assert_match(/Posture: full-auto/, seen[:prompt], "the FULL procedure reaches the session")
    assert_operator seen[:prompt].index("# Playbook —"), :<, seen[:prompt].index("# Issue comments"),
                    "comments stay last so the most recent instruction is read last"
  end

  # Requirement 2: the run has to stay reproducible after the file changes, so
  # WHAT was read and at WHICH sha go on the timeline, with a permalink.
  def test_the_first_comment_records_the_playbook_and_the_sha_it_was_read_at
    seen = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n")
    comment = seen[:comments].first
    assert_match(/^Claimed by /, comment, "the claim line still leads")
    assert_match(/^Playbook: agent\/bodies\/weekly-review\.md @ #{CLAIM_SHA[0, 8]}$/, comment)
    assert_match(%r{https://github\.com/mbryzek/devops/blob/#{CLAIM_SHA}/agent/bodies/weekly-review\.md}, comment)
  end

  # The inversion ISS-505 names: a runner on a stale checkout reads last month's
  # playbook while the issue claims to be running the current one, and
  # `agent_reported_registry` shows that only by comparing machines after the
  # fact. A runner CAN see why its own last pull did not land, so it says so on
  # the issue whose playbook it just read.
  def test_a_runner_whose_pull_is_failing_says_so_on_the_issue
    failing = [{ "source" => "checkout_pull", "message" => "fatal: could not read from remote",
                 "created_at" => Time.now.utc.iso8601 }]
    seen = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n", errors: failing)
    assert_match(/failed to fast-forward 1 time\(s\) in a row.*may be behind `origin\/main`/m, seen[:comments].first)
  end

  # A dirty tree and a checkout off `main` are BENIGN skips: the tick leaves them
  # alone on purpose, because it means a human is working in that checkout. So
  # they never count toward the ISS-511 escalation and nothing else in the system
  # reports them — on an unattended mini that is a machine which quietly stops
  # updating forever, which is exactly the case this note exists for.
  def test_a_benign_pull_skip_still_warns_because_nothing_else_reports_it
    dirty = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n", dirty: true)
    assert_match(/dirty working tree.*may be behind `origin\/main`/m, dirty[:comments].first)

    off_main = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n", branch: "wip")
    assert_match(/on `wip`, not `main`/, off_main[:comments].first)
  end

  def test_a_healthy_runner_adds_no_staleness_warning
    seen = claim_one(body: "Filed by a producer.\n\n#{POINTER}\n")
    refute_match(/behind `origin\/main`/, seen[:comments].first)
  end

  # ISS-360: a producer ported without its playbook silently fell back to generic
  # triage and filed issues instead of shipping PRs for a week. A pointer that
  # does not resolve reintroduces exactly that, so it must be a HARD stop.
  def test_a_pointer_that_does_not_resolve_starts_no_session_at_all
    seen = claim_one(body: "Filed by a producer.\n\nPlaybook: `agent/bodies/never-existed.md`\n")
    refute seen[:spawned], "a session without its playbook does a different job than the one scheduled"
    assert_equal ["needs_input"], seen[:statuses].map { |s| s[:status] },
                 "a human has to fix the path — releasing it would just be re-claimed and re-fail every 30s"
    assert_match(/did not resolve/, seen[:statuses].first[:comment])
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

  # ---- runner staleness comes from the server, never recomputed here ----

  # Restores the real method rather than removing it — Notify.event is a
  # module_function, so remove_method would delete it for every later test in
  # the file rather than just undoing the stub.
  def capturing_events
    captured = []
    original = Agent::Notify.method(:event)
    Agent::Notify.define_singleton_method(:event) { |text| captured << text; true }
    no_notify = ENV.delete("DEV_AGENT_NO_NOTIFY")
    yield captured
    captured
  ensure
    Agent::Notify.define_singleton_method(:event, original)
    ENV["DEV_AGENT_NO_NOTIFY"] = no_notify
  end

  def test_offline_runner_notification_uses_the_servers_is_stale
    events = with_agent_home do
      register_identity
      capturing_events do
        fleet = fleet_responses(runners: [runner_row,
                                          runner_row(id: "rnr-2", hostname: "mini-2.local", is_stale: true),
                                          runner_row(id: "rnr-3", hostname: "mini-3.local", is_stale: false)])
        with_stubbed_api(fleet) { capture_stdout { tick.run } }
      end
    end
    assert_equal 1, events.length, "exactly the stale runner should notify"
    assert_match(/mini-2\.local has not checked in/, events.first)
  end

  # ---- producer execution: check_failed stays distinct from filed ----

  def producer(check:, file_when: "check_fails")
    issue = file_when == "never" ? nil : { "title" => "t", "category" => "infrastructure", "fingerprint" => "fp:1" }
    Agent::Producers::Producer.new(key: "probe", schedule: Agent::Schedule.parse("every 1 hour"),
                                   schedule_text: "every 1 hour", check: check,
                                   file_when: file_when, issue: issue)
  end

  def run_producer_with(check, extra_stubs: {}, file_when: "check_fails")
    result = nil
    stubs = {
      # agent_producer_run_start wraps the run, same 2xx-varying-type constraint
      # as the claim: an absent `run` means the compare-and-set did not fire.
      "POST /agent/producers/probe/runs" => { "run" => { "id" => "run-1" } },
      "PUT /agent/producers/runs/run-1" => ->(body) { result = body[:result]; { "id" => "run-1" } },
    }.merge(extra_stubs)
    with_agent_home do
      register_identity
      with_ai_token do
        with_stubbed_api(stubs) do
          capture_stdout do
            tick(dry_run: false).run_producer(producer(check: check, file_when: file_when),
                                              nil, Agent::Host.cached_identity)
          end
        end
      end
    end
    result
  end

  # The regression that would have caught the one-shot producer bug: run the real
  # `run_producers` path against a registry with a producer that ALREADY RAN, and
  # look at the guard it actually puts on the wire. Sending the previous run's own
  # `started_at` makes the platform's inclusive `started_at >= if_no_run_since`
  # match that very row, so the producer declines itself forever.
  def test_a_producer_that_already_ran_guards_on_the_period_not_on_its_own_last_run
    ran_at = Time.utc(2026, 8, 4, 16, 57, 29)
    now    = Time.utc(2026, 8, 4, 17, 36, 0)          # well past the 30-minute interval
    sent   = nil

    registry = <<~YAML
      timezone: America/New_York
      producers:
        - key: probe
          schedule: every 30 minutes
          check: "true"
          file_when: never
    YAML

    with_agent_home do
      register_identity
      with_producer_registry(registry) do
        stubs = {
          "GET /agent/producers/runs?limit=100&offset=0" => [
            { "producer_key" => "probe", "started_at" => ran_at.iso8601, "finished_at" => ran_at.iso8601 },
          ],
          "POST /agent/producers/probe/runs" => lambda do |body|
            sent = body[:if_no_run_since] || body["if_no_run_since"]
            { "run" => { "id" => "run-1" } }
          end,
          "PUT /agent/producers/runs/run-1" => { "id" => "run-1" },
        }
        with_stubbed_api(stubs) { capture_stdout { tick(dry_run: false, now: now).run_producers(Agent::Host.cached_identity) } }
      end
    end

    refute_nil sent, "the producer was due and must have attempted a run"
    assert_equal "2026-08-04T17:27:29Z", sent
    assert Time.parse(sent) > ran_at,
           "the guard must be the period boundary, not the previous run's own start time"
  end

  def with_producer_registry(yaml)
    file = File.join(Agent::Paths.state_dir, "producers.yml")
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, yaml)
    original = Agent::Paths.method(:producers_file)
    Agent::Paths.define_singleton_method(:producers_file) { file }
    yield
  ensure
    Agent::Paths.define_singleton_method(:producers_file, original)
  end

  def test_a_crashing_check_is_check_failed_not_filed
    # Exit 2 and up means the check itself broke. Filing on it would turn a
    # broken producer into a nightly stream of bogus issues.
    assert_equal "check_failed", run_producer_with("exit 2")
    assert_equal "check_failed", run_producer_with("this-command-does-not-exist-zzz")
  end

  def test_a_clean_check_is_nothing_to_do
    assert_equal "nothing_to_do", run_producer_with("true")
  end

  # The list the in-flight check reads: every non-terminal status, so `fixed`
  # (PR open, not yet merged) blocks a re-file with no GitHub call.
  ISSUES_PATH = "GET /playbook/issues?statuses=open&statuses=claimed&statuses=needs_review" \
                "&statuses=needs_input&statuses=fixed&statuses=deployed&limit=200&offset=0".freeze

  def test_findings_file_an_issue_and_the_check_output_is_the_body
    filed = nil
    result = run_producer_with(
      "echo 'invariant x: 4 rows'; exit 1",
      extra_stubs: {
        ISSUES_PATH => [],
        "POST /playbook/issues" => ->(body) { filed = body; { "number" => 200, "occurrence_count" => 1 } },
      },
    )
    assert_equal "filed", result
    assert_equal "infrastructure", filed[:category]
    assert_equal "fp:1", filed[:fingerprint]
    # Attribution the platform stores as a column: without it, "everything this
    # producer filed" has to be reconstructed from the run history, which
    # recurrence (many runs -> one issue) makes unpaginatable.
    assert_equal "probe", filed[:producer_key]
    refute filed[:claim_on_create], "a producer files for the queue; it never claims"
    assert_match(/invariant x: 4 rows/, filed[:body], "the check's stdout IS the brief")
  end

  # `{date}` used to be resolved on the epic path only, so a plain nightly
  # producer filed the literal "pr:auto-merge:{date}" — one issue, forever, with
  # every later run skipping in flight behind it and nothing anywhere saying so.
  def test_a_plain_producer_resolves_the_date_token_in_its_fingerprint
    filed = nil
    dated = Agent::Producers::Producer.new(
      key: "probe", schedule: Agent::Schedule.parse("daily at 6:45am"),
      schedule_text: "daily at 6:45am", check: nil, file_when: "always",
      timezone: "America/New_York",
      issue: { "title" => "t", "category" => "infrastructure", "fingerprint" => "pr:auto-merge:{date}" },
    )
    with_agent_home do
      register_identity
      with_ai_token do
        stubs = {
          ISSUES_PATH => [],
          "POST /playbook/issues" => ->(body) { filed = body; { "number" => 201, "occurrence_count" => 1 } },
        }
        with_stubbed_api(stubs) do
          # 6:45am America/New_York is 10:45 UTC — the date must be the LOCAL one.
          capture_stdout { tick(dry_run: false, now: Time.utc(2026, 8, 5, 10, 45)).file_issue(dated, nil) }
        end
      end
    end
    assert_equal "pr:auto-merge:2026-08-05", filed[:fingerprint]
  end

  # And the same run's fingerprint still dedups, so a double fire on one night
  # files once rather than twice.
  def test_a_dated_fingerprint_still_blocks_a_refile_within_the_same_day
    dated = Agent::Producers::Producer.new(
      key: "probe", schedule: Agent::Schedule.parse("daily at 6:45am"),
      schedule_text: "daily at 6:45am", check: nil, file_when: "always",
      timezone: "America/New_York",
      issue: { "title" => "t", "category" => "infrastructure", "fingerprint" => "pr:auto-merge:{date}" },
    )
    result = nil
    with_agent_home do
      register_identity
      with_ai_token do
        stubs = { ISSUES_PATH => [{ "fingerprint" => "pr:auto-merge:2026-08-05", "status" => "claimed" }] }
        with_stubbed_api(stubs) do
          capture_stdout { result, _number = tick(dry_run: false, now: Time.utc(2026, 8, 5, 10, 45)).file_issue(dated, nil) }
        end
      end
    end
    assert_equal "skipped_in_flight", result
  end

  def test_a_non_terminal_issue_with_the_same_fingerprint_blocks_a_refile
    result = run_producer_with(
      "exit 1",
      extra_stubs: { ISSUES_PATH => [{ "fingerprint" => "fp:1", "status" => "fixed" }] },
    )
    assert_equal "skipped_in_flight", result
  end

  # The compare-and-set did not fire — another runner started this run first.
  # An absent `run` must skip quietly, and must NOT run the check or report a
  # result against a run id that does not exist.
  def test_an_empty_run_wrapper_skips_without_running_the_check
    out = nil
    with_agent_home do
      register_identity
      # Only the start is stubbed: running the check would write this file, and
      # reporting a result would hit an unstubbed PUT and flunk.
      marker = File.join(Agent::Paths.state_dir, "check-ran")
      with_stubbed_api({ "POST /agent/producers/probe/runs" => {} }) do
        out = capture_stdout do
          tick(dry_run: false).run_producer(producer(check: "touch #{marker}"), nil, Agent::Host.cached_identity)
        end
      end
      refute File.exist?(marker), "a skipped producer must not run its check"
    end
    # The message names both causes rather than asserting one. It used to claim
    # "another runner already started this run", which was wrong in the case that
    # actually happened in production — a single-runner fleet with nothing in
    # flight — and sent the investigation looking for a second machine.
    assert_match(/already in flight or finished/, out)
  end

  def test_file_when_never_acts_directly_and_files_nothing
    assert_equal "nothing_to_do", run_producer_with("true", file_when: "never")
    assert_equal "check_failed", run_producer_with("exit 3", file_when: "never")
  end

  # ---- epics: one container, one child per target (ISS-397) ----

  EPIC_REGISTRY = <<~YAML.freeze
    timezone: America/New_York
    producers:
      - key: probe
        schedule: every 1 hour
        file_when: always
        issue:
          type: epic
          category: infrastructure
          title: Nightly upgrades
          fingerprint: "up:{date}"
          children:
            names: [alpha, beta]
            category: infrastructure
            title: "Upgrades: {child}"
            fingerprint: "up:{child}"
  YAML

  def epic_producer
    registry = Agent::Producers.parse(EPIC_REGISTRY)
    registry.fetch(:producers).first
  end

  # Runs the real file path against a stubbed platform, returning
  # [result, issue_number, every form POSTed to /playbook/issues].
  def file_epic_with(existing)
    filed = []
    number = 100
    result = nil
    issue_number = nil
    with_agent_home do
      register_identity
      with_ai_token do
        stubs = {
          ISSUES_PATH => existing,
          "POST /playbook/issues" => lambda do |body|
            filed << body
            { "number" => (number += 1), "occurrence_count" => 1 }
          end,
        }
        with_stubbed_api(stubs) do
          capture_stdout do
            result, issue_number = tick(dry_run: false, now: Time.utc(2026, 8, 5, 7, 45)).file_issue(epic_producer, nil)
          end
        end
      end
    end
    [result, issue_number, filed]
  end

  def test_an_epic_producer_files_a_container_and_one_child_per_name
    result, number, filed = file_epic_with([])

    assert_equal "filed", result
    assert_equal 101, number, "the run records the EPIC, which is what gets verified"
    assert_equal 3, filed.length

    epic = filed.first
    assert_equal "epic", epic[:type]
    # 3:45am America/New_York is 07:45 UTC — the date must be the LOCAL one.
    assert_equal "up:2026-08-05", epic[:fingerprint]
    refute epic[:claim_on_create], "a producer files for the queue; it never claims"

    children = filed.drop(1)
    assert_equal ["Upgrades: alpha", "Upgrades: beta"], children.map { |c| c[:title] }
    assert_equal %w[up:alpha up:beta], children.map { |c| c[:fingerprint] }
    # issue_form.parent_number is typed `string` on the platform.
    assert_equal %w[101 101], children.map { |c| c[:parent_number] }
    children.each { |c| assert_nil c[:type], "a child is an issue, never a nested epic" }
    # Epic AND children, so one producer's whole night resolves to one key --
    # stated on the children rather than left to the platform's inheritance, so
    # a child detached from its epic keeps its attribution.
    assert_equal %w[probe probe probe], filed.map { |f| f[:producer_key] }
  end

  # Per-child dedup is the whole reason for the split: one repo stuck on an open
  # issue must not take the other five down with it.
  def test_a_child_with_an_open_issue_is_skipped_and_its_siblings_still_file
    _result, _number, filed = file_epic_with([{ "fingerprint" => "up:alpha", "status" => "claimed" }])

    assert_equal 2, filed.length, "the epic plus the ONE child that was free"
    assert_equal "Upgrades: beta", filed.last[:title]
    assert_includes filed.first[:body], "1 child(ren) were skipped"
  end

  # An epic with no children is a container nobody can work and nobody can
  # delete — there is no hard delete, only `dismissed`.
  def test_a_night_where_every_child_is_in_flight_files_nothing_at_all
    existing = [
      { "fingerprint" => "up:alpha", "status" => "open" },
      { "fingerprint" => "up:beta", "status" => "fixed" },
    ]
    result, number, filed = file_epic_with(existing)

    assert_equal "skipped_in_flight", result
    assert_nil number
    assert_empty filed, "no epic may be created with nothing under it"
  end

  # A fingerprint template with no {child} would make every child dedup against
  # its siblings, so only the first would ever be filed.
  def test_a_child_template_without_the_token_is_a_parse_error
    yaml = EPIC_REGISTRY.sub('fingerprint: "up:{child}"', 'fingerprint: "up:all"')
    error = assert_raises(Agent::Producers::ConfigError) { Agent::Producers.parse(yaml) }
    assert_match(/\{child\}/, error.message)
  end

  def test_an_epic_without_children_is_a_parse_error
    yaml = EPIC_REGISTRY.sub(/^ *children:\n(.*\n)*/, "")
    error = assert_raises(Agent::Producers::ConfigError) { Agent::Producers.parse(yaml) }
    assert_match(/requires an issue.children block/, error.message)
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
  # schedule change meant logging into every machine, so "producers.yml in git is
  # the registry" was true only of the file, never of what a machine was running.

  # An `origin` with one commit, and a clone of it pointed at by
  # DEV_AGENT_DEVOPS_REPO. Returns [origin, checkout].
  def with_devops_clone(root)
    origin = File.join(root, "devops-origin")
    init_repo(origin)
    write_commit(origin, "agent/producers.yml", "timezone: America/New_York\nproducers: []\n")
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
        write_commit(origin, "agent/producers.yml", "timezone: America/New_York\nproducers: []\n# newer\n")
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
        write_commit(origin, "agent/producers.yml", "# theirs\n")
        write_commit(checkout, "agent/producers.yml", "# ours\n")
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
        write_commit(origin, "agent/producers.yml", "# theirs\n")
        File.write(File.join(checkout, "agent/producers.yml"), "# uncommitted local edit\n")
        local = head_of(checkout)
        register_identity
        out = with_stubbed_api(fleet_responses) { capture_stdout { tick(dry_run: false).update_checkout } }
        assert_match(/devops pull failed/, out)
        assert_equal local, head_of(checkout), "a dirty checkout must never be reset"
        assert_equal "# uncommitted local edit\n", File.read(File.join(checkout, "agent/producers.yml")),
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
        write_commit(origin, "agent/producers.yml", "# theirs\n")
        system("git", "-C", checkout, "checkout", "-qb", "feature", out: File::NULL, err: File::NULL)
        write_commit(checkout, "agent/producers.yml", "# ours, on feature\n")
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
      write_commit(origin, "agent/producers.yml", "timezone: America/New_York\nproducers: []\n")
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
        write_commit(origin, "agent/producers.yml", "# newer\n")
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
      assert_equal [Agent::Maintenance::AIDIRS_SOURCE, Agent::Maintenance::DOCKER_SOURCE], ran
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

  # ---- ISS-392: the registry each runner reports ----

  def test_the_runner_reports_its_registry_with_the_devops_sha
    reported = nil
    with_agent_home do |root|
      with_devops_clone(root) do |_origin, checkout|
        write_commit(checkout, "agent/producers.yml", <<~YML)
          timezone: America/New_York
          producers:
            - key: probe
              schedule: every 1 hour
              check: "true"
              file_when: check_fails
              issue:
                category: infrastructure
                title: t
                fingerprint: fp:1
        YML
        register_identity
        stubs = fleet_responses.merge(
          "PUT /agent/registry/#{RUNNER_ID}" => ->(body) { reported = body; {} },
        )
        with_stubbed_api(stubs) { capture_stdout { tick(dry_run: false).report_registry(Agent::Host.cached_identity) } }

        assert_equal head_of(checkout), reported[:devops_sha],
                     "the reported sha is what makes a machine stuck on an old checkout visible"
        assert_equal ["probe"], reported[:producers].map { |p| p[:producer_key] }
        assert_equal "every 1 hour", reported[:producers].first[:schedule]
        refute_nil reported[:producers].first[:next_due_at]
      end
    end
  end

  # The registry report carries the schedule and the sha, and nothing else. The maintenance vitals
  # that briefly rode here moved to the heartbeat in ISS-528 (see that block above), and leaving a
  # single one behind would mean the platform had two homes for the same fact — one of which is
  # deleted at the server-side-scheduling cutover.
  def test_the_registry_report_carries_no_machine_state
    reported = nil
    with_agent_home do |root|
      with_devops_clone(root) do |_origin, _checkout|
        register_identity
        stubs = fleet_responses.merge("PUT /agent/registry/#{RUNNER_ID}" => ->(body) { reported = body; {} })
        stub_singleton(Agent::Maintenance, :disk, ->(*) { [11, 22] }) do
          with_stubbed_api(stubs) do
            capture_stdout { tick(dry_run: false).run_maintenance }
            capture_stdout { tick(dry_run: false).report_registry(Agent::Host.cached_identity) }
          end
        end
        assert_equal %i[devops_sha producers], reported.keys.sort_by(&:to_s)
      end
    end
  end

  # The throttle is what keeps a 30-second tick from PUTting 2,880 times a day.
  # It is keyed on the sha as well as on time, so a push converges the fleet on
  # the next tick rather than up to ten minutes later.
  def test_a_second_report_is_skipped_until_the_sha_moves
    with_agent_home do |root|
      with_devops_clone(root) do |_origin, checkout|
        register_identity
        calls = 0
        stubs = fleet_responses.merge("PUT /agent/registry/#{RUNNER_ID}" => ->(_body) { calls += 1; {} })
        with_stubbed_api(stubs) do
          capture_stdout do
            runner = tick(dry_run: false)
            runner.report_registry(Agent::Host.cached_identity)
            runner.report_registry(Agent::Host.cached_identity)
            assert_equal 1, calls, "an unchanged registry must not be re-sent every 30 seconds"

            write_commit(checkout, "agent/producers.yml", "timezone: America/New_York\nproducers: []\n# moved\n")
            tick(dry_run: false).report_registry(Agent::Host.cached_identity)
          end
        end
        assert_equal 2, calls, "a new devops sha must be reported on the next tick"
      end
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
