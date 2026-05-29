#!/usr/bin/env ruby
require 'minitest/autorun'
load File.expand_path('../bin/dev', __dir__)
load File.expand_path('../lib/tag.rb', __dir__)

# Covers the `dev pending {list,release}` subcommand split and the
# RELEASE_AUTO_TAG escape hatch that lets `pending release` run releases
# without interactive prompts.
class TestDevPending < Minitest::Test
  def test_parse_pending_release_args_defaults
    app_filter, concurrency = parse_pending_release_args([])
    assert_nil app_filter
    assert_equal 4, concurrency
  end

  def test_parse_pending_release_args_app_filter
    app_filter, concurrency = parse_pending_release_args(["--app", "acumen"])
    assert_equal "acumen", app_filter
    assert_equal 4, concurrency
  end

  def test_parse_pending_release_args_concurrency
    app_filter, concurrency = parse_pending_release_args(["--concurrency", "8"])
    assert_nil app_filter
    assert_equal 8, concurrency
  end

  def test_parse_pending_release_args_both_flags
    app_filter, concurrency = parse_pending_release_args(["--app", "rallyd", "--concurrency", "2"])
    assert_equal "rallyd", app_filter
    assert_equal 2, concurrency
  end

  def test_parse_pending_release_args_rejects_unknown
    assert_raises(SystemExit) { parse_pending_release_args(["--bogus"]) }
  end

  def test_parse_pending_release_args_rejects_zero_concurrency
    assert_raises(SystemExit) { parse_pending_release_args(["--concurrency", "0"]) }
  end

  def test_parse_pending_release_args_requires_app_value
    assert_raises(SystemExit) { parse_pending_release_args(["--app"]) }
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
end

# pending_items derives DB repos from the apps registry (scala apps ship a
# "<app>-postgresql" repo), NOT from a filesystem glob — so abandoned
# *-postgresql checkouts next to the apps are never picked up.
class TestPendingItems < Minitest::Test
  FakeApp = Struct.new(:name, :stack, keyword_init: true)

  class FakeRegistry
    def initialize(apps, deployable)
      @apps = apps
      @deployable = deployable
    end
    attr_reader :apps
    def deployable = @deployable
  end

  def with_registry(apps, deployable = nil)
    deployable ||= apps
    orig = Work::Registry.method(:load)
    Work::Registry.define_singleton_method(:load) { FakeRegistry.new(apps, deployable) }
    yield
  ensure
    Work::Registry.define_singleton_method(:load, orig)
  end

  def names = pending_items.map(&:first)

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
    # An ignored/archived scala app is in `apps` but not in `deployable`; its
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
      _, dir = pending_items.find { |n, _| n == "platform-postgresql" }
      assert_equal File.expand_path("~/code/platform-postgresql"), dir
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

