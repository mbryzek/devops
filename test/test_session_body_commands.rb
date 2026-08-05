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

  def bodies
    Dir.glob(File.join(ROOT, "claude-{issues,invariants}", "*-body.md"))
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

  # Reporting a Reviewable URL is explicitly forbidden -- Mike navigates there
  # from GitHub himself -- and the bodies are where a session learns what to
  # report. Two of them still said "Report the Reviewable URL" until ISS-526's
  # follow-up; this keeps that from coming back.
  def test_no_session_body_tells_a_session_to_report_a_reviewable_url
    offenders = bodies.select { |p| File.read(p).match?(/report the reviewable url/i) }
    assert_empty offenders.map { |p| File.basename(p) }
  end
end
