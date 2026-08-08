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
#      passed it down and nothing said it was missing. The half that lives here
#      is the TELLING: the prompt states a credential's state either way, before
#      the session plans. Since ISS-1037 the other half — actually getting the
#      value to a process — is `dev agent credential exec`, and it is tested in
#      test_dev_agent_credential_use.rb. Being told this machine holds a key and
#      holding it are deliberately no longer the same thing.
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

  # Opting out of CredentialsGuard (above) buys back the REAL `probe`, and with
  # it the real `probe`'s dependence on the ambient process environment. Every
  # assertion below that exercises the env repo must therefore say which process
  # environment it is asking about, because a runner that exports
  # PLAYBOOK_CLAUDE_KEY short-circuits `probe` before `stub_lookup` is consulted
  # and the test quietly measures the machine instead. Every agent runner does
  # export it — ISS-570 is what put it there — so this failed on the fleet and
  # passed on the laptop it was written on (ISS-613).
  #
  # Named rather than `{}` so a call site reads as an assertion about an empty
  # environment instead of an argument someone might tidy away.
  NO_PROCESS_ENV = {}.freeze

  def credential(name: "PLAYBOOK_CLAUDE_KEY", source: C::AppEnv.new(app: "platform", environment: "development"))
    C::Credential.new(name: name, source: source,
                      required_by: "#{name} things", how_to_provide: "set #{name} somewhere",
                      usage_example: "curl -H \"x-api-key: $#{name}\" ...")
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

  def test_the_session_environment_never_produces_an_anthropic_api_key_variable
    refute_includes C.withheld.keys, "ANTHROPIC_API_KEY"
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
    assert_match(/does not exist/, explanations[2])
  end

  # `env: {}` is load-bearing and its absence is why this test failed on every
  # runner and passed on every laptop: the process environment wins over the env
  # repo, and a runner's own sessions are handed PLAYBOOK_CLAUDE_KEY (ISS-570) —
  # so the credential resolved :present from the inherited environment and the
  # locked branch under test was never reached.
  def test_a_locked_env_repo_reads_as_absent_rather_than_raising
    stub_lookup(:locked) do
      found = C.check(credentials: [credential], env: NO_PROCESS_ENV).first
      assert found.absent?
      refute found.present?
    end
  end

  # `check` reads the same two sources `probe` does, so the process environment
  # has to be controllable through it too — otherwise the only way to test its
  # env-repo behaviour is to hope the machine is not carrying the key. Pins the
  # keyword rather than trusting the call sites above to keep passing it.
  def test_check_reads_the_process_environment_it_is_given
    stub_lookup(:locked) do
      assert C.check(credentials: [credential], env: NO_PROCESS_ENV).first.absent?
      assert C.check(credentials: [credential], env: { "PLAYBOOK_CLAUDE_KEY" => SECRET }).first.present?
    end
  end

  # The same keyword on the value-carrying face, which since ISS-1037 is `probe`
  # itself. This is the ISS-613 lesson and it outlived the function it was
  # written against: a test that stubs `EnvironmentVariables.lookup` and leaves
  # `env` defaulted is not pinning anything, because the process environment
  # short-circuits before the stub is consulted — and every agent runner exports
  # one of these, so it passes on a laptop and measures the machine on the fleet.
  def test_probe_reads_the_process_environment_it_is_given
    stub_lookup(:present, SECRET) do
      assert_equal [:present, SECRET, :env_repo], C.probe(credential, env: NO_PROCESS_ENV)
      assert_equal [:present, "from-the-shell", :process_env],
                   C.probe(credential, env: { "PLAYBOOK_CLAUDE_KEY" => "from-the-shell" })
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
    # ISS-1037 split "this machine has the key" from "you are holding it". The
    # first half is ISS-570's promise and is unchanged — a session must know
    # while it is still planning that work against this API can be closed out
    # here. The second is now false on purpose, and the section has to say so, or
    # a session reaches for a variable that is empty and reads the empty result
    # as a finding.
    assert_match(/PLAYBOOK_CLAUDE_KEY.*available on this runner/, section)
    assert_match(/NOT in your environment/, section)
    assert_includes section, "dev agent credential exec --name PLAYBOOK_CLAUDE_KEY"
    assert_match(/x-api-key/, section)
    assert_match(/ANTHROPIC_API_KEY/, section, "the session must be told which variable NOT to set")
    refute_includes section, SECRET
  end

  # ISS-961. "Never print, echo, commit or paste it" was the whole warning, and a
  # session that obeyed all four still leaked both fleet credentials: inlining a
  # value into a shell command is none of those verbs, and a sibling session's
  # `pgrep -fl` printed it. The correct form has to be stated where the usage
  # example is, because that is the line that puts a command on the screen.
  def test_the_prompt_says_a_credential_must_never_be_inlined_into_a_command
    section = Agent::Prompt.credentials_section(
      with_probe(:present, SECRET, :env_repo) { C.check(credentials: [credential]) },
    )
    assert_match(/never write the value into a command line/i, section)
    # ISS-1037 changed the safe form from "pass `$NAME`" to a command that puts
    # the value in one process, so the assertion follows it there. What must not
    # change is that the correct form NAMES the variable it applies to, on the
    # same screen as the example.
    assert_includes section, "$PLAYBOOK_CLAUDE_KEY",
                    "the safe form must name the variable it applies to"
    assert_match(/SINGLE quotes/, section,
                 "the quoting is the difference between a live request and a silent unauthenticated one")
    assert_match(/ps.*shows every\s+argument|argument of every process to every sibling/m, section,
                 "the session must be told WHY, or it reads as one more prohibition to weigh")
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

  # ---- the two env-repo layouts (ISS-635) ----
  #
  # `apps/<app>/env/*.env` is what an APP boots with; `api_keys/<file>` is what a
  # HUMAN or a tool authenticates with. The NewRelic key was filed under the
  # first for years: no application anywhere read it, so nothing broke visibly
  # when it went stale, and every session that followed the playbook's
  # source-it-from-the-app-env instruction got a 401 and an empty NRQL result —
  # which reads exactly like a healthy production graph.
  def test_a_key_file_credential_reads_the_whole_file_as_its_value
    with_env_repo("api_keys/newrelic" => "NRAK-fake\n") do
      status, value, source = C.probe(credential(name: "NEWRELIC_USER_KEY", source: C::KeyFile.new(file: "newrelic")), env: {})
      assert_equal [:present, "NRAK-fake", :env_repo], [status, value, source]
    end
  end

  def test_a_key_file_that_is_absent_is_no_file_rather_than_missing
    with_env_repo({}) do
      status, = C.probe(credential(name: "NEWRELIC_USER_KEY", source: C::KeyFile.new(file: "newrelic")), env: {})
      assert_equal :no_file, status
    end
  end

  # An empty file is a different mistake from an absent one — somebody wrote the
  # file and put nothing in it — and the doctor tells you to do different things.
  def test_an_empty_key_file_is_missing_rather_than_present
    with_env_repo("api_keys/newrelic" => "\n") do
      status, value = C.probe(credential(name: "NEWRELIC_USER_KEY", source: C::KeyFile.new(file: "newrelic")), env: {})
      assert_equal [:missing, nil], [status, value]
    end
  end

  # The env repo encrypts everything by default, so api_keys/ is git-crypt'd too.
  # A session may not unlock it, so a locked file must report as locked and never
  # be mistaken for a key that was never issued.
  def test_a_locked_key_file_reports_locked_and_never_unlocks
    with_env_repo("api_keys/newrelic" => "\x00GITCRYPT\x00binary-goo") do
      status, value = C.probe(credential(name: "NEWRELIC_USER_KEY", source: C::KeyFile.new(file: "newrelic")), env: {})
      assert_equal [:locked, nil], [status, value]
    end
  end

  # The registry itself, not a stand-in: the NewRelic key must be sourced from
  # api_keys/, because pointing it back at an app env file is the ISS-635 bug.
  def test_the_newrelic_credential_is_sourced_from_the_api_keys_directory
    found = C::CREDENTIALS.find { |c| c.name == "NEWRELIC_USER_KEY" }
    refute_nil found, "the NewRelic key must be handed to sessions, not sourced from a playbook instruction"
    assert_equal "env/api_keys/newrelic", found.source_label
  end

  # One API's header is another API's 401, so the "pass it explicitly" line the
  # assignment block prints has to come from the credential rather than from a
  # single hardcoded Anthropic example.
  def test_each_credential_states_how_to_pass_it_and_never_a_value
    C::CREDENTIALS.each do |c|
      refute_empty c.usage_example.to_s, "#{c.name} tells a session nothing about how to send it"
      assert_includes c.usage_example, "$#{c.name}",
                      "#{c.name}'s example must carry the variable, never a value"
    end
  end

  def test_the_prompt_uses_each_credentials_own_usage_example
    nr = credential(name: "NEWRELIC_USER_KEY", source: C::KeyFile.new(file: "newrelic"))
    section = Agent::Prompt.credentials_section(
      with_probe(:present, SECRET, :env_repo) { C.check(credentials: [nr]) },
    )
    assert_match(/NEWRELIC_USER_KEY.*available on this runner/, section)
    assert_includes section, "x-api-key: $NEWRELIC_USER_KEY"
    refute_includes section, "anthropic-version",
                    "a NewRelic key must not be documented with Anthropic's headers"
  end

  private

  def stub_lookup(status, value = nil)
    original = EnvironmentVariables.method(:lookup)
    EnvironmentVariables.define_singleton_method(:lookup) { |_app, _env, _key| [status, value] }
    yield
  ensure
    EnvironmentVariables.define_singleton_method(:lookup, original)
  end

  # A throwaway env repo, laid out exactly as the real one is relative to a
  # devops checkout, so the path arithmetic is exercised rather than stubbed.
  def with_env_repo(files)
    Dir.mktmpdir do |root|
      original = EnvRepo.method(:path)
      EnvRepo.define_singleton_method(:path) { |relative| File.join(root, "env", relative) }
      files.each do |relative, contents|
        path = File.join(root, "env", relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, contents)
      end
      begin
        yield
      ensure
        EnvRepo.define_singleton_method(:path, original)
      end
    end
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
