#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `Agent::Playbook` — the pointer a producer's issue carries, and the resolution a
# claiming runner does against the platform (ISS-505, ISS-523, ISS-526).
#
# The tests that matter here are the two ends of the round trip (what the platform
# writes is what the runner reads back) and the failure modes, because the failure
# modes are the whole reason the pointer is designed this way: a pointer that does
# not resolve must be LOUD, never a quiet fall back to generic triage, and a key
# that comes out of a human-editable issue body must never be trusted to be a safe
# URL path segment.
#
# What is NOT here anymore, deliberately: every test about reading a file out of
# `agent/bodies/` and permalinking a git sha. That directory is deleted — the
# playbooks are append-only rows in the platform, so the version a run records is a
# `created_at` that is still readable after ten later edits, which a sha only gave
# us while the file was still in git.
class TestDevAgentPlaybook < Minitest::Test
  include DevTestSupport

  TOKEN = "tok-runner".freeze

  VERSION = "2026-08-05T14:04:20.055Z".freeze

  BODY = <<~MD.strip
    # Daily slow-query review

    Review the platform's database query costs for the last 24 hours, find queries
    worth fixing, prove the fix, and open a PR.

        dev queries top --limit 25
  MD

  CHILD_BODY = "# Dependency upgrades\n\nRun `dev dependencies upgrade --app {child}` and open a PR.".freeze

  def stub_playbooks(rows)
    responses = {}
    rows.each { |key, value| responses["GET /agent/playbooks/#{key}"] = value }
    with_stubbed_api(responses) { yield }
  end

  def resolve(body, rows)
    stub_playbooks(rows) do
      Agent::Playbook.resolve_in(body, token: TOKEN, use_localhost: false)
    end
  end

  def row(body: BODY, key: "slow-query-review")
    { "key" => key, "body" => body, "created_at" => VERSION }
  end

  # ---- the round trip ----
  #
  # The platform writes the line and the claiming runner reads it back. One format,
  # two repos: `ProducerIssueBody.withPlaybook` is the other half, and a change to
  # either side that the other does not follow is a session with no runbook.

  def test_a_written_pointer_reads_back_as_the_same_key
    line = Agent::Playbook.pointer_line("slow-query-review")
    pointer = Agent::Playbook.pointer_in("some evidence\n\n#{line}\n\nmore prose")
    assert_equal "slow-query-review", pointer.key
    assert_nil pointer.target
  end

  def test_a_child_pointer_carries_its_target_through_the_round_trip
    line = Agent::Playbook.pointer_line("dependency-upgrade-app", target: "platform")
    pointer = Agent::Playbook.pointer_in("evidence\n\n#{line}")
    assert_equal "dependency-upgrade-app", pointer.key
    assert_equal "platform", pointer.target
  end

  # The exact line the platform actually emits, copied from ProducerIssueBody. If
  # this starts failing, the two repos have drifted and every producer-filed issue
  # is arriving with a runbook nothing resolves.
  def test_the_line_the_platform_actually_writes_parses
    body = "Filed automatically by the `dependency-upgrade` producer.\n\n---\n\n" \
           "Playbook: `dependency-upgrade-app` (target: acumen)\n\n" \
           "The procedure itself is deliberately NOT copied here."
    pointer = Agent::Playbook.pointer_in(body)
    assert_equal "dependency-upgrade-app", pointer.key
    assert_equal "acumen", pointer.target
  end

  # One row serves every child of an epic and says `--app {child}` where the
  # command differs, so the substitution is what makes a shared playbook possible
  # at all. Without it the session is told to run a command with a literal
  # `{child}` in it.
  def test_the_target_substitutes_the_child_token_at_resolve_time
    body = "evidence\n\n#{Agent::Playbook.pointer_line('dependency-upgrade-app', target: 'acumen')}"
    resolved = resolve(body, { "dependency-upgrade-app" => row(body: CHILD_BODY, key: "dependency-upgrade-app") })

    assert_includes resolved.text, "--app acumen"
    refute_includes resolved.text, "{child}"
  end

  def test_a_targetless_playbook_is_handed_over_exactly_as_written
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    assert_equal BODY, resolve(body, { "slow-query-review" => row }).text
  end

  # ---- what must NOT be mistaken for a pointer ----
  #
  # An indented example, or prose about the mechanism, must not resolve — an issue
  # describing this very design would otherwise point at a playbook.
  def test_prose_that_merely_mentions_a_playbook_is_not_a_pointer
    [
      "    Playbook: `slow-query-review`",
      "See Playbook: `slow-query-review` for the procedure",
      "Playbook: slow-query-review",
      "The playbook is slow-query-review.",
    ].each do |line|
      assert_nil Agent::Playbook.pointer_in(line), "must not match: #{line}"
    end
  end

  # Every human-written issue carries its brief inline, so no pointer is the common
  # case and must cost nothing — not a lookup, not a warning.
  def test_an_issue_with_no_pointer_resolves_to_nothing_at_all
    assert_nil Agent::Playbook.resolve_in("A human wrote this issue by hand.", token: TOKEN, use_localhost: false)
    assert_nil Agent::Playbook.resolve_in(nil, token: TOKEN, use_localhost: false)
  end

  # ---- the hard failures ----

  # ISS-360: a producer ported without its playbook fell back to generic triage and
  # filed issues instead of shipping PRs for a week, with nothing saying so. A key
  # the platform has never heard of has to stop the claim.
  def test_a_key_the_platform_does_not_have_raises
    body = "evidence\n\n#{Agent::Playbook.pointer_line('no-such-playbook')}"
    error = assert_raises(Agent::Playbook::MissingError) do
      resolve(body, { "no-such-playbook" => nil })
    end
    assert_includes error.message, "no-such-playbook"
  end

  # A row that exists but says nothing is the same failure wearing a 200: the
  # session would get an empty brief and quietly do generic triage.
  def test_an_empty_body_raises_rather_than_handing_over_an_empty_brief
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    assert_raises(Agent::Playbook::MissingError) do
      resolve(body, { "slow-query-review" => row(body: "   \n") })
    end
  end

  # The key becomes a URL path segment and it is read out of a body a human can
  # edit, so it is rejected on shape BEFORE any request — reaching the network here
  # would itself fail the test (NetworkGuard), which is the assertion.
  def test_a_key_that_is_not_url_safe_raises_before_any_request
    ["../../etc/passwd", "agent/bodies/x.md", "Weekly Review", "-leading-dash", ""].each do |key|
      assert_raises(Agent::Playbook::MissingError, "must reject: #{key.inspect}") do
        Agent::Playbook.resolve(Agent::Playbook::Pointer.new(key: key), token: TOKEN, use_localhost: false)
      end
    end
  end

  # A platform the runner cannot reach is not a missing playbook, but it has the
  # same consequence for this claim — do not start a session that would do the
  # wrong job — so it comes back as the same error, saying which it was.
  def test_an_unreachable_platform_stops_the_claim_and_says_so
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    raiser = ->(_payload) { raise ApiError, "500 Internal Server Error" }
    error = assert_raises(Agent::Playbook::MissingError) do
      resolve(body, { "slow-query-review" => raiser })
    end
    assert_includes error.message, "could not be read from the platform"
  end

  # ---- what the run records ----

  # The audit trail ISS-505 turns on, and the reason copy-on-write was worth its
  # cost: the version named here is still there, and still readable, after any
  # number of later edits.
  def test_a_resolved_playbook_records_the_version_it_was_read_at
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    resolved = resolve(body, { "slow-query-review" => row })

    assert_equal VERSION, resolved.version
    assert_equal "slow-query-review @ #{VERSION}", resolved.label
  end
end
