#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'agent/dependency'
require 'prs/deploy'

# The dispatch gate that asks GitHub instead of the tracker (ISS-649), and the
# hole ISS-739 found in it.
#
# `unshipped` has exactly one job — decide whether the code a blocked issue is
# about to be built on is actually on `main` — and every one of its answers is a
# dispatch decision. A false "shipped" starts a session against code that does
# not exist; a false "unshipped" defers healthy work for a day. The module had no
# test at all, which is how the closed-unmerged case shipped unnoticed.
#
# So the cases here are the whole answer space of one blocker: not shipped by the
# tracker's own reckoning, dismissed, fixed+merged+released, fixed+merged+not
# released (ISS-1097), fixed+open, fixed+closed, and every UNKNOWN (`gh` silent,
# blocker unreadable, no PR fix recorded, a state this code does not recognise, a
# release state that could not be read) — which fail OPEN by policy and must keep
# doing so, since a gate that stalls the queue whenever GitHub is unreachable is
# a worse failure than the one it prevents.
class TestAgentDependency < Minitest::Test
  include DevTestSupport

  URL = "https://github.com/mbryzek/devops/pull/359".freeze
  OTHER_URL = "https://github.com/mbryzek/platform/pull/1600".freeze
  SHA = "12bb30e3eb88061a10cb98bdd11d40d6fc9c76f8".freeze

  def issue_with_blocker(number: 633, status: "fixed")
    { "number" => "644",
      "links" => [{ "type" => "blocked_by", "direction" => "outgoing",
                    "issue" => { "number" => number, "status" => status } }] }
  end

  # A merged PR carries its merge commit — the thing a release is asked to
  # contain. `gh` returns it under `mergeCommit` for every PR that merged.
  def pr(url: URL, state: "OPEN", sha: SHA)
    { "url" => url, "state" => state, "number" => 359,
      "mergeCommit" => (state == "MERGED" && sha ? { "oid" => sha } : nil) }
  end

  # Run `unshipped` with the blocker's own record, the PR lookup, and the release
  # check stubbed. `blocker` nil stands in for an unreadable issue; `prs` maps
  # url => PR (or nil, which is what `gh` returns for every unknown); `release`
  # is what Prs::Deploy says about a merge commit — :shipped by default, so a
  # test that says nothing about releases is testing the merge half alone.
  def unshipped(issue, blocker: nil, prs: {}, release: :shipped)
    with_stubs(blocker: blocker, prs: prs, release: release) do
      Agent::Dependency.unshipped(issue, use_localhost: false)
    end
  end

  # `release: :real` leaves Prs::Deploy alone — for the cases it answers without
  # asking GitHub anything, which are the ones worth exercising unstubbed.
  def with_stubs(blocker:, prs:, release:, &block)
    stub_singleton(Agent::Api, :issue, lambda { |*, **|
      raise ApiError, "500 from the platform" if blocker == :error
      blocker
    }) do
      stub_singleton(Agent::Github, :pr_by_url, ->(url) { prs[url] }) do
        if release == :real
          block.call
        else
          stub_singleton(Prs::Deploy, :state, lambda { |repo, sha, **|
            release.is_a?(Proc) ? release.call(repo, sha) : release
          }, &block)
        end
      end
    end
  end

  def fixed_blocker(*urls) = { "fixes" => urls.map { |u| { "url" => u } } }

  # ---- the tracker's own rule, agreed with rather than re-derived ----

  def test_a_blocker_that_is_not_terminal_blocks_on_its_status_alone
    result = unshipped(issue_with_blocker(status: "claimed"))
    assert_equal [{ "number" => 633, "status" => "claimed", "pr" => nil, "state" => :working }], result
    assert_equal ["ISS-633 is still `claimed`"], Agent::Dependency.describe(result)
  end

  # Nobody is ever going to ship it, so deferring on it would defer forever.
  def test_a_dismissed_blocker_never_blocks
    assert_empty unshipped(issue_with_blocker(status: "dismissed"))
  end

  def test_an_issue_with_no_blockers_dispatches
    assert_empty unshipped({ "number" => "644", "links" => [] })
    assert_empty unshipped({ "number" => "644" })
  end

  # ---- fixed, with GitHub as the authority ----

  def test_a_merged_fix_dispatches
    assert_empty unshipped(issue_with_blocker,
                           blocker: fixed_blocker(URL), prs: { URL => pr(state: "MERGED") })
  end

  # ---- ISS-1105: an open fix blocks, whatever else on the list merged ----
  #
  # THE bug. One change spanning repos is closed out as one `--status fixed --url`
  # plus a `dev issues fix --url` per sibling (ISS-759), so a fix list is
  # CONCURRENT as often as it is sequential, and every url on it has to merge
  # before the code a dependent builds on exists. Reading one merge as "shipped"
  # dispatched ISS-1009 against an Elm contract change still sitting in an open PR.
  def test_an_open_fix_blocks_even_when_a_sibling_fix_merged
    result = unshipped(issue_with_blocker,
                       blocker: fixed_blocker(URL, OTHER_URL),
                       prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
    assert_equal 1, result.size, "the merged sibling says nothing about the open one"
    assert_equal OTHER_URL, result.first["pr"]["url"]
  end

  # Recording order does not matter: it is the OPEN url that is named, not the
  # last one written down.
  def test_the_open_fix_is_named_however_the_list_is_ordered
    result = unshipped(issue_with_blocker,
                       blocker: fixed_blocker(OTHER_URL, URL),
                       prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
    assert_equal OTHER_URL, result.first["pr"]["url"]
  end

  # ISS-998 as it actually happened, end to end: two recorded fixes, the platform
  # one merged, the hoa-frontend one open. This is the state ISS-1009 was woken
  # and dispatched on.
  def test_the_iss998_shape_defers_rather_than_dispatching
    platform = "https://github.com/mbryzek/platform/pull/2230"
    frontend = "https://github.com/mbryzek/hoa-frontend/pull/107"
    blocker = { "fixes" => [{ "url" => platform }, { "url" => frontend }] }
    prs = { platform => pr(url: platform, state: "MERGED"), frontend => pr(url: frontend, state: "OPEN") }

    result = unshipped(issue_with_blocker(number: 998), blocker: blocker, prs: prs)
    assert_equal ["ISS-998 is `fixed`, but its fix #{frontend} has not merged"],
                 Agent::Dependency.describe(result)
    refute cleared?(issue_with_blocker(number: 998), blocker: blocker, prs: prs),
           "the wake sweep is what actually fired here — it must not clear either"
  end

  # The case the old `any?` rule was written for, and the cost this change
  # accepts: a reopened issue whose round-1 fix merged and whose round-2 fix is
  # still open now holds its dependents. Nothing on a fix list says which ROUND a
  # url belongs to, so the two shapes are indistinguishable and this picks the
  # recoverable failure — a deferral, re-checked daily and escalated to a human
  # after seven attempts — over dispatching against code that is not on main.
  def test_a_reopened_issues_later_open_fix_now_defers_too
    refute_empty unshipped(issue_with_blocker,
                           blocker: fixed_blocker(URL, OTHER_URL),
                           prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
  end

  # A CLOSED-unmerged fix is deliberately not promoted the same way: abandoned,
  # superseded, or rewritten under the url that did land. It still loses to a
  # merge elsewhere on the list, because nothing about it will ever change and
  # blocking on it has no daily merge to end it (ISS-739 keeps its scope).
  def test_a_closed_fix_beside_a_merged_one_still_dispatches
    assert_empty unshipped(issue_with_blocker,
                           blocker: fixed_blocker(URL, OTHER_URL),
                           prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "CLOSED") })
  end

  def test_an_open_fix_blocks_and_names_the_pr
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr })
    assert_equal 1, result.size
    assert_equal URL, result.first["pr"]["url"]
    assert_equal ["ISS-633 is `fixed`, but its fix #{URL} has not merged"], Agent::Dependency.describe(result)
  end

  # ---- ISS-739: the answer that used to be silently "shipped" ----

  # The whole bug. Marked `fixed`, one recorded fix, and that PR was closed
  # without merging — nothing landed, and the old code answered nil, which the
  # caller reads as "dispatch is safe".
  def test_a_fix_closed_without_merging_still_blocks
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: "CLOSED") })
    assert_equal 1, result.size, "a closed-unmerged fix shipped nothing — that is unshipped, not unknown"
    assert_equal URL, result.first["pr"]["url"]
  end

  # …and says so in words that cannot be read as "not yet". This deferral loop
  # only ends with a human, unlike the open-PR one.
  def test_the_note_distinguishes_closed_from_merely_unmerged
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: "CLOSED") })
    line = Agent::Dependency.describe(result).first
    assert_includes line, "CLOSED WITHOUT MERGING"
    refute_includes line, "has not merged"
  end

  # ---- ISS-1085: the same wording, wherever it is read ----

  # `dev issues show` prints the blocker's number, status and title on its own
  # line, so it wants the PR clause WITHOUT the "ISS-N is `fixed`" half the
  # deferral comment carries. Both come from `pr_reason`, so the note a session
  # reads on the timeline and the line a human reads before claiming cannot become
  # two different accounts of one PR.
  def test_the_pr_clause_is_the_tail_of_the_sentence_the_dispatcher_writes
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr })
    assert_equal "its fix #{URL} has not merged", Agent::Dependency.pr_reason(result.first)
    assert_includes Agent::Dependency.describe(result).first, Agent::Dependency.pr_reason(result.first)
  end

  # No PR to name, so there is no second line to print: the blocker never reached
  # a shipped status, and the status already on the line is the whole reason.
  def test_a_blocker_with_no_pr_has_no_clause
    result = unshipped(issue_with_blocker(status: "claimed"))
    assert_nil Agent::Dependency.pr_reason(result.first)
  end

  # An open fix outranks a closed one: it is the PR that will actually ship, and
  # naming it is what makes the deferral note actionable.
  def test_an_open_fix_is_named_over_a_closed_one
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                       prs: { URL => pr(state: "CLOSED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
    assert_equal OTHER_URL, result.first["pr"]["url"]
  end

  # Among several closed fixes, the LAST RECORDED one — fixes span repos, where
  # PR numbers are not comparable, so the recorded order is the only chronology.
  def test_the_last_recorded_closed_fix_is_the_one_named
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                       prs: { URL => pr(state: "CLOSED"), OTHER_URL => pr(url: OTHER_URL, state: "CLOSED") })
    assert_equal OTHER_URL, result.first["pr"]["url"]
  end

  # `deployed` and `verified` are past `fixed` on the ladder and get the same
  # treatment: the status is still the tracker's word, not GitHub's.
  def test_the_github_check_covers_every_shipped_status
    %w[fixed deployed verified].each do |status|
      result = unshipped(issue_with_blocker(status: status),
                         blocker: fixed_blocker(URL), prs: { URL => pr(state: "CLOSED") })
      assert_equal 1, result.size, "#{status} must still be checked against GitHub"
    end
  end

  # ---- fail open, everywhere an answer is UNKNOWN ----

  # `gh` missing, unauthenticated, rate-limited, or the url naming no PR. Not
  # knowing is not the same as knowing it did not merge, and a gate that stalls
  # the queue whenever GitHub is unreachable is the worse failure.
  def test_an_unreachable_github_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => nil })
  end

  # One unknown among several is still an unknown: the merged one might be the
  # one that could not be read.
  def test_one_unreadable_pr_among_several_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                           prs: { URL => pr(state: "CLOSED"), OTHER_URL => nil })
  end

  def test_a_blocker_whose_record_cannot_be_read_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: nil)
    assert_empty unshipped(issue_with_blocker, blocker: :error)
  end

  # A fix that is a design document, not a PR: there is no merge to wait for.
  def test_a_non_pr_fix_dispatches
    blocker = { "fixes" => [{ "url" => "https://github.com/mbryzek/claude/blob/main/plans/x.md" }] }
    assert_empty unshipped(issue_with_blocker, blocker: blocker)
    assert_empty unshipped(issue_with_blocker, blocker: { "fixes" => [] })
  end

  # A state this code does not recognise is an unknown too — `closed?` is
  # deliberately not "anything that is not open".
  def test_an_unrecognised_pr_state_dispatches
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL),
                           prs: { URL => pr(state: "SOMETHING_NEW") })
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: nil) })
  end

  # ---- ISS-922: `cleared?`, the same question asked from the other side ----
  #
  # `unshipped` decides whether to DISPATCH and fails open, so every unknown
  # answers []. `cleared?` decides whether to WAKE an issue already parked, and
  # inverting [] would turn a `gh` blip into a fleet-wide unsnooze. These cases
  # are the ones where the two must disagree.

  def cleared?(issue, blocker: nil, prs: {}, release: :shipped)
    with_stubs(blocker: blocker, prs: prs, release: release) do
      Agent::Dependency.cleared?(issue, use_localhost: false)
    end
  end

  def test_a_merged_fix_clears_the_deferral
    assert cleared?(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr(state: "MERGED") })
  end

  def test_an_open_fix_does_not_clear_the_deferral
    refute cleared?(issue_with_blocker, blocker: fixed_blocker(URL), prs: { URL => pr })
  end

  # The whole safety argument. Every one of these dispatches through `unshipped`
  # by design; none of them is evidence of a merge, so none of them wakes.
  def test_every_unknown_leaves_the_deferral_in_place
    { "an unreachable github" => [fixed_blocker(URL), { URL => nil }],
      "an unreadable blocker" => [nil, {}],
      "a blocker read that raised" => [:error, {}],
      "a fix that is a document" => [{ "fixes" => [{ "url" => "https://github.com/mbryzek/claude/blob/main/plans/x.md" }] }, {}],
      "no fix recorded at all" => [{ "fixes" => [] }, {}],
      "an unrecognised pr state" => [fixed_blocker(URL), { URL => pr(state: "SOMETHING_NEW") }] }
      .each do |label, (blocker, prs)|
      assert_empty unshipped(issue_with_blocker, blocker: blocker, prs: prs),
                   "#{label} must still DISPATCH — the gate fails open"
      refute cleared?(issue_with_blocker, blocker: blocker, prs: prs),
             "#{label} is not evidence of a merge, so it must not wake a deferral"
    end
  end

  # EVERY recorded fix, not any (ISS-1105). This sweep is what actually woke
  # ISS-1009: one merge among two is not the code being on main, and the note it
  # writes says "there is nothing left to wait for".
  def test_an_open_fix_beside_a_merged_one_does_not_clear
    refute cleared?(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                    prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") })
  end

  def test_every_recorded_fix_merging_clears
    assert cleared?(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                    prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "MERGED") })
  end

  # A url `gh` could not read now counts AGAINST waking. Under `any?` it could be
  # ignored, because one positive merge was the whole bar; under `all?` it is a
  # fix that has not been SHOWN to merge, and this side has always required
  # positive evidence. Costs a day at most; the claim-time gate still fails open.
  def test_a_merged_fix_beside_an_unreadable_one_does_not_clear
    refute cleared?(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                    prs: { URL => pr(state: "MERGED"), OTHER_URL => nil })
  end

  # A blocker still being worked has nothing merged to find, whatever GitHub says.
  def test_a_live_blocker_never_clears
    refute cleared?(issue_with_blocker(status: "claimed"))
  end

  # Nobody is ever going to ship it, so there is no merge to wait for — the one
  # place this agrees with the tracker's status by itself.
  def test_a_dismissed_blocker_clears
    assert cleared?(issue_with_blocker(status: "dismissed"))
  end

  # What `dev issues block --remove` leaves behind, which is exactly what the
  # escalation note asks a human to produce.
  def test_an_issue_whose_edge_was_removed_clears
    assert cleared?({ "number" => "644", "links" => [] })
  end

  # EVERY blocker, not any: one still-open fix holds the issue even when the
  # other merged.
  def test_one_unmerged_blocker_among_several_holds_the_deferral
    issue = { "number" => "644",
              "links" => [{ "type" => "blocked_by", "direction" => "outgoing",
                            "issue" => { "number" => 633, "status" => "fixed" } },
                          { "type" => "blocked_by", "direction" => "outgoing",
                            "issue" => { "number" => 634, "status" => "claimed" } }] }
    refute cleared?(issue, blocker: fixed_blocker(URL), prs: { URL => pr(state: "MERGED") })
  end

  # ---- ISS-1097: merged is not live ----
  #
  # ISS-1024 said it in as many words: "Once workers#207 is merged AND the workers
  # deploy is live, retry the held windows. Retrying BEFORE the fix is live only
  # burns four more attempts." The gate read the first half, woke it at 16:09 with
  # #207 merged at 16:08 and the newest workers tag still at 0.1.77, and the
  # session that claimed it four minutes later could do nothing at all.
  #
  # Both directions move together, always. A wake looser than the gate wakes an
  # issue the claim behind it re-defers on sight, walking it toward the
  # seven-attempt escalation for nothing.

  def merged_pr = { URL => pr(state: "MERGED") }

  def test_a_merged_but_unreleased_fix_blocks
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL),
                       prs: merged_pr, release: :unshipped)
    assert_equal 1, result.size, "the code is on main and not in production — that is not landed"
    assert_equal :unreleased, result.first["state"]
    assert_equal URL, result.first["pr"]["url"]
  end

  def test_a_merged_but_unreleased_fix_does_not_wake_a_deferral
    refute cleared?(issue_with_blocker, blocker: fixed_blocker(URL),
                    prs: merged_pr, release: :unshipped)
  end

  def test_a_merged_and_released_fix_both_dispatches_and_wakes
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: merged_pr, release: :shipped)
    assert cleared?(issue_with_blocker, blocker: fixed_blocker(URL), prs: merged_pr, release: :shipped)
  end

  # …and says so in words that cannot be read as "not merged", which is flatly
  # false about a commit sitting on main and is the confusion this was filed
  # about. It names the repo, because "release the thing" is the action.
  def test_the_note_distinguishes_unreleased_from_unmerged
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL),
                       prs: merged_pr, release: :unshipped)
    line = Agent::Dependency.describe(result).first
    assert_includes line, "merged and has NOT been released"
    assert_includes line, "not in the newest `devops` release"
    refute_includes line, "has not merged"
    # …and `dev issues show` prints the same clause, from the same source (ISS-1085).
    assert_includes line, Agent::Dependency.pr_reason(result.first)
  end

  # devops, and it is the most common blocker repo in this fleet: nothing builds
  # or ships it, every runner fast-forwards its checkout at the top of every tick,
  # so merging IS deploying. Waiting for a tag there would park every
  # devops-blocked issue until the daily expiry — undoing ISS-922 for the
  # majority case in the name of a release nobody is ever going to cut.
  def test_a_repo_that_publishes_no_releases_counts_as_landed_on_merge
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL),
                           prs: merged_pr, release: :unreleasable)
    assert cleared?(issue_with_blocker, blocker: fixed_blocker(URL),
                    prs: merged_pr, release: :unreleasable)
  end

  # A release state that could not be read is an unknown like any other: it
  # DISPATCHES (the gate fails open) and it does not WAKE (an unreadable GitHub
  # is not evidence that anything shipped).
  def test_an_unreadable_release_state_dispatches_but_does_not_wake
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL),
                           prs: merged_pr, release: :unknown)
    refute cleared?(issue_with_blocker, blocker: fixed_blocker(URL),
                    prs: merged_pr, release: :unknown)
  end

  # The second compounding cause. `fixed -> deployed -> verified` is a one-way
  # ladder a session can walk by hand, and ISS-1012 reached `verified` at 16:03
  # for a PR that merged at 16:08 — five minutes in the future. Any check reading
  # "is the blocker at deployed-or-better" clears on that. This reads the commit.
  def test_a_status_past_deployed_is_not_evidence_that_anything_shipped
    %w[fixed deployed verified].each do |status|
      issue = issue_with_blocker(status: status)
      refute_empty unshipped(issue, blocker: fixed_blocker(URL), prs: merged_pr, release: :unshipped),
                   "#{status} is the tracker's word, not a release"
      refute cleared?(issue, blocker: fixed_blocker(URL), prs: merged_pr, release: :unshipped),
             "#{status} must not wake an issue whose blocker is not in a release"
    end
  end

  # The repo comes from the fix url — the only place a blocker's repo is written
  # down — and the sha from the PR's merge commit, which is what a release is
  # asked to contain.
  def test_the_release_check_is_asked_about_the_fixs_own_repo_and_merge_commit
    asked = []
    unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: merged_pr,
              release: ->(repo, sha) { asked << [repo, sha]; :shipped })
    assert_equal [["devops", SHA]], asked
  end

  # A merged PR whose merge commit `gh` did not return is an UNKNOWN, not a
  # release failure — no stub here, because Prs::Deploy answers that without
  # asking GitHub anything.
  def test_a_merged_pr_with_no_merge_commit_is_unknown
    prs = { URL => pr(state: "MERGED", sha: nil) }
    assert_empty unshipped(issue_with_blocker, blocker: fixed_blocker(URL), prs: prs, release: :real)
    refute cleared?(issue_with_blocker, blocker: fixed_blocker(URL), prs: prs, release: :real)
  end

  # …which it can only do because the field is asked for. `gh search prs` cannot
  # return it, which is why SEARCH_FIELDS is a separate list.
  def test_the_pr_lookup_asks_for_the_merge_commit
    assert_includes Agent::Github::PR_FIELDS, "mergeCommit"
    refute_includes Agent::Github::SEARCH_FIELDS, "mergeCommit"
  end

  # Deferrals cluster on the same blocking PR — that is what a shared dependency
  # IS — so a sweep over twenty issues waiting on one merge asks GitHub once.
  def test_the_release_oracle_memoises_per_repo_and_sha
    calls = 0
    stub_singleton(Prs::Deploy, :state, lambda { |_repo, _sha, **|
      calls += 1
      :shipped
    }) do
      oracle = Agent::Dependency.release_oracle
      3.times { assert_equal :shipped, oracle.call("workers", SHA) }
      oracle.call("workers", "other")
    end
    assert_equal 2, calls
  end

  # An open PR still outranks an unreleased merge in the note: it is the one that
  # has not landed at all, and naming it is what makes the deferral actionable.
  def test_an_open_fix_is_named_over_an_unreleased_one
    result = unshipped(issue_with_blocker, blocker: fixed_blocker(URL, OTHER_URL),
                       prs: { URL => pr(state: "MERGED"), OTHER_URL => pr(url: OTHER_URL, state: "OPEN") },
                       release: :unshipped)
    assert_equal OTHER_URL, result.first["pr"]["url"]
    assert_equal :open, result.first["state"]
  end

  # ---- ISS-922: the attempt count is CONSECUTIVE, not a running total ----

  def defer(n = 1) = Array.new(n) { { "body" => "Snoozed until whenever. #{Agent::Dependency::DEFER_MARKER} — attempt x of 7." } }
  def wake_note = { "body" => "#{Agent::Dependency::WAKE_MARKER}.\n\nEverything landed." }
  def platform_wake = { "body" => "#{Agent::Dependency::PLATFORM_WAKE_MARKER}." }

  def test_deferrals_accumulate_while_an_issue_stays_blocked
    assert_equal 0, Agent::Dependency.defer_attempts([])
    assert_equal 3, Agent::Dependency.defer_attempts(defer(3))
  end

  # The escalation means "a week of daily checks has not cleared it". An issue
  # that WAS cleared, dispatched, and later blocked again on a different PR is
  # not that, and a running total would push it to needs_input on history that
  # is no longer about anything.
  def test_a_wake_resets_the_run
    assert_equal 1, Agent::Dependency.defer_attempts(defer(4) + [wake_note] + defer(1))
    assert_equal 0, Agent::Dependency.defer_attempts(defer(4) + [wake_note])
  end

  # A human clearing the snooze by hand — `dev issues snooze --wake`, or the
  # button in playbook-admin — ends the run for the same reason, and it is the
  # note the platform writes on the sweep's own DELETE too.
  def test_the_platforms_own_wake_note_resets_the_run
    assert_equal 2, Agent::Dependency.defer_attempts(defer(5) + [platform_wake] + defer(2))
  end

  # Only the LAST wake, and only what came after it.
  def test_only_the_most_recent_wake_counts
    comments = defer(2) + [wake_note] + defer(3) + [platform_wake] + defer(1)
    assert_equal 1, Agent::Dependency.defer_attempts(comments)
  end

  # Unrelated chatter between a wake and the next deferral changes nothing.
  def test_other_comments_are_ignored
    comments = defer(1) + [{ "body" => "Claimed by Mac." }, wake_note, { "body" => nil }] + defer(2)
    assert_equal 2, Agent::Dependency.defer_attempts(comments)
  end
end
