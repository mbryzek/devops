#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-845: `dev issues review` — the walk through the issues blocked on a human.
#
# The properties under test are the ones that decide whether the command is safe
# to leave a person alone with:
#
#   1. the lookahead window is ONE integer, and consuming an issue tops it back
#      up rather than staging a second batch;
#   2. a summary session is read-only BY CONSTRUCTION — the write tools are
#      denied on its argv, not asked for politely in its prompt;
#   3. a session that is slow, that fails, or that is cancelled leaves the walk
#      standing: the deterministic fallback is a FLOOR, never a fallback path
#      that can itself strand an issue;
#   4. terminating a session kills its process group and leaves nothing running
#      — Ctrl-C at the prompt never reaches them, so this is the only thing that
#      does;
#   5. a line typed at the prompt is the ANSWER unless it is exactly one of the
#      listed keys, and the answer is recorded verbatim with the issue moved to
#      `open` (not to whatever it was before it blocked, which would be
#      `claimed` — invisible to `dev issues claim`).
#
# The process tests drive a real child through a subclass that overrides `argv`,
# so the machinery is exercised end to end without `claude` and without a
# network. `DevTestSupport::NetworkGuard` raises on any request that is not
# stubbed, so nothing here can reach the live tracker.
class TestDevIssuesReview < Minitest::Test
  include DevTestSupport

  # ---------- fixtures ----------

  def blocked_issue(number: "574", status: "needs_input", created: "2026-05-01T09:00:00Z", body: "Route the inbound mail.", title: "Route email.dev.bryzek.com into SendGrid Inbound Parse")
    {
      "id" => "iss-#{number}",
      "number" => number,
      "category" => "improvement",
      "status" => status,
      "title" => title,
      "body" => body,
      "created" => { "at" => created, "by" => { "name" => "Otto AI" } },
      "occurrence_count" => 1,
    }
  end

  def comment(at:, body:, to: nil, from: "claimed", author: "Otto AI")
    c = { "body" => body, "created" => { "at" => at, "by" => { "name" => author } } }
    c["transition"] = { "from" => from, "to" => to } if to
    c
  end

  # A session whose child process is a `ruby -e` script rather than `claude`.
  # Everything else — the pipe drain, the deadline, the process group, the
  # terminate path — is the real code.
  def scripted_session(script, number: "574", timeout: 20)
    klass = Class.new(IssueReview::Session) do
      define_method(:argv) { ["ruby", "-e", script] }
    end
    klass.new(number: number, prompt: "irrelevant", model: "irrelevant", chdir: Dir.pwd, timeout: timeout)
  end

  # Duck-typed stand-in for the Window's tests: those are about WHICH sessions
  # exist and when, which needs no process at all.
  class FakeSession
    attr_reader :number, :start_count, :terminate_count

    def initialize(number, text: "summary", live: false)
      @number = number
      @text = text
      @live = live
      @start_count = 0
      @terminate_count = 0
    end

    def start
      @start_count += 1
      self
    end

    def summary = IssueReview::Summary.new(@number, @text, nil)
    def ready? = !@live
    def done? = !@live
    def terminate = @terminate_count += 1
  end

  def fake_window(numbers, size: 3, live: false, registry: {})
    IssueReview::Window.new(numbers, size: size) do |number|
      registry[number] = FakeSession.new(number, text: "summary #{number}", live: live)
    end
  end

  # ---------- the lookahead window, as a pure function ----------

  def test_window_starts_the_first_k_in_walk_order
    assert_equal %w[1 2 3], IssueReview.window_numbers(%w[1 2 3 4 5 6], [], 3)
  end

  def test_window_tops_back_up_to_k_as_issues_are_consumed
    numbers = %w[1 2 3 4 5 6]
    assert_equal %w[2 3 4], IssueReview.window_numbers(numbers, %w[1], 3)
    assert_equal %w[4 5 6], IssueReview.window_numbers(numbers, %w[1 2 3], 3)
  end

  def test_window_never_reoffers_a_consumed_issue
    # Consumption is not required to be in order — `--number` can scope the walk
    # to any subset — so the filter is by membership, not by position.
    assert_equal %w[1 4], IssueReview.window_numbers(%w[1 2 3 4], %w[2 3], 3)
  end

  def test_window_shrinks_when_fewer_issues_remain_than_k
    assert_equal %w[5 6], IssueReview.window_numbers(%w[1 2 3 4 5 6], %w[1 2 3 4], 5)
    assert_empty IssueReview.window_numbers(%w[1 2], %w[1 2], 5)
  end

  def test_window_of_zero_starts_nothing
    # Not reachable from the CLI, but the guard is what makes K a plain integer
    # rather than a value with a special case hiding behind it.
    assert_empty IssueReview.window_numbers(%w[1 2 3], [], 0)
  end

  # ---------- the window, as scheduling ----------

  def test_the_first_issue_is_started_before_any_other
    # "Nothing queued behind a batch" falls out of starting in walk order rather
    # than being a special case for the first issue — which is what keeps K one
    # integer instead of a first-batch rule and a steady-state rule.
    registry = {}
    window = fake_window(%w[1 2 3 4 5], size: 3, registry: registry)
    window.take("1")
    assert_equal "1", registry.keys.first
  end

  def test_k_is_the_number_of_UNREAD_sessions_in_flight
    # After the first summary is read, the window is topped up so that K sessions
    # are still running AHEAD of where the walk is — that is what makes every
    # issue after the first a zero-wait — and the top-up happens before the wait
    # on this issue's summary, not after its answer.
    registry = {}
    window = fake_window(%w[1 2 3 4 5], size: 3, registry: registry)
    window.take("1")
    assert_equal %w[1 2 3 4], registry.keys, "3 unread (2,3,4) once 1 has been consumed"
    window.take("2")
    assert_equal %w[1 2 3 4 5], registry.keys
    assert_equal 1, registry["5"].start_count, "a topped-up session is started exactly once"
  end

  def test_the_window_never_runs_more_than_k_sessions_ahead
    registry = {}
    fake_window(%w[1 2 3 4 5 6 7 8], size: 3, registry: registry).take("1")
    assert_operator registry.length, :<=, 4, "K unread plus the one being read"
  end

  def test_a_session_is_never_started_twice
    registry = {}
    window = fake_window(%w[1 2 3], size: 3, registry: registry)
    window.take("1")
    window.take("2")
    window.take("3")
    assert(registry.values.all? { |s| s.start_count == 1 })
  end

  def test_restart_terminates_the_old_session_and_runs_a_fresh_one
    sessions = []
    window = IssueReview::Window.new(%w[1], size: 1) do |number|
      sessions << FakeSession.new(number, text: "attempt #{sessions.length + 1}")
      sessions.last
    end
    assert_equal "attempt 1", window.take("1").text
    assert_equal "attempt 2", window.restart("1").text
    assert_equal 1, sessions.first.terminate_count
  end

  def test_shutdown_terminates_every_session_the_walk_started
    registry = {}
    window = fake_window(%w[1 2 3 4], size: 2, live: true, registry: registry)
    window.take("1")
    window.shutdown
    assert_equal %w[1 2 3], registry.keys, "the take topped the window up before shutting down"
    assert(registry.values.all? { |s| s.terminate_count == 1 })
  end

  # ---------- the session ----------

  def test_a_summary_session_cannot_write_anything
    # The guarantee is on the ARGV. An instruction in the prompt would be advice
    # to a model; this is a denial at the CLI, and the session runs unattended
    # with its cwd on a directory full of real checkouts.
    argv = IssueReview::Session.new(number: "1", prompt: "p", model: "m", chdir: "/tmp", timeout: 1).argv
    denied = argv[argv.index("--disallowedTools") + 1].split
    %w[Edit Write NotebookEdit Bash].each { |tool| assert_includes denied, tool }
    assert_includes argv, "--print"
    assert_equal "p", argv.last, "the prompt is the last positional argument"
  end

  def test_a_session_that_succeeds_returns_its_output_stripped
    summary = scripted_session('puts "QUESTION  Ship it?"').summary
    assert summary.ok?
    assert_equal "QUESTION  Ship it?", summary.text
  end

  def test_a_session_that_exits_non_zero_is_an_error_not_a_summary
    summary = scripted_session('$stderr.puts "boom"; exit 3').summary
    refute summary.ok?
    assert_match(/exited 3/, summary.error)
    assert_match(/boom/, summary.error)
  end

  def test_a_session_that_produces_nothing_is_not_a_summary
    # A clean exit with no output is a failure to summarise, not an empty
    # summary: printing nothing under the heading would read as "no question".
    refute scripted_session('exit 0').summary.ok?
  end

  def test_a_session_that_never_finishes_is_stopped_and_falls_back
    session = scripted_session('sleep 60', timeout: 1)
    summary = session.summary
    refute summary.ok?
    assert_match(/still running after 1s/, summary.error)
  end

  def test_a_stopped_session_leaves_no_process_behind
    # This is the Ctrl-C property. The child is in its own process group, so the
    # terminal's interrupt never reaches it — terminate is the only thing that
    # does, and a walk that abandoned it would otherwise leave a model running
    # with nobody to read it.
    session = scripted_session('sleep 60', timeout: 30)
    session.start
    pid = session.send(:instance_variable_get, :@wait).pid
    assert alive?(pid), "the child should be running before terminate"
    session.terminate
    assert wait_until_gone(pid), "the process group should be gone after terminate"
    refute session.summary.ok?
    assert_match(/cancelled/, session.summary.error)
  end

  def test_a_session_that_cannot_be_started_degrades_instead_of_raising
    klass = Class.new(IssueReview::Session) do
      def argv = ["definitely-not-a-real-binary-#{Process.pid}"]
    end
    summary = klass.new(number: "1", prompt: "p", model: "m", chdir: Dir.pwd, timeout: 5).summary
    refute summary.ok?
    assert_match(/could not start a summary session/, summary.error)
  end

  def test_a_summary_is_computed_once_and_reused
    # --all reads every summary in the print pass and reaches the same issue
    # again in the answer pass; re-running the session there would double the
    # cost of the mode that exists to avoid waiting.
    session = scripted_session('puts "once"')
    assert_equal session.summary.object_id, session.summary.object_id
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until_gone(pid, seconds: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.05 while alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    !alive?(pid)
  end

  # ---------- what a typed line means ----------

  def test_every_escape_hatch_is_recognised_on_its_own
    { "e" => :editor, "s" => :skip, "z" => :snooze, "d" => :dismiss, "r" => :retry, "q" => :quit }.each do |key, kind|
      assert_equal kind, IssueReview.parse_answer(key).kind
      assert_equal kind, IssueReview.parse_answer("  #{key.upcase}  \n").kind, "#{key} should match trimmed and upcased"
    end
  end

  def test_anything_that_is_not_exactly_a_key_is_the_answer
    # The whole point of the rule. An answer that happens to start with a key
    # letter is still an answer — this is the common case and it must never be
    # swallowed by a command.
    ["skip the second option", "delete it", "e2e is fine here", "s3", "z"].each_with_index do |raw, idx|
      action = IssueReview.parse_answer(raw)
      next if idx == 4 # the bare key
      assert_equal :answer, action.kind, "#{raw.inspect} should be an answer"
      assert_equal raw, action.text
    end
  end

  def test_an_empty_line_opens_the_editor
    assert_equal :editor, IssueReview.parse_answer("\n").kind
    assert_equal :editor, IssueReview.parse_answer("   ").kind
  end

  def test_eof_ends_the_walk_rather_than_recording_a_blank_answer
    # stdin closing under the walk means nobody is left to answer. Reading that
    # as an empty answer would reopen the issue with a blank comment.
    assert_equal :quit, IssueReview.parse_answer(nil).kind
  end

  # ---------- the queue ----------

  def test_the_walk_is_oldest_first
    # The queue's problem is the issue that has been waiting longest, and the
    # list endpoint (and the nudge email) are newest first — which is precisely
    # the order that never reaches it. ISS-574 was waiting long before ISS-832.
    newest = blocked_issue(number: "832", created: "2026-08-01T00:00:00Z")
    oldest = blocked_issue(number: "574", created: "2026-05-01T00:00:00Z")
    middle = blocked_issue(number: "703", created: "2026-06-15T00:00:00Z", status: "needs_review")
    path = issues_list_path(statuses: ISSUE_REVIEW_STATUSES, is_snoozed: false)
    with_stubbed_api("GET #{path}" => [newest, middle, oldest]) do
      assert_equal %w[574 703 832], issue_review_queue("endpoint", nil).map { |i| i["number"] }
    end
  end

  def test_the_queue_asks_for_both_blocked_statuses_and_skips_snoozed
    # A snoozed issue was deliberately parked; putting it back in the walk asks
    # the question its owner already deferred.
    path = issues_list_path(statuses: ISSUE_REVIEW_STATUSES, is_snoozed: false)
    assert_match(/statuses=needs_input&statuses=needs_review/, path)
    assert_match(/is_snoozed=false/, path)
  end

  def test_scoping_to_a_number_that_is_not_blocked_says_what_is
    path = issues_list_path(statuses: ISSUE_REVIEW_STATUSES, is_snoozed: false)
    with_stubbed_api("GET #{path}" => [blocked_issue(number: "574")]) do
      out, status = capture_stderr_and_exit { issue_review_queue("endpoint", "999") }
      assert_equal 1, status
      assert_match(/Not waiting on an answer: 999/, out)
      assert_match(/Waiting now: 574/, out)
    end
  end

  def test_scoping_accepts_padded_and_iss_prefixed_numbers
    path = issues_list_path(statuses: ISSUE_REVIEW_STATUSES, is_snoozed: false)
    with_stubbed_api("GET #{path}" => [blocked_issue(number: "574"), blocked_issue(number: "645")]) do
      assert_equal %w[645], issue_review_queue("endpoint", "ISS-0645").map { |i| i["number"] }
    end
  end

  # ---------- how long it has been waiting ----------

  def test_waiting_is_measured_from_the_transition_that_blocked_it
    issue = blocked_issue(created: "2020-01-01T00:00:00Z")
    comments = [
      comment(at: "2020-01-02T00:00:00Z", body: "claimed", to: "claimed", from: "open"),
      comment(at: (Time.now - (9 * 24 * 60 * 60)).utc.iso8601, body: "Which retention?", to: "needs_input"),
    ]
    assert_equal " · waiting 9 days", issue_review_waiting_label(issue, comments)
  end

  def test_waiting_falls_back_to_when_it_was_filed
    # `dev issues handoff` files an issue and parks it at needs_input in one
    # breath, so there is not always a transition to measure from.
    issue = blocked_issue(created: (Time.now - (3 * 24 * 60 * 60)).utc.iso8601)
    assert_equal " · waiting 3 days", issue_review_waiting_label(issue, [])
  end

  def test_waiting_reads_as_today_rather_than_zero_days
    assert_equal " · waiting since today", issue_review_waiting_label(blocked_issue(created: Time.now.utc.iso8601), [])
  end

  def test_an_unreadable_timestamp_drops_the_label_rather_than_crashing_the_walk
    assert_equal "", issue_review_waiting_label(blocked_issue(created: "not a date"), [])
  end

  # ---------- the deterministic fallback ----------

  def test_the_fallback_leads_with_the_note_that_blocked_the_issue
    comments = [
      comment(at: "2026-05-01T00:00:00Z", body: "Filed."),
      comment(at: "2026-05-02T00:00:00Z", body: "Which SendGrid subdomain should this use?", to: "needs_input"),
      comment(at: "2026-05-03T00:00:00Z", body: "", to: "needs_input"),
    ]
    out = issue_review_fallback(blocked_issue, comments)
    assert_match(/Which SendGrid subdomain should this use\?/, out)
    assert_match(/Everything else: `dev issues show 574`/, out)
  end

  def test_the_fallback_prefers_the_latest_note_when_none_recorded_a_transition
    comments = [comment(at: "2026-05-01T00:00:00Z", body: "first"), comment(at: "2026-05-02T00:00:00Z", body: "later clarification")]
    assert_match(/later clarification/, issue_review_fallback(blocked_issue, comments))
  end

  def test_the_fallback_says_so_when_nothing_was_left_behind
    assert_match(/No note was left when this was blocked/, issue_review_fallback(blocked_issue, []))
  end

  def test_the_fallback_lists_the_blockers_with_their_status
    issue = blocked_issue.merge(
      "links" => [{ "type" => "blocked_by", "direction" => "outgoing",
                    "issue" => { "number" => "639", "title" => "Stop writing invite_code", "status" => "fixed" } }],
    )
    assert_match(/Blocked by: ISS-639 \(fixed\) Stop writing invite_code/, issue_review_fallback(issue, []))
  end

  # ---------- handoff commands ----------

  def test_handoff_commands_are_read_back_out_of_the_body_the_cli_wrote
    # Parser and producer are asserted against each other on purpose: the shape
    # is one this CLI produces, so a change to handoff_body that this could not
    # read would be a silent regression in the one thing a handoff issue is FOR.
    commands = ["openclaw cron rm weekly-review-1", "openclaw cron rm weekly-review-2"]
    issue = blocked_issue(body: handoff_body("No runner has operator.admin.", "396", commands, [], "no-op"))
    assert_equal commands, issue_review_handoff_commands(issue)
  end

  # The section carries prose as well as commands since ISS-917 -- what to set
  # before pasting, what a second run does. Neither is a command, and printing one
  # under "Waiting on a human to run:" is exactly the prose-for-a-command failure
  # `dev issues handoff` exists to prevent.
  def test_only_the_indented_commands_are_read_back_not_the_prose_around_them
    issue = blocked_issue(body: handoff_body("No runner has the token.", "396",
                                             ['curl -H "x-api-key: $OPENCLAW_TOKEN" https://x/y'],
                                             ["OPENCLAW_TOKEN"], "the DELETE is idempotent"))
    assert_equal ['curl -H "x-api-key: $OPENCLAW_TOKEN" https://x/y'], issue_review_handoff_commands(issue)
  end

  def test_handoff_commands_are_printed_in_the_fallback
    issue = blocked_issue(body: handoff_body("No runner has this scope.", "396", ["openclaw cron rm weekly-review-1"],
                                             [], "the second rm errors harmlessly"))
    out = issue_review_fallback(issue, [])
    assert_match(/Waiting on a human to run:/, out)
    assert_match(/openclaw cron rm weekly-review-1/, out)
  end

  def test_an_issue_that_is_not_a_handoff_contributes_no_commands
    assert_empty issue_review_handoff_commands(blocked_issue(body: "Just prose."))
    assert_empty issue_review_handoff_commands(blocked_issue(body: "Run these steps by hand:\n\n  step one"))
    assert_empty issue_review_handoff_commands(blocked_issue.reject { |k, _| k == "body" })
  end

  # ---------- recording the answer ----------

  def test_an_answer_is_recorded_verbatim_and_the_issue_reopens
    # `open` and not the status it held before it blocked: most of these were
    # `claimed`, and a claimed issue nobody is working is invisible to
    # `dev issues claim`, which only ever offers open ones.
    sent = nil
    answer = "Use email.dev.bryzek.com; the MX record is already pointed at SendGrid."
    with_stubbed_api(
      "PUT #{issue_status_path('574')}" => ->(body) { sent = body; blocked_issue(status: "open") },
    ) do
      capture_stdout { issue_review_record_answer("endpoint", blocked_issue, answer) }
    end
    assert_equal "open", sent[:status]
    assert_equal answer, sent[:comment], "the answer is recorded with nothing added to it"
    assert_equal "internal", sent[:visibility]
  end

  def test_dismissing_from_the_walk_records_the_reason
    sent = nil
    with_stubbed_api(
      "PUT #{issue_status_path('574')}" => ->(body) { sent = body; blocked_issue(status: "dismissed") },
    ) do
      capture_stdout { issue_review_dismiss("endpoint", blocked_issue, "Superseded by ISS-700.") }
    end
    assert_equal "dismissed", sent[:status]
    assert_equal "Superseded by ISS-700.", sent[:comment]
  end

  def test_snoozing_from_the_walk_defers_without_changing_the_status
    sent = nil
    with_stubbed_api(
      "PUT #{issue_snooze_path('574')}" => ->(body) { sent = body; blocked_issue.merge("snoozed_until" => body[:snoozed_until]) },
    ) do
      capture_stdout { issue_review_snooze("endpoint", blocked_issue, 7) }
    end
    parsed = Time.parse(sent[:snoozed_until])
    assert_in_delta 7 * 24 * 60 * 60, parsed - Time.now, 120
    refute sent.key?(:status), "a snooze defers the issue; it does not answer it"
  end

  def test_a_rejected_write_costs_that_issue_and_not_the_walk
    # The walk is holding a person's attention and K running sessions. A 422 on
    # one transition must not unwind through handle_errors and take the rest of
    # the queue — and the summaries already paid for — with it.
    out = capture_stdout do
      result = issue_review_write(blocked_issue) { raise ApiError, "status is not a valid transition" }
      assert_nil result, "nil sends the prompt loop round again"
    end
    assert_match(/ISS-574 was NOT updated: status is not a valid transition/, out)
    assert_match(/Nothing was recorded/, out)
  end

  def test_a_dead_credential_stops_the_walk_rather_than_re_prompting_forever
    # Every remaining write would fail the same way, so quietly re-asking through
    # fourteen issues would be worse than saying so once.
    assert_raises(SessionExpired) { issue_review_write(blocked_issue) { raise SessionExpired, "expired" } }
  end

  # ---------- the shared status write ----------

  def test_the_status_write_drops_blanks_and_always_writes_internally
    sent = nil
    with_stubbed_api("PUT #{issue_status_path('574')}" => ->(body) { sent = body; blocked_issue }) do
      issue_put_status("endpoint", "574", status: "open", comment: "answered", url: nil, app: "")
    end
    assert_equal({ status: "open", comment: "answered", visibility: "internal" }, sent)
  end

  def test_a_status_write_with_no_comment_names_no_visibility
    sent = nil
    with_stubbed_api("PUT #{issue_status_path('574')}" => ->(body) { sent = body; blocked_issue }) do
      issue_put_status("endpoint", "574", status: "deployed")
    end
    assert_equal({ status: "deployed" }, sent)
  end

  # ---------- the summarizer prompt ----------

  def test_the_prompt_carries_both_the_instructions_and_the_issue
    # The issue is rendered IN rather than looked up: a session told to fetch it
    # would need the playbook credential and a Bash tool, and Bash is exactly
    # what is denied to keep it read-only.
    prompt = issue_review_prompt(blocked_issue, [comment(at: "2026-05-02T00:00:00Z", body: "Which subdomain?", to: "needs_input")],
                                 use_localhost: false)
    assert_match(/READ THE CODE/, prompt)
    assert_match(/ISS-574/, prompt)
    assert_match(/Route the inbound mail\./, prompt)
    assert_match(/Which subdomain\?/, prompt)
  end

  # ---------- the end-of-walk report ----------

  def test_the_report_counts_what_happened_and_what_was_left
    issues = %w[574 645 703 722].map { |n| blocked_issue(number: n) }
    out = issue_review_report(issues, { "574" => :answered, "645" => :skipped })
    assert_match(/1 answered, 1 skipped of 4 issue\(s\)/, out)
    assert_match(/2 left exactly as they were/, out)
    assert_match(/`dev issues claim` will offer them/, out)
  end

  def test_a_walk_that_answered_nothing_says_so_without_a_claim_hint
    out = issue_review_report([blocked_issue], {})
    assert_match(/Nothing recorded of 1 issue/, out)
    refute_match(/will offer them/, out)
  end

  def test_a_finished_walk_reports_no_leftovers
    out = issue_review_report([blocked_issue], { "574" => :answered })
    refute_match(/left exactly as/, out)
  end

  # ---------- arg handling ----------

  def test_an_unknown_flag_shows_the_invocation_line
    out, status = capture_stderr_and_exit { cmd_issues_review(["--bogus"]) }
    assert_equal 1, status
    assert_match(/unexpected argument\(s\): --bogus/, out)
    assert_match(/issues review \[--number/, out)
  end

  def test_number_without_a_value_is_a_usage_error
    out, status = capture_stderr_and_exit { cmd_issues_review(["--number"]) }
    assert_equal 1, status
    assert_match(/--number requires a value/, out)
  end

  def test_it_refuses_to_run_without_a_terminal
    # The whole output is a question, so a pipe has nobody to answer it. Blocking
    # on a read that never returns is the failure this replaces — and the message
    # names what a script actually wanted.
    refute $stdin.tty?, "the test process is the non-interactive case"
    out, status = capture_stderr_and_exit { cmd_issues_review([]) }
    assert_equal 1, status
    assert_match(/interactive/, out)
    assert_match(/dev issues list --status needs_input --status needs_review/, out)
  end

  def test_it_is_wired_into_the_issues_subcommands
    assert_includes SUBCOMMANDS["issues"], "review"
    refute_nil INVOCATIONS["issues review"]
    assert_match(/issues review/, USAGE)
  end
end
