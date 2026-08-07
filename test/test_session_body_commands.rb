#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require_relative '../lib/common'

# The files under claude-issues/ and claude-invariants/ are not documentation --
# they ARE the brief an autonomous session is handed, and the shell in them is
# shell that session runs with nobody at the keyboard to notice it failed.
#
# So a command in one has to be a command that works. `insights-body.md` told
# every insights session to run `claude-db start` with no --app, which the CLI
# hard-refuses ("--app is required for `start`"), and the session's only path to
# an isolated database was that line.
#
# These are structural checks over every body rather than assertions about one
# file, so a body added later is covered by construction.
class TestSessionBodyCommands < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  # agent/instructions.md belongs in this glob and was missing from it. It is not
  # a README about the briefs -- Agent::Prompt.build puts it FIRST in the prompt of
  # every autonomous session, ahead of the issue body and the playbook, so it is
  # the most widely executed brief in the repo. Excluding it is how the idiom in
  # test_no_session_body_swallows_a_failed_command below survived ISS-581, which
  # fixed this same class of bug in the claude-issues/ bodies beside it.
  def bodies
    Dir.glob(File.join(ROOT, "claude-{issues,invariants}", "*-body.md")) +
      [File.join(ROOT, "agent", "instructions.md")]
  end

  def test_there_are_bodies_to_check
    refute_empty bodies, "the glob stopped matching the session bodies"
  end

  # An INVOCATION, as opposed to prose naming the command: a body may say "the
  # CONF_DB_DEV_URL that `claude-db start` printed" without that being something
  # the session runs. What it runs is written with a path or inside a command
  # substitution, so that is what this matches.
  INVOCATION = %r{(?:\$\(\s*|/)(?:[\w./~-]*/)?claude-db start([^|"'`)]*)}

  # Every `claude-db start` a body tells a session to RUN must name its app --
  # the CLI refuses `start` without one. Matched up to the next pipe, quote or
  # close-paren so a --app appearing later on the line for an unrelated reason
  # cannot make this pass.
  def test_every_claude_db_start_in_a_session_body_names_its_app
    offenders = bodies.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        args = line[INVOCATION, 1]
        next if args.nil? || args.include?("--app")
        "#{File.basename(path)}:#{i + 1}: #{line.strip}"
      end
    end
    assert_empty offenders,
                 "`claude-db start` requires --app; these bodies hand a session a command that exits 1:\n" +
                 offenders.join("\n")
  end

  # The bodies must not point a session at a file that was deleted. agent/bodies/
  # went away with ISS-526 (the playbooks moved into the platform), and a brief
  # telling a session to read a path that does not exist wastes the one thing it
  # cannot ask for: a human to correct it.
  def test_no_session_body_points_at_a_deleted_playbook_directory
    offenders = bodies.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{File.basename(path)}:#{i + 1}: #{line.strip}" if line.include?("agent/bodies/")
      end
    end
    assert_empty offenders, "agent/bodies/ was deleted by ISS-526:\n#{offenders.join("\n")}"
  end

  # A pipeline reports only its LAST command's exit status, so wrapping a command
  # whose failure MATTERS in `eval "$(cmd | grep ... | sed ...)"` discards it: the
  # failed command prints nothing, grep and sed match nothing, `eval ""` exits 0,
  # and whatever is chained after `&&` runs as if it had succeeded.
  #
  # lib/session_db.rb's own error message already tells sessions not to do this,
  # in as many words -- and agent/instructions.md handed every session exactly
  # that command for `claude-db start`. A start that failed left CONF_DB_DEV_URL
  # unset and `sbt test` running against the shared :5432 database, which is the
  # single outcome that whole guard exists to prevent (ISS-318).
  # Deliberately NOT `[^)]*` before the pipe. The line this was written for nests a
  # second substitution inside the first (`--port "$(claude-db next-port)"`), so a
  # class excluding `)` stops at that inner close-paren and never reaches the pipe
  # -- the regex missed the exact line it exists to catch. Matching any character
  # over-matches instead of under-matching, which is the right direction for a
  # lint: prose can be reworded around it, a session running the command cannot.
  SWALLOWING_EVAL = /eval\s+"?\$\(.*\|/

  def test_no_session_body_swallows_a_failed_command_in_an_eval_pipeline
    offenders = bodies.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{File.basename(path)}:#{i + 1}: #{line.strip}" if line.match?(SWALLOWING_EVAL)
      end
    end
    assert_empty offenders,
                 "a pipeline's exit status is its LAST command's, so these hand a session a command " \
                 "that proceeds after a failure:\n" + offenders.join("\n")
  end

  # Reporting a Reviewable URL is explicitly forbidden -- Mike navigates there
  # from GitHub himself -- and the bodies are where a session learns what to
  # report. Two of them still said "Report the Reviewable URL" until ISS-526's
  # follow-up; this keeps that from coming back.
  def test_no_session_body_tells_a_session_to_report_a_reviewable_url
    offenders = bodies.select { |p| File.read(p).match?(/report the reviewable url/i) }
    assert_empty offenders.map { |p| File.basename(p) }
  end
end