# cmd_pending_release orchestrates DB-first + parallel-app workers.
# Stub resolve_pending_items + release_one so tests do no real I/O.
class TestPendingReleaseOrchestration < Minitest::Test
  def setup
    @rows = []
    @release_results = {}
    @released = []
    @released_mutex = Mutex.new

    @orig_resolve = Object.instance_method(:resolve_pending_items)
    @orig_release = Object.instance_method(:release_one)

    rows_ref = -> { @rows }
    results_ref = -> { @release_results }
    released_ref = -> { @released }
    released_mutex = @released_mutex

    Object.send(:define_method, :resolve_pending_items) { |_| rows_ref.call }
    Object.send(:define_method, :release_one) do |name|
      released_mutex.synchronize { released_ref.call << name }
      results_ref.call.fetch(name) { { ok: true, log: "ok" } }
    end
  end

  def teardown
    Object.send(:define_method, :resolve_pending_items, @orig_resolve)
    Object.send(:define_method, :release_one, @orig_release)
  end

  def capture_io
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  # Like capture_io, but tolerates SystemExit (cmd_pending_release calls
  # `exit 1` on failure). Returns [output, system_exit_or_nil] so callers
  # can assert on both.
  def capture_io_with_exit
    buf = StringIO.new
    old_stdout = $stdout
    $stdout = buf
    exc = nil
    begin
      yield
    rescue SystemExit => e
      exc = e
    end
    [buf.string, exc]
  ensure
    $stdout = old_stdout
  end

  def test_releases_only_apps_with_ahead_gt_zero
    @rows = [
      ["acumen",   { tag: "0.0.1", ahead: 1, last: "abc msg" }],
      ["rallyd",   { tag: "0.0.2", ahead: 0, last: "def msg" }],
      ["michaelb", { tag: "0.0.3", ahead: 2, last: "ghi msg" }],
    ]
    out = capture_io { cmd_pending_release(["--concurrency", "2"]) }
    assert_equal %w[acumen michaelb].sort, @released.sort
    assert_match(/released: acumen, michaelb|released: michaelb, acumen/, out)
  end

  def test_skips_pending_detection_errors_but_continues
    @rows = [
      ["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }],
      ["broken", { error: "no checkout" }],
    ]
    out = capture_io { cmd_pending_release([]) }
    assert_equal ["acumen"], @released
    assert_match(/Pending-detection errors:/, out)
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
      capture_io { cmd_pending_release([]) }
    end
    assert_equal 1, err.status
  end

  def test_no_pending_prints_up_to_date_and_does_not_release
    @rows = [["acumen", { tag: "0.0.1", ahead: 0, last: "abc" }]]
    out = capture_io { cmd_pending_release([]) }
    assert_empty @released
    assert_match(/All apps up to date/, out)
  end

  def test_handles_release_one_raising
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }]]
    Object.send(:define_method, :release_one) { |_| raise "kaboom" }
    err = assert_raises(SystemExit) do
      capture_io { cmd_pending_release([]) }
    end
    assert_equal 1, err.status
  end

  # ---- Two-phase ordering + DB-failure skip ----

  def test_dbs_release_before_apps
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql",   { tag: "0.0.2", ahead: 1, last: "b" }],
      ["platform",            { tag: "0.0.3", ahead: 1, last: "c" }],
      ["platform-postgresql", { tag: "0.0.4", ahead: 1, last: "d" }],
    ]
    capture_io { cmd_pending_release([]) }
    db_idx = @released.each_index.select { |i| @released[i].end_with?("-postgresql") }
    app_idx = @released.each_index.reject { |i| @released[i].end_with?("-postgresql") }
    assert db_idx.max < app_idx.min, "expected all DBs before any app, got #{@released.inspect}"
  end

  def test_db_releases_run_serially
    order = []
    order_mutex = Mutex.new
    @rows = [
      ["acumen-postgresql",   { tag: "0.0.1", ahead: 1, last: "a" }],
      ["platform-postgresql", { tag: "0.0.2", ahead: 1, last: "b" }],
    ]
    Object.send(:define_method, :release_one) do |name|
      order_mutex.synchronize { order << "start:#{name}" }
      sleep 0.02 # let other workers race — they shouldn't
      order_mutex.synchronize { order << "end:#{name}" }
      { ok: true, log: "" }
    end
    capture_io { cmd_pending_release(["--concurrency", "8"]) }
    # Serial: every start is immediately followed by its end with no other start
    # interleaved between them.
    pairs = order.each_slice(2).to_a
    pairs.each do |start_evt, end_evt|
      assert_match(/^start:/, start_evt)
      assert_match(/^end:/, end_evt)
      assert_equal start_evt.sub("start:", ""), end_evt.sub("end:", "")
    end
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
    _, exc = capture_io_with_exit { cmd_pending_release([]) }
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
    out, exc = capture_io_with_exit { cmd_pending_release([]) }
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
    out, exc = capture_io_with_exit { cmd_pending_release([]) }
    refute_nil exc
    assert_includes @released, "platform"
    refute_match(/skipped:/, out)
  end

  def test_only_apps_pending_no_phase_1_header
    @rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = capture_io { cmd_pending_release([]) }
    refute_match(/Phase 1/, out)
    assert_match(/Phase 2/, out)
  end

  def test_only_dbs_pending_no_phase_2_header
    @rows = [["platform-postgresql", { tag: "0.0.1", ahead: 1, last: "a" }]]
    out = capture_io { cmd_pending_release([]) }
    assert_match(/Phase 1/, out)
    refute_match(/Phase 2/, out)
  end
end
