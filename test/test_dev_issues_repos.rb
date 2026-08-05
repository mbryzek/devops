#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# ISS-562: `--repo` on `dev issues create`.
#
# CLAUDE.md's "Auto-filing dev issues" section has always told sessions to repeat
# `--repo <name>` for every repository the work is in, and explained that the
# agent executor clones each named repo and pre-creates the attempt's branch. The
# flag did not exist, so every session that followed the instruction hit
# "unexpected argument(s): --repo" and dropped it — filing an issue that carries
# no repos and whose session therefore clones for itself and names its own
# branch, which is the ISS-365 failure the instruction was written to prevent.
#
# What each test here pins is the part that fails SILENTLY: a repo name that
# reaches `gh repo clone mbryzek/<name>` in a shape it cannot use, and a
# validation that refuses to file rather than degrade when GitHub cannot be asked.
class TestDevIssuesRepos < Minitest::Test
  include DevTestSupport

  # Stands in for `gh repo list mbryzek`. Set directly because `issue_repo_problems`
  # memoizes into this ivar, and NO test here may reach the network.
  def stub_known_repos(names)
    @issue_github_repo_names = names
  end

  def test_repo_flag_is_documented_on_create_and_workaround
    assert_match(/--repo NAME/, usage_for("issues create"))
    assert_match(/--repo NAME/, usage_for("issues workaround"))
  end

  def test_normalize_trims_drops_blanks_and_dedupes
    assert_equal %w[platform devops],
                 issue_normalize_repos(["platform", " devops ", "platform", "", "   "])
  end

  # The whole reason the name is validated: it is interpolated into
  # `gh repo clone mbryzek/<name>`, so a slug clones mbryzek/mbryzek/devops and a
  # url clones nothing at all — both of them hours later, unattended.
  def test_a_slug_or_url_is_rejected_before_the_known_list_is_consulted
    stub_known_repos(nil) # GitHub deliberately unavailable: shape still fails.
    problems = issue_repo_problems(["mbryzek/devops"])
    assert_equal 1, problems.length
    assert_match(%r{--repo mbryzek/devops: not a repository name}, problems.first)

    assert_match(/not a repository name/,
                 issue_repo_problems(["https://github.com/mbryzek/devops"]).first)
    assert_match(/not a repository name/, issue_repo_problems(["~/code/platform"]).first)
  end

  def test_an_unknown_name_is_rejected_with_the_full_list
    stub_known_repos(%w[platform devops platform-postgresql])
    problems = issue_repo_problems(%w[platform platfrom])
    assert_equal 1, problems.length
    assert_match(/--repo platfrom: no such repository under mbryzek/, problems.first)
    # The list is the point: "I typed the wrong name" deserves the right one.
    assert_match(/Known: devops, platform, platform-postgresql/, problems.first)
  end

  def test_known_names_pass
    stub_known_repos(%w[platform devops])
    assert_empty issue_repo_problems(%w[platform devops])
    assert_empty issue_repo_problems([])
  end

  # An unaskable GitHub must not turn a caught typo into a lost finding: the
  # membership check is skipped, the filing proceeds, and a bad name costs the
  # session a clone it would have done itself anyway.
  def test_membership_is_skipped_when_github_cannot_be_asked
    stub_known_repos(nil)
    assert_empty issue_repo_problems(%w[a-repo-nobody-has])
  end

  # `dev issues show` is where a human checks whether the executor will have a
  # checkout ready. An issue with none renders no line at all rather than "none",
  # which would read as a setting someone chose.
  def test_show_renders_the_repos_and_omits_the_line_when_there_are_none
    issue = {
      "id" => "iss-1", "number" => "562", "category" => "bug", "status" => "claimed",
      "title" => "the flag does not exist", "occurrence_count" => 1,
      "created" => { "at" => "2026-08-05T12:00:00Z", "by" => { "id" => "usr-1", "name" => "Mike Bryzek" } },
    }
    refute_match(/^- Repos:/, issue_render_item(issue))
    assert_match(/^- Repos: devops, platform$/,
                 issue_render_item(issue.merge("repositories" => %w[devops platform])))
  end
end
