#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'
require 'dependencies/updates'
require 'tmpdir'
load File.expand_path('../bin/dev', __dir__)

class TestDependenciesParseReport < Minitest::Test
  SAMPLE = <<~OUT
    [info] welcome to sbt 1.9.9 (Eclipse Adoptium Java 17.0.9)
    [info] Found 3 dependency updates for core
    [info]   org.postgresql:postgresql : 42.7.11 -> 42.7.13
    [info]   com.typesafe.play:play : 2.9.0 -> 2.9.7 -> 3.0.9
    [info]   com.sendgrid:sendgrid-java:test : 4.10.3 -> 4.10.4
    [info] Found 1 dependency update for api
    [info]   org.postgresql:postgresql : 42.7.11 -> 42.7.13
    [success] Total time: 42 s
  OUT

  def test_parses_and_dedupes_across_subprojects
    updates = Dependencies::Updates.parse_report(SAMPLE)
    assert_equal 3, updates.length
    pg = updates.find { |u| u[:artifact] == "postgresql" }
    assert_equal "org.postgresql", pg[:group]
    assert_equal "42.7.11", pg[:current]
    assert_equal ["42.7.13"], pg[:candidates]
  end

  def test_multi_arrow_chain_collects_all_candidates
    play = Dependencies::Updates.parse_report(SAMPLE).find { |u| u[:artifact] == "play" }
    assert_equal ["2.9.7", "3.0.9"], play[:candidates]
  end

  def test_scoped_module_id_drops_config
    sg = Dependencies::Updates.parse_report(SAMPLE).find { |u| u[:artifact] == "sendgrid-java" }
    refute_nil sg
    assert_equal "com.sendgrid", sg[:group]
  end

  def test_noise_lines_are_ignored
    assert_empty Dependencies::Updates.parse_report("[info] compiling 3 Scala sources\n[success] done")
    assert_empty Dependencies::Updates.parse_report("")
    assert_empty Dependencies::Updates.parse_report(nil)
  end
end

class TestDependenciesPolicy < Minitest::Test
  def choose(current, candidates) = Dependencies::Updates.choose_target(current, candidates)

  def test_picks_highest_stable_candidate
    assert_equal "3.0.9", choose("2.9.0", ["2.9.7", "3.0.9"])
  end

  def test_numeric_not_lexicographic_compare
    assert_equal "42.7.13", choose("42.7.9", ["42.7.13"])
  end

  def test_skips_prerelease_candidates
    assert_equal "2.9.7", choose("2.9.0", ["2.9.7", "3.0.0-RC1", "3.0.0-M2", "4.0.0-SNAPSHOT"])
  end

  def test_nil_when_only_prereleases_available
    assert_nil choose("2.9.0", ["3.0.0-RC1"])
  end

  def test_nil_when_current_is_not_simple
    assert_nil choose("2.9.0-play28", ["3.0.9"])
  end

  def test_nil_when_no_candidate_is_greater
    assert_nil choose("3.0.9", ["3.0.9", "2.9.7"])
  end

  # commons-codec really publishes 20041127.091804 on Maven Central; a semver
  # current must never "upgrade" onto a datestamp release (and vice versa).
  def test_rejects_datestamp_candidate_for_semver_current
    assert_nil choose("1.22.0", ["20041127.091804"])
    assert_equal "1.23.0", choose("1.22.0", ["1.23.0", "20041127.091804"])
  end

  def test_datestamp_current_stays_in_datestamp_lane
    assert_equal "20250101.1", choose("20240101.1", ["20250101.1", "1.5.0"])
  end
end

