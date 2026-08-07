#!/usr/bin/env ruby
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)
load File.expand_path('../lib/tag.rb', __dir__)

# Covers the `dev pending {check,release}` subcommand split and the
# RELEASE_AUTO_TAG escape hatch that lets `pending release` run releases
# without interactive prompts.
class TestDevPending < Minitest::Test
  def test_parse_deploy_all_args_defaults
    app_filter, concurrency = parse_deploy_all_args([])
    assert_nil app_filter
    assert_equal 10, concurrency
  end

  def test_parse_deploy_all_args_app_filter
    app_filter, concurrency = parse_deploy_all_args(["--app", "acumen"])
    assert_equal "acumen", app_filter
    assert_equal 10, concurrency
  end

  def test_parse_deploy_all_args_concurrency
    app_filter, concurrency = parse_deploy_all_args(["--concurrency", "8"])
    assert_nil app_filter
    assert_equal 8, concurrency
  end

  def test_parse_deploy_all_args_both_flags
    app_filter, concurrency = parse_deploy_all_args(["--app", "rallyd", "--concurrency", "2"])
    assert_equal "rallyd", app_filter
    assert_equal 2, concurrency
  end

  def test_parse_deploy_all_args_rejects_unknown
    assert_raises(SystemExit) { parse_deploy_all_args(["--bogus"]) }
  end

  def test_parse_deploy_all_args_rejects_zero_concurrency
    assert_raises(SystemExit) { parse_deploy_all_args(["--concurrency", "0"]) }
  end

  def test_parse_deploy_all_args_requires_app_value
    assert_raises(SystemExit) { parse_deploy_all_args(["--app"]) }
  end

  def test_tag_auto_false_by_default
    ENV.delete(Tag::AUTO_TAG_ENV)
    refute Tag.auto?
  end

  def test_tag_auto_true_for_truthy_values
    %w[1 true yes TRUE Yes].each do |v|
      ENV[Tag::AUTO_TAG_ENV] = v
      assert Tag.auto?, "expected Tag.auto? to be true for #{v.inspect}"
    end
  ensure
    ENV.delete(Tag::AUTO_TAG_ENV)
  end

  def test_tag_auto_false_for_other_values
    %w[0 no false off].each do |v|
      ENV[Tag::AUTO_TAG_ENV] = v
      refute Tag.auto?, "expected Tag.auto? to be false for #{v.inspect}"
    end
  ensure
    ENV.delete(Tag::AUTO_TAG_ENV)
  end

  def test_db_repo_identifies_postgresql_suffix
    assert db_repo?("platform-postgresql")
    assert db_repo?("acumen-postgresql")
    refute db_repo?("platform")
    refute db_repo?("acumen")
    refute db_repo?("postgresql-tools")
  end

  def test_lib_repo_identifies_lib_prefix
    assert lib_repo?("lib-util")
    assert lib_repo?("lib-cipher")
    refute lib_repo?("platform")
    refute lib_repo?("hoa-frontend")
    # A library is never also a DB repo, so the three release paths stay disjoint.
    refute(lib_repos.any? { |n| db_repo?(n) })
  end

  # The lib list is the one `dev dependencies` already watches, so there is a
  # single definition of "our scala libs" rather than a second hardcoded copy.
  def test_lib_repos_come_from_the_dependencies_registry
    assert_equal Dependencies::Updates::APPS.keys.select { |n| n.start_with?("lib-") }.sort,
                 lib_repos.sort
    assert_includes lib_repos, "lib-util"
    refute_includes lib_repos, "platform"
  end
end

# A stand-in apps registry. Shared by every deploy test rather than nested in
# one class: the app <-> schema-repo mapping is now read by the release
# orchestration too (ISS-738), and a second copy of the fake would be a second
# definition of what a deployable looks like.
module DeployRegistryFake
  FakeApp = Struct.new(:name, :stack, :repo, keyword_init: true) do
    # Mirrors Work::Registry::App: the repo (and so the checkout dir) defaults to
    # the app name but can differ once an app is rebranded ahead of its repo.
    def repo_name = (repo || name).split("/").last
  end

  class FakeRegistry
    def initialize(apps, deploy_tracked)
      @apps = apps
      @deploy_tracked = deploy_tracked
    end
    attr_reader :apps
    def deploy_tracked = @deploy_tracked
    def find(name) = @apps.find { |a| a.name == name }
  end

  # platform and playbook-api are ONE codebase deployed to two DigitalOcean
  # accounts, so both are built from ~/code/platform and both are migrated by
  # platform-postgresql. That pair is the whole subject of ISS-738, so it is the
  # default fleet here.
  def default_registry_apps
    [
      FakeApp.new(name: "platform",     stack: :scala, repo: "mbryzek/platform"),
      FakeApp.new(name: "playbook-api", stack: :scala, repo: "mbryzek/platform"),
      FakeApp.new(name: "acumen",       stack: :scala),
    ]
  end

  def fake_registry(apps, deploy_tracked = nil)
    FakeRegistry.new(apps, deploy_tracked || apps)
  end

  def with_registry(apps, deploy_tracked = nil)
    registry = fake_registry(apps, deploy_tracked)
    orig = Work::Registry.method(:load)
    Work::Registry.define_singleton_method(:load) { registry }
    yield
  ensure
    Work::Registry.define_singleton_method(:load, orig)
  end
end

# Every seam `run_deploys` crosses between a list of pending items and a set of
# released names. A class that releases anything has to replace ALL of them, not
# the ones it happens to think of, because two of the three reach this machine:
# phase gating resolves the app <-> schema-repo mapping through the registry
# (`pkl eval` per app over ~/code/env/apps), and the expanding/contracting split
# shells out to `sem-info` and git in the REAL checkout the stubbed rows do not
# have. Miss one and the test asserts on whatever is checked out here.
#
# That is what ISS-795 was: TestDeployStatusPrompt stubbed neither, so its
# DB-before-app ordering test resolved gating against the real fleet — right on
# an idle box, and wrong when the box was loaded enough for the shell-outs to
# resolve differently or slowly. Sharing the seams is what stops the next class
# from picking a different subset of them.
#
# Included rather than inherited so a class keeps its own other stubs
# (DeployStatusStubs); call `stub_release_seams` from setup. Nothing needs a
# teardown: every stub goes through `stub_global_for_test`, which GuardEveryTest
# restores after the test.
module DeployReleaseStubs
  include DevTestSupport # stub_global_for_test
  include DeployRegistryFake

  # Names in the order `release_one` saw them.
  attr_reader :released

  # How many times the deploy filed its post-deploy work. Counted rather than
  # asserted present because the bug both ISS-810 and ISS-816 describe was N of
  # them, not none: one per app, concurrently, for work that is global.
  attr_reader :filings

  # The app names of each filing, in order.
  attr_reader :filed_apps

  # Stands in for PostDeployWork so a test never files against the real tracker —
  # `run_deploys` reaches it on every successful app release.
  FakeWork = Struct.new(:names, :on_file) do
    def any? = true

    def file!
      on_file.call(names)
      PostDeployWork::Filed.new(epic: 900, children: [[901, "Reconcile feature flags"]])
    end

    def manual_commands = []
  end

  # A tracker the deploy cannot reach. The deploy is already over when this
  # happens, so what is asserted is the report and the exit code, not a retry.
  class ExplodingWork
    def any? = true
    def file! = raise(ApiError, "no AI API token stored")
    def manual_commands = ["api publish", "dev features reconcile --apply", "dev issues reconcile --apply"]
  end

  def stub_release_seams
    @released = []
    @released_mutex = Mutex.new
    @release_results = {}
    @registry_apps = default_registry_apps
    @untracked = []
    @contracting = []
    @filings = 0
    @filed_apps = []

    # Each stub body lands on Object, so `self` inside it is NOT the test — but a
    # lambda defined here keeps this test as its own self, so the ivars above
    # stay readable (and a test can still change them after setup).
    registry = -> { fake_registry(@registry_apps, @registry_apps.reject { |a| @untracked.include?(a.name) }) }
    # Phase 1 releases the serial DB thread alongside the free apps, so these
    # appends genuinely race — the accumulator is shared mutable state and needs
    # the mutex, not just the assertion that reads it.
    release = lambda do |name|
      @released_mutex.synchronize { @released << name }
      @release_results.fetch(name) { { ok: true, log: "ok" } }
    end
    # Reading a DB repo's new migrations means a git checkout these stubbed rows
    # do not have. Default every DB to expanding — what every test written before
    # ISS-317 assumes — and let a test name its contracting repos.
    partition = ->(db_pending) { db_pending.partition { |n| !@contracting.include?(n) } }
    # The filing happens after every phase, so it is not concurrent with
    # anything — but it is reached from the same run_deploys the release threads
    # feed, so count it under the same mutex as the releases.
    file = lambda do |names|
      @released_mutex.synchronize do
        @filings += 1
        @filed_apps << names
      end
    end

    stub_global_for_test(:cached_registry) { registry.call }
    stub_global_for_test(:release_one) { |name, _progress| release.call(name) }
    stub_global_for_test(:partition_db_releases) { |db_pending| partition.call(db_pending) }
    stub_global_for_test(:post_deploy_work) { |names| DeployReleaseStubs::FakeWork.new(names, file) }
  end

  # Like capture_io, but tolerates SystemExit (cmd_deploy_all calls `exit 1` on
  # failure). Returns [output, system_exit_or_nil] so callers can assert on both.
  def capture_io_with_exit
    buf = StringIO.new
    old = $stdout
    $stdout = buf
    exc = nil
    begin
      yield
    rescue SystemExit => e
      exc = e
    end
    [buf.string, exc]
  ensure
    $stdout = old
  end

  # Phases 3 and 5 (libraries, devops) run only with someone to answer a prompt.
  def with_tty(interactive)
    orig = Object.instance_method(:interactive_terminal?)
    Object.send(:define_method, :interactive_terminal?) { interactive }
    yield
  ensure
    Object.send(:define_method, :interactive_terminal?, orig)
  end

  def contracting!(*names)
    @contracting = names
  end

  # Name a different fleet than the platform / playbook-api / acumen default.
  def registry!(*apps)
    @registry_apps = apps
  end

  # Name an app the registry knows and `dev deploy` does not release (an ignored
  # deployable sharing another app's repo).
  def untracked!(*names)
    @untracked = names
  end

  # The invariant every DB-first ordering test actually pins: no app released
  # before a database. Stated as an index comparison rather than an exact list
  # because phase 1 runs the DB thread and the free apps CONCURRENTLY — an exact
  # list would also assert a scheduling order nothing guarantees — and because it
  # reports what it got when it does trip.
  def assert_dbs_before_apps
    db_idx  = @released.each_index.select { |i| db_repo?(@released[i]) }
    app_idx = @released.each_index.reject { |i| db_repo?(@released[i]) }
    refute_empty db_idx,  "expected a database release, got #{@released.inspect}"
    refute_empty app_idx, "expected an app release, got #{@released.inspect}"
    assert db_idx.max < app_idx.min, "expected all DBs before any app, got #{@released.inspect}"
  end
