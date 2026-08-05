#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-525: the three producers whose check needed a git workspace.
#
# `codegen-sync`, `depsguard` and `browserslist-update` were the only producers
# left whose check could not run without a machine to clone into — and therefore
# the only reason a server -> runner check-dispatch path would ever have had to
# be built (epic ISS-519). The check moved into the playbook instead: all three
# file unconditionally, and the claiming session runs the check as its FIRST step
# and dismisses the issue when it comes back clean.
#
# Every assertion here pins a failure that is SILENT in production. A playbook
# that loses its check line turns into a nightly issue nobody can act on. One
# that closes a clean run `fixed` instead of `dismissed` suppresses every
# subsequent run until a human clicks verify. And a `check` put back into
# producers.yml runs inline in the tick, on whichever machine won the run, under
# the work lock — which is the thing this issue removed.
class TestAgentWorkspaceProducers < Minitest::Test
  include DevTestSupport

  # The check each producer used to carry, and now names as the first step of its
  # playbook. The command has to be IDENTICAL: the point of ISS-525 is that the
  # check moved, not that it was reinvented in prose.
  MOVED_CHECKS = {
    "codegen-sync"        => "dev codegen sync --check",
    "depsguard"           => "dev depsguard",
    "browserslist-update" => "dev browserslist update --check",
  }.freeze

  PLAYBOOKS = {
    "codegen-sync"        => "bodies/codegen-sync.md",
    "depsguard"           => "bodies/depsguard-fix.md",
    "browserslist-update" => "bodies/browserslist-update.md",
  }.freeze

  def registry = @registry ||= Agent::Producers.load
  def producer(key) = registry.fetch(:producers).find { |p| p.key == key }
  def playbook(key) = producer(key).body_text.to_s

  def test_all_three_file_unconditionally_and_run_no_check_on_the_tick
    MOVED_CHECKS.each_key do |key|
      p = producer(key)
      refute_nil p, "#{key}: the producer is gone from the registry"
      assert_equal "always", p.file_when, "#{key}: must file unconditionally — the session decides"
      assert_nil p.check,
                 "#{key}: a check needing a git workspace is the work wearing a check's clothes — " \
                 "it runs inline in the tick, under the work lock, on one machine"
      assert p.files_issue?, "#{key}: a producer that files nothing gives the session nothing to claim"
    end
  end

  # Without a body_file the filed issue falls back to claude-issues/default-body.md
  # and the session does generic triage (ISS-360). That was survivable while a
  # check's stdout arrived as the brief; now the playbook IS the brief.
  def test_each_ships_the_playbook_that_carries_its_check
    PLAYBOOKS.each do |key, rel|
      assert_equal File.join(Agent::Paths.agent_dir, rel), producer(key).body_file
      refute_empty playbook(key), "#{key}: playbook is empty"
    end
  end

  # THE assertion of ISS-525. A playbook that lost its check line files a nightly
  # issue with nothing to run, and the session invents its own idea of the job.
  def test_each_playbook_names_the_exact_check_that_moved_into_it
    MOVED_CHECKS.each do |key, command|
      assert_includes playbook(key), command,
                      "#{key}: the check moved into this playbook — without the command it did not move, it vanished"
    end
  end

  # A playbook step is only as good as the command existing. A typo'd first step
  # fails inside a claimed session, four hours of lease later, as "the command
  # could not be run" rather than as a registry error the next tick.
  def test_every_moved_check_is_a_real_dev_command
    MOVED_CHECKS.each_value do |command|
      words = command.split
      assert_equal "dev", words.shift, "#{command}: not a `dev` invocation"
      cmd = words.shift
      assert_includes COMMANDS, cmd, "#{command}: `dev #{cmd}` is not a command"
      sub = words.first
      next if sub.nil? || sub.start_with?("-")
      assert_includes SUBCOMMANDS.fetch(cmd, []), sub, "#{command}: `dev #{cmd} #{sub}` is not a subcommand"
    end
  end

  def test_the_browserslist_check_flag_is_documented_where_the_cli_advertises_it
    assert_includes INVOCATIONS.fetch("browserslist update"), "--check",
                    "the playbook's first step is a flag the CLI does not advertise"
  end

  # A clean run must leave a TERMINAL issue. `fixed` and `deployed` are both
  # non-terminal for producer dedup (Agent::Producers::TERMINAL_ISSUE_STATUSES),
  # so a no-op run closed `fixed` suppresses the NEXT run, and the one after,
  # until somebody clicks verify — a daily check going quiet for a week with
  # nothing anywhere reporting that it had.
  def test_each_playbook_dismisses_a_clean_run
    PLAYBOOKS.each_key do |key|
      assert_includes playbook(key), "--status dismissed",
                      "#{key}: a clean run must close TERMINAL, or it suppresses every run after it"
      assert_includes Agent::Producers::TERMINAL_ISSUE_STATUSES, "dismissed"
    end
  end

  # The other half of the same instruction: a clean run must also STOP. A session
  # that dismisses and then goes looking for adjacent work is the fire-and-forget
  # behaviour the queue replaced.
  def test_each_playbook_tells_a_clean_run_to_stop_without_a_pr
    PLAYBOOKS.each_key do |key|
      text = playbook(key).downcase
      assert_includes text, "stop", "#{key}: a clean run must be told to stop, not to find something else to do"
      assert_match(/exit(s|ed)? 0|\| 0 \|/, playbook(key),
                   "#{key}: the playbook must say which exit code means clean")
    end
  end

  # The dirty branch is the other outcome the producer exists for, and it goes
  # through a PR like everything else. `browserslist update` without `--check`
  # pushes straight to main — that is exactly what ISS-525 took off the schedule,
  # so no playbook may reintroduce it.
  def test_each_playbook_ships_a_pr_and_never_pushes_to_main
    PLAYBOOKS.each_key do |key|
      assert_includes playbook(key), "gh pr", "#{key}: the fix branch must open a PR"
      refute_match(/^\s*git push[^\n]*\bmain\b/, playbook(key),
                   "#{key}: an autonomous session never pushes to main")
      refute_match(/gh pr create[^\n]*--base/, playbook(key),
                   "#{key}: never pass --base to gh pr create — it is how stacked PRs happen")
      refute_match(/git clone[^\n]*--depth/, playbook(key), "#{key}: no shallow clones")
    end
  end

  # Every playbook must open `# Heading` + blank + paragraph, because that opening
  # IS the abstract the filed issue renders in admin. Enforced at parse time too;
  # asserted here so the failure names the file rather than the whole registry.
  def test_each_playbook_abstracts_cleanly
    PLAYBOOKS.each_key do |key|
      assert Agent::Playbook.abstracts_cleanly?(playbook(key)),
             "#{key}: playbook must open with a `# Heading` and then a paragraph"
    end
  end

  # UNDATED, and this is the asymmetry an editor is most likely to "fix" after
  # reading the dated ones on api-lint and meta-review. Each of these fingerprints
  # names a standing CONDITION ("generated code is out of sync"), so while a fix
  # PR is open the issue sits at `fixed` — non-terminal — and tomorrow files
  # nothing on top of it. Dating them would open a second issue against the same
  # open PR every single night. The dated ones are dated because a clean run there
  # closes non-terminal; here a clean run dismisses, which IS terminal.
  def test_the_fingerprints_stay_undated
    expected = {
      "codegen-sync"        => "codegen:sync",
      "depsguard"           => "depsguard:scan",
      "browserslist-update" => "browserslist:update",
    }
    expected.each do |key, fingerprint|
      p = producer(key)
      assert_equal fingerprint, p.fingerprint
      refute_includes p.fingerprint, Agent::Producers::DATE_TOKEN,
                      "#{key}: dating this would file a second issue on top of the still-open fix PR"
      assert_equal fingerprint, p.fingerprint_at(Time.utc(2026, 8, 5, 7, 0))
    end
  end

  # Schedules are unchanged by ISS-525: what moved is WHERE the check runs, not
  # when the producer fires. A migration that quietly shifted an hour would be
  # indistinguishable from one that worked.
  def test_the_schedules_did_not_move
    {
      "codegen-sync"        => "daily at 3:00am",
      "depsguard"           => "weekly on monday at 5:13am",
      "browserslist-update" => "weekly on monday at 4:13am",
    }.each do |key, text|
      assert_equal text, producer(key).schedule_text, "#{key}: schedule drifted"
    end
  end

  # The point of the whole issue, asserted directly: no check left in the registry
  # needs a git workspace, so nothing has to dispatch a check to a machine and the
  # producer concept can move server-side (ISS-519).
  #
  # An allow-list rather than a heuristic — "does this command clone?" is not
  # answerable from a string, and a new workspace-bound check would be added by
  # someone who did not read this file. Adding a check here is a deliberate act
  # that has to be justified in the diff.
  ALLOWED_CHECKS = [
    "dev invariants check --app platform",
    "dev invariants check --app acumen",
    "dev issues reconcile --apply",
  ].freeze

  def test_no_producer_check_needs_a_git_workspace
    checks = registry.fetch(:producers).filter_map(&:check).sort
    assert_equal ALLOWED_CHECKS.sort, checks,
                 "a producer check changed. Every check runs INLINE in the tick, under the work lock, on " \
                 "whichever machine won the run — so it must be cheap and must not need a git checkout. " \
                 "If the new one clones, regenerates or installs anything, it belongs in a playbook with " \
                 "`file_when: always` (ISS-525), not here."
  end
end