class TestDependenciesDenylist < Minitest::Test
  U = Dependencies::Updates

  def entry(artifact, versions: nil, apps: nil)
    e = { "artifact" => artifact, "reason" => "test" }
    e["versions"] = versions if versions
    e["apps"] = apps if apps
    e
  end

  def test_artifact_wide_deny
    e = entry("com.google.inject:guice")
    assert U.denied_by([e], "platform", "com.google.inject", "guice", "6.0.0")
    refute U.denied_by([e], "platform", "com.google.inject", "guice-assistedinject", "6.0.0")
  end

  def test_version_constraints
    assert U.denied_by([entry("a:b", versions: ">= 6.0.0")], "platform", "a", "b", "6.1.0")
    refute U.denied_by([entry("a:b", versions: ">= 6.0.0")], "platform", "a", "b", "5.9.0")
    assert U.denied_by([entry("a:b", versions: "= 6.0.0")], "platform", "a", "b", "6.0.0")
    refute U.denied_by([entry("a:b", versions: "= 6.0.0")], "platform", "a", "b", "6.0.1")
    assert U.denied_by([entry("a:b", versions: "6.0.0")], "platform", "a", "b", "6.0.0")
    assert U.denied_by([entry("a:b", versions: "> 6.0.0")], "platform", "a", "b", "6.0.1")
    refute U.denied_by([entry("a:b", versions: "> 6.0.0")], "platform", "a", "b", "6.0.0")
  end

  def test_app_scoping
    e = entry("a:b", apps: ["platform"])
    assert U.denied_by([e], "platform", "a", "b", "2.0.0")
    refute U.denied_by([e], "acumen", "a", "b", "2.0.0")
  end

  def test_apply_policy_partitions
    updates = [
      { group: "a", artifact: "ok", current: "1.0.0", candidates: ["1.1.0"] },
      { group: "a", artifact: "pinned", current: "1.0.0", candidates: ["2.0.0"] },
      { group: "a", artifact: "odd", current: "1.0-play28", candidates: ["2.0.0"] },
    ]
    deny = [entry("a:pinned")]
    r = U.apply_policy(updates, deny, "platform")
    assert_equal [{ group: "a", artifact: "ok", current: "1.0.0", target: "1.1.0" }], r[:bumps]
    assert_equal 1, r[:held].length
    assert_equal "pinned", r[:held].first[:artifact]
    assert_equal "test", r[:held].first[:reason]
    assert_equal ["odd"], r[:skipped].map { |s| s[:artifact] }
  end

  def test_load_denylist_validates_and_handles_missing
    Dir.mktmpdir do |dir|
      assert_equal [], U.load_denylist(File.join(dir, "nope.yml"))
      good = File.join(dir, "good.yml")
      File.write(good, "deny:\n  - artifact: a:b\n    reason: broken\n")
      assert_equal 1, U.load_denylist(good).length
      bad = File.join(dir, "bad.yml")
      File.write(bad, "deny:\n  - artifact: a:b\n")
      assert_raises(RuntimeError) { U.load_denylist(bad) }
    end
  end

  def test_shipped_denylist_parses
    assert_kind_of Array, U.load_denylist(DEPS_DENYLIST_PATH)
  end

  # guice 7 is jakarta.inject-only and play-guice 3.0.x is javax.inject, so the
  # bump cannot be green in ANY repo until Play 3.1.0 ships stable. Denying it
  # per-app would let a lib-ai release push guice 7 onto platform/acumen
  # transitively, so this asserts every watched app is covered — and that 6.0.0
  # (the version that reads both javax and jakarta) is still allowed through.
  def test_shipped_denylist_holds_guice_7_everywhere
    deny = U.load_denylist(DEPS_DENYLIST_PATH)
    %w[guice guice-assistedinject].each do |artifact|
      group = artifact == "guice" ? "com.google.inject" : "com.google.inject.extensions"
      Dependencies::Updates::APPS.each_key do |app|
        assert U.denied_by(deny, app, group, artifact, "7.0.0"),
               "#{group}:#{artifact} 7.0.0 must be denied for #{app}"
        refute U.denied_by(deny, app, group, artifact, "6.0.0"),
               "#{group}:#{artifact} 6.0.0 must stay allowed for #{app}"
      end
    end
  end
end

class TestDependenciesPrompt < Minitest::Test
  def test_prompt_contains_bumps_and_workflow
    bumps = [{ group: "org.postgresql", artifact: "postgresql", current: "42.7.11", target: "42.7.13" }]
    p = Dependencies::Updates.upgrade_prompt(app: "acumen", branch: "dep-upgrade-x", bumps: bumps, issue: 1104)
    assert_includes p, "org.postgresql:postgresql  42.7.11 -> 42.7.13"
    assert_includes p, "./run.sh test"
    assert_includes p, "gh pr create --draft --head dep-upgrade-x"
    assert_includes p, "gh pr ready"
    assert_includes p, "Deferred upgrades"
    assert_includes p, %q{"ISS-1104: Upgrade dependencies"}
    assert_includes p, "never\nforce-push"
  end

  def test_platform_prompt_uses_session_db_in_one_shell_call
    p = Dependencies::Updates.upgrade_prompt(app: "platform", branch: "b", bumps: [], issue: 1)
    assert_includes p, "claude-db start"
    assert_includes p, "CONF_DB_DEV_URL"
    assert_includes p, "&& sbt test"
    assert_includes p, "worktree"
  end

  def test_lib_cipher_prompt_uses_testquick
    p = Dependencies::Updates.upgrade_prompt(app: "lib-cipher", branch: "b", bumps: [], issue: 1)
    assert_includes p, "sbt testQuick"
  end
