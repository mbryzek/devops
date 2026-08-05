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
    p = Dependencies::Updates.upgrade_prompt(app: "acumen", branch: "dep-upgrade-x", bumps: bumps)
    assert_includes p, "org.postgresql:postgresql  42.7.11 -> 42.7.13"
    assert_includes p, "./run.sh test"
    assert_includes p, "gh pr create --draft --head dep-upgrade-x"
    assert_includes p, "gh pr ready"
    assert_includes p, "Deferred upgrades"
    assert_includes p, "never\nforce-push"
  end

  def test_platform_prompt_uses_session_db_in_one_shell_call
    p = Dependencies::Updates.upgrade_prompt(app: "platform", branch: "b", bumps: [])
    assert_includes p, "claude-db start"
    assert_includes p, "CONF_DB_DEV_URL"
    assert_includes p, "&& sbt test"
    assert_includes p, "worktree"
  end

  def test_lib_cipher_prompt_uses_testquick
    p = Dependencies::Updates.upgrade_prompt(app: "lib-cipher", branch: "b", bumps: [])
    assert_includes p, "sbt testQuick"
  end
end

class TestDependenciesArgs < Minitest::Test
  include DevTestSupport

  def test_default_is_all_apps
    assert_equal Dependencies::Updates::APPS.keys, parse_dependencies_args([], "dependencies check")
  end

  def test_app_filter_repeatable_and_deduped
    got = parse_dependencies_args(%w[--app platform --app acumen --app platform], "dependencies check")
    assert_equal %w[platform acumen], got
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

# The origin every sweep clones from, and the credential it clones with. This
# used to be an SSH remote, which assumes a GitHub key on every box that runs a
# sweep; the agent runner has a gh token and no key at all, so the whole nightly
# dependency run died at clone (ISS-469 / ISS-475).
class TestGithubOrigin < Minitest::Test
  include DevTestSupport

  def test_origin_is_https_for_every_dependencies_app
    Dependencies::Updates::APPS.each do |app, slug|
      origin = github_origin(slug)
      assert_equal "https://github.com/#{slug}.git", origin, "#{app} must clone over https"
    end
  end

  # The regression itself. An unattended sweep may only depend on a credential
  # that is unconditionally present, and an SSH identity is not one — on
  # 2026-08-05 it was there at 03:48 and gone at 03:50 inside a single run.
  def test_origin_is_never_ssh
    refute_includes github_origin("mbryzek/acumen"), "git@github.com",
                    "an unattended sweep must not depend on an SSH identity"
  end
end

class TestCloneRepoCredentials < Minitest::Test
  include DevTestSupport

  # Captures the argv clone_repo would hand git.
  def clone_cmd(origin: "https://github.com/mbryzek/acumen.git")
    captured = nil
    stub_global(:run_step, lambda { |cmd, _path, _verbose, _log|
      captured = cmd
      [true, ""]
    }) do
      clone_repo(origin, "acumen", "/wd", false, +"")
    end
    captured
  end

  def test_clone_carries_the_gh_credential_helper
    assert_includes clone_cmd.each_cons(2).to_a,
                    ["-c", "credential.https://github.com.helper=!gh auth git-credential"]
  end

  # `-c` on clone persists into the new repo's config, so the fetch and the PR
  # push that follow inherit the same login. A clone that authenticates and a
  # push that then fails is the failure this ordering exists to prevent.
  def test_credential_config_precedes_the_url_so_git_persists_it
    cmd = clone_cmd
    assert cmd.index("-c") < cmd.index("https://github.com/mbryzek/acumen.git")
    assert_equal ["git", "clone"], cmd.first(2)
  end

  def test_returns_nil_when_git_fails
    stub_global(:run_step, ->(_cmd, _p, _v, _l) { [false, "boom"] }) do
      assert_nil clone_repo("https://github.com/mbryzek/acumen.git", "acumen", "/wd", false, +"")
    end
  end
end

class TestDependenciesClone < Minitest::Test
  include DevTestSupport

  def test_returns_path_and_no_error_on_success
    stub_global(:clone_repo, ->(_o, name, workdir, _v, _log) { File.join(workdir, name) }) do
      clone, err = dependencies_clone("acumen", "/wd")
      assert_equal "/wd/acumen", clone
      assert_nil err
    end
  end

  # A bare "clone failed" reads identically for a renamed repo, a dead network,
  # and a missing SSH key — which is exactly why ISS-469 needed an investigation
  # instead of being readable off the report.
  def test_failure_carries_git_output
    git_says = "Cloning into '/wd/acumen'...\n\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n"
    stub_global(:clone_repo, ->(_o, _n, _w, _v, log) { log << git_says; nil }) do
      clone, err = dependencies_clone("acumen", "/wd")
      assert_nil clone
      assert_equal :error, err[:status]
      assert_includes err[:error], "Permission denied (publickey)"
      refute_includes err[:error], "\n\n", "blank lines are dropped so the tail is all signal"
    end
  end

  def test_failure_with_no_output_still_reports
    stub_global(:clone_repo, ->(_o, _n, _w, _v, _log) { nil }) do
      _, err = dependencies_clone("acumen", "/wd")
      assert_equal "clone failed", err[:error]
    end
  end
end