end

# deploy_items derives DB repos from the apps registry (scala apps ship a
# "<repo>-postgresql" repo), NOT from a filesystem glob — so abandoned
# *-postgresql checkouts next to the apps are never picked up.
class TestPendingItems < Minitest::Test
  include DeployRegistryFake
  FakeApp = DeployRegistryFake::FakeApp

  def names = deploy_items.map(&:first)

  def dirs = deploy_items.to_h { |name, dir, _| [name, dir] }

  # A deployable can be rebranded ahead of its repo, and the checkout on disk is
  # named for the repo — so the deploy list must follow `repo`, not `name`. Getting
  # this wrong makes `dev deploy status` report "no checkout" for a renamed app.
  def test_checkout_dir_follows_the_repo_not_the_app_name
    apps = [FakeApp.new(name: "playbook-www", stack: :sveltekit, repo: "mbryzek/legacy-www")]
    with_registry(apps) do
      assert_includes names, "playbook-www"
      assert_equal File.expand_path("~/code/legacy-www"), dirs["playbook-www"]
    end
  end

  def test_db_repo_follows_the_repo_not_the_app_name
    apps = [FakeApp.new(name: "playbook", stack: :scala, repo: "mbryzek/platform")]
    with_registry(apps) do
      assert_includes names, "platform-postgresql"
      refute_includes names, "playbook-postgresql"
    end
  end

  def test_derives_db_repo_per_scala_app
    apps = [
      FakeApp.new(name: "platform", stack: :scala),
      FakeApp.new(name: "acumen",   stack: :scala),
    ]
    with_registry(apps) do
      assert_includes names, "platform-postgresql"
      assert_includes names, "acumen-postgresql"
    end
  end

  def test_non_scala_apps_get_no_db_repo
    apps = [
      FakeApp.new(name: "rallyd",    stack: :sveltekit),
      FakeApp.new(name: "acumen-ui", stack: :elm),
    ]
    with_registry(apps) do
      refute(names.any? { |n| n.end_with?("-postgresql") })
    end
  end

  def test_non_deployable_scala_app_gets_no_db_repo
    # An ignored/archived scala app is in `apps` but not in `deploy_tracked`; its
    # DB repo must not show up as a phantom pending entry.
    scala = FakeApp.new(name: "archived", stack: :scala)
    with_registry([scala], []) do
      refute_includes names, "archived-postgresql"
    end
  end

  def test_ignores_stray_postgresql_checkouts_on_disk
    # Even if e.g. ~/code/dependency-postgresql exists on disk, it is not in the
    # registry as a scala app, so it must not appear.
    apps = [FakeApp.new(name: "platform", stack: :scala)]
    with_registry(apps) do
      refute_includes names, "dependency-postgresql"
    end
  end

  def test_db_repo_path_is_sibling_of_apps
    apps = [FakeApp.new(name: "platform", stack: :scala)]
    with_registry(apps) do
      _, dir = deploy_items.find { |n, _| n == "platform-postgresql" }
      assert_equal File.expand_path("~/code/platform-postgresql"), dir
    end
  end

  # Libraries are not registry apps (they ship to Maven Central), so they are
  # added independently of whatever the registry holds.
  def test_libraries_are_always_included
    with_registry([FakeApp.new(name: "platform", stack: :scala)]) do
      lib_repos.each { |lib| assert_includes names, lib }
    end
  end

  def test_library_path_is_sibling_of_apps
    with_registry([FakeApp.new(name: "platform", stack: :scala)]) do
      assert_equal File.expand_path("~/code/lib-util"), dirs["lib-util"]
    end
  end

  # devops is not a registry app either — it ships nothing — but it still falls
  # behind, and nothing else in the fleet reports that.
  def test_devops_is_always_included
    with_registry([FakeApp.new(name: "platform", stack: :scala)]) do
      assert_includes names, "devops"
      assert_equal File.expand_path("~/code/devops"), dirs["devops"]
      refute_includes names, "devops-postgresql"
    end
  end

  # Libraries are not scala *apps*, so they must not sprout a DB repo.
  def test_libraries_get_no_db_repo
    with_registry([FakeApp.new(name: "platform", stack: :scala)]) do
      refute_includes names, "lib-util-postgresql"
    end
  end

  def test_results_sorted_and_unique
    apps = [
      FakeApp.new(name: "platform", stack: :scala),
      FakeApp.new(name: "acumen",   stack: :scala),
    ]
    with_registry(apps) do
      assert_equal names, names.sort
      assert_equal names, names.uniq
    end
  end
end