end

class TestDependenciesArgs < Minitest::Test
  include DevTestSupport

  def test_default_is_all_apps
    assert_equal Dependencies::Updates::APPS.keys, parse_dependencies_args([], "dependencies check").apps
  end

  def test_app_filter_repeatable_and_deduped
    got = parse_dependencies_args(%w[--app platform --app acumen --app platform], "dependencies check")
    assert_equal %w[platform acumen], got.apps
  end

  def test_rejects_unknown_app
    _, status = capture_stderr_and_exit { parse_dependencies_args(%w[--app nope], "dependencies check") }
    assert_equal 1, status
  end

  def test_rejects_unknown_option
    _, status = capture_stderr_and_exit { parse_dependencies_args(%w[--bogus], "dependencies upgrade") }
    assert_equal 1, status
  end

  def test_app_requires_value
    _, status = capture_stderr_and_exit { parse_dependencies_args(%w[--app], "dependencies check") }
    assert_equal 1, status
  end
end

# ISS-1104: the nightly opened PRs titled bare "Upgrade dependencies", which
# `dev agent merge-lane` skips as `no_issue_prefix` and `dev issues reconcile`
# cannot adopt. The number now comes in on `--issue` and titles the PR.
class TestDependenciesIssueNumber < Minitest::Test
  include DevTestSupport

  def test_accepts_bare_and_prefixed_forms
    assert_equal 1104, Dependencies::Updates.parse_issue_number("1104")
    assert_equal 1104, Dependencies::Updates.parse_issue_number("ISS-1104")
    assert_equal 1104, Dependencies::Updates.parse_issue_number(" iss-1104 ")
  end

  # An unsubstituted placeholder out of a playbook (`--issue <n>`) must fail
  # loudly rather than title a PR with something the merge lane will refuse.
  def test_rejects_non_numbers
    ["", "<n>", "ISS-", "0", "12a", "ISS-1104: Upgrade"].each do |bad|
      assert_nil Dependencies::Updates.parse_issue_number(bad), "#{bad.inspect} must not parse"
    end
  end

  def test_parses_issue_for_upgrade
    assert_equal 1104, parse_dependencies_args(%w[--issue ISS-1104], "dependencies upgrade").issue
  end

  def test_issue_is_upgrade_only
    _, status = capture_stderr_and_exit { parse_dependencies_args(%w[--issue 1104], "dependencies check") }
    assert_equal 1, status
  end

  def test_rejects_unparseable_issue
    _, status = capture_stderr_and_exit { parse_dependencies_args(%w[--issue <n>], "dependencies upgrade") }
    assert_equal 1, status
  end

  def test_issue_requires_value
    _, status = capture_stderr_and_exit { parse_dependencies_args(%w[--issue], "dependencies upgrade") }
    assert_equal 1, status
  end

  # The gate the whole issue is about: no issue number, no run — checked before
  # anything is cloned, so no PR can reach GitHub without the prefix.
  def test_refuses_when_there_is_no_issue_anywhere
    out, status = with_agent_issue(nil) { capture_stderr_and_exit { dependencies_issue!(nil) } }
    assert_equal 1, status
    assert_includes out, "no issue number"
  end

  # The case that actually runs: the executor names the child issue this session
  # was spawned for, so the nightly needs no flag and no playbook change.
  def test_defaults_to_the_sessions_own_issue
    assert_equal 1104, with_agent_issue("1104") { dependencies_issue!(nil) }
  end

  def test_explicit_issue_wins_over_the_environment
    assert_equal 42, with_agent_issue("1104") { dependencies_issue!(42) }
  end

  # A DEV_AGENT_ISSUE that is not a number is not an issue number: refuse rather
  # than title a PR `ISS-0:` or `ISS-nonsense:`.
  def test_ignores_a_junk_environment_value
    _out, status = with_agent_issue("nonsense") { capture_stderr_and_exit { dependencies_issue!(nil) } }
    assert_equal 1, status
  end

  def with_agent_issue(value)
    saved = ENV["DEV_AGENT_ISSUE"]
    ENV["DEV_AGENT_ISSUE"] = value
    yield
  ensure
    ENV["DEV_AGENT_ISSUE"] = saved
  end

  def test_pr_title_carries_the_prefix
    assert_equal "ISS-1104: Upgrade dependencies", Dependencies::Updates.pr_title(1104)
  end
