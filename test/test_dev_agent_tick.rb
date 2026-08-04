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
        "DEV_AGENT_NO_NOTIFY" => "1",
      }
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
    refute filed[:claim_on_create], "a producer files for the queue; it never claims"
    assert_match(/invariant x: 4 rows/, filed[:body], "the check's stdout IS the brief")
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
