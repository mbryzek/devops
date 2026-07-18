#!/usr/bin/env ruby
require 'minitest/autorun'
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
end

# deploy_items derives DB repos from the apps registry (scala apps ship a
# "<app>-postgresql" repo), NOT from a filesystem glob — so abandoned
# *-postgresql checkouts next to the apps are never picked up.
class TestPendingItems < Minitest::Test
  FakeApp = Struct.new(:name, :stack, keyword_init: true)

  class FakeRegistry
    def initialize(apps, deploy_tracked)
      @apps = apps
      @deploy_tracked = deploy_tracked
    end
    attr_reader :apps
    def deploy_tracked = @deploy_tracked
  end

  def with_registry(apps, deploy_tracked = nil)
    deploy_tracked ||= apps
    orig = Work::Registry.method(:load)
    Work::Registry.define_singleton_method(:load) { FakeRegistry.new(apps, deploy_tracked) }
    yield
  ensure
    Work::Registry.define_singleton_method(:load, orig)
  end

  def names = deploy_items.map(&:first)

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

# cmd_deploy_all orchestrates DB-first + parallel-app workers.
# Stub resolve_deploy_items + release_one so tests do no real I/O.
class TestPendingReleaseOrchestration < Minitest::Test
  def setup
    @rows = []
    @release_results = {}
    @released = []
    @released_mutex = Mutex.new

    @orig_resolve = Object.instance_method(:resolve_deploy_items)
    @orig_release = Object.instance_method(:release_one)

    rows_ref = -> { @rows }
    results_ref = -> { @release_results }
    released_ref = -> { @released }
    released_mutex = @released_mutex

    Object.send(:define_method, :resolve_deploy_items) { |_| rows_ref.call }
    Object.send(:define_method, :release_one) do |name|
      released_mutex.synchronize { released_ref.call << name }
      results_ref.call.fetch(name) { { ok: true, log: "ok" } }
    end
  end

  def teardown
    Object.send(:define_method, :resolve_deploy_items, @orig_resolve)
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

  # Like capture_io, but tolerates SystemExit (cmd_deploy_all calls
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
    Object.send(:define_method, :release_one) { |_| raise "kaboom" }
    err = assert_raises(SystemExit) do
      capture_io { cmd_deploy_all([]) }
    end
    assert_equal 1, err.status
  end

  def test_releases_prod_stale_app_with_no_new_commits
    @rows = [
      ["acumen", { tag: "0.0.2", ahead: 0, last: "a", prod: "0.0.1", prod_stale: true }],
      ["rallyd", { tag: "0.0.3", ahead: 0, last: "b", prod: "0.0.3", prod_stale: false }],
    ]
    capture_io { cmd_deploy_all([]) }
    assert_equal ["acumen"], @released
  end

  # ---- Two-phase ordering + DB-failure skip ----

  def test_dbs_release_before_apps
    @rows = [
      ["acumen",              { tag: "0.0.1", ahead: 1, last: "a" }],
      ["acumen-postgresql",   { tag: "0.0.2", ahead: 1, last: "b" }],
      ["platform",            { tag: "0.0.3", ahead: 1, last: "c" }],
      ["platform-postgresql", { tag: "0.0.4", ahead: 1, last: "d" }],
    ]
    capture_io { cmd_deploy_all([]) }
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
    # No prod url and no docker_k8s (e.g. clubaid-app): nothing to ask.
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

  def setup
    @released = []
    @orig_release = Object.instance_method(:release_one)
    released_ref = @released
    Object.send(:define_method, :release_one) do |name|
      released_ref << name
      { ok: true, log: "ok" }
    end
  end

  def teardown
    Object.send(:define_method, :release_one, @orig_release)
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
    assert_equal %w[platform-postgresql platform], @released
  end

  # A lone app releases serially, so the banner drops the concurrency detail.
  def test_phase2_message_single_app_omits_concurrency
    assert_equal "Phase 2: releasing platform", deploy_phase2_message(["platform"], 10)
  end

  # Multiple apps show the effective pool, capped at the number of apps.
  def test_phase2_message_caps_concurrency_to_app_count
    assert_equal "Phase 2: releasing 2 app(s) with concurrency=2: rallyd, hackathon",
      deploy_phase2_message(%w[rallyd hackathon], 10)
  end

  # When fewer apps than the requested concurrency would still saturate, the
  # requested value is shown unchanged.
  def test_phase2_message_uses_requested_concurrency_when_lower
    assert_equal "Phase 2: releasing 5 app(s) with concurrency=2: a, b, c, d, e",
      deploy_phase2_message(%w[a b c d e], 2)
  end
end