end

class TestDependenciesSbtCmd < Minitest::Test
  def test_sbt1_injects_sbt1_plugin_file
    Dir.mktmpdir do |clone|
      FileUtils.mkdir_p(File.join(clone, "project"))
      File.write(File.join(clone, "project", "build.properties"), "sbt.version=1.12.11\n")
      cmd = dependencies_sbt_cmd(clone, "/wd")
      assert_includes cmd, "--addPluginSbtFile=/wd/sbt-updates.sbt"
    end
  end

  # sbt 2 (lib-cipher) has no built-in dependencyUpdates and needs the
  # sbt-updates_sbt2_3 release — a different plugin file, still injected.
  def test_sbt2_injects_sbt2_plugin_file
    Dir.mktmpdir do |clone|
      FileUtils.mkdir_p(File.join(clone, "project"))
      File.write(File.join(clone, "project", "build.properties"), "sbt.version=2.0.1\n")
      cmd = dependencies_sbt_cmd(clone, "/wd")
      assert_includes cmd, "--addPluginSbtFile=/wd/sbt-updates-sbt2.sbt"
    end
  end

  def test_missing_build_properties_defaults_to_sbt1
    Dir.mktmpdir do |clone|
      cmd = dependencies_sbt_cmd(clone, "/wd")
      assert_includes cmd, "--addPluginSbtFile=/wd/sbt-updates.sbt"
    end
  end
end

# ISS-478: the nightly run cloned over SSH from a launchd job with no ssh-agent
# identity, so every repo came back "clone failed" on a box where HTTPS reads and
# writes the same private repos fine.
class TestGithubCloneTransport < Minitest::Test
  def test_github_origin_is_https
    assert_equal "https://github.com/mbryzek/lib-cipher.git", github_origin("mbryzek/lib-cipher")
  end

  def test_rewrites_scp_style_ssh_remote
    assert_equal "https://github.com/mbryzek/platform.git", github_https_url("git@github.com:mbryzek/platform.git")
  end

  def test_rewrites_ssh_remote_without_git_suffix
    assert_equal "https://github.com/mbryzek/platform.git", github_https_url("git@github.com:mbryzek/platform")
  end

  def test_rewrites_ssh_scheme_remote
    assert_equal "https://github.com/mbryzek/platform.git", github_https_url("ssh://git@github.com/mbryzek/platform.git")
  end

  def test_https_remote_is_unchanged
    assert_equal "https://github.com/mbryzek/platform.git", github_https_url("https://github.com/mbryzek/platform.git")
  end

  # `browserslist update` clones from whatever remote a local checkout carries.
  # Only github.com is rewritten — another host or a local path is not ours to
  # rewrite, and silently pointing a clone somewhere else would be worse than
  # failing.
  def test_other_hosts_and_paths_pass_through
    assert_equal "git@gitlab.com:acme/thing.git", github_https_url("git@gitlab.com:acme/thing.git")
    assert_equal "/tmp/some/local/repo", github_https_url("/tmp/some/local/repo")
  end
end

