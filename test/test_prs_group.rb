#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'prs/group'
require 'prs/deploy'

# ISS-758: a change that spans repos must not merge a consumer ahead of its
# producer.
#
# Everything under test here is the DECISION — group, order, hold — and none of
# it touches the network: GitHub and the deploy probe arrive as lambdas, so a
# test states the world and asserts the verdict.
#
# The case these were written from is ISS-698: `platform-postgresql#514` (merged),
# `platform#2133`, `playbook-admin#815` and `playbook-app#460`, all on branch
# `i698_sbd`, where merging either frontend before platform ships is the
# playbook-admin #760 failure — a swallowed 404 that renders as "No data".
class TestPrsGroup < Minitest::Test
  include DevTestSupport

  SCALA = %w[platform acumen].freeze

  def pr(repo:, number:, branch: "i698_sbd", state: "OPEN", draft: false, body: "", sha: nil)
    { "repository" => repo, "number" => number, "headRefName" => branch, "state" => state,
      "isDraft" => draft, "body" => body, "title" => "ISS-698: x",
      "url" => "https://github.com/mbryzek/#{repo}/pull/#{number}",
      "mergeCommit" => sha ? { "oid" => sha } : nil }
  end

  def build(prs, deployed: ->(_r, _s) { nil }, lookup: ->(_r, _n) { nil })
    Prs::Group.build(prs, scala_repos: SCALA, deployed: deployed, lookup: lookup)
  end

  def one(prs, **kwargs) = build(prs, **kwargs).first

  def verdicts(group) = group.members.to_h { |m| [m.key, m.verdict] }

  # ---- roles and order ----

  def test_role_is_read_from_the_repo_name_and_the_scala_registry
    assert_equal :schema, Prs::Group.role("platform-postgresql", scala_repos: SCALA)
    assert_equal :library, Prs::Group.role("lib-util", scala_repos: SCALA)
    assert_equal :producer, Prs::Group.role("mbryzek/platform", scala_repos: SCALA)
    assert_equal :consumer, Prs::Group.role("playbook-admin", scala_repos: SCALA)
    assert_equal :self_deploying, Prs::Group.role("devops", scala_repos: SCALA)
  end

  # `platform` is only a producer because the registry says it is a scala app.
  # Hardcoding that list here is the drift this parameter exists to avoid.
  def test_a_repo_the_registry_does_not_call_scala_is_a_consumer
    assert_equal :consumer, Prs::Group.role("platform", scala_repos: [])
  end

  def test_members_are_ordered_schema_then_library_then_producer_then_consumer
    group = one([pr(repo: "playbook-admin", number: 815),
                 pr(repo: "platform", number: 2133),
                 pr(repo: "platform-postgresql", number: 514),
                 pr(repo: "lib-util", number: 9)])
    assert_equal %w[platform-postgresql#514 lib-util#9 platform#2133 playbook-admin#815],
                 group.members.map(&:key)
  end

  # ---- grouping ----

  def test_prs_sharing_a_head_branch_across_repos_are_one_group
    groups = build([pr(repo: "platform", number: 2133),
                    pr(repo: "playbook-admin", number: 815),
                    pr(repo: "rallyd", number: 7, branch: "i713_atc")])
    assert_equal %w[i698_sbd i713_atc], groups.map(&:branch)
    assert groups.first.cross_repo?
    refute groups.last.cross_repo?
  end

  # `<branch>_<suffix>` is the ISS-657 convention for several INDEPENDENT PRs
  # from one run. Folding those into the parent's group would invent an ordering
  # the contract says is not there — so they stay separate, and the parent is
  # named as a possible drift for a human to judge.
  def test_a_suffixed_branch_is_its_own_group_and_is_flagged_not_joined
    groups = build([pr(repo: "platform", number: 2133, branch: "i735_tej"),
                    pr(repo: "devops", number: 400, branch: "i735_tej_404")])
    assert_equal 2, groups.length
    drifted = groups.find { |g| g.branch == "i735_tej_404" }
    assert_equal ["i735_tej"], drifted.suspected_drift
    assert_empty groups.find { |g| g.branch == "i735_tej" }.suspected_drift
  end

  def test_a_pr_with_no_head_branch_is_not_a_group
    assert_empty build([pr(repo: "platform", number: 1, branch: "")])
  end

  # ---- inferred ordering ----

  def test_a_consumer_holds_while_its_producer_is_still_open
    group = one([pr(repo: "platform", number: 2133),
                 pr(repo: "playbook-admin", number: 815)])
    assert_equal :eligible, verdicts(group)["platform#2133"]
    assert_equal :waits_on_merge, verdicts(group)["playbook-admin#815"]
    assert_match(/platform#2133 has not merged/, group.members.last.reason)
  end

  # The ISS-758 case in one assertion: merged is NOT enough.
  def test_a_consumer_holds_while_its_merged_producer_has_not_deployed
    prs = [pr(repo: "platform", number: 2133, state: "MERGED", sha: "abc123"),
           pr(repo: "playbook-admin", number: 815)]
    held = one(prs, deployed: ->(_r, _s) { false })
    assert_equal :waits_on_deploy, verdicts(held)["playbook-admin#815"]

    shipped = one(prs, deployed: ->(_r, _s) { true })
    assert_equal :eligible, verdicts(shipped)["playbook-admin#815"]
  end

  # The deploy oracle is asked about the PRODUCER's repo and the producer's merge
  # commit — getting either wrong would answer a different question and pass.
  def test_the_deploy_probe_is_asked_about_the_producers_merge_commit
    asked = []
    one([pr(repo: "platform", number: 2133, state: "MERGED", sha: "abc123"),
         pr(repo: "playbook-admin", number: 815)],
        deployed: ->(r, s) { asked << [r, s]; true })
    assert_equal [["platform", "abc123"]], asked
  end

  # Fail-safe, everywhere: a question this cannot answer holds the PR. The
  # alternative fails open on precisely the case the module exists to catch.
  def test_an_unknown_deploy_state_holds
    group = one([pr(repo: "platform", number: 2133, state: "MERGED", sha: "abc123"),
                 pr(repo: "playbook-admin", number: 815)],
                deployed: ->(_r, _s) { nil })
    assert_equal :unknown_deploy, verdicts(group)["playbook-admin#815"]
  end

  def test_a_merged_producer_with_no_merge_commit_holds_rather_than_passing
    group = one([pr(repo: "platform", number: 2133, state: "MERGED"),
                 pr(repo: "playbook-admin", number: 815)],
                deployed: ->(_r, _s) { true })
    assert_equal :unknown_deploy, verdicts(group)["playbook-admin#815"]
  end

  # ---- declared edges ----

  def test_declared_edges_are_parsed_with_their_deploy_requirement
    edges = Prs::Group.declared_edges("intro\nDepends-On: platform#2133\ndepends-on: lib-util#9 merged\n")
    assert_equal %w[platform#2133 lib-util#9], edges.map(&:key)
    assert_equal [true, false], edges.map(&:requires_deploy)
  end

  def test_prose_that_merely_mentions_a_pr_is_not_an_edge
    assert_empty Prs::Group.declared_edges("this depends on platform#2133 landing first")
  end

  # A declared edge must be able to CORRECT the inference, not only add to it.
  # Here the producer is the one that waits, which role order would never say —
  # and the inferred consumer→producer edge is dropped rather than kept, or the
  # two together would be a cycle this code invented.
  def test_a_declared_edge_reverses_the_inferred_one_rather_than_deadlocking_with_it
    group = one([pr(repo: "platform", number: 2133, body: "depends-on: playbook-admin#815"),
                 pr(repo: "playbook-admin", number: 815)])
    assert_equal :waits_on_merge, verdicts(group)["platform#2133"]
    assert_equal :eligible, verdicts(group)["playbook-admin#815"]
  end

  # One `depends-on:` line in one body must not silently un-order the rest of the
  # group. A body that says LESS constraining less is the wrong direction for a
  # safety check, so inference still covers everything the bodies do not contradict.
  def test_a_declared_edge_elsewhere_does_not_drop_the_inferred_schema_ordering
    group = one([pr(repo: "platform-postgresql", number: 514),
                 pr(repo: "platform", number: 2133),
                 pr(repo: "playbook-admin", number: 815, body: "depends-on: platform#2133")])
    assert_equal :eligible, verdicts(group)["platform-postgresql#514"]
    # …still waiting on the migration, which no body mentions.
    assert_equal :waits_on_merge, verdicts(group)["platform#2133"]
    assert_match(/platform-postgresql#514/, group.members[1].reason)
  end

  def test_a_declared_edge_marked_merged_does_not_wait_for_a_deploy
    group = one([pr(repo: "platform", number: 2133, state: "MERGED", sha: "abc123"),
                 pr(repo: "playbook-admin", number: 815, body: "depends-on: platform#2133 merged")],
                deployed: ->(_r, _s) { false })
    assert_equal :eligible, verdicts(group)["playbook-admin#815"]
  end

  # An edge may name a PR in another group, or one older than the scan window.
  def test_an_edge_outside_the_group_is_resolved_through_the_lookup
    outside = pr(repo: "platform", number: 2000, branch: "other", state: "MERGED", sha: "old1")
    group = one([pr(repo: "playbook-admin", number: 815, body: "depends-on: platform#2000")],
                lookup: ->(_repo, number) { number == 2000 ? outside : nil },
                deployed: ->(_r, _s) { true })
    assert_equal :eligible, verdicts(group)["playbook-admin#815"]
  end

  def test_an_edge_that_cannot_be_resolved_holds
    group = one([pr(repo: "playbook-admin", number: 815, body: "depends-on: platform#9999")])
    assert_equal :unknown_dependency, verdicts(group)["playbook-admin#815"]
  end

  def test_a_cycle_holds_every_member_in_it
    group = one([pr(repo: "platform", number: 2133, body: "depends-on: playbook-admin#815"),
                 pr(repo: "playbook-admin", number: 815, body: "depends-on: platform#2133")])
    assert_equal %i[cycle cycle], group.members.map(&:verdict)
  end

  # ---- devops, drafts, and the states that are not decisions ----

  # Merging devops IS deploying it, fleet-wide, within one 30-second tick. The
  # whole group is a human decision, not just the devops PR — the siblings are
  # part of a change whose devops half nothing may merge automatically.
  def test_a_group_containing_devops_is_a_human_decision_for_every_member
    group = one([pr(repo: "devops", number: 387, branch: "i754_ukk"),
                 pr(repo: "playbook-admin", number: 817, branch: "i754_ukk"),
                 pr(repo: "playbook-app", number: 470, branch: "i754_ukk")])
    assert group.human_only
    assert_equal [:human] * 3, group.members.map(&:verdict)
  end

  def test_a_draft_is_reported_as_a_draft_rather_than_as_eligible
    group = one([pr(repo: "platform", number: 2133, draft: true)])
    assert_equal :draft, verdicts(group)["platform#2133"]
  end

  def test_merged_and_closed_members_carry_their_own_state_not_a_hold
    group = one([pr(repo: "platform-postgresql", number: 514, state: "MERGED", sha: "s"),
                 pr(repo: "platform", number: 2133, state: "CLOSED")])
    assert_equal :merged, verdicts(group)["platform-postgresql#514"]
    assert_equal :closed, verdicts(group)["platform#2133"]
  end

  # A lone PR has nothing to order against, and must not be held by the machinery
  # that exists for the ones that do.
  def test_a_single_repo_group_is_eligible
    group = one([pr(repo: "playbook-admin", number: 815)])
    refute group.cross_repo?
    assert_equal :eligible, verdicts(group)["playbook-admin#815"]
  end

  # The full ISS-698 shape, end to end.
  def test_the_iss_698_group_holds_both_frontends_until_platform_ships
    prs = [pr(repo: "platform-postgresql", number: 514, state: "MERGED", sha: "mig1"),
           pr(repo: "platform", number: 2133),
           pr(repo: "playbook-admin", number: 815),
           pr(repo: "playbook-app", number: 460)]
    group = one(prs, deployed: ->(_r, _s) { true })
    assert_equal %w[platform-postgresql#514 platform#2133 playbook-admin#815 playbook-app#460],
                 group.members.map(&:key)
    assert_equal :eligible, verdicts(group)["platform#2133"]
    assert_equal %w[playbook-admin#815 playbook-app#460], group.blocked.map(&:key)
  end
end

# The deploy half: "has this merge commit shipped", which is the only fact in
# this feature that a single-PR check cannot see.
class TestPrsDeploy < Minitest::Test
  include DevTestSupport

  def capture_for(responses)
    lambda do |cmd|
      key = responses.keys.find { |k| cmd.join(" ").include?(k) }
      key ? responses[key] : nil
    end
  end

  def test_a_commit_contained_in_the_running_version_is_deployed
    cap = capture_for("compare/0.19.13...abc" => "behind\n")
    assert_equal true, Prs::Deploy.contains?("platform", "abc",
                                             live_version: ->(_r) { "0.19.13" }, capture: cap)
  end

  def test_a_commit_ahead_of_the_running_version_is_not_deployed
    cap = capture_for("compare/0.19.13...abc" => "ahead\n")
    assert_equal false, Prs::Deploy.contains?("platform", "abc",
                                              live_version: ->(_r) { "0.19.13" }, capture: cap)
  end

  # The tag is NOT the fallback for an app that has a probe: "tagged but the
  # deploy never ran" is exactly the state that must not read as shipped. It is
  # the fallback only for repos with nothing to ask — schema repos, libraries.
  def test_a_repo_with_no_prod_probe_falls_back_to_its_newest_release_tag
    cap = capture_for("/tags" => "0.9.2\n0.10.1\nexplore_stuff_backup_snapshot\n",
                      "compare/0.10.1...mig1" => "identical\n")
    assert_equal true, Prs::Deploy.contains?("platform-postgresql", "mig1",
                                             live_version: ->(_r) { nil }, capture: cap)
  end

  # 0.10.1 over 0.9.2 — string ordering gets this backwards, and picking the
  # wrong "newest" tag compares against the wrong release.
  def test_release_tags_are_ordered_numerically_and_non_releases_are_ignored
    cap = capture_for("/tags" => "0.9.2\n0.10.1\nbackup_snapshot\nv0.10.0\n")
    assert_equal "0.10.1", Prs::Deploy.deployed_ref("platform-postgresql", live_version: ->(_r) { nil },
                                                                           capture: cap)
  end

  # ISS-1097: the two kinds of "there is no ref to compare against". A repo that
  # publishes NO releases is not an unknown — devops is the case, and merging
  # there IS deploying — while a tag list that could not be read is. `contains?`
  # folds both to nil because holding is the only safe act for a merge check;
  # Agent::Dependency reads them apart.
  def test_a_repo_that_publishes_no_releases_is_told_apart_from_one_that_could_not_be_read
    none = capture_for("/tags" => "\n")
    assert_equal :unreleasable, Prs::Deploy.state("devops", "abc", live_version: ->(_r) { nil }, capture: none)
    assert_nil Prs::Deploy.contains?("devops", "abc", live_version: ->(_r) { nil }, capture: none)

    silent = ->(_cmd) { nil }
    assert_equal :unknown, Prs::Deploy.state("devops", "abc", live_version: ->(_r) { nil }, capture: silent)
  end

  def test_the_state_of_a_commit_against_what_shipped
    cap = capture_for("compare/0.19.13...abc" => "behind\n")
    assert_equal :shipped, Prs::Deploy.state("platform", "abc", live_version: ->(_r) { "0.19.13" }, capture: cap)

    ahead = capture_for("compare/0.19.13...abc" => "ahead\n")
    assert_equal :unshipped, Prs::Deploy.state("platform", "abc", live_version: ->(_r) { "0.19.13" },
                                                                  capture: ahead)
    assert_equal :unknown, Prs::Deploy.state("platform", "", live_version: ->(_r) { "0.19.13" }, capture: cap)
  end

  # Every failure path is nil, and Prs::Group reads nil as a HOLD.
  def test_an_unanswerable_probe_is_unknown_rather_than_false
    silent = ->(_cmd) { nil }
    assert_nil Prs::Deploy.contains?("platform", "abc", live_version: ->(_r) { nil }, capture: silent)
    assert_nil Prs::Deploy.contains?("platform", "", live_version: ->(_r) { "0.19.13" }, capture: silent)
    assert_nil Prs::Deploy.contains?("platform", "abc", live_version: ->(_r) { "0.19.13" },
                                     capture: ->(_cmd) { "\n" })
  end

  # A group of four consumers waiting on one producer must not probe production
  # four times.
  def test_the_oracle_memoises_per_repo_and_sha
    calls = 0
    cap = lambda do |cmd|
      calls += 1
      cmd.join(" ").include?("compare") ? "behind\n" : nil
    end
    oracle = Prs::Deploy.oracle(live_version: ->(_r) { "0.19.13" }, capture: cap)
    3.times { assert_equal true, oracle.call("platform", "abc") }
    assert_equal 1, calls
  end
end
