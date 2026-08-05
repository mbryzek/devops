#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::Credentials — the external-API keys a claimed session is handed, and
# the absence of one told to the session before it plans (ISS-570).
#
# The assertions here are about two failures, and neither is "does the lookup
# work".
#
#   1. A SILENCE. The ISS-565 session wrote a Claude-API schema probe, could not
#      send one request, and found that out only after the code existed — so it
#      designed the request shape against the documentation and shipped it
#      unverified. The credential was on the machine the entire time; nothing
#      passed it down and nothing said it was missing. Both halves are tested:
#      `resolve` actually injects it, and the prompt states its state either way.
#
#   2. A LEAK, of two distinct kinds. A live API key must not reach anything
#      that gets printed (prompt.md lands in the log tree and gets quoted into
#      issue comments), and it must never be exported as ANTHROPIC_API_KEY —
#      the process this environment is handed to IS `claude`, which resolves
#      that variable as its own credential, so the leak there is not disclosure
#      but silently moving the whole fleet onto per-token API billing.
class TestDevAgentCredentials < Minitest::Test
  include DevTestSupport

  C = Agent::Credentials

  # This file is ABOUT `probe`, so it opts out of the healthy-machine stand-in
  # every other suite gets — safely, because every test below supplies its own
  # probe or its own lookup.
  def before_setup
    super
    DevTestSupport::CredentialsGuard.uninstall
  end

  SECRET = "sk-ant-not-a-real-key-0123456789".freeze

  def credential(name: "PLAYBOOK_CLAUDE_KEY", app: "platform", environment: "development")
    C::Credential.new(name: name, app: app, environment: environment,
                      required_by: "#{name} things", how_to_provide: "set #{name} somewhere")
  end

  # Stub the ONE read both public faces go through, so they cannot disagree.
  def with_probe(status, value = nil, source = nil)
    original = C.method(:probe)
    C.define_singleton_method(:probe) { |_credential, **_opts| [status, value, source] }
    yield
  ensure
    C.define_singleton_method(:probe, original)
  end

  # ---- the ANTHROPIC_API_KEY hazard ----

  # The regression guard for the one mistake that would be invisible in every
  # output: `claude` reads ANTHROPIC_API_KEY, so a credential exported under
  # that name reconfigures the session's own billing rather than giving it a key
  # to test with. Asserted over the real list, so a future entry cannot
  # reintroduce it.
  def test_no_credential_is_named_anthropic_api_key
    C::CREDENTIALS.each do |c|
      refute_equal "ANTHROPIC_API_KEY", c.name,
                   "exporting ANTHROPIC_API_KEY into a session's environment reconfigures the `claude` " \
                   "CLI that IS the session — use a distinct name and pass it explicitly"
    end
  end

  def test_resolve_never_produces_an_anthropic_api_key_variable
    with_probe(:present, SECRET, :env_repo) do
      refute_includes C.resolve.keys, "ANTHROPIC_API_KEY"
    end
  end

  # ---- injection ----

  def test_resolve_hands_an_env_repo_credential_to_the_session
    with_probe(:present, SECRET, :env_repo) do
      assert_equal({ "PLAYBOOK_CLAUDE_KEY" => SECRET }, C.resolve(credentials: [credential]))
    end
  end

  # Process.spawn merges this hash over an inherited ENV, so a credential the
  # runner's own environment already carries reaches the child either way.
  # Re-listing it would pull a secret through more code for no effect.
  def test_resolve_omits_credentials_the_child_already_inherits
    with_probe(:present, SECRET, :process_env) do
      assert_empty C.resolve(credentials: [credential])
    end
  end

  def test_resolve_omits_credentials_that_do_not_resolve
    %i[missing locked no_file].each do |status|
      with_probe(status) { assert_empty C.resolve(credentials: [credential]) }
    end
  end

  # ---- probe precedence ----

  def test_the_process_environment_wins_over_the_env_repo
    stub_lookup(:present, "from-the-repo") do
      status, value, source = C.probe(credential, env: { "PLAYBOOK_CLAUDE_KEY" => "from-the-shell" })
      assert_equal [:present, "from-the-shell", :process_env], [status, value, source]
    end
  end

  def test_an_empty_process_variable_falls_through_to_the_env_repo
    stub_lookup(:present, "from-the-repo") do
      status, value, source = C.probe(credential, env: { "PLAYBOOK_CLAUDE_KEY" => "" })
      assert_equal [:present, "from-the-repo", :env_repo], [status, value, source]
    end
  end

  # ---- the three absent states stay three ----
  #
  # They call for opposite responses: add the variable / this machine cannot
  # read the secrets repo / you are not looking at an env repo at all. Collapsing
  # them reports a wrong diagnosis with total confidence.
  def test_each_absent_state_explains_itself_differently
    explanations = %i[missing locked no_file].map do |status|
      with_probe(status) { C.check(credentials: [credential]).first.explanation }
    end
    assert_equal explanations.uniq.length, explanations.length
    assert_match(/not set/, explanations[0])
    assert_match(/LOCKED/, explanations[1])
    assert_match(/no env repo/, explanations[2])
  end

  def test_a_locked_env_repo_reads_as_absent_rather_than_raising
    stub_lookup(:locked) do
      found = C.check(credentials: [credential]).first
      assert found.absent?
      refute found.present?
    end
  end

  # ---- the leak ----

  # `check` is the face that gets printed — by the doctor, and into prompt.md,
  # which is written to the log tree. It must be unable to carry a value at all,
  # including through the `inspect` a Struct gives an exception or a log line.
  def test_check_results_cannot_carry_the_secret
    with_probe(:present, SECRET, :env_repo) do
      found = C.check(credentials: [credential])
      refute_includes found.inspect, SECRET
      refute_includes found.first.explanation, SECRET
      refute_includes found.map(&:to_s).join, SECRET
    end
  end

  # ---- what the session is told ----

  def test_the_prompt_states_an_available_credential_and_how_to_use_it
    section = Agent::Prompt.credentials_section(
      with_probe(:present, SECRET, :env_repo) { C.check(credentials: [credential]) },
    )
    assert_match(/PLAYBOOK_CLAUDE_KEY.*available in your environment/, section)
    assert_match(/x-api-key/, section)
    assert_match(/ANTHROPIC_API_KEY/, section, "the session must be told which variable NOT to set")
    refute_includes section, SECRET
  end

  # The whole point of the issue: a session must learn the gap while planning,
  # not discover it after writing code it cannot test — and must be told the
  # specific thing to do about it rather than quietly designing against the docs.
  def test_the_prompt_states_an_absent_credential_and_what_to_do_instead
    section = Agent::Prompt.credentials_section(
      with_probe(:missing) { C.check(credentials: [credential]) },
    )
    assert_match(/NOT available on this runner/, section)
    assert_match(/cannot be closed out here/, section)
    assert_match(/dev issues workaround/, section)
    assert_match(/unverified/, section)
  end

  # The prompt is assembled from the assignment block, so a section that renders
  # correctly but is never included would pass every test above and ship nothing.
  def test_the_assignment_block_carries_the_section
    assignment = Agent::Prompt.assignment(
      issue: { "number" => 570, "title" => "t", "category" => "bug" },
      slug: "i570_bmn", workspace: "/tmp/ws",
      credentials: with_probe(:present, SECRET, :env_repo) { C.check(credentials: [credential]) },
    )
    assert_match(/Live external-API credentials on this runner/, assignment)
    refute_includes assignment, SECRET
  end

  # ---- the doctor ----

  # Reported, never blocking: a runner without an Anthropic key can still claim
  # the overwhelming majority of the queue, and failing provisioning over a
  # narrow capability would turn a report into an outage.
  def test_the_doctor_reports_an_absent_credential_without_failing
    out = with_probe(:missing) { capture_stdout { agent_doctor_credentials } }
    assert_match(/ABSENT PLAYBOOK_CLAUDE_KEY/, out)
    assert_match(/Nothing else is blocked/, out)
  end

  def test_the_doctor_never_prints_the_value
    out = with_probe(:present, SECRET, :env_repo) { capture_stdout { agent_doctor_credentials } }
    assert_match(/ok\s+PLAYBOOK_CLAUDE_KEY/, out)
    refute_includes out, SECRET
  end

  private

  def stub_lookup(status, value = nil)
    original = EnvironmentVariables.method(:lookup)
    EnvironmentVariables.define_singleton_method(:lookup) { |_app, _env, _key| [status, value] }
    yield
  ensure
    EnvironmentVariables.define_singleton_method(:lookup, original)
  end

  def capture_stdout
    buf = StringIO.new
    old = $stdout
    $stdout = buf
    yield
    buf.string
  ensure
    $stdout = old
  end
end