class TestCloneRepo < Minitest::Test
  include DevTestSupport

  # Replaces run_step for the duration of the block, recording its arguments.
  # Defined on Object because bin/dev's helpers are top-level methods.
  def with_recorded_run_step(result)
    calls = []
    Object.send(:alias_method, :__real_run_step, :run_step)
    Object.send(:define_method, :run_step) do |cmd, path, verbose, log, env: {}|
      calls << { cmd: cmd, path: path, env: env }
      log << "fatal: could not read Username for 'https://github.com'\n"
      result
    end
    yield calls
  ensure
    Object.send(:alias_method, :run_step, :__real_run_step)
    Object.send(:remove_method, :__real_run_step)
  end

  def test_clones_an_ssh_origin_over_https
    with_recorded_run_step([true, nil]) do |calls|
      Dir.mktmpdir { |wd| clone_repo("git@github.com:mbryzek/platform.git", "platform", wd, false, +"") }
      assert_includes calls.first[:cmd], "https://github.com/mbryzek/platform.git"
      refute_includes calls.first[:cmd].join(" "), "git@github.com"
    end
  end

  # A credential prompt in a launchd job hangs the sweep for its whole timeout;
  # failing fast with git's own message is the only useful outcome there.
  def test_clone_never_prompts_for_credentials
    with_recorded_run_step([true, nil]) do |calls|
      Dir.mktmpdir { |wd| clone_repo(github_origin("mbryzek/lib-ai"), "lib-ai", wd, false, +"") }
      assert_equal "0", calls.first[:env]["GIT_TERMINAL_PROMPT"]
    end
  end

  def test_failed_clone_returns_nil_and_keeps_gits_reason
    with_recorded_run_step([false, nil]) do |_calls|
      log = +""
      Dir.mktmpdir { |wd| assert_nil clone_repo(github_origin("mbryzek/lib-ai"), "lib-ai", wd, false, log) }
      assert_includes clone_failed_error(log), "could not read Username"
    end
  end

  def test_clone_failed_error_without_output_is_still_readable
    assert_equal "clone failed", clone_failed_error("")
  end
end

# ISS-478: both commands printed `[error] - clone failed` and exited 0, so a
# night where nothing worked was indistinguishable from a quiet one to the agent
# session, the cron and anything else reading `$?`.
class TestDependenciesExitCode < Minitest::Test
  def test_ok_when_every_repo_finished
    results = { "lib-ai" => { status: :pr_opened }, "acumen" => { status: :in_sync } }
    assert_equal DEPS_EXIT_OK, dependencies_exit_code(results)
  end

  # The open-PR gate. The pipeline documents this as a successful, self-gating
  # night, so it must not turn the run red.
  def test_open_pr_skip_is_not_a_failure
    results = { "lib-ai" => { status: :skipped, error: "an open dep-upgrade PR already exists" } }
    assert_equal DEPS_EXIT_OK, dependencies_exit_code(results)
  end

  def test_check_status_ok_is_a_success
    assert_equal DEPS_EXIT_OK, dependencies_exit_code("platform" => { status: :ok, bumps: [] })
  end

  def test_failed_when_any_repo_errored
    results = { "lib-ai" => { status: :in_sync }, "lib-cipher" => { status: :error, error: "clone failed" } }
    assert_equal DEPS_EXIT_FAILED, dependencies_exit_code(results)
  end

  # A Claude session that timed out or ended without a PR left the repo unfinished
  # — not an error status, and previously counted as a clean night.
  def test_failed_when_a_repo_needs_attention
    assert_equal DEPS_EXIT_FAILED, dependencies_exit_code("platform" => { status: :needs_attention })
  end

  # Success is asserted, not inferred: an unrecognised status is not evidence of
  # a healthy run.
  def test_failed_on_an_unknown_status
    assert_equal DEPS_EXIT_FAILED, dependencies_exit_code("platform" => { status: :something_new })
  end

  def test_failed_when_no_repo_was_processed
    assert_equal DEPS_EXIT_FAILED, dependencies_exit_code({})
  end

  # The verdict is the last line of a long nightly log — it has to name the repos
  # that caused the non-zero exit.
  def test_verdict_names_the_failed_repos
    results = { "lib-ai" => { status: :in_sync }, "lib-cipher" => { status: :error }, "acumen" => { status: :needs_attention } }
    verdict = dependencies_verdict(results, DEPS_EXIT_FAILED)
    assert_includes verdict, "lib-cipher"
    assert_includes verdict, "acumen"
    refute_includes verdict, "lib-ai"
  end
end

