#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
require 'agent/dotfiles'

# Agent::Dotfiles — the shell startup files, made safe to read (ISS-1035).
#
# EVERY FIXTURE HERE IS SYNTHETIC, and constructed to be obviously so. The real
# `~/.zshrc` and `~/.alias` on the runners hold a live Jira token and a live
# Artifactory password, and this suite never reads them — a test that opened the
# real file to prove it redacts would be the exact leak the module exists to
# stop, permanently, in a committed transcript.
#
# The suite is in two halves and the second is the one that matters.
#
# The first half is ordinary: known credential shapes come out redacted. That is
# mostly a test of Agent::Redact, which has its own suite.
#
# The second half tests the INVERSION, which is the whole reason this module is
# not just a call to Redact. A credential whose variable name nothing recognises
# — `JIRA_PAT`, `ARTIFACTORY_PW` — must still be hidden, because the name is
# precisely what this fleet cannot know in advance. If those assertions ever go
# green by being relaxed rather than by the code getting better, the sanctioned
# reader has become a leak with a blessing on it, which is strictly worse than
# the `cat ~/.zshrc` it replaced.
class TestDevAgentDotfiles < Minitest::Test
  D = Agent::Dotfiles

  # Fake, and shaped like the things they stand in for.
  JIRA = "ATATT3xFfGF0abcdefghijklmnopqrstuvwxyz0123456789".freeze
  ARTIFACTORY = "AKCp8kAAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH".freeze
  ANTHROPIC = "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGG".freeze

  def render(text) = text.lines.each_with_index.map { |raw, i| D.line(raw.chomp, i + 1) }

  def rendered(text) = render(text).map(&:text).join("\n")

  # ---- the reported incident: both credentials, in the files they are in ----

  def test_hides_a_token_whose_name_a_pattern_recognises
    out = rendered(%(export JIRA_API_TOKEN="#{JIRA}"))
    refute_includes out, JIRA
    assert_includes out, "export JIRA_API_TOKEN=[redacted]"
  end

  # THE test. `PAT` is not in Redact::SECRET_NAME and never will be reliably —
  # neither is `PW`, `CRED`, `SIG` or whatever the next dotfile picks. A reader
  # built on a name net would print this value in full.
  def test_hides_a_token_whose_name_NOTHING_recognises
    out = rendered(%(export JIRA_PAT="#{JIRA}"))
    refute_includes out, JIRA
    assert_includes out, "export JIRA_PAT=[hidden]"
  end

  def test_hides_an_artifactory_password_under_an_unrecognised_name
    out = rendered(%(ARTIFACTORY_PW='#{ARTIFACTORY}'))
    refute_includes out, ARTIFACTORY
    assert_includes out, "ARTIFACTORY_PW=[hidden]"
  end

  def test_hides_a_bare_unquoted_value
    out = rendered("MYVAR=#{ARTIFACTORY}")
    refute_includes out, ARTIFACTORY
  end

  # An issued token anywhere on the line is Redact's job and still runs, so a
  # credential that is not in an assignment at all is caught by the net even
  # though the seal does not reach it.
  def test_redacts_an_issued_token_outside_an_assignment
    out = rendered(%(alias ask='curl -H "x-api-key: #{ANTHROPIC}" https://api.anthropic.com'))
    refute_includes out, ANTHROPIC
  end

  # ---- the inversion, stated directly ----

  # The property that must never be weakened: a value is shown because it was
  # recognised as STRUCTURE, never because it was not recognised as a secret.
  def test_an_unrecognised_value_is_hidden_not_shown
    %w[hunter2 correcthorsebattery en_US.UTF-8 vim abc/def AKCp8k/abcdefgh].each do |value|
      out = rendered("SOMETHING=#{value}")
      assert_includes out, "SOMETHING=[hidden]", "#{value.inspect} must not be shown"
    end
  end

  def test_a_dollar_sign_inside_a_password_does_not_buy_it_through
    out = rendered("DB_THING=pa$$word")
    assert_includes out, "DB_THING=[hidden]"
  end

  def test_base64_padding_is_not_a_path_segment
    out = rendered("SOMETHING=abc/def+ghi=")
    assert_includes out, "SOMETHING=[hidden]"
  end

  # ---- what must survive, or nobody runs this instead of `cat` ----

  # The ISS-1033 question, verbatim. This is the reason the module exists, so an
  # alias line has to come through untouched.
  def test_alias_lines_are_shown_in_full
    out = rendered("alias ps='ps -ax'\nalias rm='rm -i'")
    assert_includes out, "alias ps='ps -ax'"
    assert_includes out, "alias rm='rm -i'"
  end

  def test_path_expressions_are_shown
    [
      %(export PATH="$HOME/code/devops/bin:$PATH"),
      %(export PATH=/usr/local/bin:/usr/bin:$PATH),
      %(export NVM_DIR=~/.nvm),
      %(export EDITOR_DIR=./bin),
    ].each { |l| assert_equal l, rendered(l), "must be shown verbatim" }
  end

  # ISS-753's line. A session sent to look at SBT_OPTS gets nothing from
  # `SBT_OPTS=[hidden]`, and a heap setting is not a credential.
  def test_flag_values_are_shown
    line = %(export SBT_OPTS="-Xms40G -Xmx40G")
    assert_equal line, rendered(line)
  end

  def test_numbers_and_booleans_are_shown
    ["HISTSIZE=10000", "SAVEHIST=10000", "DISABLE_AUTO_UPDATE=true"].each do |l|
      assert_equal l, rendered(l)
    end
  end

  def test_source_lines_comments_and_conditionals_are_shown
    text = <<~ZSH
      # the aliases everything else depends on
      [ -f ~/.alias ] && source ~/.alias
      if [[ -o interactive ]]; then
        setopt PROMPT_SUBST
      fi
    ZSH
    assert_equal text.strip, rendered(text).strip
  end

  # ---- the reported state, per line ----

  def test_states_distinguish_a_finding_from_an_ordinary_value
    lines = render("export JIRA_API_TOKEN=#{JIRA}\nexport JIRA_PAT=#{JIRA}\nexport PATH=$HOME/bin:$PATH")
    assert_equal %i[redacted hidden shown], lines.map(&:state)
    assert_equal %w[JIRA_API_TOKEN JIRA_PAT PATH], lines.map(&:name)
    assert lines[0].credential?
    assert lines[1].opaque?
    refute lines[2].credential?
  end

  def test_a_non_assignment_line_has_no_name
    assert_nil render("alias ps='ps -ax'").first.name
  end

  # ---- reading a real directory ----

  def test_reads_the_startup_files_in_zsh_order_and_follows_a_sourced_file
    in_home do |home|
      write(home, ".zprofile", %(export PATH="$HOME/bin:$PATH"\nsource ~/.alias\n))
      write(home, ".zshrc", %(export JIRA_PAT="#{JIRA}"\n))
      write(home, ".alias", %(alias ps='ps -ax'\nARTIFACTORY_PW='#{ARTIFACTORY}'\n))

      files = D.read(home: home)
      assert_equal ["~/.zprofile", "~/.alias", "~/.zshrc"], files.map(&:display)
      assert_equal "~/.zprofile", files[1].sourced_by

      body = files.flat_map { |f| f.lines.map(&:text) }.join("\n")
      refute_includes body, JIRA
      refute_includes body, ARTIFACTORY
      assert_includes body, "alias ps='ps -ax'"
    end
  end

  # The guarded form, which is how `~/.alias` is actually reached. An anchored
  # `source` pattern passes every other test in this file and silently never
  # follows the file holding one of the two credentials.
  def test_follows_a_source_guarded_by_a_test
    in_home do |home|
      write(home, ".zprofile", "[ -f ~/.alias ] && source ~/.alias\n")
      write(home, ".alias", "alias ps='ps -ax'\n")
      assert_equal ["~/.zprofile", "~/.alias"], D.read(home: home).map(&:display)
    end
  end

  # The normal case on this fleet, not an exotic one: every startup file is a
  # symlink into a `~/code/misc/env` checkout. Reporting only the realpath loses
  # which startup file it IS, and reporting only the logical name hides that the
  # credential is committed to a repo — where moving it out of the working tree
  # does not take it out of the history.
  def test_a_symlinked_startup_file_reports_both_names
    in_home do |home|
      Dir.mkdir(::File.join(home, "env"))
      write(home, "env/zshrc", "alias ps='ps -ax'\n")
      ::File.symlink(::File.join(home, "env/zshrc"), ::File.join(home, ".zshrc"))

      file = D.read(home: home).first
      assert_equal "~/.zshrc", file.display
      assert_equal "~/env/zshrc", file.resolves_to
    end
  end

  def test_an_ordinary_file_reports_no_symlink_target
    in_home do |home|
      write(home, ".zshrc", "alias ps='ps -ax'\n")
      assert_nil D.read(home: home).first.resolves_to
    end
  end

  def test_absent_startup_files_are_simply_absent
    in_home do |home|
      write(home, ".zshrc", "alias ll='ls -la'\n")
      assert_equal ["~/.zshrc"], D.read(home: home).map(&:display)
    end
  end

  # A `source` loop is a real thing to write by accident, and this runs
  # unattended: recursing forever would wedge the tick's doctor, not just fail.
  def test_a_source_cycle_terminates
    in_home do |home|
      write(home, ".zprofile", "source ~/.alias\n")
      write(home, ".alias", "source ~/.zprofile\n")
      assert_equal ["~/.zprofile", "~/.alias"], D.read(home: home).map(&:display)
    end
  end

  def test_does_not_follow_a_source_outside_home_or_one_it_cannot_resolve
    in_home do |home|
      write(home, ".zshrc", "source /opt/homebrew/thing.sh\nsource $NVM_DIR/nvm.sh\n")
      files = D.read(home: home)
      assert_equal ["~/.zshrc"], files.map(&:display)
      assert_equal ["/opt/homebrew/thing.sh", "$NVM_DIR/nvm.sh"], D.unresolved_sources(files.first, home: home)
    end
  end

  def test_a_vendored_script_is_reported_by_size_rather_than_printed
    in_home do |home|
      write(home, ".zshrc", "source ~/.nvm/nvm.sh\n")
      Dir.mkdir(::File.join(home, ".nvm"))
      write(home, ".nvm/nvm.sh", "# nvm\n#{'x' * (Agent::Dotfiles::MAX_AUTO_BYTES + 1)}\n")

      nvm = D.read(home: home).find { |f| f.display.end_with?("nvm.sh") }
      refute_nil nvm
      refute nvm.shown?
      assert_includes nvm.note, "too large"
      assert_nil nvm.lines
    end
  end

  # Every rule here is a regex, and a regex against invalid UTF-8 raises. One
  # latin-1 byte in a comment would take out `dev agent doctor` on that machine
  # — the command that reports the credentials — and it would look like a bug in
  # the code rather than a property of the file.
  def test_a_dotfile_with_invalid_utf8_still_reads
    in_home do |home|
      ::File.binwrite(::File.join(home, ".zshrc"), "# caf\xE9\nexport JIRA_PAT=#{JIRA}\n")
      files = D.read(home: home)
      body = files.flat_map { |f| f.lines.map(&:text) }.join("\n")
      refute_includes body, JIRA
      assert_includes body, "export JIRA_PAT=[hidden]"
    end
  end

  # Naming a path explicitly is not a way around the redaction — only around the
  # size guard.
  def test_an_explicitly_named_file_is_still_redacted
    in_home do |home|
      write(home, ".secrets", %(export JIRA_PAT="#{JIRA}"\n))
      files = D.read(home: home, paths: [::File.join(home, ".secrets")])
      body = files.flat_map { |f| f.lines.map(&:text) }.join("\n")
      refute_includes body, JIRA
      assert_includes body, "[hidden]"
    end
  end

  def test_findings_name_the_file_and_the_variable_and_carry_no_value
    in_home do |home|
      write(home, ".zshrc", %(export JIRA_API_TOKEN="#{JIRA}"\nexport PATH=$HOME/bin\n))
      file, line = D.findings(D.read(home: home)).first
      assert_equal "~/.zshrc", file.display
      assert_equal "JIRA_API_TOKEN", line.name
      assert_equal 1, line.number
      refute_includes line.text, JIRA
    end
  end

  # ---- helpers ----

  def in_home
    Dir.mktmpdir { |dir| yield ::File.realpath(dir) }
  end

  def write(home, name, body)
    ::File.write(::File.join(home, name), body)
  end
end
