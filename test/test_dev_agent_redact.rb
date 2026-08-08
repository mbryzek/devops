#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/redact'
require 'agent/processes'

# Agent::Redact — the credentials a process listing must not hand over (ISS-961).
#
# Every fixture that looks like a command line here is the SHAPE a runner
# actually carries: the tool-shell wrapper the Claude CLI spawns each Bash call
# under, the curl invocations `Agent::Credentials` teaches every session, and the
# `CONF_DB_DEV_URL` a Scala run exports next to sbt. The secret values are
# obviously fake and constructed to be — a real one in a test fixture would be
# the exact leak this module exists to stop.
#
# Two halves, and the second matters as much as the first. Redacting is easy;
# redacting WITHOUT changing the shape is the requirement, because
# `Agent::Processes` classifies a process by matching TOOL_SHELL and
# CLAUDE_SESSION against the string this returns. A redactor that broke those
# would silently stop the leak sweep, and a runner buried under leaked processes
# would report exactly what a clean one does.
class TestDevAgentRedact < Minitest::Test
  R = Agent::Redact
  P = Agent::Processes

  SNAPSHOT = "/Users/athena/.claude/shell-snapshots/snapshot-zsh-1786156545066-x1ork6.sh".freeze

  ANTHROPIC = "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH".freeze
  NEWRELIC = "NRAK-AAAABBBBCCCCDDDDEEEE".freeze

  def tool_shell(inner) = "/bin/zsh -c source #{SNAPSHOT} 2>/dev/null || true && eval '#{inner}'"

  # ---- the reported incident ----

  # ISS-961, verbatim in shape: a sibling session's long-running `npm run dev`,
  # which a `pgrep -fl api` in an unrelated session matched — partly ON the
  # Anthropic key, since `sk-ant-api03-` contains the pattern being searched for.
  def test_redacts_the_command_line_that_leaked
    line = tool_shell("NEWRELIC_USER_KEY=#{NEWRELIC} PLAYBOOK_CLAUDE_KEY=#{ANTHROPIC} npm run dev")
    out = R.command(line)

    refute_includes out, ANTHROPIC
    refute_includes out, NEWRELIC
    assert_includes out, "NEWRELIC_USER_KEY=[redacted]"
    assert_includes out, "PLAYBOOK_CLAUDE_KEY=[redacted]"
    assert_includes out, "npm run dev"
  end

  # ---- shape preservation: the thing that must not break ----

  def test_redacted_tool_shell_still_matches_the_sweep_patterns
    line = tool_shell("PLAYBOOK_CLAUDE_KEY=#{ANTHROPIC} npm run dev")
    assert_match P::TOOL_SHELL, R.command(line)
  end

  def test_redacted_session_wrapper_still_matches_claude_session
    line = "/bin/sh -c claude --print --dangerously-skip-permissions " \
           "--model claude-opus-5\\[1m\\] < /Users/athena/Library/Logs/dev-agent/issues/ISS-961/prompt.md"
    assert_match P::CLAUDE_SESSION, R.command(line)
  end

  # The parse path is where redaction actually runs, so the whole predicate —
  # not just the two regexes — has to survive it. A leaked group whose command
  # lines carried secrets must still be classified as leaked.
  def test_leak_predicate_survives_redaction
    ps = <<~PS
      7871 1 7871 10:00.00 05:00.00 #{tool_shell("PLAYBOOK_CLAUDE_KEY=#{ANTHROPIC} npm run dev")}
      7900 7871 7871 10:00.00 05:00.00 node /Users/athena/code/x/node_modules/.bin/vite dev
    PS
    entries = P.parse(ps)

    assert_equal 2, entries.length
    entries.each { |e| refute_includes e.command, ANTHROPIC }
    assert_equal 1, P.leaked(entries).length
  end

  def test_parse_redacts_every_command_it_returns
    ps = "6735 6734 6734 10:00.00 05:00.00 /bin/sh -c NEWRELIC_USER_KEY=#{NEWRELIC} ./poll.sh\n"
    assert_equal "/bin/sh -c NEWRELIC_USER_KEY=[redacted] ./poll.sh", P.parse(ps).first.command
  end

  # ---- what it must NOT touch ----

  # A `$NAME` reference is a session doing exactly what it was told. Keeping it
  # is what lets whoever reads a listing tell "did it right" from "inlined the
  # value", which is the only question worth asking of a leaked line.
  def test_keeps_variable_references_intact
    assert_equal 'PLAYBOOK_CLAUDE_KEY=$PLAYBOOK_CLAUDE_KEY npm run dev',
                 R.command('PLAYBOOK_CLAUDE_KEY=$PLAYBOOK_CLAUDE_KEY npm run dev')
    assert_equal 'KEY=${PLAYBOOK_CLAUDE_KEY}', R.command('KEY=${PLAYBOOK_CLAUDE_KEY}')
    assert_equal 'API_KEY="$NEWRELIC_USER_KEY"', R.command('API_KEY="$NEWRELIC_USER_KEY"')
  end

  def test_leaves_ordinary_commands_alone
    [
      "SBT_OPTS=-Xms4G -Xmx12G sbt Test/compile",
      "sbt -no-share test",
      "curl -X POST https://api.newrelic.com/graphql",
      "/usr/bin/git -C /Users/athena/code/ai/i961/devops fetch origin",
      "node /Users/athena/code/playbook-www/node_modules/.bin/vite dev --port 5173",
    ].each { |line| assert_equal line, R.command(line), line }
  end

  def test_secret_predicate_reports_whether_anything_was_removed
    refute R.secret?("sbt Test/compile")
    assert R.secret?("PLAYBOOK_CLAUDE_KEY=#{ANTHROPIC} npm run dev")
  end

  # ---- the individual rules ----

  def test_redacts_issued_tokens_wherever_they_appear
    {
      "echo #{ANTHROPIC}" => "sk-ant-",
      "echo #{NEWRELIC}" => "NRAK-",
      "gh auth login --with-token ghp_AAAABBBBCCCCDDDDEEEEFFFFGGGG" => "ghp_",
      "X github_pat_11AAAAAAA0BBBBBBBBBB_cccccccccc" => "github_pat_",
      "X xoxb-1111111111-2222222222-abcdefghijkl" => "xoxb-",
      "X AKIAIOSFODNN7EXAMPLE" => "AKIA",
    }.each do |line, marker|
      out = R.command(line)
      refute_includes out, marker, line
      assert_includes out, "[redacted]", line
    end
  end

  # The shape `Agent::Credentials` puts in front of every session, and therefore
  # the shape most likely to be in an argv on this fleet. Redacted by header
  # NAME, which is what catches a token whose issuer stamped nothing on it.
  def test_redacts_auth_headers_by_name
    out = R.command(%(curl -H "x-api-key: opaque-token-with-no-prefix" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/messages))
    refute_includes out, "opaque-token-with-no-prefix"
    assert_includes out, 'x-api-key: [redacted]'
    assert_includes out, "anthropic-version: 2023-06-01"
    assert_includes out, "https://api.anthropic.com/v1/messages"
  end

  def test_keeps_the_bearer_scheme_and_drops_the_token
    out = R.command(%(curl -H 'Authorization: Bearer opaque-token' https://example.com))
    assert_includes out, "Authorization: Bearer [redacted]"
    refute_includes out, "opaque-token"
  end

  # An unquoted header must not swallow the rest of the command into the
  # placeholder — that would lose the shape and, in a tool-shell line, the
  # snapshot path the sweep matches on.
  def test_unquoted_auth_header_redacts_only_the_token
    assert_equal "curl -H x-api-key: [redacted] -X POST https://example.com",
                 R.command("curl -H x-api-key: opaque-token -X POST https://example.com")
  end

  def test_redacts_the_password_out_of_a_connection_string
    out = R.command("CONF_DB_DEV_URL=jdbc:postgresql://claude:hunter2@localhost:5433/platform sbt test")
    refute_includes out, "hunter2"
    assert_includes out, "jdbc:postgresql://claude:[redacted]@localhost:5433/platform"
    assert_includes out, "sbt test"
  end

  # `CONF_DB_DEV_URL` is not a secret NAME, so the assignment rule does not fire
  # and the URL rule is the only thing standing between a production connection
  # string and a listing. Asserted separately so a future edit to SECRET_NAME
  # cannot make this pass for the wrong reason.
  def test_url_password_rule_fires_without_a_secret_variable_name
    assert_includes R.command("psql postgres://app:s3cr3t@db.internal:5432/prod"),
                    "postgres://app:[redacted]@db.internal:5432/prod"
  end

  def test_collapses_a_named_assignment_carrying_an_issued_token_to_one_placeholder
    assert_equal "PLAYBOOK_CLAUDE_KEY=[redacted]", R.command("PLAYBOOK_CLAUDE_KEY=#{ANTHROPIC}")
  end

  def test_handles_quoted_assignment_values
    assert_equal "SENDGRID_API_KEY=[redacted] ./send.sh", R.command("SENDGRID_API_KEY='SG.a b c' ./send.sh")
    assert_equal "PLAY_CRYPTO_SECRET=[redacted]", R.command(%(PLAY_CRYPTO_SECRET="a b c"))
  end

  def test_nil_and_empty_are_not_errors
    assert_nil R.command(nil)
    assert_equal "", R.command("")
  end

  # ---- the guard ------------------------------------------------------------

  AGENT_LIB = File.expand_path("../lib/agent", __dir__)

  # Redacting in `Agent::Processes.parse` only holds while that is the ONE place
  # a command line enters this codebase. A second `ps` caller added later would
  # reintroduce the whole leak with nothing to say so — and it would look
  # perfectly reasonable, because reading `ps` is an ordinary thing to want.
  #
  # So the rule is mechanical rather than cultural, exactly as
  # test_dev_agent_shell.rb makes the Open3 deadline mechanical (ISS-740): a
  # boundary that has to be remembered is a boundary that gets forgotten once and
  # leaks a credential nobody notices. If a new call site genuinely needs `ps`,
  # this test failing is the conversation about routing it through Agent::Redact.
  def test_nothing_under_lib_agent_reads_ps_except_agent_processes
    offenders = Dir.glob(File.join(AGENT_LIB, "*.rb")).sort.filter_map do |file|
      next if File.basename(file) == "processes.rb"
      lines = File.readlines(file).each_with_index.select do |line, _i|
        line =~ /["']ps["']/ && line !~ /^\s*#/
      end
      next if lines.empty?
      "#{File.basename(file)}:#{lines.map { |_l, i| i + 1 }.join(',')}"
    end
    assert_empty offenders,
                 "these read process command lines, which carry whatever credential a sibling session " \
                 "inlined into a command — go through Agent::Processes, which redacts at parse " \
                 "(ISS-961): #{offenders.join(' ')}"
  end
end
