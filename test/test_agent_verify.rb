#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/ci'
require 'agent/merge_lane'
require 'agent/tick'
require 'agent/verify'

# The fleet verify job (ISS-848) — the thing that PRODUCES the `ci` check the
# merge lane reads.
#
# Every failure this guards is silent in the direction that matters, and each one
# is a different silence:
#
#   a job that never answers   the lane reads `:ci_pending` for a job still
#                              running and for a job that died, and waits forever
#                              on both. Nothing raises; the queue just stops.
#   a job enqueued twice       one merge invalidates every sibling PR, so an
#                              uncapped scan fills the fleet in a single pass and
#                              starves the sessions on it.
#   a green on the wrong tree  a result re-pointed at the current head, or a warm
#                              build that kept state it should have thrown away,
#                              is a green the lane MERGES without anyone looking.
#   a lane that stopped reading it
#                              `Agent::MergeLane` reads a commit status only
#                              through the `context`/`state` arm of its rollup
#                              normalisation. Drop that arm in a refactor and
#                              every repo silently reports `:no_ci_verdict`.
class TestAgentVerify < Minitest::Test
  include DevTestSupport

  def with_state_dir
    Dir.mktmpdir do |root|
      previous = [ENV["DEV_AGENT_STATE_DIR"], ENV["DEV_AGENT_LOG_ROOT"]]
      begin
        ENV["DEV_AGENT_STATE_DIR"] = File.join(root, "state")
        ENV["DEV_AGENT_LOG_ROOT"] = File.join(root, "logs")
        FileUtils.mkdir_p(ENV["DEV_AGENT_STATE_DIR"])
        Agent::Verify.instance_variable_set(:@enrolment_cache, nil)
        # DevTestSupport::VerifyGuard neuters `scan` and `claim` for the whole
        # suite, so that no test can walk the real lane or post a real commit
        # status. This is the one file whose subject they are, so it asks for them
        # back — with the shell stubbed underneath, which is what keeps the
        # network out.
        with_real_verify { yield root }
      ensure
        ENV["DEV_AGENT_STATE_DIR"], ENV["DEV_AGENT_LOG_ROOT"] = previous
        Agent::Verify.instance_variable_set(:@enrolment_cache, nil)
      end
    end
  end

  # ---- the contract with the lane -------------------------------------------

  # THE PROPERTY THAT MADE THIS SWAP CHEAP, and the one a later refactor can
  # silently break. GitHub returns two shapes through one `statusCheckRollup`
  # array: an Actions CheckRun (`name` + `status`/`conclusion`) and a commit
  # status (`context` + `state`). The fleet posts the SECOND, so a lane that
  # stopped reading `context` would report `:no_ci_verdict` on every repo — and
  # would do it without a single error anywhere.
  def test_the_lane_reads_a_commit_status_the_fleet_could_post
    sha = "a" * 40
    pr = {
      "state" => "OPEN", "isDraft" => false, "isCrossRepository" => false,
      "title" => "ISS-1: something", "mergeStateStatus" => "CLEAN",
      "headRefOid" => sha, "baseRefName" => "main",
      "statusCheckRollup" => [{ "context" => Agent::Verify::CHECK, "state" => "SUCCESS" }],
    }
    verdict = Agent::MergeLane.verdict(pr, repo: "mbryzek/playbook-admin", base_status: "ahead")
    assert_equal :mergeable, verdict.code
    assert verdict.mergeable?, "a commit status must be able to green a PR, or nothing the fleet posts counts"
  end

  # ...and the same shape while it is still running is `:ci_pending` rather than
  # `:no_ci_verdict`. That distinction is what stops a second box enqueueing a
  # sha this one is already building.
  def test_a_pending_commit_status_reads_as_in_flight_not_as_no_ci
    pr = base_pr("statusCheckRollup" => [{ "context" => Agent::Verify::CHECK, "state" => "PENDING" }])
    assert_equal :ci_pending, Agent::MergeLane.verdict(pr, repo: "mbryzek/playbook-admin").code
  end

  # ---- the enqueue signal ---------------------------------------------------

  # A head sha with no `ci` entry is exactly the lane's `:no_ci_verdict`, read
  # from the other side. Anything else is somebody's answer and is left alone.
  def test_only_a_pr_with_no_ci_entry_is_a_candidate
    with_state_dir do
      assert Agent::Verify.needs_check?("mbryzek/x", base_pr("statusCheckRollup" => []))
      refute Agent::Verify.needs_check?("mbryzek/x", base_pr(
        "statusCheckRollup" => [{ "context" => "ci", "state" => "SUCCESS" }]
      ))
      refute Agent::Verify.needs_check?("mbryzek/x", base_pr(
        "statusCheckRollup" => [{ "context" => "ci", "state" => "FAILURE" }]
      ))
    end
  end

  # A REPO THAT STILL PRODUCES `ci` FROM GITHUB ACTIONS IS NEVER ENQUEUED HERE.
  # The rollup carries CheckRuns and commit statuses alike, so reading it — rather
  # than the statuses endpoint — is what stops two producers racing to post one
  # context on one commit, which the lane would resolve by whichever landed last.
  def test_an_actions_check_run_suppresses_the_fleet
    with_state_dir do
      refute Agent::Verify.needs_check?("mbryzek/x", base_pr(
        "statusCheckRollup" => [{ "name" => "ci", "status" => "IN_PROGRESS" }]
      ))
      refute Agent::Verify.needs_check?("mbryzek/x", base_pr(
        "statusCheckRollup" => [{ "name" => "ci", "status" => "COMPLETED", "conclusion" => "SUCCESS" }]
      ))
    end
  end

  # THE SELF-HEAL. A box that posted `pending` and then vanished leaves a status
  # the lane waits on forever, and nothing else in the system would ever notice.
  # A pending older than a job could possibly still be running is abandoned.
  def test_an_abandoned_pending_status_is_re_enqueued_and_a_recent_one_is_not
    with_state_dir do
      now = Time.now
      pr = base_pr("statusCheckRollup" => [{ "context" => "ci", "state" => "PENDING" }])

      with_status(created_at: (now - 60).utc.iso8601) do
        refute Agent::Verify.needs_check?("mbryzek/x", pr, now: now),
               "a job that started a minute ago must not be stolen from the runner working it"
      end
      with_status(created_at: (now - Agent::Verify::STALE_PENDING_SECONDS - 60).utc.iso8601) do
        assert Agent::Verify.needs_check?("mbryzek/x", pr, now: now)
      end
    end
  end

  # Deliberately only PENDING is ever re-enqueued: a `failure` is an ANSWER, and
  # re-running a red PR on a timer hides a real failure behind an eventual green.
  def test_an_old_failure_is_never_re_enqueued
    with_state_dir do
      refute Agent::Verify.needs_check?("mbryzek/x", base_pr(
        "statusCheckRollup" => [{ "context" => "ci", "state" => "FAILURE" }]
      ), now: Time.now + (30 * 24 * 3600))
    end
  end

  # A draft is skipped because the LANE skips it: verifying one spends a build on
  # a pull request nothing can act on.
  def test_drafts_and_forks_are_not_candidates
    with_state_dir do
      prs = [base_pr("number" => 1, "isDraft" => true),
             base_pr("number" => 2, "isCrossRepository" => true),
             base_pr("number" => 3)]
      stub_singleton(Agent::MergeLane, :open_prs, ->(_repo) { prs }) do
        assert_equal [3], Agent::Verify.pr_candidates("mbryzek/x").map(&:pr)
      end
    end
  end

  # `gh pr list --repo playbook-admin` does not resolve a bare name outside a
  # checkout of that repo: it exits non-zero, `capture` reads that as no output,
  # and `open_prs` reads THAT as "no open pull requests". A scan over the bare
  # LANE_REPOS therefore finds nothing, forever, while reporting that every PR is
  # covered — which is precisely the silence this whole module exists to remove.
  def test_the_scan_asks_github_about_fully_qualified_repositories
    assert Agent::Verify.repos.all? { |r| r.include?("/") }, "a bare repo name silently finds no pull requests"
    refute_includes Agent::Verify.repos, "mbryzek/devops",
                    "merging devops deploys the fleet in 30s, so a check on it buys no automation"
  end

  # ---- the cap --------------------------------------------------------------

  # FAILURE MODE 2. One merge in a 50-PR repo makes 49 siblings need a new check
  # at once, because every merge invalidates every sibling under the lane's AHEAD
  # invariant. What is dropped must be COUNTED — a silent truncation reads as
  # "the fleet is keeping up" when 45 pull requests are waiting.
  def test_the_scan_caps_each_pass_and_reports_what_it_deferred
    with_state_dir do
      prs = (1..20).map { |n| base_pr("number" => n, "headRefOid" => format("%040d", n)) }
      with_scan(prs, enrolled: true) do
        scan = Agent::Verify.scan(limit: 4, include_main: false)
        assert_equal 4, scan.candidates.length
        assert_equal 16, scan.dropped
      end
    end
  end

  # ...and it caps ACROSS repos fairly. One merge into a busy repo invalidates
  # every sibling PR in it at once, so concatenating repos and taking the first N
  # would give that repo every slot in every pass and leave a one-PR repo behind
  # it never built at all.
  def test_the_cap_is_shared_across_repos_rather_than_taken_by_the_busiest
    with_state_dir do
      busy = (1..10).map { |n| base_pr("number" => n, "headRefOid" => format("%040d", n)) }
      quiet = [base_pr("number" => 99, "headRefOid" => "b" * 40)]
      stub_singleton(Agent::MergeLane, :open_prs, lambda { |repo|
        next busy if repo.to_s.include?("playbook-admin")
        repo.to_s.include?("rallyd") ? quiet : []
      }) do
        stub_singleton(Agent::Verify, :enrolled?, ->(_repo, _sha) { true }) do
          numbers = Agent::Verify.scan(limit: 2, include_main: false).candidates.map(&:pr)
          assert_includes numbers, 99, "the quiet repo must not be starved by the busy one"
        end
      end
    end
  end

  # Enrolment is `ci/build.sh` at the HEAD SHA and nothing else: no registry to
  # drift from the repos that have one, and the enrolling commit is one the lane
  # can read at the sha it is verifying.
  def test_an_unenrolled_repo_produces_no_candidates
    with_state_dir do
      with_scan([base_pr("number" => 1)], enrolled: false) do
        assert_empty Agent::Verify.scan(include_main: false).candidates
      end
    end
  end

  # The answer for a sha can never change, so it is asked ONCE. Without this,
  # ten repos with no CI re-ask the same question every scan and burn the API
  # budget the enrolled ones need.
  def test_enrolment_is_asked_once_per_sha
    with_state_dir do
      asked = 0
      stub_shell(lambda { |cmd, _opts|
        asked += 1 if cmd.include?("--jq")
        shell_result(output: "abc")
      }) do
        3.times { Agent::Verify.enrolled?("mbryzek/x", "a" * 40) }
      end
      assert_equal 1, asked
    end
  end

  # A LOOKUP THAT FAILED IS NOT AN ANSWER. A `gh` blip must cost one skipped pass,
  # never an enrolment silently withdrawn for the life of a sha — which, because
  # the cache is permanent, it would be.
  def test_a_failed_enrolment_lookup_is_unknown_and_is_not_cached
    with_state_dir do
      stub_shell(->(_cmd, _opts) { shell_result(output: "connection reset", exitstatus: 1) }) do
        assert_nil Agent::Verify.enrolled?("mbryzek/x", "a" * 40)
      end
      refute_includes Agent::Verify.enrolment_cache.keys, "mbryzek/x@#{'a' * 40}"
    end
  end

  # ---- the fleet-wide dedup -------------------------------------------------

  # FAILURE MODE 6: two machines verifying one sha. The dedup has to live where
  # the other box can SEE it, which is why it is a commit status and not a file
  # here. Post a token, read the context back; the box whose token is not the
  # current one drops the job before it spends a build on it.
  def test_a_claim_is_only_taken_when_our_own_token_comes_back
    with_state_dir do
      candidate = Agent::Verify::Candidate.new(repo: "mbryzek/x", pr: 1, sha: "a" * 40, event: "pull_request")

      with_status(description: "queued on Mac (mine)") do
        assert_equal "mine", Agent::Verify.claim(candidate, token: "mine")
      end
      with_status(description: "queued on OtherBox (theirs)") do
        assert_nil Agent::Verify.claim(candidate, token: "mine"),
                   "another runner's pending status means this box must not build the sha"
      end
    end
  end

  def test_a_claim_that_could_not_be_posted_is_not_taken
    with_state_dir do
      candidate = Agent::Verify::Candidate.new(repo: "mbryzek/x", pr: 1, sha: "a" * 40, event: "pull_request")
      stub_shell(->(_cmd, _opts) { shell_result(output: "403", exitstatus: 1) }) do
        assert_nil Agent::Verify.claim(candidate, token: "mine")
      end
    end
  end

  # ---- silence is the unrecoverable outcome ---------------------------------

  # A worker that DECIDED but could not post is re-posted with ITS answer, never
  # with a guess. The `result` marker exists for exactly this window.
  def test_the_reap_reposts_the_answer_a_worker_could_not_post
    with_state_dir do
      record = dead_job
      Agent::Verify.mark_result(record["key"], "success")
      posted = capture_status_posts do
        Agent::Verify.reap { |_r, outcome, _m| assert_equal :reposted, outcome }
      end
      assert_equal ["success"], posted
      assert_empty Agent::Verify.all, "an answered job is forgotten"
    end
  end

  # A worker that vanished before it had any answer is given a FAILURE, because
  # the lane cannot recover from silence: `:ci_pending` is indistinguishable from
  # a dead runner and it waits forever on both. A parked PR a human unparks is the
  # cheaper mistake, and the description says which kind of red it is.
  def test_a_worker_that_died_without_answering_gets_a_failure_marked_infrastructure
    with_state_dir do
      dead_job
      described = []
      stub_shell(lambda { |cmd, _opts|
        described.concat(cmd.select { |a| a.to_s.start_with?("description=") })
        shell_result(output: "{}")
      }) do
        Agent::Verify.reap { |_r, outcome, _m| assert_equal :rescued, outcome }
      end
      assert_match(/INFRASTRUCTURE FAULT/, described.join(" "))
    end
  end

  # ...and a rescue POST that itself failed KEEPS the record. Dropping it would
  # leave the pending status with nothing left in the system that knows about it.
  def test_a_rescue_that_could_not_be_posted_keeps_the_record_for_the_next_tick
    with_state_dir do
      dead_job
      stub_shell(->(_cmd, _opts) { shell_result(output: "502", exitstatus: 1) }) do
        Agent::Verify.reap { |_r, outcome, _m| assert_equal :unresolved, outcome }
      end
      assert_equal 1, Agent::Verify.all.length
    end
  end

  # An answered job costs nothing but forgetting the record — and must NOT post a
  # second status over the one the worker already published.
  def test_an_answered_job_is_forgotten_without_a_second_post
    with_state_dir do
      record = dead_job
      Agent::Verify.mark_posted(record["key"], "success")
      posted = capture_status_posts { Agent::Verify.reap }
      assert_empty posted
      assert_empty Agent::Verify.all
    end
  end

  # ---- the outcome, and what a person is told -------------------------------

  # A red suite and a runner that could not answer both PARK the pull request,
  # and that is correct — the lane must not take a machine's word about itself.
  # What differs is what a PERSON does, so the distinction has to survive
  # somewhere a person reads, which under a fleet job is the status description.
  def test_an_infrastructure_fault_is_a_failure_that_says_so
    build = Agent::Verify.outcome_for(:ok, status_with(1), started: Time.now, timeout: 600)
    assert_equal "failure", build.state
    refute build.infra?
    refute_match(/INFRASTRUCTURE/, build.description)

    infra = Agent::Verify.outcome_for(:ok, status_with(Agent::Ci::INFRA_EXIT_CODE), started: Time.now, timeout: 600)
    assert_equal "failure", infra.state
    assert infra.infra?
    assert_match(/INFRASTRUCTURE FAULT/, infra.description)
    assert_equal Agent::Ci::INFRA_EXIT_CODE, infra.exit_code
  end

  # A build that HUNG must answer, and must answer as the machine's fault. This
  # is failure mode 1 and it is the one the lane cannot survive.
  def test_a_timed_out_build_answers_rather_than_going_silent
    outcome = Agent::Verify.outcome_for(:timed_out, nil, started: Time.now, timeout: 600)
    assert_equal "failure", outcome.state
    assert outcome.infra?
    assert_match(/deadline/, outcome.description)
  end

  # A missing script is enrolment that was withdrawn between the scan and the
  # build. Not a red suite — nothing ran.
  def test_a_missing_build_script_is_an_infrastructure_fault
    outcome = Agent::Verify.outcome_for(:missing, nil, started: Time.now, timeout: 600)
    assert outcome.infra?
    assert_match(/not enrolled/, outcome.description)
  end

  def test_a_clean_build_is_a_success
    outcome = Agent::Verify.outcome_for(:ok, status_with(0), started: Time.now, timeout: 600)
    assert_equal "success", outcome.state
    assert_equal 0, outcome.exit_code
  end

  # ---- the session database -------------------------------------------------

  # RUN, ATTEMPT AND SHARD, all three. `claude-db` keys a database on this, and
  # eight platform runs sharing one went from 3 failures to 39 as `tasks` reached
  # 131,632 rows (ISS-801). Two boxes may verify one sha — harmless by design, and
  # only harmless while their databases are distinct — so the attempt component
  # has to separate PROCESSES, not just retries.
  def test_the_session_id_separates_every_run_attempt_and_machine
    a = Agent::Verify.session_id("mbryzek/platform", "a" * 40, pid: 100, now: Time.at(1_000))
    b = Agent::Verify.session_id("mbryzek/platform", "a" * 40, pid: 101, now: Time.at(1_000))
    c = Agent::Verify.session_id("mbryzek/platform", "a" * 40, pid: 100, now: Time.at(2_000))
    d = Agent::Verify.session_id("mbryzek/platform", "b" * 40, pid: 100, now: Time.at(1_000))
    assert_equal 4, [a, b, c, d].uniq.length
    assert_includes a, "platform"
    assert_match(/-s1\z/, a, "the shard slot must survive even while nothing shards")
  end

  # The name is interpolated into a Postgres identifier after sanitising, and
  # truncation is at the END — so a name long enough to be cut would collide with
  # every other attempt on the same sha.
  def test_the_session_id_fits_a_postgres_identifier
    longest = Agent::MergeLane::LANE_REPOS.max_by(&:length)
    id = Agent::Verify.session_id("mbryzek/#{longest}", "a" * 40, pid: 99_999, now: Time.at(9_999_999_999))
    assert_operator id.length, :<, 50, "session ids must survive DbApp#session_db_name's truncation"
  end

  # ---- warm vs cold ---------------------------------------------------------

  # THE FALSE-GREEN RULE, applied where it actually bites: `git clean` WITHOUT
  # `-x` keeps the ignored files (`target/`, `node_modules/`) that make a build
  # warm, and with `-x` takes them. A cold build that silently cleaned warm would
  # only be slow; a warm build that should have been cold produces a GREEN the
  # lane merges.
  def test_the_pull_request_path_keeps_ignored_state_and_main_throws_it_away
    with_state_dir do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, ".git"))
        stub_singleton(Agent::Paths, :ci_checkout, ->(_repo) { dir }) do
          assert_includes clean_flags(dir, clean: false), "-fd"
          assert_includes clean_flags(dir, clean: true), "-xfd"
        end
      end
    end
  end

  # ---- capacity: one pool, one number ---------------------------------------

  # ISS-848 deleted the reservation, and the thing that must NOT come back with it
  # is a second subtraction: verify jobs are counted by `live_jobs`, so a
  # capacity that also subtracted a reservation would double-count them.
  def test_capacity_is_the_machines_own_number_with_nothing_subtracted
    tick = Agent::Tick.new(use_localhost: false, claude_argv: ["claude"], dry_run: true, now: Time.now)
    assert_equal 3, tick.send(:capacity, { "max_concurrency" => 3 })
    assert_equal 1, tick.send(:capacity, nil)
    assert_equal 0, tick.send(:capacity, { "max_concurrency" => -2 })
  end

  # A live verify job occupies the machine exactly as a session does. Counting
  # only sessions is how one box ends up running its full session concurrency
  # PLUS a build, which is the oversubscription the deleted reservation existed
  # to prevent.
  def test_a_running_verify_job_counts_against_the_same_capacity
    with_state_dir do
      tick = Agent::Tick.new(use_localhost: false, claude_argv: ["claude"], dry_run: true, now: Time.now)
      assert_equal 0, tick.send(:live_jobs)
      Agent::Verify.write("key" => "x-abc", "repo" => "mbryzek/x", "sha" => "a" * 40, "pid" => Process.pid)
      assert_equal 1, tick.send(:live_jobs)
    end
  end

  # ---- helpers --------------------------------------------------------------

  def base_pr(overrides = {})
    {
      "number" => 1, "state" => "OPEN", "isDraft" => false, "isCrossRepository" => false,
      "title" => "ISS-1: something", "mergeStateStatus" => "CLEAN",
      "headRefOid" => "a" * 40, "baseRefName" => "main", "statusCheckRollup" => [],
    }.merge(overrides)
  end

  def status_with(code) = Struct.new(:success?, :exitstatus).new(code.zero?, code)

  # `gh api .../status` as this module reads it: one JSON object per line.
  def with_status(fields, &block)
    body = JSON.generate({ "context" => Agent::Verify::CHECK, "state" => "pending" }.merge(fields))
    stub_shell(->(_cmd, _opts) { shell_result(output: body) }, &block)
  end

  def with_scan(prs, enrolled:, &block)
    stub_singleton(Agent::MergeLane, :open_prs, ->(repo) { repo.to_s.include?("playbook-admin") ? prs : [] }) do
      stub_singleton(Agent::Verify, :enrolled?, ->(_repo, _sha) { enrolled }, &block)
    end
  end

  def dead_job
    # Above the platform's pid ceiling, so `alive?` answers ESRCH rather than
    # ever reaching a real process. NEVER a non-positive pid: `Process.kill`
    # reads those as a process group.
    Agent::Verify.write("key" => "x-abcdef", "repo" => "mbryzek/x", "pr" => 1,
                        "sha" => "a" * 40, "pid" => 4_000_000, "host" => "TestBox",
                        "timeout_at" => (Time.now + 3600).utc.iso8601)
  end

  def capture_status_posts(&block)
    posted = []
    stub_shell(lambda { |cmd, _opts|
      arg = cmd.find { |a| a.to_s.start_with?("state=") }
      posted << arg.to_s.sub("state=", "") if arg
      shell_result(output: "{}")
    }, &block)
    posted
  end

  def clean_flags(dir, clean:)
    seen = []
    stub_shell(lambda { |cmd, _opts|
      seen.concat(cmd) if cmd.include?("clean")
      shell_result(output: "")
    }) do
      Agent::Verify.checkout("mbryzek/x", "a" * 40, pr: 1, clean: clean)
    end
    seen
  end
end
