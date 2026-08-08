#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::ProdRead and `dev prod get` — the production reads a session can make,
# and the sentence that tells it so (ISS-1062).
#
# The failure these are about is not an outage. ISS-1056 arrived with its
# evidence already gathered from acumen's own API — seven `duplicate_transactions`
# row ordinals that return 500 and the one between them that does not, checked a
# row at a time with `limit=1`. The session that fixed it had that exact access:
# `~/.platform/devops_acumen` is a live session and ApiClient has known how to
# present it since acumen shipped. Told nothing about it, and reading §3's "never
# touch the production database", it concluded production was unreachable,
# reconstructed the cause from git history, and shipped a migration naming four
# stale enum values it had never observed plus a delete of rows it had never
# counted.
#
# So the assertions below are about a SILENCE and a BOUNDARY:
#
#   1. The silence — that the capability is stated in the assignment block, in
#      both its present and absent forms, and that a section which renders
#      correctly but never gets included would fail here rather than ship.
#   2. The boundary — that this reads and cannot write. `prod` has exactly one
#      subcommand, and the §3 database prohibition is restated inside the very
#      section that grants the read, so the next session cannot take either half
#      for the other.
class TestAgentProdRead < Minitest::Test
  include DevTestSupport

  P = Agent::ProdRead

  SESSION_ID = "ASnot-a-real-acumen-session-0123456789".freeze

  def target(app) = P::TARGETS.find { |t| t.app == app }

  def check(present:)
    P.check(targets: [target("acumen")], probe: ->(_path) { present })
  end

  # ---- what a session actually presents ----

  # A session does not authenticate the way a human does, and the probe has to
  # follow the identity that will really go out (ApiClient.auth_header_for):
  # acumen's own stored session for acumen, the AI actor's token for everything
  # on the platform host.
  #
  # Asking ApiClient.credential_for? instead would branch on CLAUDECODE — set in
  # the session, unset in the dispatcher that builds the prompt — so the answer
  # would describe whichever process happened to ask (ISS-613).
  def test_the_probed_file_is_the_one_a_session_will_present
    assert_equal File.expand_path("~/.platform/devops_acumen"), target("acumen").credential_file
    assert_equal File.expand_path("~/.platform/devops_ai"), target("platform").credential_file
  end

  # ---- presence, without ambient state and without the value ----

  def test_check_answers_from_the_injected_probe_only
    assert_predicate check(present: true).first, :present?
    refute_predicate check(present: false).first, :present?
  end

  # `probe` is injectable for the reason Credentials' `env` is: every runner has
  # these files, so a defaulted probe asserts :present on the fleet and nowhere
  # else, and the test becomes a statement about the box it ran on (ISS-613).
  def test_check_never_touches_the_filesystem_when_a_probe_is_given
    seen = []
    P.check(targets: P::TARGETS, probe: ->(path) { seen << path; true })
    assert_equal P::TARGETS.map(&:credential_file), seen
  end

  # An empty credential file is absent, because ApiClient.session_id_for and
  # ai_token both return nil for one — reporting it present would promise a
  # credential the request path then refuses.
  def test_an_empty_credential_file_is_absent
    Dir.mktmpdir do |dir|
      empty = File.join(dir, "empty")
      File.write(empty, "  \n")
      filled = File.join(dir, "filled")
      File.write(filled, SESSION_ID)

      refute P::DEFAULT_PROBE.call(empty)
      refute P::DEFAULT_PROBE.call(File.join(dir, "absent"))
      assert P::DEFAULT_PROBE.call(filled)
    end
  end

  # `check` carries a STATUS and never contents. The section it feeds is rendered
  # into prompt.md, which lands in the log tree and gets quoted into issue
  # comments.
  def test_check_never_carries_the_credential
    found = P.check(targets: [target("acumen")], probe: ->(_p) { true })
    refute_includes found.inspect, SESSION_ID
    refute_includes Agent::Prompt.prod_read_section(found), SESSION_ID
  end

  # ---- the silence: what the session is told ----

  def test_the_present_form_names_the_command_and_the_guardrails
    section = Agent::Prompt.prod_read_section(check(present: true))

    assert_match(/readable/, section)
    assert_match(/dev prod get --app acumen/, section)
    # A stored session expires, unlike an API key, and check deliberately spends
    # no network round-trip finding out — so the confirming call has to be named
    # where the session decides whether to rely on it.
    assert_match(%r{dev prod get --app acumen /sessions/current}, section)
    assert_match(/never quote a real merchant name/i, section)
    assert_match(/Bryzek Family/, section)
  end

  # The confirming call is the cheapest GET each identity is entitled to, and one
  # API's is another's 404: acumen answers `/sessions/current` because the
  # credential IS a session, and the platform host returns 404 for that route —
  # which a session would read as a broken credential, the confident wrong
  # diagnosis this module exists to stop. Verified against both hosts by hand.
  def test_each_target_confirms_on_a_route_that_identity_can_actually_reach
    assert_equal "/sessions/current", target("acumen").confirm_path
    refute_equal "/sessions/current", target("platform").confirm_path
    P::TARGETS.each { |t| refute_nil t.confirm_path, "#{t.app} declares no confirm_path" }

    platform = Agent::Prompt.prod_read_section(P.check(targets: [target("platform")], probe: ->(_p) { true }))
    assert_match(%r{dev prod get --app platform #{Regexp.escape(target('platform').confirm_path)}}, platform)
    refute_match(%r{--app platform /sessions/current}, platform)
  end

  # The ISS-1056 shape exactly: no access, and the run still has to be honest
  # about which half of its conclusion was observed.
  def test_the_absent_form_demands_the_inference_be_disclosed
    section = Agent::Prompt.prod_read_section(check(present: false))

    assert_match(/NOT readable on this runner/, section)
    assert_match(/cannot be confirmed here/, section)
    assert_match(/INFERRED rather than observed/, section)
    assert_match(/dev issues workaround/, section)
  end

  # The boundary, stated inside the grant. Without it the section reads as
  # either a §3 relaxation (it is not — the database prohibition is untouched) or
  # as nothing at all, which is the state that produced ISS-1062.
  def test_the_section_restates_the_database_prohibition
    section = Agent::Prompt.prod_read_section(check(present: true))
    assert_match(/not a relaxation of §3/i, section)
    assert_match(/production DATABASE/, section)
  end

  # A section that renders correctly but is never included would pass every test
  # above and ship nothing.
  def test_the_assignment_block_carries_the_section
    assignment = Agent::Prompt.assignment(
      issue: { "number" => 1062, "title" => "t", "category" => "bug" },
      slug: "i1062", workspace: "/tmp/ws",
      credentials: [],
      prod_read: check(present: true),
    )
    assert_match(/Production data you can READ on this runner/, assignment)
    refute_includes assignment, SESSION_ID
  end

  # ---- the boundary: one household, enforced ----

  # Every other acumen guardrail governs what may be QUOTED, which no code can
  # check. This one governs what is REQUESTED, and a typo is enough to break it:
  # Mike's session carries `multi_groups`, so a different `/g/<key>/` in a path a
  # session is otherwise typing offsets into reaches somebody else's household.
  def test_another_households_group_is_refused_before_the_request
    err, status = capture_stderr_and_exit do
      cmd_prod_get(["--app", "acumen", "/g/cameron/duplicate/transactions?limit=1"])
    end
    assert_equal 1, status
    assert_match(/refused/, err)
    assert_match(/other people's households/, err)
    # Refused BEFORE the request: NetworkGuard raises on any live call, and
    # with_stubbed_api is deliberately not in play here.
    refute_match(/attempted a live API request/, err)
  end

  def test_the_permitted_group_and_a_groupless_path_are_allowed
    t = target("acumen")
    assert_nil t.refusal_for("/g/bryzek/duplicate/transactions?limit=1&offset=675")
    assert_nil t.refusal_for("/sessions/current")
    refute_nil t.refusal_for("/g/julien/transactions")
    # A prefix collision is not a match: `bryzek-old` is a different group.
    refute_nil t.refusal_for("/g/bryzek-old/transactions")
  end

  # nil where the concept does not apply, rather than a copied literal: the
  # platform host has no per-tenant path prefix and enforces the AI actor's
  # authorization server-side.
  def test_the_platform_target_declares_no_group_scope
    assert_nil target("platform").allowed_group
    assert_nil target("platform").refusal_for("/g/anything/x")
  end

  # ---- the boundary: this reads, and cannot write ----

  # The singleton is the design, not an accident: a `prod` command that could
  # also write would be a write path to production wearing a read command's name.
  # Adding one has to be a decision, so it fails here first.
  def test_prod_has_exactly_one_subcommand_and_it_is_get
    assert_equal %w[get], SUBCOMMANDS["prod"]
    assert_includes COMMANDS, "prod"
    assert INVOCATIONS.key?("prod get")
  end

  # There is no --localhost either: a command named `prod` that could be pointed
  # at localhost invites the prod/local session mix-up ApiClient.session_file
  # exists to prevent.
  def test_the_invocation_offers_no_write_and_no_localhost
    usage = INVOCATIONS.fetch("prod get")
    refute_match(/localhost/, usage)
    refute_match(/--method|post|put|delete/i, usage)
  end

  # ---- the command ----

  def test_it_sends_a_get_and_prints_the_body_as_json_on_stdout
    out = nil
    capture_stderr_and_exit do
      out = with_stubbed_api("GET /sessions/current" => { "group" => { "key" => "bryzek" } }) do
        capture_stdout { cmd_prod_get(%w[--app acumen /sessions/current]) }
      end
    end
    assert_equal({ "group" => { "key" => "bryzek" } }, JSON.parse(out))
  end

  # stdout stays a clean JSON document so `| jq` works; everything a human or a
  # session needs to READ goes to stderr.
  def test_the_guardrails_reach_stderr_not_stdout
    err, = capture_stderr_and_exit do
      with_stubbed_api("GET /sessions/current" => {}) do
        capture_stdout { cmd_prod_get(%w[--app acumen /sessions/current]) }
      end
    end
    assert_match(/never quote a real merchant name/i, err)
    assert_match(/Bryzek Family/, err)
  end

  def test_it_rejects_an_unknown_app_and_a_pathless_call
    err, status = capture_stderr_and_exit { cmd_prod_get(%w[--app acumen]) }
    assert_equal 1, status
    assert_match(/requires a path/, err)

    err, status = capture_stderr_and_exit { cmd_prod_get(%w[--app nope /x]) }
    assert_equal 1, status
    assert_match(/Unknown --app/, err)
  end

  # An unquoted path holding `&` reaches the command as its first segment and the
  # rest becomes separate shell commands, so a second positional is nearly always
  # a swallowed query string rather than a typo — and saying so is the difference
  # between one confused minute and ten.
  def test_a_second_positional_blames_the_quoting
    err, status = capture_stderr_and_exit { cmd_prod_get(%w[--app acumen /a /b]) }
    assert_equal 1, status
    assert_match(/quote it/, err)
  end

  # A non-2xx is the answer as often as it is a failure: "this row 500s" IS the
  # observation a product-owner issue asks to have confirmed. The body has to
  # survive to stderr, and the status has to be non-zero so a shell loop over
  # offsets reports each row honestly.
  def test_a_500_is_reported_as_an_observation_with_its_body
    responses = { "GET /g/bryzek/x" => ->(_body) { raise ApiError.new('HTTP 500 GET /g/bryzek/x: {"code":500}', code: 500) } }
    err, status = capture_stderr_and_exit do
      with_stubbed_api(responses) { cmd_prod_get(%w[--app acumen /g/bryzek/x]) }
    end
    assert_equal 1, status
    assert_match(/HTTP 500/, err)
    assert_match(/"code":500/, err)
  end

  # An expired stored session is a human-only fix — `dev auth login --app acumen`
  # is an interactive password prompt — so it gets the ISS-945 treatment: name the
  # boundary and hand back the line that parks it, rather than leaving a session
  # with a 401 and no next step.
  def test_an_expired_session_hands_the_refresh_over_to_a_human
    responses = { "GET /sessions/current" => ->(_body) { raise SessionExpired, "HTTP 401 for acumen" } }
    err, status = with_env("DEV_AGENT_ISSUE" => "1062") do
      stub_singleton(ApiClient, :ai_session?, -> { true }) do
        capture_stderr_and_exit do
          with_stubbed_api(responses) { cmd_prod_get(%w[--app acumen /sessions/current]) }
        end
      end
    end

    assert_equal 1, status
    assert_match(/dev issues handoff --from 1062/, err)
    assert_match(/--key prod-read-session-expired-acumen/, err)
    assert_match(/dev auth login --app acumen/, err)
    # `--rerun` is required by `dev issues handoff` and nothing verifies it, so a
    # handoff this command composes has to carry one that is actually true.
    assert_match(/--rerun /, err)
  end

  # A human at a keyboard CAN run the login, so telling them to file a handoff
  # would be nonsense.
  def test_a_human_is_told_to_log_in_rather_than_hand_it_over
    responses = { "GET /sessions/current" => ->(_body) { raise SessionExpired, "HTTP 401 for acumen" } }
    err, status = stub_singleton(ApiClient, :ai_session?, -> { false }) do
      capture_stderr_and_exit do
        with_stubbed_api(responses) { cmd_prod_get(%w[--app acumen /sessions/current]) }
      end
    end

    assert_equal 1, status
    assert_match(/dev auth login --app acumen/, err)
    refute_match(/dev issues handoff/, err)
  end

  private

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
