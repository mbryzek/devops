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
      }
      FileUtils.mkdir_p(File.join(root, "devops"))
      FileUtils.cp_r(File.expand_path("../agent", __dir__), File.join(root, "devops"))
      # A stand-in claude checkout, so this fixture models a PROVISIONED machine.
      # Without it phase_a's Agent::ClaudeConfig step reads `missing_repo` and
      # every test that walks a phase would be counting a second failing source
      # it never meant to exercise.
      FileUtils.mkdir_p(File.join(root, "claude"))
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
      env = tick.send(:child_env, "i707_abc", 707)
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
      assert_equal "i707_abc", tick.send(:child_env, "i707_abc", 707)["CLAUDE_SESSION_ID"]
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
      stub_shell(lambda { |cmd, opts|
        seen << [opts[:env], *cmd]
        shell_result
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
        # Both lookups, or the empty-workspace case falls through to a live
        # `gh search prs` (ISS-657 turned the reap's two calls into these).
        Agent::Github => { prs_in_workspace: ->(*) { [] }, search_prs: ->(*) { [] },
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

  # ---- the give-up count, at the reap (ISS-734) ----
  #
  # `Agent::Outcome.attempt_number` is pinned in test_dev_agent_outcome.rb; these
  # two pin the wiring around it, which is where the defect actually lived: the
  # reap handed classification a COUNT OF LEASES, and released every lease as an
  # undifferentiated hand-back so no later reap could tell a failure from an
  # ordinary release. Both halves go through the real HTTP seam — an outcome the
  # release stopped sending would land as an unstubbed-request flunk.

  # One lease row as the platform returns it; `outcome` nil is a live lease.
  def lease_row(id, outcome, at:)
    { "id" => id, "outcome" => outcome, "created" => { "at" => at }, "runner_id" => RUNNER_ID }
  end

  # A reap of a session that left nothing behind, over a given lease history.
  def reap_with_history(history)
    seen = { statuses: [], released: [] }
    with_agent_home do
      register_identity
      with_ai_token do
        subject = tick(dry_run: false)
        record = Agent::Jobs.write("issue" => 707, "pid" => 999_999, "slug" => "i707_abc", "branch" => "i707_abc",
                                   "lease_id" => "lse-now", "started_at" => (Time.now - 60).utc.iso8601,
                                   "timeout_at" => (Time.now + 3600).utc.iso8601)
        live, closed = history.partition { |l| l["outcome"].nil? }
        api = {
          "GET /playbook/issue/leases?is_active=true&issue_number=707&limit=100&offset=0" => live,
          "GET /playbook/issue/leases?is_active=false&issue_number=707&limit=100&offset=0" => closed,
          "GET /playbook/issues/707" => { "number" => 707, "status" => "claimed" },
          "PUT /playbook/issues/707/status" => ->(b) { seen[:statuses] << b; {} },
          # The lease says HOW this attempt ended, and nothing else does.
          "DELETE /playbook/issue/leases/lse-now?outcome=failed" => ->(_b) { seen[:released] << "failed"; {} },
        }
        stubs = {
          Agent::Github => { prs_in_workspace: ->(*) { [] }, search_prs: ->(*) { [] },
                             plans_committed_since?: ->(*) { false } },
          subject => { cleanup: ->(*) {} },
        }
        with_stubbed_methods(stubs) do
          with_stubbed_api(api) { capture_stdout { subject.send(:reap_one, record, Agent::Host.cached_identity) } }
        end
      end
    end
    seen
  end

  # THE bug. Two leases that failed at nothing — the issue was reopened for a
  # regression, reclaimed, handed back — and then a session that really did fail.
  # Counting rows made that first real failure the third and parked the issue in
  # `needs_input`, which `dev issues claim` never offers again.
  def test_an_ordinary_lease_history_does_not_give_up_on_the_first_real_failure
    seen = reap_with_history([lease_row("lse-1", "released", at: "2026-08-01T00:00:00Z"),
                              lease_row("lse-2", "released", at: "2026-08-02T00:00:00Z"),
                              lease_row("lse-now", nil, at: "2026-08-03T00:00:00Z")])
    assert_equal ["failed"], seen[:released], "the reap must record how the attempt ended on its lease"
    assert_equal "open", seen[:statuses].first[:status]
    assert_match(/Failure 1 of 3 in a row/, seen[:statuses].first[:comment])
  end

  # And the threshold still fires when the failures really are consecutive.
  def test_three_failed_leases_in_a_row_still_reach_needs_input
    seen = reap_with_history([lease_row("lse-0", "completed", at: "2026-08-01T00:00:00Z"),
                              lease_row("lse-1", "failed", at: "2026-08-02T00:00:00Z"),
                              lease_row("lse-2", "cancelled", at: "2026-08-03T00:00:00Z"),
                              lease_row("lse-now", nil, at: "2026-08-04T00:00:00Z")])
    assert_equal "needs_input", seen[:statuses].first[:status]
    assert_match(/Failure 3 of 3 in a row/, seen[:statuses].first[:comment])
  end

  # ---- the ops close-out contract, at the reap (ISS-815) ----
  #
  # Agent::Outcome's own arms are pinned in test_dev_agent_outcome.rb. What is
  # only testable HERE is the wiring: that the reap actually reads the records
  # this attempt wrote, from the log tree that survives the workspace it deletes,
  # and that it reads THIS attempt's and not a predecessor's.

  # A reap of a session that ran operations and exited cleanly. `ops` are written
  # before the reap, exactly as `dev agent run-op` would have written them.
  def reap_with_operations(ops, started_at: Time.now - 60)
    seen = { statuses: [], released: [] }
    with_agent_home do
      register_identity
      with_ai_token do
        subject = tick(dry_run: false)
        record = Agent::Jobs.write("issue" => 707, "pid" => 999_999, "slug" => "i707_abc", "branch" => "i707_abc",
                                   "lease_id" => "lse-now", "producer_filed" => true,
                                   "started_at" => started_at.utc.iso8601,
                                   "timeout_at" => (Time.now + 3600).utc.iso8601)
        ops.each { |op| Agent::Ops.write(707, op) }
        Agent::Paths.write_atomic(Agent::Jobs.exit_code_file(707), "0\n")
        api = {
          "GET /playbook/issue/leases?is_active=true&issue_number=707&limit=100&offset=0" => [],
          "GET /playbook/issue/leases?is_active=false&issue_number=707&limit=100&offset=0" => [],
          "GET /playbook/issues/707" => { "number" => 707, "status" => "claimed" },
          "PUT /playbook/issues/707/status" => ->(b) { seen[:statuses] << b; {} },
          "DELETE /playbook/issue/leases/lse-now?outcome=completed" => ->(_b) { seen[:released] << "completed"; {} },
        }
        stubs = {
          Agent::Github => { prs_in_workspace: ->(*) { [] }, search_prs: ->(*) { [] },
                             plans_committed_since?: ->(*) { false } },
          subject => { cleanup: ->(*) {} },
        }
        with_stubbed_methods(stubs) do
          with_stubbed_api(api) { capture_stdout { subject.send(:reap_one, record, Agent::Host.cached_identity) } }
        end
      end
    end
    seen
  end

  def op_record(operation:, summary:, status: 0, started_at: Time.now)
    Agent::Ops::Record.new(operation: operation, argv: ["dev", operation], status: status, timed_out: false,
                           summary: summary, effects: {}, started_at: started_at.utc.iso8601,
                           finished_at: started_at.utc.iso8601, output_tail: "")
  end

  # Before this arm the very same run — producer-filed, no PR, no plan, exit 0 —
  # landed on `nothing_to_do` and DISMISSED itself, with the twelve transitions it
  # had just applied recorded nowhere.
  def test_a_session_that_ran_its_operations_closes_the_issue_as_deployed
    seen = reap_with_operations([op_record(operation: "issues-reconcile", summary: "12 deployed, 0 skipped.")])

    assert_equal ["completed"], seen[:released]
    assert_equal "deployed", seen[:statuses].first[:status]
    # WHAT IT DID, not merely that it exited 0 — the timeline is where that fact
    # has to land, or the contract has recorded nothing worth having run.
    assert_match(/issues-reconcile — 12 deployed, 0 skipped\./, seen[:statuses].first[:comment])
    refute_match(/nothing to do/, seen[:statuses].first[:comment])
  end

  # The reap reads the log tree, which OUTLIVES an attempt — so attempt 1 running
  # the operation and then crashing leaves a successful record behind for an
  # attempt 2 that did nothing at all. `started_at` is what separates them.
  def test_a_previous_attempts_operation_does_not_close_out_this_attempt
    seen = reap_with_operations([op_record(operation: "issues-reconcile", summary: "12 deployed.",
                                           started_at: Time.now - 7200)],
                                started_at: Time.now - 60)
    assert_equal "dismissed", seen[:statuses].first[:status], "this attempt delivered nothing of its own"
    assert_match(/nothing to do/, seen[:statuses].first[:comment])
  end

  # ---- who wins: the session's own status, or the reap's classification ----
  #
  # ISS-815 asked the question, so it gets an answer that cannot quietly change:
  # THE SESSION'S OWN STATUS WINS. An issue no longer `claimed` was moved by the
  # session, and the reap comments instead of writing.
  #
  # Not a contradiction of "classification never trusts Claude's prose". A
  # session may declare a status by taking a recorded ACTION — `dev issues status
  # --status needs_review`, `dev issues handoff` — each a platform write with an
  # author and a timeline entry. What it may not do is narrate. The stub flunks
  # on any request it was not told about, so the ABSENCE of a status PUT here is
  # the assertion.
  def test_a_status_the_session_set_itself_is_not_overwritten_by_the_reap
    comments = []
    with_agent_home do
      register_identity
      with_ai_token do
        subject = tick(dry_run: false)
        record = Agent::Jobs.write("issue" => 707, "pid" => 999_999, "slug" => "i707_abc", "branch" => "i707_abc",
                                   "lease_id" => "lse-now", "producer_filed" => true,
                                   "started_at" => (Time.now - 60).utc.iso8601,
                                   "timeout_at" => (Time.now + 3600).utc.iso8601)
        Agent::Paths.write_atomic(Agent::Jobs.exit_code_file(707), "0\n")
        api = {
          "GET /playbook/issue/leases?is_active=true&issue_number=707&limit=100&offset=0" => [],
          "GET /playbook/issue/leases?is_active=false&issue_number=707&limit=100&offset=0" => [],
          # The session closed itself out, the way a suggestion session does.
          "GET /playbook/issues/707" => { "number" => 707, "status" => "needs_review" },
          "POST /playbook/issues/707/comments" => ->(b) { comments << b; {} },
          "DELETE /playbook/issue/leases/lse-now?outcome=completed" => ->(_b) { {} },
        }
        stubs = {
          Agent::Github => { prs_in_workspace: ->(*) { [] }, search_prs: ->(*) { [] },
                             plans_committed_since?: ->(*) { false } },
          subject => { cleanup: ->(*) {} },
        }
        with_stubbed_methods(stubs) do
          with_stubbed_api(api) { capture_stdout { subject.send(:reap_one, record, Agent::Host.cached_identity) } }
        end
      end
    end
    assert_equal 1, comments.length
    assert_match(/already at `needs_review`/, comments.first[:body],
                 "the reap must record its own reading without applying it")
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

  # ---- a reap whose outcome write fails (ISS-741) ----

  READY_PR = { "url" => "https://github.com/mbryzek/devops/pull/12", "state" => "OPEN", "isDraft" => false,
               "number" => 12, "title" => "ISS-707: fix it", "headRefName" => "i707_abc",
               "repository" => "mbryzek/devops" }.freeze

  # A dead session's job record, with the workspace it left behind. String keys
  # throughout, because that is what a record read back off disk has.
  def reaped_job(extra = {}, slug: "i707_abc")
    Agent::Paths.mkdir_p(Agent::Workspace.path(slug))
    # A CLEAN exit, which is the shape the bug needs: with no PR left to find,
    # exit 0 is what classifies as `nothing_to_do` rather than as a failure.
    Agent::Paths.mkdir_p(Agent::Paths.issue_dir(707))
    File.write(Agent::Jobs.exit_code_file(707), "0\n")
    Agent::Jobs.write({ "issue" => 707, "pid" => dead_pid, "slug" => slug, "branch" => slug,
                        "lease_id" => "lse-1", "producer_filed" => true,
                        "started_at" => (Time.now - 60).utc.iso8601,
                        "timeout_at" => (Time.now + 3600).utc.iso8601 }.merge(extra))
  end

  # THE regression test, run as the two ticks it actually takes.
  #
  # Tick 1: the session left a ready PR, classification finds it, `cleanup`
  # deletes the workspace those PRs were found in, and then the status write
  # takes a platform 500. The job record survives, so 30 seconds later:
  #
  # Tick 2: the workspace is gone, so the real `prs_in_workspace` finds nothing,
  # and the fallback `gh search prs` is inside its own documented index lag —
  # both empty. Before ISS-741 that re-classified as `nothing_to_do` and
  # DISMISSED a producer-filed issue with its fix sitting ready on GitHub. The
  # verdict is on the job record now, so the retry applies it unchanged.
  #
  # Note what tick 2 does NOT stub: `prs_in_workspace` runs for real against the
  # deleted directory. That is the failure being reproduced, not a premise.
  def test_a_delivered_pr_is_not_re_classified_when_the_outcome_write_fails
    with_agent_home do
      register_identity
      identity = Agent::Host.cached_identity
      subject = tick(dry_run: false)
      record = reaped_job
      workspace = Agent::Workspace.path(record.fetch("slug"))

      api = { issue_lease_history: ->(*) { [{ "id" => "lse-1" }] },
              issue: ->(*) { { "status" => "claimed" } },
              set_status: ->(*) { raise ApiError.new("500 Internal Server Error", code: 500) } }
      out = with_stubbed_methods(
        Agent::Github => { prs_in_workspace: ->(*) { [READY_PR] }, plans_committed_since?: ->(*) { false } },
        Agent::Api => api,
        subject => { drop_session_databases: ->(*) {} },
      ) { capture_stdout { subject.send(:reap, identity) } }

      assert_match(/could not be closed out/, out, "one failing outcome write must not abort the reap")
      refute Dir.exist?(workspace), "cleanup did not run — this test no longer reproduces the bug"

      pending = Agent::Jobs.find(707)
      refute_nil pending, "the job record must survive so the write is retried"
      assert_equal "ready_pr", pending.dig("reap", "result", "name"),
                   "the verdict must be written down BEFORE the evidence for it is deleted"

      # Tick 2 — the platform is healthy again, GitHub still has not indexed the
      # branch, and the workspace it was found in no longer exists.
      wrote = nil
      with_stubbed_methods(
        Agent::Github => { search_prs: ->(*) { [] }, plans_committed_since?: ->(*) { false } },
        Agent::Api => api.merge(
          set_status: ->(number, status, **opts) { wrote = [number, status, opts[:url]]; {} },
          record_fix: ->(*) { {} },
          release_lease: ->(*) { {} },
        ),
        subject => { drop_session_databases: ->(*) {} },
      ) { capture_stdout { subject.send(:reap, identity) } }

      assert_equal [707, "fixed", READY_PR["url"]], wrote,
                   "the retry re-derived an outcome from evidence the first reap deleted"
      assert_nil Agent::Jobs.find(707), "a job whose outcome was recorded must be finished"
    end
  end

  # The same record, reaped twice, with a HUMAN-filed issue: the nothing_to_do
  # this bug produced lands on `needs_input` rather than `dismissed` there, which
  # is quieter and no less wrong — the PR is orphaned either way.
  def test_a_recorded_verdict_is_applied_rather_than_re_classified
    with_agent_home do
      register_identity
      recorded = Agent::Outcome::Result.new(name: "ready_pr", status: "fixed", lease_outcome: "completed",
                                            reason: "Ready PR #{READY_PR['url']}", url: READY_PR["url"])
      record = reaped_job({ "producer_filed" => false,
                            "reap" => { "result" => Agent::Outcome.to_h(recorded), "prs" => [READY_PR] } })
      subject = tick(dry_run: false)

      result = nil
      with_stubbed_methods(
        # Neither lookup may be reached: a recorded verdict is not re-derived,
        # and `gh` is not asked a question whose answer cannot change it.
        Agent::Github => { prs_in_workspace: ->(*) { flunk "re-classified a recorded verdict" },
                           search_prs: ->(*) { flunk "re-classified a recorded verdict" },
                           plans_committed_since?: ->(*) { flunk "re-classified a recorded verdict" } },
      ) do
        capture_stdout { _rec, result, _prs = subject.send(:reap_decision, record, Agent::Host.cached_identity) }
      end

      assert_equal recorded, result
    end
  end

  # A job record written by an executor that predates ISS-741 has no verdict on
  # it, and a truncated or hand-edited one has half of one. Both re-classify,
  # which is the old behaviour and never worse than it — what must not happen is
  # the reap raising on a file it did not write.
  def test_an_unreadable_recorded_verdict_falls_back_to_classifying
    with_agent_home do
      register_identity
      subject = tick(dry_run: false)
      [nil, { "url" => "https://x" }, "not a hash"].each do |broken|
        record = reaped_job({ "reap" => { "result" => broken } })
        result = nil
        with_stubbed_methods(
          Agent::Github => { prs_in_workspace: ->(*) { [READY_PR] }, plans_committed_since?: ->(*) { false } },
          Agent::Api => { issue_lease_history: ->(*) { [] } },
        ) do
          capture_stdout { _rec, result, _prs = subject.send(:reap_decision, record, Agent::Host.cached_identity) }
        end
        assert_equal "ready_pr", result.name
      end
    end
  end

  # `dev agent status` on a machine in exactly the state this bug leaves behind.
  # "FINISHED (unreaped)" reads as "nothing has looked at this yet", which is the
  # opposite of what a recorded verdict means.
  def test_status_distinguishes_an_unreaped_job_from_one_awaiting_its_outcome_write
    with_agent_home do
      assert_match(/FINISHED \(unreaped\)/, agent_job_line(reaped_job))

      recorded = Agent::Outcome::Result.new(name: "ready_pr", status: "fixed", lease_outcome: "completed",
                                            reason: "Ready PR #{READY_PR['url']}", url: READY_PR["url"])
      awaiting = reaped_job({ "reap" => { "result" => Agent::Outcome.to_h(recorded) } })
      assert_match(/FINISHED \(ready_pr recorded; outcome write pending\)/, agent_job_line(awaiting))
    end
  end

  # A dry run must classify and say so without writing the verdict down — the
  # write is a side effect like every other one, and `--dry-run` is also the
  # provisioning smoke test.
  def test_a_dry_run_records_no_verdict
    with_agent_home do
      register_identity
      record = reaped_job
      out = with_stubbed_methods(
        Agent::Github => { prs_in_workspace: ->(*) { [READY_PR] }, plans_committed_since?: ->(*) { false } },
        Agent::Api => { issue_lease_history: ->(*) { [] } },
      ) { capture_stdout { tick.send(:reap, Agent::Host.cached_identity) } }

      assert_match(/ISS-707 → ready_pr/, out)
      assert_nil Agent::Jobs.find(707)["reap"], "a dry run wrote the verdict to the job record"
      assert Dir.exist?(Agent::Workspace.path(record.fetch("slug"))), "a dry run deleted the workspace"
    end
  end

  # A machine with no Docker running still has an outcome to record and a lease
  # to release, and the hourly `claude-db gc` is the backstop for whatever this
  # could not drop. What must NOT happen is the tick dying here.
  def test_a_failing_database_reap_is_logged_and_does_not_stop_the_reap
    with_agent_home do
      stub_shell(->(*) { raise Errno::ENOENT, "claude-db" }) do
        out = capture_stdout { tick(dry_run: false).send(:drop_session_databases, "i707_abc") }
        assert_match(/claude-db end for i707_abc failed/, out)
      end
    end
  end

  # A Docker that hangs rather than fails is the worse half of the same case
  # (ISS-740): this runs inside the reap that has to finish for the lease to be
  # released at all, so an unbounded `claude-db end` stranded the lease AND the
  # runner. Losing one session's databases has a backstop — the hourly age-based
  # gc; losing the reap has none.
  def test_a_hanging_database_reap_is_bounded_and_reported
    with_agent_home do
      stub_shell(->(*) { shell_result(timed_out: true, timeout: Agent::Tick::CLAUDE_DB_END_TIMEOUT_SECONDS) }) do
        out = capture_stdout { tick(dry_run: false).send(:drop_session_databases, "i707_abc") }
        assert_match(/claude-db end for i707_abc timed out after 120s/, out)
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

  # ---- the `.claude` link (ISS-615) ----
  #
  # Agent::ClaudeConfig has its own tests; what these two prove is the WIRING.
  # The link is invisible when it is missing — no error, no failed session, just
  # every rule and every skill CLAUDE.md names silently absent — so a call site
  # dropped from phase_a is a regression nothing else in this suite would catch.

  def test_phase_a_creates_the_claude_config_link
    with_agent_home do |root|
      register_identity
      link = File.join(root, ".claude")
      refute File.symlink?(link), "fixture started with the link already in place"

      stubs = fleet_responses.merge(
        "POST /agent/runners/#{RUNNER_ID}/heartbeat" => ->(_body) { runner_row },
      )
      with_stubbed_api(stubs) { capture_stdout { tick(dry_run: false).phase_a } }

      assert_equal "claude", File.readlink(link)
      assert_equal File.realpath(File.join(root, "claude")), File.realpath(link)
    end
  end

  def test_a_dry_run_says_what_it_would_link_and_links_nothing
    with_agent_home do |root|
      register_identity
      out = with_stubbed_api(fleet_responses) { capture_stdout { tick.run } }

      assert_match(/would ensure #{Regexp.escape(File.join(root, '.claude'))}/, out)
      refute File.symlink?(File.join(root, ".claude")), "dry run created the link"
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

  # Pausing is the only control that stops ONE machine from taking new work, so
  # the state it must never be confused with is "we could not find out". The
  # fleet read is a different endpoint from the lease POST and fails
  # independently of it: this used to rescue to nil, fall through the `runner &&`
  # guard, and claim on a runner that had been paused thirty seconds earlier.
  def test_an_unreadable_fleet_claims_nothing_rather_than_assuming_unpaused
    with_agent_home do
      register_identity
      responses = fleet_responses.merge(
        "GET /agent/runners" => ->(_body) { raise ApiError, "503 Service Unavailable" },
      )
      out = with_stubbed_api(responses) { capture_stdout { tick.run } }
      assert_match(/fleet state unknown/, out)
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

  # ISS-783. CPU headroom rides the same heartbeat as disk headroom, and this assertion is load
  # bearing in a way the platform side cannot cover: AgentInvariants' oversubscription check reads
  # a column, so if devops ever stopped SENDING these the column would simply go null fleet-wide
  # and the check would go quiet — which from the platform is indistinguishable from a fleet that
  # is comfortably idle. Same argument AgentInvariants writes out for the maintenance vitals.
  def test_the_load_average_rides_the_heartbeat
    with_agent_home do
      register_identity
      sent = nil
      stub_singleton(Agent::Processes, :load_average, ->(*) { [48.5, 30.0, 12.25] }) { sent = heartbeat_once }
      assert_equal 48.5, sent[:load_average_1m]
      assert_equal 12.25, sent[:load_average_15m]
    end
  end

  # A machine that will not say reports nothing rather than 0, exactly as an unreadable df does. A
  # reported 0 is the picture of an idle machine, so it is the one wrong answer that would keep an
  # oversubscribed box looking healthy forever.
  def test_a_machine_that_will_not_report_its_load_sends_nothing_rather_than_zero
    with_agent_home do
      register_identity
      sent = nil
      stub_singleton(Agent::Processes, :load_average, ->(*) { nil }) { sent = heartbeat_once }
      refute sent.key?(:load_average_1m)
      refute sent.key?(:load_average_15m)
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
  # `links` / `blocker_issues` / `prs` drive the dependency gate below and are
  # absent from every other caller, which is itself an assertion: `with_stubbed_api`
  # flunks on an unstubbed request, so an issue with no blockers reaching for a
  # blocker or for GitHub would fail every claim test in this file.
  def claim_one(body:, number: 707, errors: [], playbooks: nil, links: nil, blocker_issues: {}, prs: {},
                comments: [], branch: nil, extra_stubs: nil, max_concurrency: 1, parent: nil, children: nil,
                resume: ->(_branch) { nil })
    seen = { comments: [], statuses: [], released: [], snoozed: [], calls: [], prompt: nil, spawned: false,
             claims: 0, resume_lookups: [] }
    with_agent_home do
      register_identity
      Agent::Errors.write(errors) unless errors.empty?
      with_ai_token do
        issue = { "number" => number, "title" => "Weekly code review: platform", "category" => "infrastructure",
                  "body" => body }
        issue["links"] = links if links
        # A child of an epic, as the claim reads it: the parent reference rides
        # the issue itself, and the child ORDER costs the one extra list call
        # asserted below (ISS-767).
        issue["parent"] = { "number" => parent.to_s } if parent
        stubs = {
          "POST /playbook/issue/leases" => lambda { |_b|
            seen[:claims] += 1
            lease = { "id" => "lse-1", "issue_number" => number }
            lease["branch"] = branch if branch
            { "lease" => lease }
          },
          "GET /playbook/issues/#{number}" => issue,
          "GET /playbook/issues/#{number}/comments?limit=101&offset=0" => comments,
          "POST /playbook/issues/#{number}/comments" => ->(b) { seen[:comments] << b[:body]; {} },
          "PUT /playbook/issues/#{number}/status" => ->(b) { seen[:calls] << :status; seen[:statuses] << b; {} },
          "DELETE /playbook/issue/leases/lse-1" => ->(_b) { seen[:calls] << :release; seen[:released] << "lse-1"; {} },
          "PUT /playbook/issues/#{number}/snooze" => lambda { |b|
            seen[:calls] << :snooze
            seen[:snoozed] << b
            { "number" => number, "snoozed_until" => b[:snoozed_until] }
          },
        }
        blocker_issues.each { |n, row| stubs["GET /playbook/issues/#{n}"] = row }
        if children
          key = "GET /playbook/issues?parent_number=#{parent}&limit=200&offset=0"
          stubs[key] = children.respond_to?(:call) ? children : children.map { |n| { "number" => n.to_s } }
        end
        stubs.merge!(extra_stubs.call(seen)) if extra_stubs.respond_to?(:call)
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
        # `gh pr view`, as this claim will see it: nil for a url means UNKNOWN
        # (gh missing, rate limited, no such PR), which the gate must read as
        # "dispatch" and never as "not merged".
        pr_view = ->(url) { prs[url] }
        # Every claim asks whether its branch already carries an open PR
        # (ISS-767 — the branch is derived, so a retry arrives on its
        # predecessor's name). That is a `gh search prs` call, and a suite that
        # made it for real would be both slow and rate-limited, so it is stubbed
        # here rather than per-test: `resume_lookups` is what the resume
        # assertions below read.
        resume_lookup = ->(b) { seen[:resume_lookups] << b; resume.call(b) }
        stub_singleton(Agent::Github, :pr_by_url, pr_view) do
          stub_singleton(Agent::Workspace, :resume, resume_lookup) do
            stub_singleton(Agent::Jobs, :spawn_session, spawn) do
              with_stubbed_api(stubs) do
                seen[:out] = capture_stdout do
                  tick(dry_run: false).claim(Agent::Host.cached_identity, runner_row(max_concurrency: max_concurrency))
                end
                # Read INSIDE with_agent_home: the state dir is a tmpdir that is
                # gone, and DEV_AGENT_STATE_DIR restored, by the time `seen` is
                # returned.
                seen[:errors] = Agent::Errors.list
              end
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

  # ---- the dependency gate (ISS-649) ----
  #
  # The tracker unblocks a `blocked_by` edge as soon as the blocker reaches
  # `fixed`, on the premise that `fixed` means the blocker's PR merged. In this
  # fleet it does not: §1 of the standing instructions has every session record
  # `fixed` the moment its PR is READY. So a dependent issue becomes claimable
  # while the code it builds on is still on somebody's open branch, and the
  # session that gets it can only re-implement that branch or stack on it —
  # ISS-644 stacked, and its PR could not merge until a human merged the other
  # one first.
  #
  # These prove the gate asks GitHub rather than the status, and that it puts the
  # issue DOWN (deferred, at its own status) rather than escalating it on day one.

  BLOCKER_PR = "https://github.com/mbryzek/devops/pull/359".freeze

  def blocked_by(number: "633", status: "fixed")
    [{ "type" => "blocked_by", "direction" => "outgoing",
       "issue" => { "number" => number, "title" => "lint the playbook store", "status" => status } }]
  end

  def blocker_issue(number: "633", fixes: [{ "url" => BLOCKER_PR }])
    { number => { "number" => number, "status" => "fixed", "fixes" => fixes } }
  end

  def pr(state, url: BLOCKER_PR)
    { url => { "url" => url, "number" => 359, "title" => "ISS-633: lint the playbook store", "state" => state } }
  end

  def test_a_blocker_fixed_on_a_pr_that_has_not_merged_starts_no_session
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: pr("OPEN"))
    refute seen[:spawned], "the dependency is not on origin/main; a session could only stack on it"
    assert_equal ["lse-1"], seen[:released], "the lease must not be held by a session that never started"
    assert_empty seen[:statuses], "an unmerged dependency is not a status change — it is not work YET"
    refute_empty seen[:snoozed], "and it has to leave the queue, or the next tick re-claims it in 30 seconds"
  end

  # `snoozed_until` is cleared by any status transition, and releasing the lease
  # transitions claimed -> open. Snoozing first would be wiped by the release and
  # the issue would spin through this gate every 30 seconds.
  def test_the_lease_is_released_before_the_issue_is_deferred
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: pr("OPEN"))
    assert_equal [:release, :snooze], seen[:calls]
  end

  # What a human reads a week later has to name the PR, not just say "blocked".
  def test_the_deferral_names_the_pull_request_it_is_waiting_on
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: pr("OPEN"))
    comment = seen[:snoozed].first[:comment]
    assert_includes comment, Agent::Tick::DEPENDENCY_DEFER_MARKER
    assert_includes comment, BLOCKER_PR
    assert_includes comment, "ISS-633"
    assert_match(/attempt 1 of #{Agent::Tick::DEPENDENCY_DEFER_LIMIT}/, comment)
  end

  def test_a_blocker_whose_pr_has_merged_dispatches_normally
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: pr("MERGED"))
    assert seen[:spawned], "the code is on origin/main — this is ordinary work now"
    assert_empty seen[:snoozed]
  end

  # A reopened issue accumulates fixes, and `dev issues fix` appends more after the
  # fact. Reading only the newest would defer a dependent on a follow-up PR whose
  # merge it never needed.
  def test_any_merged_fix_clears_the_blocker_even_with_a_later_one_still_open
    later = "https://github.com/mbryzek/devops/pull/400"
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue(fixes: [{ "url" => BLOCKER_PR }, { "url" => later }]),
                     prs: pr("MERGED").merge(pr("OPEN", url: later)))
    assert seen[:spawned]
  end

  # FAIL OPEN. `gh` missing, a rate limit, a url that names no PR — every unknown
  # dispatches. A gate that stalls the queue whenever GitHub is unreachable is a
  # worse failure than the one it prevents, and it would be a silent one.
  def test_a_pr_that_cannot_be_read_dispatches_rather_than_stalling_the_queue
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: {})
    assert seen[:spawned]
    assert_empty seen[:snoozed]
  end

  # A document fix is not a merge anybody is waiting for.
  def test_a_blocker_whose_fix_is_a_document_dispatches
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue(fixes: [{ "url" => "https://docs.google.com/document/d/1" }]),
                     prs: {})
    assert seen[:spawned]
  end

  # The server passes over an issue whose blocker is live work, so this is a race
  # it should never see — agreeing with the server costs one branch and cannot
  # false-positive. No blocker is read and GitHub is never called.
  def test_a_blocker_that_is_still_live_work_defers_without_asking_github
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by(status: "claimed"))
    refute seen[:spawned]
    assert_includes seen[:snoozed].first[:comment], "ISS-633 is still `claimed`"
  end

  # A dismissed blocker is never going to ship. The tracker treats it as
  # unblocking and so does this: the dependent is on its own.
  def test_a_dismissed_blocker_does_not_hold_anything_back
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by(status: "dismissed"))
    assert seen[:spawned]
  end

  # Deferring forever is the silent-aging outcome the whole close-out contract
  # exists to prevent: a snoozed issue is out of the queue AND out of the daily
  # nudge, so a PR nobody merges would stall its dependents with nothing anywhere
  # saying so. After a week of daily checks it becomes a human's problem, loudly.
  def test_a_week_of_deferrals_escalates_to_needs_input
    prior = Array.new(Agent::Tick::DEPENDENCY_DEFER_LIMIT - 1) do
      { "body" => "#{Agent::Tick::DEPENDENCY_DEFER_MARKER} — not dispatched, deferred 1 day." }
    end
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: pr("OPEN"), comments: prior)
    refute seen[:spawned]
    assert_empty seen[:snoozed], "another day of silence is exactly what has already failed six times"
    assert_equal ["needs_input"], seen[:statuses].map { |s| s[:status] }
    assert_includes seen[:statuses].first[:comment], BLOCKER_PR
    assert_equal ["lse-1"], seen[:released]
  end

  # The undeferrable path arrives at the escalation with the lease ALREADY
  # released by `defer_for_dependency`. A second DELETE answers 404/409, which is
  # an ApiError, and it unwound the rest of the claim loop — the status write had
  # already landed, so the issue was fine and only the tick's account of what it
  # did was wrong (ISS-743).
  def test_a_deferral_that_will_not_record_escalates_and_releases_the_lease_exactly_once
    undeferrable = ->(_seen) { { "PUT /playbook/issues/707/snooze" => ->(_b) { { "number" => 707 } } } }
    seen = claim_one(body: "Wire the new lint into D4.", links: blocked_by,
                     blocker_issues: blocker_issue, prs: pr("OPEN"), extra_stubs: undeferrable)
    refute seen[:spawned]
    assert_equal ["needs_input"], seen[:statuses].map { |s| s[:status] },
                 "a deferral that cannot be recorded escalates — leaving it open and undeferred spins"
    assert_includes seen[:statuses].first[:comment], "could not record the deferral"
    assert_equal ["lse-1"], seen[:released], "the lease is released once, by defer_for_dependency"
    assert_equal 1, seen[:calls].count(:release)
  end

  # ---- a claim that raises must not take the tick with it (ISS-743) ----
  #
  # `start_job` runs with the lease ALREADY GRANTED. Anything it raises that is
  # not one of the two platform errors used to travel out of phase_b, out of
  # Tick#run and past `handle_errors` — killing the process and leaving the issue
  # `claimed` with no session until the lease expired, roughly every ten minutes,
  # with a launchd stderr backtrace as the only evidence.

  # The REACHABLE case. `lease["branch"]` is supplied by the platform, and
  # Agent::Workspace refuses (RuntimeError) anything it could not have minted
  # itself, because the unchecked path mkdir_p's and later rm_rf's a
  # caller-controlled path under ~/code/ai. That guard is right; the caller now
  # answers it instead of dying on it.
  # Drives a claim whose lease carries `branch`, and hands back every branch that
  # reached the resume path — which is what these assert: whether the recorded
  # branch is looked up at all, and in which order against the derived one.
  def claim_resuming(branch)
    seen = claim_one(body: "Mike wrote this one by hand.", branch: branch)
    [seen, seen[:resume_lookups]]
  end

  def test_a_recorded_branch_the_workspace_would_refuse_starts_a_fresh_attempt
    seen, asked = claim_resuming("../../../etc/passwd")
    assert_equal ["i707"], asked,
                 "a branch this executor could not have minted must never reach the resume path — only the derived one"
    assert seen[:spawned], "the issue still gets a session — on the derived branch, as a closed prior PR already does"
    assert_match(/on branch `i707`/, seen[:comments].first)
    assert_match(/is not a slug this executor could have minted/, seen[:out])
    assert_empty seen[:released], "nothing failed — this is an ordinary fresh attempt"
  end

  # An over-long branch is refused the same way and for the same reason: it
  # matches the pattern but is past the 19-char ceiling sbt's socket path
  # imposes, which does not fail loudly — sbt simply cannot start.
  def test_an_over_long_recorded_branch_is_refused_the_same_way
    seen, asked = claim_resuming("i707_#{'a' * 40}")
    assert_equal ["i707"], asked
    assert seen[:spawned]
    assert_match(/on branch `i707`/, seen[:comments].first)
  end

  # A recorded branch that IS one of ours is still looked up FIRST, and it is the
  # only thing the lease's `branch` column is good for since ISS-767: an attempt
  # made under the old random scheme has its PR on `i707_abc`, and that PR is the
  # one to update rather than duplicate. With no open PR on it the claim falls
  # through to the derived name, which is where every new attempt lives.
  def test_a_recorded_branch_that_is_one_of_ours_is_preferred_before_the_derived_one
    seen, asked = claim_resuming("i707_abc")
    assert_equal %w[i707_abc i707], asked
    assert seen[:spawned]
    assert_match(/on branch `i707`/, seen[:comments].first)
  end

  # ...and when it DOES have an open PR it wins outright: the derived name is
  # never even asked for, because opening a second PR on an issue already under
  # review is the one thing this ordering exists to prevent.
  def test_a_recorded_branch_with_an_open_pr_wins_over_the_derived_one
    seen = claim_one(body: "Mike wrote this one by hand.", branch: "i707_abc",
                     resume: ->(b) { b == "i707_abc" ? "mbryzek/devops" : nil })
    assert_equal ["i707_abc"], seen[:resume_lookups], "the derived name is never even asked for"
    assert seen[:spawned]
    assert_match(/on branch `i707_abc`/, seen[:comments].first)
    assert_match(/This is a RESUME/, seen[:prompt])
  end

  # ---- the derived branch name (ISS-767) ----
  #
  # `i<epic>_c<nn>` for a child of an epic, `i<issue>` for a standalone issue,
  # and NOTHING random. The name is the join key `dev prs group` runs on, so what
  # matters is that two runs of the same claim agree byte for byte — and that the
  # epic prefix never becomes a merge order (see below).

  def branch_from(seen) = seen[:comments].first[/on branch `([^`]+)`/, 1]

  def test_a_standalone_issue_gets_the_issue_number_as_its_branch
    # `children` is absent, which is itself the assertion: `with_stubbed_api`
    # flunks on an unstubbed request, so an issue with no parent reaching for a
    # child list would fail here rather than silently costing a call per claim.
    seen = claim_one(body: "Mike wrote this one by hand.")
    assert_equal "i707", branch_from(seen)
  end

  def test_a_child_of_an_epic_gets_the_epic_prefix_and_its_position
    seen = claim_one(body: "Mike wrote this one by hand.", parent: 682, children: %w[701 707 690])
    assert_equal "i682_c03", branch_from(seen), "sorted by issue number: 690 is c01, 701 is c02, 707 is c03"
    assert_match(/Branch to use in every repo you touch: `i682_c03`/, seen[:prompt])
  end

  # The whole point: a retry has to land on the branch its predecessor pushed, or
  # review feedback opens a second PR instead of updating the one under review.
  def test_two_claims_of_the_same_child_compute_the_same_branch
    branches = 2.times.map do
      branch_from(claim_one(body: "Mike wrote this one by hand.", parent: 682, children: %w[701 707 690]))
    end
    assert_equal 1, branches.uniq.length
  end

  # A child filed LATER cannot renumber the children that already have branches:
  # issue numbers are monotonic and the ordering is numeric.
  def test_a_child_added_later_does_not_move_an_existing_child
    early = branch_from(claim_one(body: "b", parent: 682, children: %w[690 701 707]))
    late = branch_from(claim_one(body: "b", parent: 682, children: %w[690 701 707 760 799]))
    assert_equal early, late
  end

  # Branch naming must never be able to cost a claim. The list call is one HTTP
  # request on a path the rest of the claim does not need, and an issue that gets
  # no session is strictly worse than one whose branch loses its epic prefix.
  def test_a_child_list_that_will_not_load_falls_back_to_the_standalone_form
    seen = claim_one(body: "b", parent: 682,
                     children: ->(_b) { raise ApiError.new("boom", code: 500) })
    assert seen[:spawned], "the session still starts"
    assert_equal "i707", branch_from(seen)
    assert_match(/could not resolve ISS-707's position in epic ISS-682/, seen[:out])
  end

  # Same fallback for a child list that loads but does not contain this issue —
  # an epic re-parented mid-claim, or a tracker that disagrees with itself. There
  # is no position to take, and inventing one would name a branch a later attempt
  # could not recompute.
  def test_a_child_missing_from_its_own_epic_falls_back_to_the_standalone_form
    seen = claim_one(body: "b", parent: 682, children: %w[690 701])
    assert seen[:spawned]
    assert_equal "i707", branch_from(seen)
    assert_match(/is not in epic ISS-682's child list/, seen[:out])
  end

  # THE constraint this whole scheme is under (ISS-767): `c<nn>` is creation
  # order and never merge order. A lane that read c01-before-c02 as a dependency
  # would be right most of the time and silently wrong the moment a child is
  # filed late. So the session is told, in the
  # standing instructions it is handed, and nothing in the executor parses the
  # suffix back out.
  def test_the_session_is_told_that_the_child_index_is_not_a_merge_order
    seen = claim_one(body: "b", parent: 682, children: %w[690 701 707])
    assert_match(/`c<nn>` IS CREATION ORDER\. It is NEVER merge order\./, seen[:prompt])
    assert_match(/ordering comes only from explicit `blocked_by`\s+edges/, seen[:prompt])
  end

  # The backstop, for every failure nobody has thought of. Before the session is
  # spawned the lease is worth nothing to anyone, so it goes back rather than
  # sitting held until it expires.
  def test_a_claim_that_crashes_before_the_spawn_releases_the_lease
    boom = ->(_seen) { { "GET /playbook/issues/707" => ->(_b) { raise "the platform sent something unparseable" } } }
    seen = claim_one(body: "unused", extra_stubs: boom, max_concurrency: 2)
    refute seen[:spawned]
    assert_equal ["lse-1"], seen[:released], "a lease nothing is running under must go back to the queue"
    assert_match(/claim FAILED \(RuntimeError: the platform sent something unparseable\)/, seen[:out])
    assert_equal 1, seen[:claims], "and claiming stops — whatever broke is not issue-specific"
  end

  # ...but NOT once a session exists. `start_job` spawns before it writes the
  # claim comment, so a failure in that last call has a live child holding the
  # lease legitimately: releasing it would expire a session that is working,
  # which is the "machine competes with itself" failure the two-phase split
  # exists to prevent.
  def test_a_claim_that_crashes_after_the_spawn_leaves_the_lease_held
    boom = ->(_seen) { { "POST /playbook/issues/707/comments" => ->(_b) { raise "500 from the comment write" } } }
    seen = claim_one(body: "Mike wrote this one by hand.", extra_stubs: boom)
    assert seen[:spawned]
    assert_empty seen[:released], "a lease with a live session under it is held, not released"
    assert_match(/a session is already running under this lease/, seen[:out])
  end

  # Three in a row files an issue rather than scrolling past on stderr, which is
  # what `record_failure` buys over a log line — and the streak is what made the
  # original failure invisible for as long as it was.
  def test_a_crashing_claim_is_recorded_durably
    boom = ->(_seen) { { "GET /playbook/issues/707" => ->(_b) { raise "unparseable" } } }
    seen = claim_one(body: "unused", extra_stubs: boom)
    assert_equal [Agent::Tick::CLAIM_ERROR_SOURCE], seen[:errors].map { |e| e["source"] }
    assert_includes seen[:errors].first["message"], "ISS-707: RuntimeError: unparseable"
  end

  # And the whole-phase backstop: a crash anywhere ELSE in Phase B — the reap,
  # the toolchain check — used to kill the process just as dead. Phase A has
  # already run by then, so the heartbeat stays green and the machine looks
  # healthy while doing no work at all.
  def test_a_work_phase_crash_is_contained_and_recorded_rather_than_killing_the_tick
    with_agent_home do
      register_identity
      subject = tick(dry_run: false)
      subject.define_singleton_method(:reap) { |_identity| raise IOError, "the reap fell over" }
      out = capture_stdout { subject.phase_b }
      assert_match(/work phase CRASHED \(IOError: the reap fell over\)/, out)
      assert_equal [Agent::Tick::WORK_PHASE_ERROR_SOURCE], Agent::Errors.list.map { |e| e["source"] }
    end
  end

  # ---- runner staleness is the PLATFORM's alert, not a runner's ----

  # A runner has NO notification channel, and that is the design (ISS-535, and
  # the removal that followed it). Everything a tick would have pushed lands on
  # the platform record instead — an outcome moves the issue to `fixed` or
  # `needs_input` with the url and the reason, a repeated infra failure files a
  # fingerprinted issue, and runner staleness is
  # `CheckAgentRunnerHealthProcessor` emailing off the same
  # `AgentInvariants.StaleAfterHours` the tick used to read back as `is_stale`.
  #
  # `Agent::Notify` used to sit in front of all of that, shelling out to an
  # `openclaw` that is not installed on the runners: every push the fleet ever
  # attempted was a no-op, and the module's own backstop table was the proof
  # that nothing was lost by it. A parallel path that has never once delivered
  # is not a channel, it is a second place for the truth to live, so it is gone
  # rather than documented.
  #
  # Scanned out of the source, in the same spirit as the backstop test it
  # replaces: the failure this guards is someone re-adding a runner-local alert,
  # which by construction announces itself nowhere.
  #
  # Two narrowings, both deliberate. Comments are stripped, because the history
  # above must stay written down and would otherwise trip its own guard. And the
  # binary is matched as a bare literal (`"openclaw"`, a command) rather than
  # anywhere in a string, because `Briefing::DATA_DIR` still reads a path under
  # `~/code/openclaw` — a different dependency, tracked by ISS-503, and not one
  # a notification test should be the thing that fails on.
  def test_the_runner_has_no_local_notification_channel
    sources = Dir[File.expand_path("../lib/**/*.rb", __dir__)] + [File.expand_path("../bin/dev", __dir__)]
    offenders = sources.select do |file|
      code = File.read(file).lines.grep_v(/^\s*#/).join
      code.match?(/Agent::Notify|(["'])openclaw\1/)
    end
    assert_empty offenders.map { |f| File.basename(f) },
                 "a runner cannot alert anyone — send it to the platform record instead " \
                 "(issue status, a fingerprinted issue, or a processor that emails)"
  end

  # The other half of the same rule, from the behavior side: a fleet response
  # naming a stale PEER produces nothing here. An offline machine cannot report
  # itself, and a one-runner fleet has no peer to report it, so a runner-local
  # staleness check reports nothing precisely when it matters most.
  def test_a_stale_peer_produces_no_runner_local_alert
    out = with_agent_home do
      register_identity
      fleet = fleet_responses(runners: [runner_row,
                                        runner_row(id: "rnr-2", hostname: "mini-2.local", is_stale: true),
                                        runner_row(id: "rnr-3", hostname: "mini-3.local", is_stale: false)])
      with_stubbed_api(fleet) { capture_stdout { tick.run } }
    end
    refute_match(/stale|offline/i, out,
                 "runner-offline is the platform's alert (CheckAgentRunnerHealthProcessor), not a peer runner's")
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

  # ---- ISS-742: the streak this threshold reads has to be reachable ----

  # Every source the tick can record a failure against. One tick runs all of
  # them, which is why they fail ROUND-ROBIN on a broken machine rather than one
  # at a time.
  TICK_ERROR_SOURCES = [
    Agent::Tick::CHECKOUT_PULL_ERROR_SOURCE, Agent::Tick::CLAUDE_CONFIG_ERROR_SOURCE,
    Agent::Maintenance::GC_SOURCE, Agent::Maintenance::AIDIRS_SOURCE,
    Agent::Maintenance::CLAUDE_DB_SOURCE, Agent::Maintenance::DOCKER_SOURCE,
  ].freeze

  # ERROR_ESCALATE_AT and Agent::Errors' eviction were written independently and
  # never compared, which is the whole of ISS-742: the threshold counts ONE
  # source's failures and the log evicted across ALL of them. Compared here, in
  # the suite, rather than in a comment on either side that the other cannot see.
  def test_the_error_log_can_hold_a_streak_long_enough_to_escalate
    assert_operator Agent::Errors::PER_SOURCE_CAP, :>, Agent::Tick::ERROR_ESCALATE_AT,
                    "strictly greater: a count that saturates AT the threshold matches the `==` crossing check " \
                    "on every tick forever, re-notifying a streak that was already escalated"
    assert_operator Agent::Errors::MAX_SOURCES, :>=, TICK_ERROR_SOURCES.length,
                    "every source the tick can record must fit, or one chore's failures evict another's"
  end

  # The machine this escalation exists for: five or six chores failing at once —
  # no network, full disk, dead Docker, no claude checkout. Under the old cap of
  # 10 entries TOTAL that machine filed NOTHING (the first entry for a source was
  # always evicted before its third arrived, so no count ever reached 3) while a
  # machine with three failing chores escalated correctly. With four it filed on
  # EVERY round, because eviction bounced the count 3 → 2 → 3.
  def test_every_source_escalates_exactly_once_when_all_of_them_fail_together
    with_agent_home do
      register_identity
      filed = []
      with_ai_token do
        stubs = { "POST /playbook/issues" => ->(body) { filed << body; { "number" => 42, "occurrence_count" => 1 } } }
        with_stubbed_api(stubs) do
          5.times do
            TICK_ERROR_SOURCES.each do |source|
              capture_stdout do
                tick(dry_run: false).record_failure(source, "boom",
                                                    title: ->(host) { "dev-agent: #{source} failing on #{host}" },
                                                    explain: "why this matters")
              end
            end
          end
        end
      end
      assert_equal TICK_ERROR_SOURCES.sort, filed.map { |body| body[:fingerprint].split(":").first }.sort,
                   "each failing source files exactly one issue, on the round its OWN streak crosses the threshold"
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
  # trains Mike to ignore the queue, which costs the issues that matter.
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
