#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-772: the reap's fallback lookup used to accept ANOTHER issue's PR.
#
# `head:<branch>` in GitHub search is a PREFIX match on the whole branch name,
# not an exact one — measured on this account while writing this:
#
#     $ gh search prs "head:i735_te" --owner mbryzek
#     devops#375  devops#374  devops#373  devops#372     # all i735_tej*
#     $ gh pr list --repo mbryzek/devops --head i735_te --state all
#     []                                                 # …--head is exact
#
# and `gh search prs` cannot return headRefName (SEARCH_FIELDS), so the hits
# could not be narrowed back down. `primary_pr` fell through to newest-wins, and
# the reap could record a stranger's PR as this issue's fix — the one outcome the
# whole subsystem exists to prevent, since `dev issues reconcile` then reasons
# about deployment from that url.
#
# The correction is that search DISCOVERS repos and decides nothing: both lookups
# hand their repos to `prs_in_repos`, which matches exactly (`--head`, plus the
# `ISS-<n>: ` title prefix anchored locally). So the subjects here are the two
# search-backed entry points and the guarantee that they agree with the
# workspace path they now share.
class TestAgentSearchFallback < Minitest::Test
  include DevTestSupport

  # The assigned branch of a low-numbered issue, and the branch of a
  # higher-numbered one that its prefix swallows. `i77` / `i772_o9j` is the exact
  # collision the issue was filed from.
  BRANCH = "i77".freeze
  NUMBER = "77".freeze
  MINE = "mbryzek/devops".freeze
  THEIRS = "mbryzek/platform".freeze

  def pr(number:, head:, repo: MINE, title: "ISS-77: mine", state: "OPEN", draft: false)
    { "number" => number, "url" => "https://github.com/#{repo}/pull/#{number}", "title" => title,
      "state" => state, "isDraft" => draft, "headRefName" => head, "repository" => repo }
  end

  def mine(number: 1, head: BRANCH, **opts) = pr(number: number, head: head, **opts)

  # Somebody else's work, on a branch this issue's name is a prefix of.
  def theirs(number: 2)
    pr(number: number, head: "i772_o9j", repo: THEIRS, title: "ISS-772: not mine")
  end

  # What `gh search prs` returns: the same PR MINUS headRefName, which is the
  # whole reason a hit cannot be trusted on its own.
  def hit(pr) = pr.reject { |field, _| field == "headRefName" }

  # `gh pr list` for a repo→PRs table, honouring `--head` as the real command
  # does: exactly. Both `prs_on_branch` and `prs_for_issue` go through it, so the
  # family and title matching under test run for real.
  def stub_list(table, seen: [], &block)
    impl = lambda do |repo, *args|
      seen << repo
      prs = Array(table[repo])
      head = args[args.index("--head") + 1] if args.include?("--head")
      prs = prs.select { |p| p["headRefName"] == head } if head
      prs.map { |p| p.merge("repository" => repo) }
    end
    stub_singleton(Agent::Github, :list_prs, impl, &block)
  end

  # `gh search prs`, keyed by the query the caller builds.
  def stub_search(hits_by_query, asked: [], &block)
    # Shaped up front: the stub is defined ON Agent::Github, so anything it calls
    # resolves there rather than on the test.
    table = hits_by_query.transform_values { |hits| Array(hits).map { |h| hit(h) } }
    impl = lambda do |query, **|
      asked << query
      Array(table[query])
    end
    stub_singleton(Agent::Github, :search, impl, &block)
  end

  def head_and_title(head_hits, title_hits = [])
    { "head:#{BRANCH}" => head_hits, "ISS-#{NUMBER}" => title_hits }
  end

  # ---- the fallback ----

  # The bug, end to end: the loose head match drags in a higher-numbered issue's
  # PR, and the fallback must not return it however new it is.
  def test_the_fallback_never_returns_a_pr_outside_the_branch_family
    table = { MINE => [mine], THEIRS => [theirs(number: 99)] }
    found = stub_search(head_and_title([mine, theirs(number: 99)], [mine])) do
      stub_list(table) { Agent::Github.search_prs(BRANCH, NUMBER) }
    end
    assert_equal [mine["url"]], found.map { |p| p["url"] }
  end

  # …and a repo that ONLY holds a lookalike contributes nothing, rather than its
  # newest PR. This is the case that used to record a stranger's url as the fix.
  def test_a_repo_holding_only_a_lookalike_contributes_no_pr
    found = stub_search(head_and_title([theirs])) do
      stub_list({ THEIRS => [theirs] }) { Agent::Github.search_prs(BRANCH, NUMBER) }
    end
    assert_empty found
  end

  # Siblings are still found — that is what the loose match was doing for us
  # (ISS-657), and it has to survive the correction.
  def test_the_fallback_still_finds_sibling_branches
    sibling = mine(number: 9, head: "#{BRANCH}_sig", title: "no prefix at all")
    found = stub_search(head_and_title([mine, sibling, theirs])) do
      stub_list({ MINE => [mine, sibling], THEIRS => [theirs] }) { Agent::Github.search_prs(BRANCH, NUMBER) }
    end
    assert_equal [1, 9], found.map { |p| p["number"] }.sort
  end

  # A PR titled right but branched wrong is the ISS-365 handle, and the title
  # search is the only thing that finds its repo at all.
  def test_a_renamed_branch_is_still_found_by_its_title
    renamed = mine(number: 5, head: "improve-the-thing")
    found = stub_search(head_and_title([], [renamed])) do
      stub_list({ MINE => [renamed] }) { Agent::Github.search_prs(BRANCH, NUMBER) }
    end
    assert_equal [5], found.map { |p| p["number"] }
  end

  # The fallback's hits now carry headRefName, which search itself cannot return
  # — so `primary_pr` can apply its assigned-branch tie-break here instead of
  # falling through to newest-wins and recording whichever PR was opened last.
  def test_the_fallback_returns_the_head_branch_so_the_tie_break_works
    sibling = mine(number: 9, head: "#{BRANCH}_sig")
    found = stub_search(head_and_title([mine, sibling])) do
      stub_list({ MINE => [mine, sibling] }) { Agent::Github.search_prs(BRANCH, NUMBER) }
    end
    assert_equal [BRANCH, "#{BRANCH}_sig"], found.map { |p| p["headRefName"] }.sort
    assert_equal 1, Agent::Github.primary_pr(found, BRANCH)["number"],
                 "the assigned branch must win the tie even on the fallback path"
  end

  # The workspace path and the fallback are the same decision over a different
  # source of repos. Two notions of "this issue's PR" is how they drifted apart.
  def test_the_fallback_agrees_with_the_workspace_lookup
    table = { MINE => [mine, mine(number: 9, head: "#{BRANCH}_sig")], THEIRS => [theirs] }
    Dir.mktmpdir do |ws|
      from_search = stub_search(head_and_title([mine, theirs])) do
        stub_list(table) { Agent::Github.search_prs(BRANCH, NUMBER) }
      end
      from_workspace = stub_singleton(Agent::Github, :repos_in_workspace, ->(*) { [MINE, THEIRS] }) do
        stub_list(table) { Agent::Github.prs_in_workspace(ws, BRANCH, NUMBER) }
      end
      assert_equal from_workspace.map { |p| p["url"] }, from_search.map { |p| p["url"] }
      refute_empty from_search
    end
  end

  # ---- which repos get scanned ----

  # Each candidate repo costs `gh pr list` calls under the work lock (ISS-740),
  # and the loose head match can surface a lot of them. Bounded — and a repo the
  # TITLE search confirmed is certainly this issue's, so it is never the one the
  # cap drops.
  def test_repo_scanning_is_capped_with_the_title_confirmed_repo_first
    noise = (1..8).map { |i| pr(number: 100 + i, head: "i77#{i}", repo: "mbryzek/noise#{i}", title: "ISS-77#{i}: no") }
    repos = stub_search(head_and_title(noise, [mine])) do
      Agent::Github.search_repos(BRANCH, NUMBER)
    end
    assert_equal MINE, repos.first, "a repo whose PR title carries ISS-77 is confirmed, not a candidate"
    assert_equal Agent::Github::MAX_SEARCH_REPOS, repos.length
  end

  # The title half is matched HERE, against the title the search does return, and
  # `ISS-77` must not confirm `ISS-772` — the same digit-swallowing one layer up.
  def test_a_higher_numbered_title_does_not_confirm_this_issue
    repos = stub_search(head_and_title([], [theirs])) { Agent::Github.search_repos(BRANCH, NUMBER) }
    assert_equal [THEIRS], repos, "still a candidate — the head search may yet have found it"
    refute_match Agent::Github.title_prefix(NUMBER), theirs["title"]
    assert_match Agent::Github.title_prefix(NUMBER), mine["title"]
  end

  # A number that is not one must not raise into the reap: the title half simply
  # does not apply and the branch search still answers.
  def test_a_non_numeric_issue_number_asks_only_the_head_search
    asked = []
    repos = stub_search({ "head:#{BRANCH}" => [mine] }, asked: asked) do
      Agent::Github.search_repos(BRANCH, nil)
    end
    assert_equal ["head:#{BRANCH}"], asked
    assert_equal [MINE], repos
  end

  # ---- resume ----

  # `Agent::Workspace.resume` CLONES what this returns and checks the branch out
  # in it, so a loose hit resumes the wrong repo — or, where a branch of this
  # name happens to exist, somebody else's work.
  def test_resume_ignores_a_repo_that_only_matched_the_branch_prefix
    found = stub_search({ "head:#{BRANCH} state:open" => [theirs] }) do
      stub_list({ THEIRS => [theirs] }) { Agent::Github.search_open_pr(BRANCH) }
    end
    assert_nil found
  end

  def test_resume_returns_the_open_pr_on_the_exact_branch
    found = stub_search({ "head:#{BRANCH} state:open" => [theirs, mine] }) do
      stub_list({ THEIRS => [theirs], MINE => [mine] }) { Agent::Github.search_open_pr(BRANCH) }
    end
    assert_equal MINE, found["repository"]
    assert_equal BRANCH, found["headRefName"]
  end

  # `prs_on_branch` asks `--state all`, so the exact branch can come back with a
  # finished PR. Resuming onto one pushes commits nobody is reviewing.
  def test_resume_refuses_a_branch_whose_own_pr_is_already_merged
    merged = mine(state: "MERGED")
    found = stub_search({ "head:#{BRANCH} state:open" => [merged] }) do
      stub_list({ MINE => [merged] }) { Agent::Github.search_open_pr(BRANCH) }
    end
    assert_nil found
  end
end
