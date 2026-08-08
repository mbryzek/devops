#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'release_tag'

# ISS-904: the release record for an app with no HTTP endpoint and no cluster
# access — read from GitHub, so `dev issues reconcile` can answer "has workers
# released since this fix merged" on an agent runner.
#
# Nothing here touches the network: `gh` arrives as a `capture` lambda, so a test
# states what GitHub said and asserts the verdict.
class TestReleaseTag < Minitest::Test
  include DevTestSupport

  # Match on a distinctive fragment of the command, the way TestPrsDeploy does —
  # so a test says which API call it is answering rather than restating the
  # whole argv.
  def capture_for(responses)
    lambda do |cmd|
      key = responses.keys.find { |k| cmd.join(" ").include?(k) }
      key ? responses[key] : nil
    end
  end

  def test_a_bare_repo_name_is_ours_and_a_slug_is_left_alone
    assert_equal "mbryzek/workers", ReleaseTag.slug("workers")
    assert_equal "someorg/workers", ReleaseTag.slug("someorg/workers")
  end

  # 0.10.1 over 0.9.2 — string ordering gets this backwards. And workers really
  # does carry a `workers_explore_stuff_backup` tag: picking it as "the newest
  # release" would compare a release against something that never shipped.
  def test_the_newest_release_tag_is_numeric_and_ignores_non_releases
    cap = capture_for("/tags" => "0.9.2\n0.10.1\nworkers_explore_stuff_backup\nv0.10.0\n")
    assert_equal "0.10.1", ReleaseTag.latest("workers", capture: cap)
  end

  def test_a_repo_with_no_release_tags_has_no_newest_one
    assert_nil ReleaseTag.latest("workers", capture: capture_for("/tags" => "backup_snapshot\n"))
  end

  # `gh` missing, unauthenticated, rate-limited, or the repo 404ing all arrive
  # here as nil, and every caller reads nil as "cannot tell".
  def test_an_unanswerable_tag_list_is_nil_rather_than_an_empty_answer
    assert_nil ReleaseTag.latest("workers", capture: ->(_cmd) { nil })
  end

  # ISS-1097: `latest` collapses both of these to nil because neither gives it a
  # tag to return, and a caller deciding "has this merge shipped" needs them
  # apart. `[]` is devops — a repo that does not release, where waiting for a tag
  # is waiting for something nobody will ever cut. `nil` is a read that failed.
  def test_the_tag_list_tells_a_repo_with_no_releases_apart_from_one_it_could_not_read
    assert_equal [], ReleaseTag.tags("devops", capture: capture_for("/tags" => "\n"))
    assert_equal [], ReleaseTag.tags("workers", capture: capture_for("/tags" => "backup_snapshot\n"))
    assert_nil ReleaseTag.tags("workers", capture: ->(_cmd) { nil })
  end

  def test_the_newest_of_an_already_read_list_needs_no_second_call
    assert_equal "0.10.1", ReleaseTag.newest(%w[0.9.2 0.10.1 v0.10.0])
    assert_nil ReleaseTag.newest([])
    assert_nil ReleaseTag.newest(nil)
  end

  # The tagger date, not the tagged commit's. `release` tags whatever is on main,
  # so the commit's timestamp is the last MERGE — reading it would make "released
  # since the fix merged" false for the release that shipped the fix.
  def test_an_annotated_tag_is_dated_by_its_tagger
    cap = capture_for(
      "git/ref/tags/0.1.9" => JSON.dump("object" => { "type" => "tag", "sha" => "deadbeef" }),
      "git/tags/deadbeef" => JSON.dump("tagger" => { "date" => "2026-07-08T14:55:40Z" }),
    )
    assert_equal "2026-07-08T14:55:40Z", ReleaseTag.cut_at("workers", "0.1.9", capture: cap)
  end

  # A lightweight tag has no object of its own to date. Ours are annotated; this
  # is the hand-made tag that bypassed `release`.
  def test_a_lightweight_tag_falls_back_to_its_commit_date
    cap = capture_for(
      "git/ref/tags/0.1.9" => JSON.dump("object" => { "type" => "commit", "sha" => "cafe" }),
      "commits/cafe" => JSON.dump("commit" => { "committer" => { "date" => "2026-07-01T09:00:00Z" } }),
    )
    assert_equal "2026-07-01T09:00:00Z", ReleaseTag.cut_at("workers", "0.1.9", capture: cap)
  end

  def test_a_tag_whose_date_cannot_be_read_is_nil
    unreadable = capture_for("git/ref/tags/0.1.9" => "not json")
    assert_nil ReleaseTag.cut_at("workers", "0.1.9", capture: unreadable)
    assert_nil ReleaseTag.cut_at("workers", "0.1.9", capture: ->(_cmd) { nil })

    missing_object = capture_for("git/ref/tags/0.1.9" => JSON.dump("object" => {}))
    assert_nil ReleaseTag.cut_at("workers", "0.1.9", capture: missing_object)
  end
end
