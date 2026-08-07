#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-759: one run, several INDEPENDENT units of work.
#
# A weekly review confirms four unrelated defects and correctly opens four
# independent PRs — but before this they all carried the one issue number the run
# was assigned, and a status write takes exactly one url. The rest were appended
# as extra fixes on the same issue and could not be closed out, deployed,
# verified or auto-merged apart from each other. Measured 2026-08-06: ISS-735
# carried devops #371-#375, ISS-723 carried platform #2138-#2140.
#
# `dev issues split` is the fix, and the properties under test are the ones that
# make it usable unattended:
#
#   1. the FIRST call promotes the assigned issue into an epic and adopts it, so
#      the PR it already has stays attached to a unit of work;
#   2. a later call — and an issue that already had an epic — reuses it, rather
#      than filing a second container;
#   3. the child is CLAIMED, inherits what it should, and says which number its
#      PR carries;
#   4. a promotion that half-succeeds says so loudly. An epic with no children is
#      claimed by nothing, rolled up by nothing and deleted by nothing.
class TestDevIssuesSplit < Minitest::Test
  include DevTestSupport

  SOURCE_NUMBER = "735".freeze

  def source_issue(overrides = {})
    {
      "id" => "iss-735",
      "number" => SOURCE_NUMBER,
      "category" => "improvement",
      "type" => "issue",
      "status" => "claimed",
      "severity" => "medium",
      "title" => "Weekly code review: devops",
      "body" => "Review the last week of changes to devops and ship the fixes.",
      "repositories" => ["devops"],
      "occurrence_count" => 1,
    }.merge(overrides)
  end

  def filed_epic
    { "id" => "iss-770", "number" => "770", "type" => "epic", "status" => "open",
      "category" => "improvement", "title" => "Weekly code review: devops" }
  end

  def filed_child
    { "id" => "iss-771", "number" => "771", "type" => "issue", "status" => "claimed",
      "category" => "bug", "title" => "404 handler swallows the upstream status" }
  end

  def split_args(overrides = {})
    args = {
      "--title" => "404 handler swallows the upstream status",
      "--body" => "Agent::Github.capture reads a failure as no output, so a 404 reads as no PR.",
    }.merge(overrides)
    [SOURCE_NUMBER] + args.reject { |_flag, value| value.nil? }.flat_map { |flag, value| [flag, value] }
  end

  # `POST /issues` is BOTH creates (the epic and the child), so the stub has to
  # tell them apart the way the server would — by the form.
  def run_split(args = split_args, source: source_issue, epic: filed_epic, child: filed_child, sink: {})
    responses = {
      "GET #{issues_path("/#{SOURCE_NUMBER}")}" => ->(_body) { source },
      "PUT #{issues_path("/#{SOURCE_NUMBER}")}" => lambda { |body|
        sink[:adopt] = body
        source.merge("parent" => { "number" => epic.fetch("number"), "title" => epic.fetch("title"), "status" => "open" })
      },
      "POST #{issues_path}" => lambda { |body|
        if body[:type] == "epic"
          sink[:epic] = body
          epic
        else
          sink[:child] = body
          child
        end
      },
      "POST #{issues_path("/#{SOURCE_NUMBER}/comments")}" => ->(body) { sink[:note] = body; {} },
    }
    out = with_stubbed_api(responses) { capture_stdout { cmd_issues_split(args) } }
    [out, sink]
  end

  # ---- 1. the first split promotes ----

  # The epic takes the run's own title and attribution: the run is what the epic
  # IS, and the children are what it found.
  def test_the_first_split_files_an_epic_carrying_the_issues_own_identity
    _out, sink = run_split
    assert_equal "epic", sink[:epic][:type]
    assert_equal "Weekly code review: devops", sink[:epic][:title]
    assert_equal "improvement", sink[:epic][:category]
    assert_equal ["devops"], sink[:epic][:repositories]
    assert_equal false, sink[:epic][:claim_on_create]
  end

  # An epic is a container. Claiming one is refused server-side, and a claimed
  # container would be work no session could ever pick up.
  def test_the_epic_is_never_claimed
    _out, sink = run_split
    refute sink[:epic][:claim_on_create]
  end

  # The source is ADOPTED rather than left beside the epic: it is the run itself
  # and the first of the changes, and it already has a PR.
  def test_the_source_issue_is_adopted_as_the_first_child
    _out, sink = run_split
    assert_equal "770", sink[:adopt][:parent_number]
    # The update endpoint replaces every editable field, so the round-trip has to
    # send the issue's own values back or re-parenting silently clears them —
    # `repositories` is the one that already went missing once (ISS-365).
    assert_equal ["devops"], sink[:adopt][:repositories]
    assert_equal "Weekly code review: devops", sink[:adopt][:title]
    assert_equal "medium", sink[:adopt][:severity]
    assert_equal "issue", sink[:adopt][:type]
  end

  # `fingerprint` and `producer_key` are server-owned and never rewritten by an
  # update, and this asserts the CLI does not try: adopting a producer-filed issue
  # must not cost it the dedup key its producer files against every week.
  def test_adopting_never_sends_the_server_owned_columns
    _out, sink = run_split(source: source_issue("fingerprint" => "weekly-review:devops",
                                                "producer_key" => "weekly-review-devops"))
    refute sink[:adopt].key?(:fingerprint)
    refute sink[:adopt].key?(:producer_key)
  end

  # The epic carries no producer attribution, and the omission is load-bearing:
  # a child inherits its epic's producer_key, and ProducerIssueEmitter's
  # `{datetime}` guard suppresses a producer with any issue in open or claimed.
  # An attributed epic sits open until its last child ships — which would stop a
  # sub-daily producer firing for as long as one review's PRs sat unmerged.
  def test_the_epic_carries_no_producer_key_or_fingerprint
    _out, sink = run_split(source: source_issue("fingerprint" => "weekly-review:devops",
                                                "producer_key" => "weekly-review-devops"))
    refute sink[:epic].key?(:producer_key)
    refute sink[:epic].key?(:fingerprint)
  end

  # ---- 2. later splits reuse the epic ----

  def test_an_issue_that_already_has_an_epic_files_no_second_container
    parented = source_issue("parent" => { "number" => "755", "title" => "Get out of the merge path", "status" => "open" })
    out, sink = run_split(source: parented)
    assert_nil sink[:epic], "a second epic was filed for an issue that already had one"
    assert_nil sink[:adopt], "an issue that already had an epic was re-parented anyway"
    assert_equal "755", sink[:child][:parent_number]
    assert_match(/already this issue's epic/, out)
  end

  # ---- 3. the child ----

  # Always claimed, and there is deliberately no --status: a split names work THIS
  # session is about to do. An `open` child would hold the epic open until somebody
  # claimed it, and a side finding swept into an epic is closed out silently when
  # the epic is verified, with nobody having looked at it.
  def test_the_child_is_filed_claimed_under_the_epic
    _out, sink = run_split
    assert_equal true, sink[:child][:claim_on_create]
    assert_equal "770", sink[:child][:parent_number]
    assert_equal "404 handler swallows the upstream status", sink[:child][:title]
  end

  def test_the_child_inherits_category_severity_and_repos
    _out, sink = run_split
    assert_equal "improvement", sink[:child][:category]
    assert_equal "medium", sink[:child][:severity]
    assert_equal ["devops"], sink[:child][:repositories]
  end

  # A review finds bugs under an issue filed as an improvement, and a finding can
  # live in a repo the run was not assigned.
  def test_explicit_category_severity_and_repos_win
    _out, sink = run_split(split_args("--category" => "bug", "--severity" => "high", "--repo" => "platform"))
    assert_equal "bug", sink[:child][:category]
    assert_equal "high", sink[:child][:severity]
    assert_equal ["platform"], sink[:child][:repositories]
  end

  def test_the_child_body_carries_the_finding_and_the_run_that_found_it
    _out, sink = run_split
    assert_match(/reads a failure as no output/, sink[:child][:body])
    assert_match(/Split out of ISS-735/, sink[:child][:body])
  end

  # Both directions, as `workaround` and `handoff` do it: the epic's child list
  # leads one way, and this note is what a human scanning ISS-735's own timeline
  # sees.
  def test_the_split_is_noted_on_the_source_issue
    _out, sink = run_split
    assert_match(/Split ISS-771 out of this run/, sink[:note][:body])
    assert_equal "internal", sink[:note][:visibility]
  end

  # The output is the whole interface for an unattended session: it has to say
  # which number the PR carries and how the child closes out, or the session falls
  # back to the assigned issue's number and nothing has changed.
  def test_the_output_names_the_prs_title_prefix_and_the_close_out
    out, _sink = run_split
    assert_match(/ISS-771: /, out)
    assert_match(/dev issues status 771 --status fixed --url/, out)
    assert_match(/Do NOT verify it/, out)
    assert_match(/<assigned>_<suffix>/, out)
  end

  # ---- 4. failure modes ----

  # An epic filed whose adopt then fails is a container nothing claims, nothing
  # rolls up and no command deletes — only `dismissed`. The session that would
  # notice is unattended, so the recovery command has to be in the error.
  def test_a_failed_adopt_stops_and_prints_the_recovery_command
    responses = {
      "GET #{issues_path("/#{SOURCE_NUMBER}")}" => ->(_body) { source_issue },
      "POST #{issues_path}" => ->(_body) { filed_epic },
      "PUT #{issues_path("/#{SOURCE_NUMBER}")}" => ->(_body) { raise ApiError, "500 internal error" },
    }
    out, status = capture_stderr_and_exit do
      with_stubbed_api(responses) { capture_stdout { cmd_issues_split(split_args) } }
    end
    assert_equal 1, status
    assert_match(/could not be adopted/, out)
    assert_match(/dev issues parent 735 --epic 770/, out)
  end

  # An epic holds no work of its own, so there is nothing in it to split — and the
  # command that IS wanted here is one flag away.
  def test_splitting_an_epic_is_refused_with_the_command_that_was_meant
    out, status = capture_stderr_and_exit do
      with_stubbed_api("GET #{issues_path("/#{SOURCE_NUMBER}")}" => ->(_body) { source_issue("type" => "epic") }) do
        capture_stdout { cmd_issues_split(split_args) }
      end
    end
    assert_equal 1, status
    assert_match(/already an EPIC/, out)
    assert_match(/--parent 735/, out)
  end

  # ---- arg validation (no network: these exit before the credential guard) ----

  def test_the_issue_number_title_and_body_are_all_required
    out, status = capture_stderr_and_exit { cmd_issues_split([]) }
    assert_equal 1, status
    assert_match(/missing issue number/, out)
    assert_match(/--title is required/, out)
    assert_match(/--body is required/, out)
  end

  # The number is positional and the flag loop runs FIRST, so it cannot be shifted
  # off the front — `issues parent` shipped that bug and reported a missing flag
  # about a command line that had passed it.
  def test_the_number_is_found_after_the_flags_wherever_it_sits
    _out, sink = run_split(["--title", "t", "--body", "b", SOURCE_NUMBER])
    assert_equal "t", sink[:child][:title]
  end

  def test_an_unknown_category_is_refused_by_name
    out, status = capture_stderr_and_exit { cmd_issues_split(split_args("--category" => "graphs")) }
    assert_equal 1, status
    assert_match(/--category must be one of/, out)
    assert_match(/inherit ISS-735/, out)
  end

  def test_an_unknown_severity_is_refused
    out, status = capture_stderr_and_exit { cmd_issues_split(split_args("--severity" => "urgent")) }
    assert_equal 1, status
    assert_match(/--severity must be one of/, out)
  end

  def test_an_unexpected_argument_is_reported
    out, status = capture_stderr_and_exit { cmd_issues_split(split_args + ["--epic", "770"]) }
    assert_equal 1, status
    assert_match(/unexpected argument/, out)
  end

  # ---- the command is reachable and documented ----

  def test_the_subcommand_is_registered_and_documented
    assert_includes SUBCOMMANDS.fetch("issues"), "split"
    assert INVOCATIONS.key?("issues split")
    %w[--title --body --repo --category --severity].each do |flag|
      assert_includes usage_for("issues split"), flag
    end
  end
end