# cmd_deploy_all orchestrates DB-first + parallel-app workers. DeployReleaseStubs
# replaces every seam it crosses to release something; the rows it starts from are
# this class's own.
class TestPendingReleaseOrchestration < Minitest::Test
  include DeployReleaseStubs

  def setup
    @rows = []
    stub_release_seams
    rows_ref = -> { @rows }
    stub_global_for_test(:resolve_deploy_items) { |_| rows_ref.call }
  end

  def capture_io
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def test_releases_only_apps_with_ahead_gt_zero
    @rows = [
      ["acumen",   { tag: "0.0.1", ahead: 1, last: "abc msg" }],
      ["rallyd",   { tag: "0.0.2", ahead: 0, last: "def msg" }],
      ["michaelb", { tag: "0.0.3", ahead: 2, last: "ghi msg" }],
    ]
    out = capture_io { cmd_deploy_all(["--concurrency", "2"]) }
    assert_equal %w[acumen michaelb].sort, @released.sort
    assert_match(/released: acumen, michaelb|released: michaelb, acumen/, out)
  end

  def test_skips_pending_detection_errors_but_continues
    @rows = [
      ["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }],
      ["broken", { error: "no checkout" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal ["acumen"], @released
    assert_match(/Deploy-detection errors:/, out)
    assert_match(/broken: no checkout/, out)
  end

  def test_exits_nonzero_when_any_release_fails
    @rows = [
      ["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }],
      ["rallyd", { tag: "0.0.2", ahead: 1, last: "def" }],
    ]
    @release_results = {
      "acumen" => { ok: true,  log: "" },
      "rallyd" => { ok: false, log: "boom" },
    }
    err = assert_raises(SystemExit) do
      capture_io { cmd_deploy_all([]) }
    end
    assert_equal 1, err.status
  end

  def test_no_pending_prints_up_to_date_and_does_not_release
    @rows = [["acumen", { tag: "0.0.1", ahead: 0, last: "abc" }]]
    out = capture_io { cmd_deploy_all([]) }
    assert_empty @released
    assert_match(/All apps up to date/, out)
  end

  def test_handles_release_one_raising
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }]]
    Object.send(:define_method, :release_one) { |_, _progress| raise "kaboom" }
    err = assert_raises(SystemExit) do
      capture_io { cmd_deploy_all([]) }
    end
    assert_equal 1, err.status
  end

  # The captured log in `results` can be short (a crash message, an empty
  # buffer) exactly when the failure is least obvious. The per-app log file
  # holds everything, so the summary names it — the one-time hint printed
  # before the release started has long since scrolled away.
  def test_failure_summary_names_the_apps_log_file
    app = "test-dev-deploy-log-fixture"
    path = deploy_log_path(app)
    File.write(path, "the full story\n")
    @rows = [[app, { tag: "0.0.1", ahead: 1, last: "abc" }]]
    @release_results = { app => { ok: false, log: "boom" } }

    out, exc = capture_io_with_exit { cmd_deploy_all([]) }

    assert_equal 1, exc.status
    assert_includes out, "full log: #{path}"
    assert_includes out, "boom"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_releases_prod_stale_app_with_no_new_commits
    @rows = [
      ["acumen", { tag: "0.0.2", ahead: 0, last: "a", prod: "0.0.1", prod_stale: true }],
      ["rallyd", { tag: "0.0.3", ahead: 0, last: "b", prod: "0.0.3", prod_stale: false }],
    ]
    capture_io { cmd_deploy_all([]) }
    assert_equal ["acumen"], @released
  end

  # ---- Phase ordering + DB-failure skip ----
  #
  # A DB gates only the app named after it (foo-postgresql -> foo). Unrelated
  # apps release in parallel with the serial DB phase rather than waiting it out.

  def test_each_app_waits_for_its_own_db
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql",   { tag: "0.0.2", ahead: 1, last: "b" }],
      ["platform",            { tag: "0.0.3", ahead: 1, last: "c" }],
      ["platform-postgresql", { tag: "0.0.4", ahead: 1, last: "d" }],
    ]
    capture_io { cmd_deploy_all([]) }
    assert_dbs_before_apps
  end

  def test_db_releases_run_serially
    order = []
    order_mutex = Mutex.new
    @rows = [
      ["acumen-postgresql",   { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    Object.send(:define_method, :release_one) do |name, _progress|
      order_mutex.synchronize { order << "start:#{name}" }
      sleep 0.02 # let other workers race — they shouldn't
      order_mutex.synchronize { order << "end:#{name}" }
      { ok: true, log: "" }
    end
    capture_io { cmd_deploy_all(["--concurrency", "8"]) }
    # Serial: every start is immediately followed by its end with no other start
    # interleaved between them.
    pairs = order.each_slice(2).to_a
    pairs.each do |start_evt, end_evt|
      assert_match(/^start:/, start_evt)
      assert_match(/^end:/, end_evt)
      assert_equal start_evt.sub("start:", ""), end_evt.sub("end:", "")
    end
  end

  # The regression: acumen has no dependency on platform-postgresql, so it must
  # not sit behind that migration. Its release starts while the DB is still
  # running.
  def test_app_with_no_pending_db_releases_alongside_the_db_phase
    events = []
    events_mutex = Mutex.new
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform",            { tag: "0.0.2", ahead: 1, last: "b" }],
      ["platform-postgresql", { tag: "0.0.3", ahead: 1, last: "c" }],
    ]
    Object.send(:define_method, :release_one) do |name, _progress|
      events_mutex.synchronize { events << "start:#{name}" }
      sleep 0.05 if name == "platform-postgresql"
      events_mutex.synchronize { events << "end:#{name}" }
      { ok: true, log: "" }
    end
    out = capture_io { cmd_deploy_all(["--concurrency", "8"]) }
    assert_operator events.index("start:acumen"), :<, events.index("end:platform-postgresql"),
      "acumen must not wait for an unrelated DB, got #{events.inspect}"
    # platform DOES depend on it, so it still waits.
    assert_operator events.index("end:platform-postgresql"), :<, events.index("start:platform"),
      "platform must wait for its own DB, got #{events.inspect}"
    assert_match(/in parallel with 1 app\(s\) that depend on none of them: acumen/, out)
  end

  # Nothing is gated, so every app rides along with the DB phase and there is no
  # second app phase to announce.
  def test_no_phase_2_when_no_app_depends_on_a_pending_db
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal %w[acumen platform-postgresql].sort, @released.sort
    assert_match(/Phase 1/, out)
    refute_match(/Phase 2/, out)
  end

  def test_failed_db_skips_matching_app_but_releases_unrelated_apps
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql",   { tag: "0.0.2", ahead: 1, last: "b" }],
      ["platform",            { tag: "0.0.3", ahead: 1, last: "c" }],
    ]
    @release_results = {
      "acumen-postgresql" => { ok: false, log: "migration died" },
    }
    _, exc = capture_io_with_exit { cmd_deploy_all([]) }
    refute_nil exc
    assert_equal 1, exc.status
    # acumen-postgresql attempted (and failed); platform attempted; acumen skipped.
    assert_includes @released, "acumen-postgresql"
    assert_includes @released, "platform"
    refute_includes @released, "acumen"
  end

  def test_skipped_app_appears_in_summary
    @rows = [
      ["acumen",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    @release_results = {
      "acumen-postgresql" => { ok: false, log: "boom" },
    }
    out, exc = capture_io_with_exit { cmd_deploy_all([]) }
    refute_nil exc
    assert_match(/skipped:\s+acumen \(db release failed/, out)
  end

  def test_db_pending_with_no_matching_app_does_not_skip_anything
    @rows = [
      ["athena-postgresql", { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform",          { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    @release_results = {
      "athena-postgresql" => { ok: false, log: "boom" },
    }
    out, exc = capture_io_with_exit { cmd_deploy_all([]) }
    refute_nil exc
    assert_includes @released, "platform"
    refute_match(/skipped:/, out)
  end

  def test_only_apps_pending_no_phase_1_header
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = capture_io { cmd_deploy_all([]) }
    refute_match(/Phase 1/, out)
    assert_match(/Phase 2/, out)
  end

  def test_only_dbs_pending_no_phase_2_header
    @rows = [["platform-postgresql", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = capture_io { cmd_deploy_all([]) }
    assert_match(/Phase 1/, out)
    refute_match(/Phase 2/, out)
  end

  # ---- Phase 3: libraries ----
  #
  # `release-lib` owns the terminal while it prompts (tag confirmation, GPG
  # passphrase), so libraries release last and one at a time — never alongside
  # the parallel app phase, whose output would bury the prompt.

  def test_libraries_release_after_apps_and_dbs
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql",   { tag: "0.0.2", ahead: 1, last: "b" }],
      ["lib-util",            { tag: "0.0.3", ahead: 1, last: "c" }],
    ]
    out = with_tty(true) { capture_io { cmd_deploy_all([]) } }
    assert_equal %w[acumen-postgresql acumen lib-util], @released
    assert_match(/Phase 4: releasing 1 library serially \(interactive\): lib-util/, out)
  end

  def test_libraries_release_serially
    order = []
    order_mutex = Mutex.new
    @rows = [
      ["lib-util",  { tag: "0.0.1", ahead: 1, last: "a" }],
      ["lib-query", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    Object.send(:define_method, :release_one) do |name, _progress|
      order_mutex.synchronize { order << "start:#{name}" }
      sleep 0.02 # let another worker race — there shouldn't be one
      order_mutex.synchronize { order << "end:#{name}" }
      { ok: true, log: "" }
    end
    with_tty(true) { capture_io { cmd_deploy_all(["--concurrency", "8"]) } }
    order.each_slice(2) do |start_evt, end_evt|
      assert_equal start_evt.sub("start:", ""), end_evt.sub("end:", "")
    end
  end

  def test_only_libraries_pending_no_app_or_db_phases
    @rows = [["lib-cipher", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = with_tty(true) { capture_io { cmd_deploy_all([]) } }
    refute_match(/Phase 1/, out)
    refute_match(/Phase 2/, out)
    assert_match(/Phase 4/, out)
    assert_equal ["lib-cipher"], @released
  end

  # Without a terminal (pipe, cron) release-lib's first prompt would die on EOF.
  # Skip the library rather than fail mid-release — but say so, and exit
  # non-zero, because the fleet is still behind.
  def test_libraries_skipped_without_a_terminal
    @rows = [
      ["acumen",   { tag: "0.0.1", ahead: 1, last: "a" }],
      ["lib-util", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out, exc = with_tty(false) { capture_io_with_exit { cmd_deploy_all([]) } }
    assert_equal ["acumen"], @released, "the app must still release"
    refute_nil exc
    assert_equal 1, exc.status
    assert_match(/skipped:\s+lib-util \(library release is interactive/, out)
  end

  def test_up_to_date_libraries_are_not_released
    @rows = [["lib-util", { tag: "0.0.1", ahead: 0, last: "a" }]]
    out = with_tty(true) { capture_io { cmd_deploy_all([]) } }
    assert_empty @released
    assert_match(/All apps up to date/, out)
  end

  # --- ISS-317: contracting migrations release AFTER their app ---------------
  #
  # A schema release that DROPs a column or table the live code still selects
  # took production down twice in two days when it was applied in Phase 1: the
  # old pods answered `does not exist` for every request touching the object,
  # for the whole length of the app's build and rollout.

  def test_contracting_db_releases_after_its_app
    contracting!("platform-postgresql")
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal ["platform", "platform-postgresql"], @released
    assert_match(/Phase 3: releasing 1 contracting database\(s\) serially, after their apps: platform-postgresql/, out)
  end

  def test_expanding_db_still_releases_before_its_app
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    capture_io { cmd_deploy_all([]) }
    assert_equal ["platform-postgresql", "platform"], @released
  end

  # An app whose own DB is contracting is not gated by it — it goes in the first
  # wave, alongside the expanding DBs, because the drop is what waits.
  def test_app_of_a_contracting_db_is_not_held_behind_an_unrelated_expanding_db
    contracting!("platform-postgresql")
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
      ["acumen-postgresql",   { tag: "0.0.3", ahead: 1, last: "c" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_match(/Phase 1: releasing 1 database\(s\) serially: acumen-postgresql/, out)
    assert_match(/in parallel with 1 app\(s\).*: platform/, out)
    assert_operator @released.index("platform"), :<, @released.index("platform-postgresql")
  end

  # The drop is only safe once the code that stopped using the object is live.
  # If that release failed, the old code is what production is still running, so
  # applying the migration would reproduce the incident exactly.
  def test_contracting_db_is_held_back_when_its_app_fails
    contracting!("platform-postgresql")
    @release_results = { "platform" => { ok: false, log: "boom" } }
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out, exc = capture_io_with_exit { cmd_deploy_all([]) }
    assert_equal ["platform"], @released
    refute_nil exc
    assert_match(/skipped:\s+platform-postgresql \(contracting migration held back: platform did not release/, out)
  end

  # Nothing else is pending, so there is no app to wait for and the migration
  # applies on its own.
  def test_contracting_db_releases_when_its_app_is_not_pending
    contracting!("platform-postgresql")
    @rows = [["platform-postgresql", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal ["platform-postgresql"], @released
    refute_match(/Phase 1:/, out)
    assert_match(/Phase 3:/, out)
  end

  # --- ISS-738: a schema repo migrates EVERY deployable built from its repo ---
  #
  # platform-postgresql is applied to both platform and playbook-api (the same
  # codebase, two DigitalOcean accounts), so both directions of the gating have
  # to see both deployables — not just the one the schema repo is named after.

  # The failure the issue describes: the primary app ships, the second deployable
  # does not, and the drop would land against a copy of the schema whose code is
  # still selecting the dropped object.
  def test_contracting_db_is_held_back_when_a_second_deployable_fails
    contracting!("platform-postgresql")
    @release_results = { "playbook-api" => { ok: false, log: "image pull failed" } }
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["playbook-api",        { tag: "0.0.1", ahead: 1, last: "b" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "c" }],
    ]
    out, exc = capture_io_with_exit { cmd_deploy_all([]) }
    refute_includes @released, "platform-postgresql"
    refute_nil exc
    assert_match(/skipped:\s+platform-postgresql \(contracting migration held back: playbook-api did not release/, out)
  end

  # Both deployables shipped, so nothing is left running the old code and the
  # drop is safe — the hold-back must not fire just because a second name exists.
  def test_contracting_db_releases_when_every_deployable_succeeds
    contracting!("platform-postgresql")
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["playbook-api",        { tag: "0.0.1", ahead: 1, last: "b" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "c" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal "platform-postgresql", @released.last
    assert_match(/Phase 3: releasing 1 contracting database\(s\)/, out)
  end

  # Every failed deployable is named, so the summary says which release to retry.
  def test_hold_back_names_every_deployable_that_failed
    contracting!("platform-postgresql")
    @release_results = {
      "platform"     => { ok: false, log: "boom" },
      "playbook-api" => { ok: false, log: "boom" },
    }
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["playbook-api",        { tag: "0.0.1", ahead: 1, last: "b" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "c" }],
    ]
    out, = capture_io_with_exit { cmd_deploy_all([]) }
    assert_match(/held back: platform, playbook-api did not release/, out)
  end

  # The mirror of the same bug, in the expanding direction: keying on the app's
  # own name looked for a playbook-api-postgresql that does not exist, found no
  # gate, and rolled the second deployable out in Phase 1 — in parallel with the
  # migration its new code needs.
  def test_second_deployable_waits_for_the_expanding_db_of_its_repo
    @rows = [
      ["playbook-api",        { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal ["platform-postgresql", "playbook-api"], @released
    refute_match(/in parallel with/, out)
  end

  def test_second_deployable_is_skipped_when_the_db_of_its_repo_fails
    @release_results = { "platform-postgresql" => { ok: false, log: "boom" } }
    @rows = [
      ["playbook-api",        { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out, exc = capture_io_with_exit { cmd_deploy_all([]) }
    assert_equal ["platform-postgresql"], @released
    refute_nil exc
    assert_match(/skipped:\s+playbook-api \(db release failed \(platform-postgresql\)\)/, out)
  end

  # An app the registry does not know still falls back to the naming convention,
  # so nothing about the pre-registry behaviour changes for it.
  def test_unknown_app_still_gated_by_its_conventional_db
    registry!
    @rows = [
      ["acumen",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    capture_io { cmd_deploy_all([]) }
    assert_equal ["acumen-postgresql", "acumen"], @released
  end

  # The state the fleet is actually in mid-account-split: playbook-api has a
  # database config (so release-db migrates it) but is ignored (so nothing here
  # releases or probes it). There is no release to wait for, so the drop still
  # goes — but it says out loud whose schema it just changed unchecked, rather
  # than reporting a clean Phase 3.
  def test_untracked_target_is_warned_about_not_held_back
    untracked!("playbook-api")
    contracting!("platform-postgresql")
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal ["platform", "platform-postgresql"], @released
    assert_match(/WARNING: platform-postgresql also migrates playbook-api, which this deploy does not release/, out)
  end

  # The ordinary fleet must stay quiet: a schema repo whose every deployable is
  # released has nothing unchecked, and a warning on every contracting release
  # would train everyone to ignore this one.
  def test_no_warning_when_every_target_is_released
    contracting!("platform-postgresql")
    @rows = [
      ["platform",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["playbook-api",        { tag: "0.0.1", ahead: 1, last: "b" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "c" }],
    ]
    out = capture_io { cmd_deploy_all([]) }
    refute_match(/WARNING/, out)
  end
end

# The app <-> schema-repo mapping both deploy phases gate on. One schema repo can
# migrate several deployables (ISS-738), so neither direction may be derived from
# a single conventional name.
class TestDeployDbAppMapping < Minitest::Test
  include DeployRegistryFake

  def registry
    fake_registry(default_registry_apps)
  end

  def test_app_for_db_strips_the_suffix
    assert_equal "platform", app_for_db("platform-postgresql")
    assert_equal "acumen", app_for_db("acumen-postgresql")
  end

  def test_apps_for_db_returns_every_deployable_built_from_the_repo
    assert_equal %w[platform playbook-api], apps_for_db("platform-postgresql", registry)
  end

  def test_apps_for_db_returns_the_single_deployable_of_an_unshared_repo
    assert_equal ["acumen"], apps_for_db("acumen-postgresql", registry)
  end

  # A DB repo with no registry app behind it keeps the conventional answer rather
  # than an empty list, which would silently disable the hold-back.
  def test_apps_for_db_falls_back_to_the_conventional_name
    assert_equal ["mystery"], apps_for_db("mystery-postgresql", registry)
  end

  def test_db_for_app_follows_the_repo_not_the_app_name
    assert_equal "platform-postgresql", db_for_app("playbook-api", registry)
    assert_equal "platform-postgresql", db_for_app("platform", registry)
    assert_equal "acumen-postgresql", db_for_app("acumen", registry)
  end

  def test_db_for_app_falls_back_to_the_conventional_name
    assert_equal "mystery-postgresql", db_for_app("mystery", registry)
  end

  def test_blocking_db_only_gates_on_a_pending_db
    assert_equal "platform-postgresql", blocking_db_for("playbook-api", ["platform-postgresql"], registry)
    assert_nil blocking_db_for("playbook-api", ["acumen-postgresql"], registry)
    assert_nil blocking_db_for("playbook-api", [], registry)
  end

  # A deployable with no database config is not a migration target: release-db
  # selects on the scala block, and so does this.
  def test_db_targets_exclude_a_deployable_with_no_database
    apps = default_registry_apps.reject { |a| a.name == "playbook-api" } +
           [FakeApp.new(name: "playbook-api", stack: :unknown, repo: "mbryzek/platform")]
    assert_equal ["platform"], apps_for_db("platform-postgresql", fake_registry(apps))
  end

  # An IGNORED target still counts. release-db never reads the ignore flag, so
  # the migration lands in that database either way — it is exactly the one this
  # run cannot vouch for.
  def test_unchecked_targets_name_an_ignored_deployable
    tracked = default_registry_apps.reject { |a| a.name == "playbook-api" }
    reg = fake_registry(default_registry_apps, tracked)
    assert_equal %w[platform playbook-api], apps_for_db("platform-postgresql", reg)
    assert_equal [["platform-postgresql", ["playbook-api"]]],
                 unchecked_db_targets(["platform-postgresql"], reg)
  end

  def test_unchecked_targets_are_empty_when_every_target_is_released
    assert_empty unchecked_db_targets(%w[platform-postgresql acumen-postgresql], registry)
  end
end

# The shared pending predicate: unreleased commits OR prod running something
# other than the latest tag. Used by both `pending check` and `pending release`.
class TestPendingRow < Minitest::Test
  def test_ahead_is_pending
    assert needs_deploy?({ tag: "0.0.1", ahead: 1, last: "x" })
  end

  def test_up_to_date_not_pending
    refute needs_deploy?({ tag: "0.0.1", ahead: 0, last: "x" })
  end

  def test_prod_stale_is_pending_even_with_no_new_commits
    assert needs_deploy?({ tag: "0.0.2", ahead: 0, last: "x", prod: "0.0.1", prod_stale: true })
  end

  def test_prod_matching_tag_not_pending
    refute needs_deploy?({ tag: "0.0.2", ahead: 0, last: "x", prod: "0.0.2", prod_stale: false })
  end

  def test_prod_error_alone_not_pending
    refute needs_deploy?({ tag: "0.0.2", ahead: 0, last: "x", prod_error: "HTTP 503" })
  end

  def test_detection_error_not_pending
    refute needs_deploy?({ error: "no checkout" })
  end
end

# print_deploy_status_table: a mixed fleet splits pending apps into a trailing
# "needs deploy" section; a uniform fleet stays a single table.
class TestDeployStatusTable < Minitest::Test
  def capture_io
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def up(name, tag)
    [name, { tag: tag, prod: tag, ahead: 0, prod_stale: false }]
  end

  def stale(name, tag, prod)
    [name, { tag: tag, prod: prod, ahead: 0, prod_stale: true }]
  end

  def test_mixed_fleet_splits_pending_into_needs_deploy_section
    out = capture_io do
      print_deploy_status_table([up("account", "0.0.12"), stale("acumen", "0.9.53", "0.9.52")])
    end
    lines = out.lines.map(&:chomp)
    # A "needs deploy" section header separates the two buckets, and pending
    # rows land after it — the up-to-date row comes before.
    section = lines.index("needs deploy")
    refute_nil section, "expected a 'needs deploy' section header"
    up_to_date = lines.index { |l| l.start_with?("account") }
    pending    = lines.index { |l| l.start_with?("acumen") }
    assert up_to_date < section, "up-to-date app should precede the needs-deploy section"
    assert pending > section, "pending app should follow the needs-deploy section"
  end

  def test_uniform_up_to_date_fleet_is_single_table
    out = capture_io do
      print_deploy_status_table([up("account", "0.0.12"), up("platform", "0.17.21")])
    end
    refute_match(/needs deploy/, out)
    assert_equal 1, out.scan(/^app\s+tag\s+prod\s+status$/).length
  end

  def test_uniform_pending_fleet_is_single_table
    out = capture_io do
      print_deploy_status_table([stale("acumen", "0.9.53", "0.9.52"), stale("rallyd", "0.3.18", "0.3.17")])
    end
    refute_match(/needs deploy/, out)
    assert_equal 1, out.scan(/^app\s+tag\s+prod\s+status$/).length
  end

  def test_columns_align_across_both_sections
    # A long name in the up-to-date bucket sets the width; the pending row in the
    # trailing section must line up under the same header.
    out = capture_io do
      print_deploy_status_table([up("acumen-postgresql", "0.1.36"), stale("acumen", "0.9.53", "0.9.52")])
    end
    tag_columns = out.lines.select { |l| l.include?("0.") }.map { |l| l.index(/0\./) }.uniq
    assert_equal 1, tag_columns.length, "tag column should start at the same offset in every data row"
  end
end

# prod_status: how a row acquires prod/prod_stale/prod_error.
class TestProdStatus < Minitest::Test
  FakeApp = Struct.new(:name, :docker_k8s, keyword_init: true)

  class FakeRegistry
    def initialize(url) = @url = url
    def prod_url(_) = @url
  end

  def with_fetch_app_version(result)
    orig = Object.instance_method(:fetch_app_version)
    Object.send(:define_method, :fetch_app_version) { |_r, _a| result }
    yield
  ensure
    Object.send(:define_method, :fetch_app_version, orig)
  end

  def app = FakeApp.new(name: "rallyd", docker_k8s: nil)

  def test_git_only_without_registry_or_app
    assert_equal({}, prod_status(nil, nil, "0.0.1"))
    assert_equal({}, prod_status(FakeRegistry.new("https://x"), nil, "0.0.1"))
  end

  def test_git_only_when_no_prod_probe
    # No prod url and no docker_k8s (e.g. playbook-app): nothing to ask.
    assert_equal({}, prod_status(FakeRegistry.new(nil), app, "0.0.1"))
  end

  def test_stale_when_prod_behind_tag
    with_fetch_app_version({ "version" => "0.0.1" }) do
      s = prod_status(FakeRegistry.new("https://x"), app, "0.0.2")
      assert_equal "0.0.1", s[:prod]
      assert s[:prod_stale]
    end
  end

  def test_not_stale_when_prod_matches_tag
    with_fetch_app_version({ "version" => "0.0.2" }) do
      s = prod_status(FakeRegistry.new("https://x"), app, "0.0.2")
      refute s[:prod_stale]
    end
  end

  def test_fetch_error_reported_not_stale
    with_fetch_app_version({ error: "HTTP 503" }) do
      s = prod_status(FakeRegistry.new("https://x"), app, "0.0.2")
      assert_equal "HTTP 503", s[:prod_error]
      refute s[:prod_stale]
    end
  end

  def test_empty_prod_version_reported_as_error
    with_fetch_app_version({ "version" => "  " }) do
      s = prod_status(FakeRegistry.new("https://x"), app, "0.0.2")
      assert_match(/empty/, s[:prod_error])
      refute s[:prod_stale]
    end
  end
end

# Stubs for the seams cmd_deploy_status touches: the rows it renders, whether a
# terminal is attached (it prompts only if so), and the prompt itself.
module DeployStatusStubs
  def with_rows(rows, interactive: false, answer: nil)
    orig_resolve = Object.instance_method(:resolve_deploy_items)
    orig_tty     = Object.instance_method(:interactive_terminal?)
    @prompted = nil
    prompted_ref = ->(v) { @prompted = v }
    Object.send(:define_method, :resolve_deploy_items) { |_| rows }
    Object.send(:define_method, :interactive_terminal?) { interactive }
    Ask.singleton_class.send(:alias_method, :orig_select_multiple_from_list, :select_multiple_from_list)
    Ask.define_singleton_method(:select_multiple_from_list) do |_msg, values, _opts = {}|
      prompted_ref.call(values)
      answer.nil? ? values : answer
    end
    yield
  ensure
    Object.send(:define_method, :resolve_deploy_items, orig_resolve)
    Object.send(:define_method, :interactive_terminal?, orig_tty)
    Ask.singleton_class.send(:alias_method, :select_multiple_from_list, :orig_select_multiple_from_list)
  end

  def capture_io
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

# cmd_deploy_status prints every row (not just pending ones) with tag + prod.
class TestDeployStatusOutput < Minitest::Test
  include DeployStatusStubs

  def test_lists_all_rows_including_up_to_date
    rows = [
      ["acumen",              { tag: "0.9.52", ahead: 0, last: "a", prod: "0.9.52", prod_stale: false }],
      ["platform-postgresql", { tag: "0.5.1",  ahead: 0, last: "b" }],
      ["rallyd",              { tag: "0.3.16", ahead: 2, last: "c", prod: "0.3.15", prod_stale: true }],
    ]
    out = with_rows(rows) { capture_io { cmd_deploy_status([]) } }
    assert_match(/acumen\s+0\.9\.52\s+0\.9\.52\s+up to date/, out)
    assert_match(/platform-postgresql\s+0\.5\.1\s+-\s+up to date/, out)
    assert_match(/rallyd\s+0\.3\.16\s+0\.3\.15\s+\+2 unreleased, tag 0\.3\.16 not deployed/, out)
  end

  def test_prod_stale_row_is_reported
    rows = [["rallyd", { tag: "0.0.2", ahead: 0, last: "x", prod: "0.0.1", prod_stale: true }]]
    out = with_rows(rows) { capture_io { cmd_deploy_status([]) } }
    assert_match(/rallyd\s+0\.0\.2\s+0\.0\.1\s+tag 0\.0\.2 not deployed/, out)
  end

  # A prod probe failure is a warning, not a pending release: it must be visible
  # but must not offer to deploy.
  def test_prod_error_shown_in_status_and_does_not_prompt
    rows = [["rallyd", { tag: "0.3.16", ahead: 0, last: "c", prod_error: "HTTP 503" }]]
    out = with_rows(rows, interactive: true) { capture_io { cmd_deploy_status([]) } }
    assert_match(/rallyd\s+0\.3\.16\s+-\s+prod check failed: HTTP 503/, out)
    assert_nil @prompted, "prod-probe failure must not be treated as pending"
  end

  def test_detection_error_row
    rows = [["broken", { error: "no checkout" }]]
    out = with_rows(rows) { capture_io { cmd_deploy_status([]) } }
    assert_match(/broken\s+ERROR - no checkout/, out)
  end
end

# The deploy prompt `dev deploy` shows when something is pending.
class TestDeployStatusPrompt < Minitest::Test
  include DeployStatusStubs
  # The prompt hands its selection to the SAME run_deploys the `deploy all` tests
  # exercise, so it crosses the same seams and has to replace all of them — it
  # used to replace only release_one, and resolved gating against this machine
  # (ISS-795).
  include DeployReleaseStubs

  def setup
    stub_release_seams
  end

  def pending_rows
    [
      ["acumen", { tag: "0.9.52", ahead: 0, last: "a", prod: "0.9.52", prod_stale: false }],
      ["rallyd", { tag: "0.3.16", ahead: 2, last: "c", prod: "0.3.15", prod_stale: true }],
      ["hackathon", { tag: "0.1.0", ahead: 1, last: "d", prod: "0.1.0", prod_stale: false }],
    ]
  end

  def test_prompts_with_only_pending_items_and_releases_selection
    out = with_rows(pending_rows, interactive: true, answer: ["rallyd"]) do
      capture_io { cmd_deploy_status([]) }
    end
    assert_equal %w[rallyd hackathon], @prompted, "prompt must offer exactly the pending items"
    assert_equal %w[rallyd], @released, "only the selected item may be released"
    assert_match(/released: rallyd/, out)
  end

  # `all` is the default answer, so the common case is a bare Enter.
  def test_default_answer_releases_every_pending_item
    with_rows(pending_rows, interactive: true) { capture_io { cmd_deploy_status([]) } }
    assert_equal %w[rallyd hackathon].sort, @released.sort
  end

  def test_none_selected_releases_nothing
    out = with_rows(pending_rows, interactive: true, answer: []) do
      capture_io { cmd_deploy_status([]) }
    end
    assert_empty @released
    assert_match(/Nothing selected/, out)
  end

  def test_no_prompt_when_nothing_pending
    rows = [["acumen", { tag: "0.9.52", ahead: 0, last: "a", prod: "0.9.52", prod_stale: false }]]
    with_rows(rows, interactive: true) { capture_io { cmd_deploy_status([]) } }
    assert_nil @prompted
    assert_empty @released
  end

  # Piped/cron callers have no one to answer: print the hint and exit, never block.
  def test_non_interactive_prints_hint_and_does_not_prompt
    out = with_rows(pending_rows, interactive: false) { capture_io { cmd_deploy_status([]) } }
    assert_nil @prompted
    assert_empty @released
    assert_match(/2 pending: rallyd, hackathon \(run `dev deploy all` to release\)/, out)
  end

  # Selecting a DB and its app must keep deploy_all's DB-first ordering.
  def test_selection_releases_dbs_before_apps
    rows = [
      ["platform", { tag: "0.1.0", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.5.1", ahead: 1, last: "b" }],
    ]
    with_rows(rows, interactive: true) { capture_io { cmd_deploy_status([]) } }
    assert_equal %w[platform platform-postgresql], @released.sort, "both selections must release"
    assert_dbs_before_apps
  end

  # A lone app releases serially, so the banner drops the concurrency detail.
  def test_phase2_message_single_app_omits_concurrency
    assert_equal "Phase 2: releasing platform", deploy_app_phase_message(2, ["platform"], 10)
  end

  # Multiple apps show the effective pool, capped at the number of apps.
  def test_phase2_message_caps_concurrency_to_app_count
    assert_equal "Phase 2: releasing 2 app(s) with concurrency=2: rallyd, hackathon",
      deploy_app_phase_message(2, %w[rallyd hackathon], 10)
  end

  # When fewer apps than the requested concurrency would still saturate, the
  # requested value is shown unchanged.
  def test_phase2_message_uses_requested_concurrency_when_lower
    assert_equal "Phase 2: releasing 5 app(s) with concurrency=2: a, b, c, d, e",
      deploy_app_phase_message(2, %w[a b c d e], 2)
  end
end

# Uses a real (throwaway) app name under the real ~/Library/Logs/dev-deploy
# directory rather than stubbing File.expand_path — deploy_log_path's whole
# point is that it's a stable, predictable filesystem path, so the test
# exercises the actual path.
class TestDevDeployLog < Minitest::Test
  APP = "test-dev-deploy-log-fixture"

  def setup
    @path = deploy_log_path(APP)
  end

  def teardown
    File.delete(@path) if File.exist?(@path)
  end

  def test_deploy_log_path_is_stable_across_calls
    assert_equal deploy_log_path(APP), deploy_log_path(APP)
  end

  # Printed once per run rather than per app, so it names the directory and the
  # per-app filename pattern instead of one concrete path.
  def test_deploy_log_hint_names_the_log_directory
    assert_includes deploy_log_hint, File.dirname(@path)
    assert_includes deploy_log_hint, "<app>.log"
  end

  def test_run_release_capturing_deletes_stale_file_before_writing
    File.write(@path, "stale output from a previous run\n")

    result = run_release_capturing({}, "/bin/echo", APP, Dir.pwd, DeployProgress::Disabled.new)

    assert result[:ok]
    refute_match(/stale output/, File.read(@path))
  end

  def test_run_release_capturing_streams_output_to_the_log_file
    result = run_release_capturing({}, "/bin/echo", APP, Dir.pwd, DeployProgress::Disabled.new)

    expected = "--app #{APP}\n"
    assert result[:ok]
    assert_equal expected, File.read(@path)
    assert_equal expected, result[:log]
  end

  def test_run_release_capturing_reports_failure_status
    result = run_release_capturing({}, "/usr/bin/false", APP, Dir.pwd, DeployProgress::Disabled.new)

    refute result[:ok]
  end

  # The phase display is fed from the same stream that reaches the log, so a
  # release that narrates itself through Util.step shows up in both.
  def test_run_release_capturing_feeds_the_progress_display
    io = StringIO.new
    progress = DeployProgress.new(io: io)
    progress.start(APP)
    run_release_capturing({}, "/bin/echo", APP, Dir.pwd, progress)
    progress.finish(APP, ok: true)

    assert_includes io.string, APP
  end

  # The regression that killed the acumen + properties releases on 2026-07-31:
  # a release printing a non-ASCII character (a "…" from Util.step) blew up the
  # capture with `Encoding::UndefinedConversionError: "\xE2" from ASCII-8BIT to
  # UTF-8`, and the release's own output was replaced by that message. The
  # padding pushes the character past a 4096-byte read boundary so its bytes
  # arrive in two separate chunks — the harder half of the same bug.
  def test_run_release_capturing_survives_multibyte_output_split_across_chunks
    script = write_script(<<~SH)
      printf 'x%.0s' $(seq 1 4095)
      printf 'Rolling out… done (63s)\\n'
    SH

    result = run_release_capturing({}, script, APP, Dir.pwd, DeployProgress::Disabled.new)

    assert result[:ok], result[:log]
    assert_equal Encoding::UTF_8, result[:log].encoding
    assert result[:log].valid_encoding?
    assert_includes result[:log], "Rolling out… done (63s)"
    assert_includes File.read(@path, encoding: "UTF-8"), "Rolling out… done (63s)"
  end

  # A release that fails is worth nothing to debug if its output is discarded:
  # the captured log is the diagnostic, not the exit status.
  def test_run_release_capturing_keeps_output_of_a_failing_release
    script = write_script(<<~SH)
      echo 'Building sbt distribution… failed (18s)'
      exit 3
    SH

    result = run_release_capturing({}, script, APP, Dir.pwd, DeployProgress::Disabled.new)

    refute result[:ok]
    assert_includes result[:log], "Building sbt distribution… failed (18s)"
  end

  # A bug in the capture path (a broken display, an unwritable log) is not a
  # failed deploy — the release ran and its exit status is the truth. It still
  # has to be reported rather than silently swallowed.
  def test_run_release_capturing_reports_a_capture_bug_without_failing_the_release
    progress = Object.new
    def progress.start(_app); end
    def progress.feed(_app, _chunk) = raise("display exploded")
    def progress.finish(_app, ok:, version: nil); end
    def progress.messages = (@messages ||= [])
    def progress.message(text) = messages << text

    result = run_release_capturing({}, "/bin/echo", APP, Dir.pwd, progress)

    assert result[:ok]
    assert_includes result[:log], "output capture failed"
    assert_includes progress.messages.join("\n"), "display exploded"
  end

  private

  def write_script(body)
    path = File.join(Dir.mktmpdir("dev-deploy-test"), "release")
    File.write(path, "#!/bin/sh\n#{body}")
    File.chmod(0o755, path)
    path
  end
end

# devops is the one tracked item with no artifact and no tag: the ~/code/devops
# checkout IS the deployment, so its version is a commit sha and its release is
# a `git pull`.
class TestDeployDevops < Minitest::Test
  def test_devops_repo_identifies_only_devops
    assert devops_repo?("devops")
    refute devops_repo?("platform")
    refute devops_repo?("lib-util")
    refute devops_repo?("devops-postgresql")
  end

  # The three special release paths (DB, library, devops) must stay disjoint, or
  # run_deploys would put the same item in two phases.
  def test_devops_is_not_a_db_or_library
    refute db_repo?("devops")
    refute lib_repo?("devops")
    refute_includes lib_repos, "devops"
  end

  # ---- devops_deploy_state, against real git repos ----

  def with_devops_checkout
    Dir.mktmpdir do |root|
      origin = File.join(root, "origin.git")
      work = File.join(root, "devops")
      sh("git init -q --bare -b main #{origin}")
      sh("git clone -q #{origin} #{work}")
      sh("git -C #{work} config user.email dev@example.com")
      sh("git -C #{work} config user.name dev")
      File.write(File.join(work, "README.md"), "one\n")
      sh("git -C #{work} add -A && git -C #{work} commit -q -m one")
      sh("git -C #{work} push -q origin main")
      yield work, origin
    end
  end

  # Adds a commit to origin/main that `work` has not pulled. Returns its sha.
  def push_upstream(work, origin, message)
    Dir.mktmpdir do |tmp|
      other = File.join(tmp, "other")
      sh("git clone -q #{origin} #{other}")
      sh("git -C #{other} config user.email dev@example.com")
      sh("git -C #{other} config user.name dev")
      File.write(File.join(other, "#{message}.txt"), "x\n")
      sh("git -C #{other} add -A && git -C #{other} commit -q -m #{message}")
      sh("git -C #{other} push -q origin main")
    end
    sh("git -C #{work} fetch -q origin")
    `git -C #{work} rev-parse --short origin/main`.strip
  end

  def sh(cmd)
    out = `#{cmd} 2>&1`
    raise "command failed: #{cmd}\n#{out}" unless $?.success?
    out
  end

  def test_current_checkout_is_not_pending
    with_devops_checkout do |work, _|
      d = devops_deploy_state(work)
      assert_equal 0, d[:ahead]
      assert_equal d[:tag], d[:prod], "origin/main and HEAD are the same commit"
      refute needs_deploy?(d)
      assert_nil d[:note]
    end
  end

  def test_behind_checkout_is_pending_with_both_shas
    with_devops_checkout do |work, origin|
      local = `git -C #{work} rev-parse --short HEAD`.strip
      upstream = push_upstream(work, origin, "two")

      d = devops_deploy_state(work)
      assert_equal 1, d[:ahead]
      assert_equal upstream, d[:tag], "tag column is what origin/main is at"
      assert_equal local, d[:prod], "prod column is the sha actually running"
      assert needs_deploy?(d)
    end
  end

  # A checkout parked on a branch is not fixed by a pull, so it is reported
  # rather than queued for release.
  def test_feature_branch_is_noted_but_not_pending
    with_devops_checkout do |work, _|
      sh("git -C #{work} checkout -q -b wip")

      d = devops_deploy_state(work)
      assert_equal 0, d[:ahead]
      assert_equal "on wip", d[:note]
      refute needs_deploy?(d)
    end
  end

  def test_missing_origin_main_is_an_error
    Dir.mktmpdir do |dir|
      sh("git init -q -b main #{dir}")
      assert_equal({ error: "no origin/main" }, devops_deploy_state(dir))
    end
  end

  # deploy_state_for routes devops to the sha-based state instead of demanding a
  # tag — the repo has none, and the generic path errors with "no tag" on that.
  def test_deploy_state_for_uses_the_sha_path_for_devops
    with_devops_checkout do |work, _|
      d = deploy_state_for("devops", work)
      refute_equal "no tag", d[:error]
      assert_equal d[:tag], d[:prod]
    end
  end

  # ---- release ----

  def test_release_one_for_devops_is_just_a_pull
    with_devops_checkout do |work, origin|
      upstream = push_upstream(work, origin, "two")

      original = Object.instance_method(:deploy_item_dir)
      Object.send(:define_method, :deploy_item_dir) { |_| work }
      begin
        result = release_one("devops", DeployProgress::Disabled.new)
      ensure
        Object.send(:define_method, :deploy_item_dir, original)
      end

      assert result[:ok], "expected the pull to succeed: #{result[:log]}"
      assert_equal upstream, `git -C #{work} rev-parse --short HEAD`.strip,
                   "the checkout must be at origin/main afterwards"
    end
  end

  def test_release_one_for_devops_refuses_a_feature_branch
    with_devops_checkout do |work, _|
      sh("git -C #{work} checkout -q -b wip")
      original = Object.instance_method(:deploy_item_dir)
      Object.send(:define_method, :deploy_item_dir) { |_| work }
      begin
        result = release_one("devops", DeployProgress::Disabled.new)
      ensure
        Object.send(:define_method, :deploy_item_dir, original)
      end

      refute result[:ok]
      assert_match(/not on main/, result[:log])
    end
  end

  # ---- status row ----

  def test_status_row_says_to_pull_not_unreleased
    out = capture_row("devops", { tag: "abc1234", prod: "def5678", ahead: 3, ahead_noun: "to pull" })
    assert_match(/\+3 to pull/, out)
    refute_match(/unreleased/, out)
  end

  def test_status_row_shows_the_branch_note
    out = capture_row("devops", { tag: "abc1234", prod: "abc1234", ahead: 0, note: "on wip" })
    assert_match(/on wip/, out)
  end

  def test_status_row_keeps_unreleased_wording_for_everything_else
    out = capture_row("acumen", { tag: "0.0.1", prod: "0.0.1", ahead: 2 })
    assert_match(/\+2 unreleased/, out)
  end

  def capture_row(name, d)
    old = $stdout
    $stdout = StringIO.new
    print_deploy_status_row(name, d, name.length, 10, 10)
    $stdout.string
  ensure
    $stdout = old
  end
end

# Phase 4: devops updates last and alone, because its pull rewrites the release
# scripts every other phase shells out to.
class TestDeployDevopsPhase < Minitest::Test
  include DeployReleaseStubs

  def setup
    @rows = []
    stub_release_seams
    rows_ref = -> { @rows }
    stub_global_for_test(:resolve_deploy_items) { |_| rows_ref.call }
  end

  def capture_io
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  def test_devops_releases_after_apps_dbs_and_libraries
    @rows = [
      ["devops",            { tag: "abc1234", prod: "def5678", ahead: 1, ahead_noun: "to pull" }],
      ["acumen",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
      ["lib-util",          { tag: "0.0.3", ahead: 1, last: "c" }],
    ]
    out = with_tty(true) { capture_io { cmd_deploy_all([]) } }
    assert_equal %w[acumen-postgresql acumen lib-util devops], @released
    assert_match(/Phase 5: updating devops \(git pull\)/, out)
  end

  def test_only_devops_pending_runs_no_other_phase
    @rows = [["devops", { tag: "abc1234", prod: "def5678", ahead: 1, ahead_noun: "to pull" }]]
    out = capture_io { cmd_deploy_all([]) }
    assert_equal ["devops"], @released
    refute_match(/Phase 1/, out)
    refute_match(/Phase 2/, out)
    refute_match(/Phase 3/, out)
    refute_match(/Phase 4/, out)
    assert_match(/Phase 5/, out)
  end

  # devops is never gated on a DB, and a failed DB must not skip it.
  def test_devops_still_updates_when_a_db_release_fails
    @rows = [
      ["devops",            { tag: "abc1234", prod: "def5678", ahead: 1, ahead_noun: "to pull" }],
      ["acumen-postgresql", { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen",            { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    @release_results = { "acumen-postgresql" => { ok: false, log: "boom" } }
    out, exc = capture_io_with_exit { cmd_deploy_all([]) }
    assert_includes @released, "devops", "devops must still update: #{out}"
    refute_includes @released, "acumen", "the app whose DB failed is still skipped"
    assert_equal 1, exc&.status
  end

  def test_up_to_date_devops_is_not_pulled
    @rows = [["devops", { tag: "abc1234", prod: "abc1234", ahead: 0 }]]
    out = capture_io { cmd_deploy_all([]) }
    assert_empty @released
    assert_match(/All apps up to date/, out)
  end
end

# The post-deploy work belongs to the DEPLOY, not to each app's release.
#
# `dev deploy` releases apps in parallel and each release used to RUN this work
# itself — `api publish`, the changelog, and `features reconcile --apply` and
# `issues reconcile --apply`, the last two of which are global. A five-app deploy
# therefore ran each reconciler five times at once: five unsynchronised writers
# over one feature-flag and issue state, of which only the first had anything
# left to apply, at ~7s a run (ISS-810). It is filed rather than run now
# (ISS-816), which changes what the redundancy would cost — five EPICS for one
# deploy, burying the queue `dev issues claim` reads — but not the rule. What is
# pinned here is therefore a COUNT, and the gate that decides whether the count
# is one or zero.
class TestDeployPostDeployFiling < Minitest::Test
  include DeployReleaseStubs

  def setup
    @rows = []
    stub_release_seams
    rows_ref = -> { @rows }
    stub_global_for_test(:resolve_deploy_items) { |_| rows_ref.call }
  end

  def capture_io
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  # The bug, stated as an assertion: four apps, ONE filing, naming all four.
  def test_a_multi_app_deploy_files_exactly_once_for_every_app
    @rows = [
      ["acumen",   { tag: "0.0.1", ahead: 1, last: "a" }],
      ["rallyd",   { tag: "0.0.2", ahead: 1, last: "b" }],
      ["michaelb", { tag: "0.0.3", ahead: 1, last: "c" }],
      ["hackathon", { tag: "0.0.4", ahead: 1, last: "d" }],
    ]
    capture_io { cmd_deploy_all(["--concurrency", "4"]) }
    assert_equal 4, @released.length
    assert_equal 1, @filings
    assert_equal %w[acumen hackathon michaelb rallyd], @filed_apps.first.sort
  end

  def test_a_single_app_deploy_still_files_once
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "a" }]]
    capture_io { cmd_deploy_all([]) }
    assert_equal 1, @filings
  end

  # Work moving off the critical path must not also move out of sight: the deploy
  # reports what it filed.
  def test_the_deploy_reports_what_it_filed
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = capture_io { cmd_deploy_all([]) }
    assert_includes out, "ISS-900 (epic)"
  end

  # A deploy in which no app got as far as production has changed nothing for any
  # of this work to be about — and per-app post-release never ran for a failed
  # release either, so this is the behaviour being preserved, not a new gate.
  def test_nothing_is_filed_when_every_app_release_failed
    @rows = [
      ["acumen", { tag: "0.0.1", ahead: 1, last: "a" }],
      ["rallyd", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    @release_results = {
      "acumen" => { ok: false, log: "boom" },
      "rallyd" => { ok: false, log: "boom" },
    }
    capture_io_with_exit { cmd_deploy_all([]) }
    assert_equal 0, @filings
  end

  # One survivor is enough — and only the survivor is named: filing a publish for
  # an app that never released would send the fleet to publish specs for code
  # that is not running.
  def test_only_the_apps_that_released_are_filed_for
    @rows = [
      ["acumen", { tag: "0.0.1", ahead: 1, last: "a" }],
      ["rallyd", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    @release_results = { "rallyd" => { ok: false, log: "boom" } }
    capture_io_with_exit { cmd_deploy_all([]) }
    assert_equal 1, @filings
    assert_equal ["acumen"], @filed_apps.first
  end

  # A database, a library and a devops pull run no post-release at all, so none
  # of them ever triggered this — and none of them changes what production is
  # RUNNING, which is the only question the reconcilers ask.
  def test_nothing_is_filed_for_a_deploy_with_no_app_in_it
    @rows = [
      ["lib-util", { tag: "0.0.1", ahead: 1, last: "a" }],
      ["devops",   { tag: "abc1234", prod: "def5678", ahead: 1, ahead_noun: "to pull" }],
    ]
    with_tty(true) { capture_io { cmd_deploy_all([]) } }
    assert_equal %w[lib-util devops], @released
    assert_equal 0, @filings
  end

  # A deploy that released everything and then could not file what is left has
  # succeeded at the deploy and lost its bookkeeping. It exits non-zero, and it
  # prints the commands to run by hand — an unfiled publish is exactly as silent
  # as the unrun one that used to fail the release.
  def test_a_filing_failure_fails_the_deploy_and_names_the_manual_commands
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "a" }]]
    stub_global_for_test(:post_deploy_work) { |_names| DeployReleaseStubs::ExplodingWork.new }

    out, exited = capture_io_with_exit { cmd_deploy_all([]) }
    assert_equal 1, exited&.status
    assert_includes out, "Post-deploy work NOT FILED"
    assert_includes out, "dev issues reconcile --apply"
  end

  # Last, after every phase: work filed before Phase 3's contracting migration or
  # Phase 5's devops pull would describe a deploy that was still changing.
  def test_filing_happens_after_every_release_phase
    @rows = [
      ["acumen",            { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
      ["lib-util",          { tag: "0.0.3", ahead: 1, last: "c" }],
      ["devops",            { tag: "abc1234", prod: "def5678", ahead: 1, ahead_noun: "to pull" }],
    ]
    contracting!("acumen-postgresql")
    # Records into the same list the releases append to, so the assertion is one
    # sequence rather than two that have to be correlated by hand.
    marker = ->(_names) { @released << "FILED" }
    stub_global_for_test(:post_deploy_work) { |names| DeployReleaseStubs::FakeWork.new(names, marker) }

    with_tty(true) { capture_io { cmd_deploy_all([]) } }
    assert_equal %w[acumen acumen-postgresql lib-util devops FILED], @released
  end
end