# Unit-testing `dependencies_exit_code` proves nothing about the process exit
# code: the bug was that the command computed a per-repo status, printed it, and
# then fell off the end returning 0. What is under test here is that the command
# actually exits with the verdict.
class TestDependenciesUpgradeCommand < Minitest::Test
  include DevTestSupport

  def with_stubbed_run(workdir, result)
    Object.send(:alias_method, :__real_upgrade_one, :dependencies_upgrade_one)
    Object.send(:alias_method, :__real_deps_workdir, :dependencies_workdir)
    Object.send(:define_method, :dependencies_upgrade_one) { |*_args, &_blk| result }
    Object.send(:define_method, :dependencies_workdir) { workdir }
    yield
  ensure
    Object.send(:alias_method, :dependencies_upgrade_one, :__real_upgrade_one)
    Object.send(:alias_method, :dependencies_workdir, :__real_deps_workdir)
    Object.send(:remove_method, :__real_upgrade_one)
    Object.send(:remove_method, :__real_deps_workdir)
  end

  def run_upgrade(result)
    status = nil
    out = nil
    Dir.mktmpdir do |workdir|
      with_stubbed_run(workdir, result) do
        out = capture_stdout do
          begin
            cmd_dependencies_upgrade(%w[--app lib-cipher --issue 1104])
          rescue SystemExit => e
            status = e.status
          end
        end
      end
      # The morning briefing reads this file, so a failed night must still write it.
      @status_json = JSON.parse(File.read(File.join(workdir, "dependencies-status.json")))
    end
    [out, status]
  end

  def test_clone_failure_exits_non_zero
    out, status = run_upgrade({ status: :error, error: "clone failed: Permission denied (publickey)" })
    assert_equal DEPS_EXIT_FAILED, status
    assert_includes out, "lib-cipher"
    assert_equal "error", @status_json.first["status"]
  end

  def test_pr_opened_exits_zero
    _out, status = run_upgrade({ status: :pr_opened, pr_url: "https://github.com/mbryzek/lib-cipher/pull/9" })
    assert_equal DEPS_EXIT_OK, status
  end

  def test_in_sync_exits_zero
    _out, status = run_upgrade({ status: :in_sync, held: [] })
    assert_equal DEPS_EXIT_OK, status
  end

  # ISS-1104: refused before any repo is cloned or any session is spawned, so a
  # run that could only produce an unprefixed PR never starts.
  def test_without_issue_refuses_before_doing_anything
    saved = ENV["DEV_AGENT_ISSUE"]
    ENV["DEV_AGENT_ISSUE"] = nil
    ran = false
    Object.send(:alias_method, :__real_upgrade_one, :dependencies_upgrade_one)
    Object.send(:define_method, :dependencies_upgrade_one) { |*_args, &_blk| ran = true; { status: :in_sync } }
    err, status = capture_stderr_and_exit { cmd_dependencies_upgrade(%w[--app lib-cipher]) }
    assert_equal 1, status
    assert_includes err, "no issue number"
    refute ran, "no repo may be processed without an issue number"
  ensure
    ENV["DEV_AGENT_ISSUE"] = saved
    Object.send(:alias_method, :dependencies_upgrade_one, :__real_upgrade_one)
    Object.send(:remove_method, :__real_upgrade_one)
  end

  # The wiring, end to end: the number the session was spawned for reaches the
  # per-repo run, which is what puts it in the prompt and so in the PR title.
  # Every other test here would still pass if the command resolved the issue and
  # then dropped it on the floor.
  def test_resolved_issue_reaches_the_repo_run
    saved = ENV["DEV_AGENT_ISSUE"]
    ENV["DEV_AGENT_ISSUE"] = "1104"
    seen = nil
    Object.send(:alias_method, :__real_upgrade_one, :dependencies_upgrade_one)
    Object.send(:alias_method, :__real_deps_workdir, :dependencies_workdir)
    Dir.mktmpdir do |workdir|
      Object.send(:define_method, :dependencies_workdir) { workdir }
      Object.send(:define_method, :dependencies_upgrade_one) do |*_args, issue:, &_blk|
        seen = issue
        { status: :in_sync, held: [] }
      end
      capture_stdout do
        begin
          cmd_dependencies_upgrade(%w[--app lib-cipher])
        rescue SystemExit
          nil
        end
      end
    end
    assert_equal 1104, seen
  ensure
    ENV["DEV_AGENT_ISSUE"] = saved
    Object.send(:alias_method, :dependencies_upgrade_one, :__real_upgrade_one)
    Object.send(:alias_method, :dependencies_workdir, :__real_deps_workdir)
    Object.send(:remove_method, :__real_upgrade_one)
    Object.send(:remove_method, :__real_deps_workdir)
  end
end
