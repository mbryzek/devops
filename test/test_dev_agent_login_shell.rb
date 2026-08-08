#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/login_shell'

# Agent::LoginShell — what a bare command name means on this machine (ISS-1033).
#
# THE PREMISE IS THE PART WORTH TESTING, and it is the part people get wrong from
# memory: zsh expands aliases in NON-INTERACTIVE shells, unlike bash. Everything
# this module claims rests on that one fact — if it were false, `alias ps='ps
# -ax'` would be an interactive-shell curiosity rather than something live in
# every session's Bash tool and in every `/bin/zsh -lc`. So it is asserted
# against a REAL zsh below rather than described in a comment.
#
# EVERY TEST HERE IS MACHINE-INDEPENDENT, deliberately. The obvious way to test
# this module is to run it on a runner and assert it finds `ps` — which passes on
# the fleet, fails on a laptop, and would pass again the day somebody deletes the
# alias, because the assertion would have been about the machine rather than the
# code. The Rakefile already carries that lesson (ISS-613: a credentials test
# that read green on laptops and red on the runners). So the shell probes below
# build their own `ZDOTDIR` and their own PATH, and assert about a zsh whose
# configuration the test wrote.
class TestDevAgentLoginShell < Minitest::Test
  include DevTestSupport

  # A zsh whose entire login configuration is `body`. `-l` sources
  # `$ZDOTDIR/.zprofile`, which is where this fleet's aliases come from.
  def with_zdotdir(body)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".zprofile"), body)
      yield dir
    end
  end

  # A PATH directory holding executables with the given names, so `which` has
  # something real to resolve against without depending on what this box has
  # installed.
  def with_bin(*names)
    Dir.mktmpdir do |dir|
      names.each do |name|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\n")
        File.chmod(0o755, path)
      end
      yield dir
    end
  end

  # ---- the premise ----------------------------------------------------------

  # THE WHOLE ISSUE IN ONE ASSERTION. If zsh behaved like bash here, a login
  # profile's alias would be invisible to `zsh -lc` and this module would be
  # solving a problem that does not exist.
  def test_a_non_interactive_login_zsh_expands_aliases
    with_zdotdir("alias ps='echo ALIASED'\n") do |dir|
      result = Agent::Shell.capture("/bin/zsh", "-lc", "ps", timeout: 20,
                                    env: { "ZDOTDIR" => dir }, stderr: :inherit)
      assert result.ok?, "zsh -lc failed: #{result.summary}"
      assert_equal "ALIASED", result.output.strip,
                   "a NON-interactive login zsh must expand aliases — the premise of ISS-1033"
    end
  end

  # The other half of the issue: `-ax` is PREPENDED, so a later `-p` cannot
  # narrow it back down. Asserted against the real macOS `ps` rather than
  # described, because it is the counter-intuitive step — a reader who assumes
  # the last flag wins concludes `ps -p <pid>` is safe.
  def test_a_prepended_ax_makes_a_later_p_a_no_op
    skip "macOS ps only" unless RUBY_PLATFORM.include?("darwin")

    one = Agent::Shell.capture("/bin/ps", "-o", "pid=", "-p", Process.pid.to_s, timeout: 20)
    many = Agent::Shell.capture("/bin/ps", "-ax", "-o", "pid=", "-p", Process.pid.to_s, timeout: 20)
    assert one.ok?
    assert many.ok?

    assert_equal 1, one.output.lines.count { |l| !l.strip.empty? },
                 "an unaliased `ps -p <pid>` must describe exactly one process"
    assert_operator many.output.lines.count { |l| !l.strip.empty? }, :>, 1,
                    "`-ax -p <pid>` must ignore the -p — that is what the alias does to every session"
  end

  # ---- parsing --------------------------------------------------------------

  def test_parse_reads_name_and_expansion_from_real_zsh_output
    with_zdotdir("alias ps='ps -ax'\nalias la='ls -al'\n") do |zdotdir|
      result = Agent::Shell.capture("/bin/zsh", "-lc", "alias", timeout: 20,
                                    env: { "ZDOTDIR" => zdotdir }, stderr: :inherit)
      assert result.ok?
      parsed = Agent::LoginShell.parse(result.output, path: "")
      found = parsed.find { |a| a.name == "ps" }

      refute_nil found, "the ps alias must survive a round trip through real zsh output"
      assert_equal "ps -ax", found.expansion, "the quoting zsh adds for display must be stripped"
      assert_includes parsed.map(&:name), "la"
    end
  end

  # The split is on the FIRST `=`: a name cannot contain one, a body can.
  def test_an_equals_sign_inside_the_body_is_kept
    parsed = Agent::LoginShell.parse("g=git commit -m msg=1\n", path: "")
    assert_equal "g", parsed.first.name
    assert_equal "git commit -m msg=1", parsed.first.expansion
  end

  # A body containing a newline prints across several lines. Guessing at the
  # continuation would INVENT an alias, and send an operator looking for a line to
  # delete that is not in any file — strictly worse than missing a rare one.
  def test_a_line_that_is_not_a_definition_is_skipped_rather_than_guessed_at
    parsed = Agent::LoginShell.parse("ps='ps -ax'\n  still part of something else\n\n", path: "")
    assert_equal %w[ps], parsed.map(&:name)
  end

  def test_embedded_single_quotes_are_unescaped
    parsed = Agent::LoginShell.parse(%(say='echo '\\''hi'\\'''\n), path: "")
    assert_equal "echo 'hi'", parsed.first.expansion
  end

  # Same boundary discipline as Agent::Processes: whatever later gets printed
  # from an Alias cannot be a credential, because one never gets that far.
  def test_a_credential_in_an_alias_body_is_redacted_at_parse_time
    parsed = Agent::LoginShell.parse(%(me='gh api -H "Authorization: token ghp_AAAABBBBCCCCDDDD"'\n), path: "")
    refute_includes parsed.first.expansion, "ghp_AAAABBBBCCCCDDDD"
    assert_includes parsed.first.expansion, Agent::Redact::PLACEHOLDER
    assert_includes parsed.first.expansion, "gh api", "redaction must preserve the shape around it"
  end

  # ---- the finding ----------------------------------------------------------

  def test_an_alias_whose_name_is_a_binary_is_a_shadow
    with_bin("ps") do |bin|
      found = Agent::LoginShell.shadowing(path: bin, text: "ps='ps -ax'\n")
      assert_equal %w[ps], found.map(&:name)
      assert_equal File.join(bin, "ps"), found.first.path
      assert_equal "ps -> ps -ax", found.first.to_s
    end
  end

  # It is the NAME that decides, never the expansion. Nobody typing `la` believed
  # they were running a binary called `la`, so an alias that invents a new word is
  # not a finding however much it expands to.
  def test_an_alias_that_invents_a_new_word_shadows_nothing
    with_bin("ls") do |bin|
      found = Agent::LoginShell.shadowing(path: bin, text: "la='ls -al'\ndcps='docker ps'\n")
      assert_empty found
    end
  end

  def test_a_machine_with_no_shadowing_aliases_reports_an_empty_list_not_nil
    with_bin("ps") do |bin|
      assert_equal [], Agent::LoginShell.shadowing(path: bin, text: "la='ls -al'\n")
    end
  end

  # nil and [] are different facts and the doctor prints different things for
  # them: "this machine would not answer" is not "this machine is clean".
  def test_a_shell_that_cannot_be_asked_is_nil_rather_than_clean
    stub_shell(->(_cmd, _opts) { shell_result(output: "", exitstatus: 1) }) do
      assert_nil Agent::LoginShell.shadowing(path: "/nonexistent")
    end
  end

  # THE LOGIN shell, and a bounded one. Asking this process would answer for
  # whatever ran `dev` — under launchd not the shell a session gets, and by hand
  # whatever the operator is sitting in. `-i` is absent on purpose: it would
  # additionally source .zshrc and report aliases a `/bin/zsh -lc` operation never
  # sees, and would ask a shell with no tty to be interactive.
  def test_the_probe_asks_a_login_shell_with_a_deadline_and_uninherited_stderr
    seen = nil
    stub_shell(->(cmd, opts) { seen = [cmd, opts]; shell_result(output: "ps='ps -ax'\n") }) do
      Agent::LoginShell.probe
    end

    assert_equal ["/bin/zsh", "-lc", "alias"], seen.first
    refute_includes seen.first, "-lic", "-i would report .zshrc aliases no `zsh -lc` operation sees"
    assert_equal :inherit, seen.last[:stderr],
                 "a .zprofile that warns must not be spliced into the text this parses"
    assert_operator seen.last[:timeout], :>, 0, "the doctor must not be able to hang on a wedged profile"
  end

  # ---- end to end, still machine-independent --------------------------------

  # The whole path — a real login zsh, real `alias` output, real PATH resolution —
  # against a shell and a PATH this test wrote. This is the assertion that would
  # have caught the alias on the runner, expressed so that it does not depend on
  # the runner still having it.
  def test_a_profile_that_aliases_ps_is_reported_as_shadowing
    with_zdotdir("alias ps='ps -ax'\nalias la='ls -al'\n") do |zdotdir|
      with_bin("ps", "ls") do |bin|
        result = Agent::Shell.capture("/bin/zsh", "-lc", "alias", timeout: 20,
                                      env: { "ZDOTDIR" => zdotdir }, stderr: :inherit)
        assert result.ok?
        found = Agent::LoginShell.shadowing(path: bin, text: result.output)

        assert_equal %w[ps], found.map(&:name),
                     "`ps` shadows a binary and `la` does not — the listing must say only that"
        assert_equal "ps -ax", found.first.expansion
      end
    end
  end
end
