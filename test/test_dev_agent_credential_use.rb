#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Agent::CredentialUse — one credential, into one child process, for one command
# (ISS-1037).
#
# WHAT THESE ASSERT, and none of it is "does `exec` exec".
#
#   1. THE VALUE LEFT THE SESSION. `Agent::Credentials.withheld` has to name
#      every credential with a nil, because `Process.spawn` reads nil as "remove
#      this from the child" and reads an ABSENT key as "leave whatever was
#      inherited". Those two are indistinguishable on a runner whose own shell
#      never exported the key, which is the runner this was written on — so the
#      difference is only ever caught by an assertion.
#
#   2. THE SILENT FAILURE THIS COMMAND'S SHAPE INVITES. A session that writes
#      the inner command in DOUBLE quotes has its own shell expand
#      `$NEWRELIC_USER_KEY` to the empty string before `dev` starts. The request
#      then goes out unauthenticated and NerdGraph answers an empty result set
#      rather than a 401 — ISS-635's failure mode, arriving by a new route, and
#      a run spent explaining a production graph that was never queried. The
#      expansion leaves no trace, so the only detector is the absence of the
#      NAME from argv, and it has to fire.
#
#   3. REFUSALS TEACH. A session told "no" with no shape retries by resolving
#      the value some other way and inlining it, which is exactly the ISS-961
#      hazard this exists to remove. Every refusal names the correct invocation.
#
#   4. THE AUDIT LINE CANNOT LEAK. It records a command line a SESSION composed,
#      so it goes through the same redaction `Agent::Processes` parses `ps`
#      with — otherwise a session that inlined some other secret would have this
#      helpfully write it to a file that outlives the run.
class TestDevAgentCredentialUse < Minitest::Test
  include DevTestSupport

  CU = Agent::CredentialUse
  C = Agent::Credentials

  NAME = "PLAYBOOK_CLAUDE_KEY".freeze
  SECRET = "sk-ant-not-a-real-key-0123456789".freeze

  # CredentialsGuard stubs `probe` to answer :present with "stub-<NAME>" for
  # everything, which is the right default for the suites that only need a
  # healthy machine. This file is about what `probe` ANSWERED, so it supplies its
  # own — see test_dev_agent_credentials.rb, where the same opt-out is explained
  # at length (ISS-613).
  def before_setup
    super
    DevTestSupport::CredentialsGuard.uninstall
  end

  def with_probe(status, value = nil, source = :env_repo)
    saved = C.method(:probe)
    C.define_singleton_method(:probe) { |_credential, **_opts| [status, value, status == :present ? source : nil] }
    yield
  ensure
    C.define_singleton_method(:probe, saved)
  end

  # ---- 1. the value left the session ----

  def test_withheld_names_every_credential_with_a_nil
    withheld = C.withheld
    assert_equal C::NAMES.sort, withheld.keys.sort,
                 "every credential must be NAMED, or the child inherits the runner's own export"
    withheld.each_value { |v| assert_nil v }
  end

  # The distinction the whole change rests on, stated as an assertion because it
  # is invisible on a machine that does not export the key: `spawn` removes a nil
  # and inherits an omission.
  def test_withheld_would_remove_a_credential_the_runner_itself_exports
    assert C.withheld.key?(NAME)
    assert_nil C.withheld[NAME],
               "an omitted key leaves the child inheriting the runner's environment — a silent no-op"
  end

  def test_find_resolves_by_the_name_a_session_was_told_and_nil_otherwise
    assert_equal NAME, C.find(NAME).name
    assert_nil C.find("PLAYBOOK_CLAUDE_KEY_2")
    assert_nil C.find(nil)
  end

  # ---- 2. the double-quote failure ----

  def test_a_command_that_never_mentions_the_credential_is_refused
    error = assert_raises(CU::Refusal) do
      # What the outer shell leaves behind when it expanded the reference: a
      # header with nothing after it. Indistinguishable from a typo, and it is
      # the ONLY trace, because the expansion happened before `dev` ran.
      CU.resolve!(NAME, ["/bin/zsh", "-c", 'curl -H "x-api-key: " https://api.anthropic.com/v1/messages'])
    end
    assert_match(/never mentions \$#{NAME}/, error.message)
    assert_match(/SINGLE quotes/, error.message)
    assert_includes error.message, "--implicit"
  end

  def test_a_single_quoted_reference_is_accepted
    with_probe(:present, SECRET) do
      credential, value = CU.resolve!(NAME, ["/bin/zsh", "-c", "curl -H \"x-api-key: $#{NAME}\" ..."])
      assert_equal NAME, credential.name
      assert_equal SECRET, value
    end
  end

  # A program that reads the variable itself has no reason to name it on a
  # command line, and refusing it would leave the session with no correct
  # invocation at all.
  def test_implicit_waives_the_reference_check
    with_probe(:present, SECRET) do
      _credential, value = CU.resolve!(NAME, ["./some-script.sh"], implicit: true)
      assert_equal SECRET, value
    end
    assert_raises(CU::Refusal) { CU.resolve!(NAME, ["./some-script.sh"]) }
  end

  # ---- 3. refusals teach ----

  def test_an_unknown_name_lists_the_ones_this_runner_knows
    error = assert_raises(CU::Refusal) { CU.resolve!("SOME_OTHER_KEY", ["/bin/echo", "SOME_OTHER_KEY"]) }
    C::NAMES.each { |name| assert_includes error.message, name }
  end

  def test_an_empty_command_is_refused
    assert_raises(CU::Refusal) { CU.resolve!(NAME, []) }
  end

  # The four absent states are four different actions (ISS-570), and a session
  # that cannot verify against the live API has a defined outcome rather than a
  # guess: do the offline work, say so, file a workaround.
  def test_an_unresolvable_credential_says_why_and_what_to_do
    { missing: /not set in/, locked: /git-crypt LOCKED/, no_file: /does not exist/ }.each do |status, pattern|
      with_probe(status) do
        error = assert_raises(CU::Refusal) { CU.resolve!(NAME, ["/bin/zsh", "-c", "echo $#{NAME}"]) }
        assert_match(pattern, error.message)
        assert_includes error.message, "dev issues workaround"
      end
    end
  end

  # ---- 4. the audit line ----

  def test_a_use_is_recorded_under_the_issue_and_redacted
    with_log_root do
      line = CU.record(issue: "1037", name: NAME, argv: ["/bin/zsh", "-c", "curl -H \"x-api-key: #{SECRET}\" x"])
      refute_includes line, SECRET, "the audit trail must not become the leak"
      assert_includes line, "[redacted]"
      assert_includes line, NAME, "which credential was used is the point of the record"
      assert_equal [line], File.readlines(Agent::Paths.credential_log(1037)).map(&:chomp)
    end
  end

  # Outside an agent session there is no log tree and no issue to file against —
  # `dev agent credential exec` is then just a convenience on a laptop. The
  # record is an audit trail for autonomous runs, never a precondition for using
  # a key.
  def test_nothing_is_recorded_without_an_issue
    with_log_root do
      assert_nil CU.record(issue: nil, name: NAME, argv: ["/bin/echo"])
      assert_nil CU.record(issue: "not-a-number", name: NAME, argv: ["/bin/echo"])
      assert_empty Dir.glob(File.join(Agent::Paths.issues_dir, "**", "credentials.log"))
    end
  end

  # ---- the end-to-end shape, without a live API ----

  # `exec` replaces this process, so it is exercised in a child: the assertion is
  # that the credential arrives in the child's ENVIRONMENT and in nothing else.
  def test_exec_puts_the_credential_in_the_child_environment
    with_log_root do
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
        require 'agent/credential_use'
        Agent::Credentials.define_singleton_method(:probe) { |_c, **_o| [:present, #{SECRET.inspect}, :env_repo] }
        Agent::CredentialUse.exec(name: #{NAME.inspect}, argv: ["/bin/sh", "-c", 'printf %s "$#{NAME}"'], issue: nil)
      RUBY
      out = IO.popen([{ NAME => nil }, RbConfig.ruby, "-e", script], &:read)
      assert_equal SECRET, out
    end
  end

  def with_log_root
    Dir.mktmpdir do |root|
      original = ENV["DEV_AGENT_LOG_ROOT"]
      ENV["DEV_AGENT_LOG_ROOT"] = File.join(root, "logs")
      begin
        yield root
      ensure
        ENV["DEV_AGENT_LOG_ROOT"] = original
      end
    end
  end
end
