#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `Agent::Playbook` — the pointer a producer's issue carries, and the resolution a
# claiming runner does against the platform (ISS-505, ISS-523, ISS-526).
#
# The tests that matter here are the two ends of the round trip (what the platform
# writes is what the runner reads back) and the failure modes, because the failure
# modes are the whole reason the pointer is designed this way: a pointer that does
# not resolve must be LOUD, never a quiet fall back to generic triage, and a key
# that comes out of a human-editable issue body must never be trusted to be a safe
# URL path segment.
#
# What is NOT here anymore, deliberately: every test about reading a file out of
# `agent/bodies/` and permalinking a git sha. That directory is deleted — the
# playbooks are append-only rows in the platform, so the version a run records is a
# `created_at` that is still readable after ten later edits, which a sha only gave
# us while the file was still in git.
class TestDevAgentPlaybook < Minitest::Test
  include DevTestSupport

  TOKEN = "tok-runner".freeze

  VERSION = "2026-08-05T14:04:20.055Z".freeze

  BODY = <<~MD.strip
    # Daily slow-query review

    Review the platform's database query costs for the last 24 hours, find queries
    worth fixing, prove the fix, and open a PR.

        dev queries top --limit 25
  MD

  CHILD_BODY = "# Dependency upgrades\n\nRun `dev dependencies upgrade --app {child}` and open a PR.".freeze

  def stub_playbooks(rows)
    responses = {}
    rows.each { |key, value| responses["GET /agent/playbooks/#{key}"] = value }
    with_stubbed_api(responses) { yield }
  end

  def resolve(body, rows)
    stub_playbooks(rows) do
      Agent::Playbook.resolve_in(body, token: TOKEN, use_localhost: false)
    end
  end

  def row(body: BODY, key: "slow-query-review")
    { "key" => key, "body" => body, "created_at" => VERSION }
  end

  # ---- the round trip ----
  #
  # The platform writes the line and the claiming runner reads it back. One format,
  # two repos: `ProducerIssueBody.withPlaybook` is the other half, and a change to
  # either side that the other does not follow is a session with no runbook.

  def test_a_written_pointer_reads_back_as_the_same_key
    line = Agent::Playbook.pointer_line("slow-query-review")
    pointer = Agent::Playbook.pointer_in("some evidence\n\n#{line}\n\nmore prose")
    assert_equal "slow-query-review", pointer.key
    assert_nil pointer.target
  end

  def test_a_child_pointer_carries_its_target_through_the_round_trip
    line = Agent::Playbook.pointer_line("dependency-upgrade-app", target: "platform")
    pointer = Agent::Playbook.pointer_in("evidence\n\n#{line}")
    assert_equal "dependency-upgrade-app", pointer.key
    assert_equal "platform", pointer.target
  end

  # The exact line the platform actually emits, copied from ProducerIssueBody. If
  # this starts failing, the two repos have drifted and every producer-filed issue
  # is arriving with a runbook nothing resolves.
  def test_the_line_the_platform_actually_writes_parses
    body = "Filed automatically by the `dependency-upgrade` producer.\n\n---\n\n" \
           "Playbook: `dependency-upgrade-app` (target: acumen)\n\n" \
           "The procedure itself is deliberately NOT copied here."
    pointer = Agent::Playbook.pointer_in(body)
    assert_equal "dependency-upgrade-app", pointer.key
    assert_equal "acumen", pointer.target
  end

  # One row serves every child of an epic and says `--app {child}` where the
  # command differs, so the substitution is what makes a shared playbook possible
  # at all. Without it the session is told to run a command with a literal
  # `{child}` in it.
  def test_the_target_substitutes_the_child_token_at_resolve_time
    body = "evidence\n\n#{Agent::Playbook.pointer_line('dependency-upgrade-app', target: 'acumen')}"
    resolved = resolve(body, { "dependency-upgrade-app" => row(body: CHILD_BODY, key: "dependency-upgrade-app") })

    assert_includes resolved.text, "--app acumen"
    refute_includes resolved.text, "{child}"
  end

  def test_a_targetless_playbook_is_handed_over_exactly_as_written
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    assert_equal BODY, resolve(body, { "slow-query-review" => row }).text
  end

  # ---- what must NOT be mistaken for a pointer ----
  #
  # An indented example, or prose about the mechanism, must not resolve — an issue
  # describing this very design would otherwise point at a playbook.
  def test_prose_that_merely_mentions_a_playbook_is_not_a_pointer
    [
      "    Playbook: `slow-query-review`",
      "See Playbook: `slow-query-review` for the procedure",
      "Playbook: slow-query-review",
      "The playbook is slow-query-review.",
    ].each do |line|
      assert_nil Agent::Playbook.pointer_in(line), "must not match: #{line}"
    end
  end

  # Every human-written issue carries its brief inline, so no pointer is the common
  # case and must cost nothing — not a lookup, not a warning.
  def test_an_issue_with_no_pointer_resolves_to_nothing_at_all
    assert_nil Agent::Playbook.resolve_in("A human wrote this issue by hand.", token: TOKEN, use_localhost: false)
    assert_nil Agent::Playbook.resolve_in(nil, token: TOKEN, use_localhost: false)
  end

  # ---- the hard failures ----

  # ISS-360: a producer ported without its playbook fell back to generic triage and
  # filed issues instead of shipping PRs for a week, with nothing saying so. A key
  # the platform has never heard of has to stop the claim.
  def test_a_key_the_platform_does_not_have_raises
    body = "evidence\n\n#{Agent::Playbook.pointer_line('no-such-playbook')}"
    error = assert_raises(Agent::Playbook::MissingError) do
      resolve(body, { "no-such-playbook" => nil })
    end
    assert_includes error.message, "no-such-playbook"
  end

  # A row that exists but says nothing is the same failure wearing a 200: the
  # session would get an empty brief and quietly do generic triage.
  def test_an_empty_body_raises_rather_than_handing_over_an_empty_brief
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    assert_raises(Agent::Playbook::MissingError) do
      resolve(body, { "slow-query-review" => row(body: "   \n") })
    end
  end

  # The key becomes a URL path segment and it is read out of a body a human can
  # edit, so it is rejected on shape BEFORE any request — reaching the network here
  # would itself fail the test (NetworkGuard), which is the assertion.
  def test_a_key_that_is_not_url_safe_raises_before_any_request
    ["../../etc/passwd", "agent/bodies/x.md", "Weekly Review", "-leading-dash", ""].each do |key|
      assert_raises(Agent::Playbook::MissingError, "must reject: #{key.inspect}") do
        Agent::Playbook.resolve(Agent::Playbook::Pointer.new(key: key), token: TOKEN, use_localhost: false)
      end
    end
  end

  # A platform the runner cannot reach is not a missing playbook, but it has the
  # same consequence for this claim — do not start a session that would do the
  # wrong job — so it comes back as the same error, saying which it was.
  def test_an_unreachable_platform_stops_the_claim_and_says_so
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    raiser = ->(_payload) { raise ApiError, "500 Internal Server Error" }
    error = assert_raises(Agent::Playbook::MissingError) do
      resolve(body, { "slow-query-review" => raiser })
    end
    assert_includes error.message, "could not be read from the platform"
  end

  # ---- what the run records ----

  # The audit trail ISS-505 turns on, and the reason copy-on-write was worth its
  # cost: the version named here is still there, and still readable, after any
  # number of later edits.
  def test_a_resolved_playbook_records_the_version_it_was_read_at
    body = "evidence\n\n#{Agent::Playbook.pointer_line('slow-query-review')}"
    resolved = resolve(body, { "slow-query-review" => row })

    assert_equal VERSION, resolved.version
    assert_equal "slow-query-review @ #{VERSION}", resolved.label
  end

  # ---- the hardcoded-home detector (ISS-633) ----
  #
  # One playbook, every runner, and the runners do not share a home: an absolute
  # path under `/Users/mbryzek` is right on the MacBook and silently wrong on the
  # Mac mini, where the session either errors or writes into a tree nothing reads.
  # This is the detector that makes that findable without running into it.

  # The real defect, verbatim from the row this issue was filed against.
  def test_the_status_file_path_that_filed_this_issue_is_a_finding
    body = "Write\n`/Users/mbryzek/code/openclaw/openclaw-workspace/data/slow-query-review-status.md`\nin this shape."
    findings = Agent::Playbook.home_paths_in(body, key: "slow-query-review")

    assert_equal 1, findings.length
    assert_equal 2, findings.first.line
    assert_equal "/Users/mbryzek", findings.first.path
    assert_equal "slow-query-review:2: /Users/mbryzek", findings.first.to_s
  end

  # The home-relative form the fix uses, and the form the Ruby side always used
  # (`Briefing::DATA_DIR`). If this ever became a finding the detector would be
  # flagging the fix.
  def test_a_home_relative_path_is_not_a_finding
    body = "Write `~/code/openclaw/openclaw-workspace/data/slow-query-review-status.md`\n" \
           "or `$HOME/code/openclaw/openclaw-workspace/data/`."
    assert_empty Agent::Playbook.home_paths_in(body)
  end

  # A detector with a standing false positive is one nobody runs twice — and these
  # are the exact strings the meta-review playbook carries, which describes this
  # very defect and must stay clean.
  def test_placeholders_and_commands_are_not_paths
    [
      "Do not hardcode `/Users/<someone>/code/openclaw/…`.",
      "    grep -n '/Users/' -- the old detector",
      "a path under /Users/ belonging to one person",
    ].each { |line| assert_empty Agent::Playbook.home_paths_in(line), "must not flag: #{line}" }
  end

  # Whose home it is does not matter: hardcoding THIS runner's home breaks on the
  # other one, which is the same bug pointed the other way.
  def test_the_runners_own_home_is_a_finding_too
    findings = Agent::Playbook.home_paths_in("write /Users/athena/code/ai/x and /home/ci/logs")
    assert_equal ["/Users/athena", "/home/ci"], findings.map(&:path)
  end

  def test_the_whole_store_is_linted_key_by_key
    rows = [
      { "key" => "clean", "body" => "Write `~/code/x`." },
      { "key" => "broken", "body" => "line one\nwrite /Users/mbryzek/code/x\n" },
    ]
    assert_equal ["broken:2: /Users/mbryzek"], Agent::Playbook.home_paths_in_all(rows).map(&:to_s)
  end

  # ---- what `dev agent playbooks` prints ----

  ROWS = [
    { "key" => "clean", "body" => "Write `~/code/x`.\n", "created_at" => VERSION },
    { "key" => "broken", "body" => "one\nwrite /Users/mbryzek/code/x\n", "created_at" => VERSION },
  ].freeze

  def report(rows: ROWS, lint: false)
    findings = nil
    out = capture_stdout { findings = agent_playbooks_report(rows, lint: lint) }
    [out, findings]
  end

  # This renderer describes a SET and never dumps a body. Dumping one is
  # `dev agent playbook <key>` since ISS-665 split the two commands, and the
  # stdout/stderr split that makes `> file` safe is asserted over the real command
  # in test_dev_agent_playbook_cli.rb
  # (`test_reading_a_playbook_puts_the_body_on_stdout_and_the_version_on_stderr`).
  # What is worth guarding here is that the catalogue never became a body dump
  # again: an operator listing 16 playbooks must not get 16 full texts.
  def test_the_catalogue_describes_each_playbook_without_dumping_it
    row = { "key" => "multi", "body" => "# Title\n\nBODY-LINE-THREE\n", "created_at" => VERSION }
    out, = report(rows: [row])
    assert_match(/multi/, out)
    # The first non-blank line is the abstract, and identifies the playbook...
    assert_includes out, "# Title"
    # ...but the rest of it is not printed. An operator listing 16 playbooks must
    # not be handed 16 full texts.
    refute_includes out, "BODY-LINE-THREE"
  end

  # Not "nothing to see": every producer whose issue points at a playbook is
  # unclaimable, which is ISS-360's failure fleet-wide.
  def test_an_empty_store_says_what_it_costs
    out, findings = report(rows: [])
    assert_empty findings
    assert_match(/cannot be claimed/, out)
  end

  # "No findings" said out loud is what distinguishes a clean store from a
  # detector that ran against nothing — which is exactly how the meta-review's D4
  # stopped working when the directory it grepped was deleted.
  def test_a_clean_lint_says_how_many_playbooks_it_read
    out, findings = report(rows: [ROWS.first], lint: true)
    assert_empty findings
    assert_match(/No findings in 1 playbook\(s\)/, out)
    # And it names the checks: a clean line that does not say WHAT it checked
    # cannot tell you that a defect class you just thought of is not covered.
    assert_match(/hardcoded homes, unpushable writes, reaped plans/, out)
  end

  def test_the_lint_names_the_key_the_line_and_the_path
    out, findings = report(lint: true)
    assert_equal 1, findings.length
    assert_match(/broken:2: \/Users\/mbryzek/, out)
    assert_match(/Use `~\/…`/, out)
  end

  # The catalogue is a read and stays exit-0, but a defect must be visible in it —
  # a lint you have to know to ask for is one nobody asks for.
  def test_the_catalogue_flags_an_offending_key_inline
    out, = report
    assert_match(/Playbook store: 2 playbook\(s\)/, out)
    assert_match(/broken.*v #{Regexp.escape(VERSION)}/, out)
    assert_match(/1 lint finding\(s\): \/Users\/mbryzek/, out)
    refute_match(/clean\n.*lint finding/, out)
  end

  # ---- writes no unattended session can land (ISS-644) ----
  #
  # The sibling of the hardcoded home. That one is an instruction that works on
  # ONE runner; these two work on NO runner, and both fail at the END of a run —
  # after the session has done the thinking and written the file — so a run that
  # recorded nothing looks exactly like a run with nothing to record. ISS-632 is
  # the worked example: `daily-perf-prs` pointed its dedup ledger at
  # `~/code/claude/perf-ledger.md` and no unattended run recorded an entry for
  # weeks, dedupping nothing.
  #
  # The whole design problem here is the FALSE POSITIVE, not the catch. Half the
  # store legitimately points at `~/code/claude/rules/*.mdc` and at design docs
  # under `plans/`, and a lint with a standing false positive is one nobody runs
  # twice — so the bulk of these tests are of paths that must stay clean.

  def targets(body)
    Agent::Playbook.write_targets_in(body, key: "pb").map(&:to_s)
  end

  def rules_of(body)
    Agent::Playbook.write_targets_in(body, key: "pb").map(&:rule)
  end

  # ---- 1. unpushable: outside plans/, which the push guard refuses ----

  # Verbatim the shape ISS-632 shipped for weeks.
  def test_a_ledger_at_the_repo_root_is_unpushable
    assert_equal ["pb:1: ~/code/claude/perf-ledger.md — outside `plans/` — the push guard refuses " \
                  "this write from an unattended session"],
                 targets("Append the entry to `~/code/claude/perf-ledger.md` before finishing.")
  end

  # The other half of the same defect, and the form with no prose verb anywhere:
  # the repo and the path are separate arguments of a command that is a write by
  # construction.
  def test_git_add_names_its_path_as_a_separate_argument
    assert_equal [:unpushable], rules_of("    git -C ~/code/claude add perf-ledger.md")
    assert_equal [:unpushable], rules_of("    git -C $HOME/code/claude add notes/ledger.md")
    assert_empty targets("    git -C ~/code/claude add plans/data/perf-ledger.md")
  end

  # `-A` is not a path. It is its own hazard in a shared checkout, but flagging it
  # here would mean reporting a flag as a file and the finding would read as
  # nonsense.
  def test_git_add_ignores_flags
    assert_empty targets("    git -C ~/code/claude add -A")
  end

  def test_every_spelling_of_the_repo_is_the_same_repo
    ["~", "$HOME", "${HOME}", "/Users/mbryzek", "/Users/athena", "/home/ci"].each do |home|
      assert_equal [:unpushable], rules_of("Write it to #{home}/code/claude/CLAUDE.md"), home
    end
  end

  def test_a_shell_redirect_is_a_write_cue
    assert_equal [:unpushable], rules_of('    echo "$entry" >> ~/code/claude/ledger.md')
    assert_equal [:unpushable], rules_of('    printf "%s" "$e" | tee -a ~/code/claude/ledger.md')
  end

  # ---- the false positives that would make nobody run this twice ----

  # Half the store says exactly this, and the trap is the write verb sitting AFTER
  # the path in the same sentence, about something else entirely.
  def test_reading_the_rules_before_writing_code_is_not_a_write
    assert_empty targets("- Read the relevant `~/code/claude/rules/*.mdc` before writing code — especially")
    assert_empty targets("conventions, and `~/code/claude/rules/*.mdc` covers each stack in detail.")
  end

  # A bare mention of the repo is not a target: `git -C ~/code/claude pull` and
  # the prose explaining the push guard both name it, and neither writes anything
  # to a path.
  def test_the_repo_named_without_a_path_is_not_a_target
    assert_empty targets("    git -C ~/code/claude pull --rebase origin main")
    assert_empty targets("`~/code/claude` is the one repo an unattended session commits straight to `main`.")
    assert_empty targets("the push guard refuses any push to `~/code/claude` touching anything else")
  end

  # A pointer at a document to read, whose sentence then goes on to use a verb the
  # naive matcher would take. `:` ends the previous clause's reach for the same
  # reason.
  def test_a_design_doc_pointer_is_not_a_write
    assert_empty targets("Design: `~/code/claude/plans/2026-08-04-pr-auto-merge-design.md`. Read it if\n" \
                         "you are updating the merge order.")
  end

  # ---- 2. reaped: a top-level plans/ file that `dev prune plans` git rm's ----

  def test_long_lived_state_at_the_top_of_plans_is_reaped
    assert_equal ["pb:1: ~/code/claude/plans/perf-ledger.md — a top-level `plans/` file with no date " \
                  "in its name — `dev prune plans` removes it after 14 days"],
                 targets("Append the entry to `~/code/claude/plans/perf-ledger.md`.")
  end

  # The fix ISS-632 actually shipped, and the reason a subdirectory was the whole
  # point: the reaper never descends.
  def test_a_subdirectory_under_plans_is_never_reaped
    assert_empty targets("Append the entry to `~/code/claude/plans/data/perf-ledger.md`.")
    assert_empty targets("Also write a copy to `~/code/claude/plans/data/meta-review-<YYYY-MM-DD>.md`.")
  end

  # `weekly-review` writes one of these every week and is precisely the file this
  # check must not flag — a date in the name is what a per-run snapshot always has
  # and long-lived state never does. Note the wrap: the verb is on the line above.
  def test_a_dated_snapshot_at_the_top_of_plans_is_fine
    assert_empty targets("Write the full findings report and PR\n" \
                         "grouping to `~/code/claude/plans/{child}-weekly-<date>.md`.")
    assert_empty targets("Write it to `~/code/claude/plans/triage-2026-08-06.md`.")
    assert_empty targets('    date=$(date +%F); echo x > ~/code/claude/plans/run-$(date +%F).md')
  end

  # The same sentence with the date taken out is the defect, which is what makes
  # the placeholder — not the path — the thing being tested.
  def test_the_same_wrapped_sentence_without_a_date_is_reaped
    assert_equal [:reaped], rules_of("Write the full findings report and PR\n" \
                                     "grouping to `~/code/claude/plans/{child}-weekly.md`.")
  end

  # A list item starts a new thought, so the line above it must not be allowed to
  # supply the verb — otherwise every path in a bulleted list inherits the cue
  # from whatever sentence happened to precede the list.
  def test_a_list_item_does_not_inherit_the_line_above
    assert_empty targets("Write the report and commit it.\n" \
                         "- `~/code/claude/rules/scala.general.mdc` covers the style")
  end

  # A definition names its target first and says what it is for second. This is
  # the line ISS-632 actually got wrong, and the reason a cue after the path has
  # to count at all.
  def test_a_definition_line_counts_its_verb_after_the_path
    assert_equal [:unpushable], rules_of("- `LEDGER = ~/code/claude/perf-ledger.md` — records terminal outcomes")
  end

  # A finding that reports the sentence's full stop as part of the filename names
  # a file that does not exist, and the reader has to work out which one is meant.
  def test_the_path_reported_is_the_path_without_the_sentences_punctuation
    assert_equal ["pb:1: ~/code/claude/ledger.md — #{Agent::Playbook::REASONS[:unpushable]}"],
                 targets("Append it to `~/code/claude/ledger.md`.")
    assert_equal ["pb:1: ~/code/claude/ledger.md — #{Agent::Playbook::REASONS[:unpushable]}"],
                 targets("Append it (to ~/code/claude/ledger.md), then push.")
  end

  def test_the_whole_store_is_linted_for_every_rule_at_once
    rows = [
      { "key" => "clean", "body" => "Write `~/code/claude/plans/data/x.md`." },
      { "key" => "broken", "body" => "one\nwrite /Users/mbryzek/code/claude/x.md\n" },
    ]
    # Both detectors fire on that second line, and they are two distinct defects:
    # the path is wrong on every runner but this one AND unwritable on all of them.
    assert_equal %i[home_path unpushable], Agent::Playbook.lint_all(rows).map(&:rule)
  end

  # Every rule a finding can carry has a remedy, so a detector cannot ship without
  # saying what to do instead — and `REMEDIES.fetch` in the reporter would raise
  # rather than print a bare finding.
  def test_every_rule_has_a_remedy
    rules = [Agent::Playbook::HomePath, Agent::Playbook::WriteTarget]
             .flat_map { |s| s == Agent::Playbook::HomePath ? [:home_path] : Agent::Playbook::REASONS.keys }
    rules.each { |rule| assert Agent::Playbook::REMEDIES.key?(rule), "no remedy for #{rule}" }
  end

  def test_the_lint_prints_one_remedy_per_rule_it_hit
    rows = [{ "key" => "pb", "body" => "Append it to `~/code/claude/plans/ledger.md`.\n", "created_at" => VERSION }]
    out, findings = report(rows: rows, lint: true)
    assert_equal [:reaped], findings.map(&:rule)
    assert_match(%r{plans/` SUBDIRECTORY}, out)
    refute_match(/do not share a home/, out)
  end
end
