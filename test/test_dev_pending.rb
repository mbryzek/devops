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
end

# cmd_pending_release orchestrates parallel worker threads. Stub
# resolve_pending_apps + release_one so the test does no real I/O.
class TestPendingReleaseOrchestration < Minitest::Test
  def setup
    @apps_rows = []
    @release_results = {}
    @released = []
    @released_mutex = Mutex.new

    @orig_resolve = Object.instance_method(:resolve_pending_apps)
    @orig_release = Object.instance_method(:release_one)

    rows_ref = -> { @apps_rows }
    results_ref = -> { @release_results }
    released_ref = -> { @released }
    released_mutex = @released_mutex

    Object.send(:define_method, :resolve_pending_apps) { |_| rows_ref.call }
    Object.send(:define_method, :release_one) do |name|
      released_mutex.synchronize { released_ref.call << name }
      results_ref.call.fetch(name) { { ok: true, log: "ok" } }
    end
  end

  def teardown
    Object.send(:define_method, :resolve_pending_apps, @orig_resolve)
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

  def test_releases_only_apps_with_ahead_gt_zero
    @apps_rows = [
      ["acumen",   { tag: "0.0.1", ahead: 1, last: "abc msg" }],
      ["rallyd",   { tag: "0.0.2", ahead: 0, last: "def msg" }],
      ["michaelb", { tag: "0.0.3", ahead: 2, last: "ghi msg" }],
    ]
    out = capture_io { cmd_pending_release(["--concurrency", "2"]) }
    assert_equal %w[acumen michaelb].sort, @released.sort
    assert_match(/released: acumen, michaelb|released: michaelb, acumen/, out)
  end

  def test_skips_pending_detection_errors_but_continues
    @apps_rows = [
      ["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }],
      ["broken", { error: "no checkout" }],
    ]
    out = capture_io { cmd_pending_release([]) }
    assert_equal ["acumen"], @released
    assert_match(/Pending-detection errors:/, out)
    assert_match(/broken: no checkout/, out)
  end

  def test_exits_nonzero_when_any_release_fails
    @apps_rows = [
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
    @apps_rows = [["acumen", { tag: "0.0.1", ahead: 0, last: "abc" }]]
    out = capture_io { cmd_pending_release([]) }
    assert_empty @released
    assert_match(/All apps up to date/, out)
  end

  def test_handles_release_one_raising
    @apps_rows = [["acumen", { tag: "0.0.1", ahead: 1, last: "abc" }]]
    Object.send(:define_method, :release_one) { |_| raise "kaboom" }
    err = assert_raises(SystemExit) do
      capture_io { cmd_pending_release([]) }
    end
    assert_equal 1, err.status
  end
end
