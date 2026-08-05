#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# The GitHub merge webhook's provisioning half (ISS-537).
#
# What is worth testing here is not "can we POST a hook" — that is one `gh api`
# call — but the judgment in `evaluate`: every way a hook can EXIST and still
# move zero issues. A hook that is present, active, and reported healthy by
# GitHub while the platform throws away all of its deliveries is the exact shape
# of the bug this command exists to end, so each of those ways gets a test.
class TestGithubWebhooks < Minitest::Test
  include DevTestSupport

  URL = GithubWebhooks::DEFAULT_URL

  def hook(overrides: {}, config: {})
    {
      "id" => 1,
      "active" => true,
      "events" => ["pull_request"],
      "config" => { "url" => URL, "content_type" => "json", "insecure_ssl" => "0",
                    "secret" => "********" }.merge(config),
    }.merge(overrides)
  end

  def evaluate(hooks, url: URL)
    GithubWebhooks.evaluate(repo: "mbryzek/platform", hooks: hooks, url: url)
  end

  # minitest/mock is not installed here, so `gh` is replaced by hand for the two
  # tests that need it. Everything else in this file is pure.
  def with_gh(result)
    original = GithubWebhooks.method(:capture)
    GithubWebhooks.define_singleton_method(:capture) { |*_args, **_kwargs| result }
    yield
  ensure
    GithubWebhooks.define_singleton_method(:capture, original)
  end

  # ---- absent ----

  def test_no_hooks_at_all_is_absent
    state = evaluate([])
    assert state.absent?
    assert_match(/no webhook delivers to #{Regexp.escape(URL)}/, state.summary)
  end

  # The state the whole fleet was in for a month: hooks exist, none of them ours.
  def test_only_unrelated_hooks_is_absent
    reviewable = hook(overrides: { "events" => ["*"] }, config: { "url" => "https://api.reviewable.io/github" })
    assert evaluate([reviewable]).absent?
  end

  def test_a_correct_hook_is_ok
    state = evaluate([hook])
    assert state.ok?
    assert_empty state.problems
    assert_equal 1, state.hook_id
  end

  # ---- drift ----

  # Matching on the path, not the whole URL, is what makes a host change a repair
  # of the hook that already exists. Matched on the URL alone, `sync` would add a
  # second hook and leave the first one delivering to an address nobody answers.
  def test_a_hook_on_the_right_path_but_the_wrong_host_is_drift_not_absence
    stale = hook(config: { "url" => "https://old.example.com/webhooks/github" })
    state = evaluate([stale])
    assert state.drifted?
    assert_equal 1, state.hook_id
    assert_match(/delivers to https:\/\/old\.example\.com/, state.summary)
  end

  def test_a_disabled_hook_is_drift
    assert_match(/disabled/, evaluate([hook(overrides: { "active" => false })]).summary)
  end

  # Every extra event is a delivery the platform persists, queues a task for, and
  # discards. `*` is Reviewable's shape and specifically not this one.
  def test_extra_events_are_drift
    assert_match(/subscribes to \*/, evaluate([hook(overrides: { "events" => ["*"] })]).summary)
    assert_match(/subscribes to pull_request, push/, evaluate([hook(overrides: { "events" => %w[push pull_request] })]).summary)
  end

  def test_missing_pull_request_event_is_drift
    assert_match(/subscribes to push/, evaluate([hook(overrides: { "events" => ["push"] })]).summary)
  end

  # The quiet catastrophe: GitHub omits `secret` entirely when none is set, so
  # the hook looks healthy from GitHub's side and every delivery is rejected
  # unsigned at the platform's HMAC check.
  def test_a_hook_with_no_signing_secret_is_drift
    state = evaluate([hook(config: { "secret" => nil })])
    assert state.drifted?
    assert_match(/no signing secret/, state.summary)
  end

  def test_form_encoded_content_type_is_drift
    assert_match(/content_type is form/, evaluate([hook(config: { "content_type" => "form" })]).summary)
  end

  def test_insecure_ssl_is_drift
    assert_match(/insecure_ssl is on/, evaluate([hook(config: { "insecure_ssl" => "1" })]).summary)
  end

  # Two hooks on the same path deliver every merge twice. `sync` repairing only
  # the first one forever, and never saying so, is how a duplicate survives.
  def test_two_hooks_on_the_platform_path_are_drift
    state = evaluate([hook, hook(overrides: { "id" => 2 })])
    assert state.drifted?
    assert_match(/2 hooks deliver to the platform/, state.summary)
  end

  def test_every_problem_is_reported_not_just_the_first
    state = evaluate([hook(overrides: { "active" => false, "events" => ["*"] }, config: { "secret" => nil })])
    assert_equal 3, state.problems.length, state.summary
  end

  # ---- last delivery ----
  #
  # GitHub records the last delivery's result on the hook itself. It is the only
  # credential-free way to answer "is this actually working", which is rollout
  # step 3 without waiting for a merge.

  def test_a_failing_last_delivery_is_drift
    state = evaluate([hook(overrides: { "last_response" => { "code" => 401, "status" => "unauthorized", "message" => "bad signature" } })])
    assert state.drifted?
    assert_match(/last delivery failed: 401 unauthorized \(bad signature\)/, state.summary)
  end

  def test_a_successful_last_delivery_is_not_a_problem
    assert evaluate([hook(overrides: { "last_response" => { "code" => 200, "status" => "OK" } })]).ok?
  end

  # A brand new hook has a last_response with a nil code. That is "has not fired
  # yet", not a fault — reporting it as one would make every fresh provision look
  # broken and train the reader to ignore the command.
  def test_a_hook_that_has_never_fired_is_not_a_problem
    assert evaluate([hook(overrides: { "last_response" => { "code" => nil, "status" => "unused" } })]).ok?
    assert evaluate([hook(overrides: { "last_response" => nil })]).ok?
  end

  # ---- payloads ----

  def test_create_payload_names_the_hook_and_subscribes_to_pull_request_only
    payload = GithubWebhooks.create_payload(url: URL, secret: "s3cret")
    assert_equal "web", payload["name"]
    assert_equal ["pull_request"], payload["events"]
    assert_equal true, payload["active"]
    assert_equal "s3cret", payload.dig("config", "secret")
    assert_equal "json", payload.dig("config", "content_type")
    assert_equal "0", payload.dig("config", "insecure_ssl")
  end

  # GitHub treats `name` as read-only on update, and replaces `config` wholesale
  # rather than merging it — so a repair that omitted the secret would strip the
  # secret off a working hook.
  def test_update_payload_omits_name_and_resends_the_secret
    payload = GithubWebhooks.update_payload(url: URL, secret: "s3cret")
    refute payload.key?("name")
    assert_equal "s3cret", payload.dig("config", "secret")
    assert_equal ["pull_request"], payload["events"]
  end

  # Repairing a drifted hook with the payload must actually clear the drift,
  # which is the property that makes `sync` idempotent rather than a loop.
  def test_syncing_a_drifted_hook_would_make_it_ok
    payload = GithubWebhooks.update_payload(url: URL, secret: "s3cret")
    repaired = { "id" => 1, "active" => payload["active"], "events" => payload["events"],
                 "config" => payload["config"] }
    assert evaluate([repaired]).ok?
  end

  def test_suggested_secret_is_long_and_random
    a = GithubWebhooks.suggested_secret
    assert_equal 64, a.length
    refute_equal a, GithubWebhooks.suggested_secret
  end

  # ---- fleet-level failure modes ----
  #
  # Both of these are ways the command could report "all clear" about repos it
  # never actually looked at, which is the failure it exists to end.

  def test_a_repo_the_token_cannot_read_is_its_own_state_not_an_abort
    state = GithubWebhooks.unreadable("mbryzek/secret", "404 Not Found")
    assert state.unreadable?
    refute state.ok?
    refute state.absent?
    assert_match(/404 Not Found/, state.summary)
  end

  # A repo list capped at the limit is a list with an unknown tail. Provisioning
  # it would leave the repos past the cut reporting fine by never being asked.
  def test_a_truncated_repository_listing_raises_rather_than_provisioning_a_subset
    names = (1..3).map { |i| "repo#{i}" }
    with_gh([true, names.join("\n")]) do
      error = assert_raises(GithubWebhooks::Error) { GithubWebhooks.repos(limit: 3) }
      assert_match(/capped there/, error.message)
      assert_equal names, GithubWebhooks.repos(limit: 4)
    end
  end

  def test_a_failed_repository_listing_raises
    with_gh([false, "gh: HTTP 401"]) do
      error = assert_raises(GithubWebhooks::Error) { GithubWebhooks.repos }
      assert_match(/could not list/, error.message)
    end
  end

  # ---- wiring ----

  def test_both_subcommands_are_dispatchable
    assert_includes SUBCOMMANDS.fetch("issues"), "webhook"
    assert_equal %w[status sync], SUBCOMMANDS.fetch("issues webhook")
    assert INVOCATIONS.key?("issues webhook status")
    assert INVOCATIONS.key?("issues webhook sync")
    assert Object.private_method_defined?(:cmd_issues_webhook_status)
    assert Object.private_method_defined?(:cmd_issues_webhook_sync)
  end

  def test_unknown_flags_are_rejected_by_name
    out, status = capture_stderr_and_exit { cmd_issues_webhook_status(["--nope"]) }
    assert_equal 1, status
    assert_match(/unknown argument: --nope/, out)
  end

  # --apply on `status` is a user who means `sync`. Silently ignoring it would
  # leave them believing the hooks were written.
  def test_status_rejects_apply_rather_than_ignoring_it
    out, status = capture_stderr_and_exit { cmd_issues_webhook_status(["--apply"]) }
    assert_equal 1, status
    assert_match(/unknown argument: --apply/, out)
  end
end

# `EnvironmentVariables.lookup` — one variable, read without the auto-unlock
# `load` performs.
class TestEnvironmentVariablesLookup < Minitest::Test
  include DevTestSupport

  def with_env_files(files)
    Dir.mktmpdir do |dir|
      files.each do |name, contents|
        path = File.join(dir, "#{name}.env")
        contents.is_a?(String) ? File.write(path, contents) : File.binwrite(path, contents)
      end
      original = EnvironmentVariables.method(:file_path)
      EnvironmentVariables.define_singleton_method(:file_path) do |_app, filename|
        File.join(dir, "#{filename}.env")
      end
      begin
        yield
      ensure
        EnvironmentVariables.define_singleton_method(:file_path, original)
      end
    end
  end

  def lookup(key = "GITHUB_WEBHOOK_SECRET")
    EnvironmentVariables.lookup("platform", "production", key)
  end

  def test_present
    with_env_files("production" => "GITHUB_WEBHOOK_SECRET=abc123\n", "common" => "") do
      assert_equal [:present, "abc123"], lookup
    end
  end

  def test_missing_when_the_files_exist_without_the_key
    with_env_files("production" => "OTHER=1\n", "common" => "MORE=2\n") do
      assert_equal [:missing, nil], lookup
    end
  end

  # An empty assignment is not a secret. Treating `KEY=` as present would let
  # `sync` write hooks signed with the empty string.
  def test_an_empty_value_is_missing
    with_env_files("production" => "GITHUB_WEBHOOK_SECRET=\n") do
      assert_equal [:missing, nil], lookup
    end
  end

  def test_the_environment_file_wins_over_common
    with_env_files("production" => "GITHUB_WEBHOOK_SECRET=prod\n",
                   "common" => "GITHUB_WEBHOOK_SECRET=shared\n") do
      assert_equal [:present, "prod"], lookup
    end
  end

  def test_common_is_read_when_the_environment_file_does_not_have_it
    with_env_files("production" => "OTHER=1\n", "common" => "GITHUB_WEBHOOK_SECRET=shared\n") do
      assert_equal [:present, "shared"], lookup
    end
  end

  # The whole reason this exists instead of calling `load`: a locked file is
  # reported, never decrypted. `load` would shell out to `git-crypt unlock`.
  def test_a_git_crypt_locked_file_is_reported_not_unlocked
    with_env_files("production" => "\x00GITCRYPT\x00binary-garbage".b) do
      assert_equal [:locked, nil], lookup
    end
  end

  # :no_file and :missing call for opposite responses — "you are not looking at
  # the env repo" versus "add the variable" — so they are never collapsed.
  def test_no_env_file_at_all_is_its_own_answer
    with_env_files({}) do
      assert_equal [:no_file, nil], lookup
    end
  end
end
