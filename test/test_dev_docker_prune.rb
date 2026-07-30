#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Covers `dev docker prune`'s dry-run accounting. The bug being locked down: the
# command quoted `docker system df`'s RECLAIMABLE column, which answers a
# different question than "what will this run delete" — it ignores the age filter,
# and it counts named unused volumes that `docker volume prune` (without -a) never
# touches. On the box this was found on that was 7.49GB advertised and 0.11GB
# removed. So the assertions here are about the predicates matching the docker
# commands actually run, and about which totals are honest lower bounds.
#
# Rows are shaped exactly as `docker system df -v --format json` emits them
# (sizes as go-units strings, the two different timestamp renderings, every
# numeric field a String).
class TestDevDockerPrune < Minitest::Test
  include DevTestSupport

  NOW   = Time.parse("2026-07-30 12:00:00 -0400")
  CUTOFF = NOW - 7 * 24 * 3600
  OLD    = "2026-05-12 03:12:25 -0400 EDT"       # ~2.5 months back
  RECENT = "2026-07-30 09:05:48 -0400 EDT"       # hours back
  OLD_CACHE_TS    = "2026-05-12 03:12:25.566497142 +0000 UTC"
  RECENT_CACHE_TS = "2026-07-30 09:05:48.123456789 +0000 UTC"

  def container(state:, created: OLD, size: "20.5kB")
    { "State" => state, "CreatedAt" => created, "Size" => size }
  end

  def image(containers: "0", created: OLD, unique: "304.3MB", size: "795MB")
    { "Containers" => containers, "CreatedAt" => created, "UniqueSize" => unique, "Size" => size }
  end

  def cache(shared: "false", last_used: OLD_CACHE_TS, created: OLD_CACHE_TS, size: "157MB", in_use: "false")
    { "Shared" => shared, "LastUsedAt" => last_used, "CreatedAt" => created,
      "Size" => size, "InUse" => in_use }
  end

  def volume(links: "0", size: "1.625GB", anonymous: true)
    { "Links" => links, "Size" => size,
      "Labels" => anonymous ? "com.docker.volume.anonymous=" : "com.example.keep=1" }
  end

  def plan(df, keep_named_volumes: false)
    docker_prune_plan(df, cutoff: CUTOFF, keep_named_volumes: keep_named_volumes)
      .each_with_object({}) { |s, h| h[s.label] = s }
  end

  # ---- size parsing (go-units HumanSize: decimal, not binary) ----

  def test_parses_decimal_size_suffixes
    assert_equal 0, docker_parse_size("0B")
    assert_equal 20_500, docker_parse_size("20.5kB")
    assert_equal 795_000_000, docker_parse_size("795MB")
    assert_equal 1_625_000_000, docker_parse_size("1.625GB")
  end

  # df -v prints "N/A" for a size it did not compute; a nil/garbage size must read
  # as zero rather than blowing up the whole plan.
  def test_unparseable_size_is_zero
    assert_equal 0, docker_parse_size("N/A")
    assert_equal 0, docker_parse_size(nil)
  end

  # Real output, not a hypothetical: docker derives UniqueSize as Size - SharedSize
  # and prints the negative result in scientific notation. 46 of 179 images looked
  # like this on the box this was found on, and a [\d.]-only parser reads every one
  # as zero — a silent 4.5GB hole in the image estimate.
  def test_parses_negative_scientific_notation_sizes
    assert_equal(-96_100_000, docker_parse_size("-9.61e+07B"))
    assert_equal(-218_500_000, docker_parse_size("-2.185e+08B"))
    assert_equal 96_100_000, docker_parse_size("9.61e+07B")
  end

  # A negative unique size is an accounting artifact, not disk that returns, so it
  # must not subtract from the step's total.
  def test_negative_unique_sizes_do_not_shrink_the_image_total
    df = { "Images" => [image(unique: "304.3MB"), image(unique: "-2.185e+08B")] }
    assert_equal 304_300_000, plan(df)["images"].bytes
  end

  def test_formats_bytes_back_in_decimal_units
    assert_equal "7.49GB", docker_format_size(7_490_000_000)
    assert_equal "110.00MB", docker_format_size(110_000_000)
    assert_equal "512B", docker_format_size(512)
  end

  # ---- timestamp parsing (two renderings in one document) ----

  def test_parses_both_timestamp_renderings
    assert_equal Time.parse("2026-05-12 03:12:25 -0400"), docker_parse_time(OLD)
    assert_equal Time.parse("2026-05-12 03:12:25.566497142 +0000"), docker_parse_time(OLD_CACHE_TS)
  end

  def test_unparseable_timestamp_is_not_a_candidate
    assert_nil docker_parse_time("N/A")
    # Direction matters: an object we cannot date is left OUT, so the estimate
    # never promises more than the run delivers.
    refute docker_older?("N/A", CUTOFF)
  end

  # ---- containers: prune skips live ones and filters on CREATED time ----

  def test_container_step_counts_only_stopped_containers_past_the_cutoff
    df = { "Containers" => [
      container(state: "exited"),
      container(state: "created"),
      container(state: "running"),           # live — prune never takes it
      container(state: "paused"),            # live
      container(state: "exited", created: RECENT), # inside the age filter
    ] }
    step = plan(df)["containers"]
    assert_equal 2, step.count
    assert_equal 41_000, step.bytes
    refute step.at_least, "container writable layers are exact, not a lower bound"
  end

  # ---- images: only unreferenced ones, and the total is a lower bound ----

  def test_image_step_excludes_referenced_and_recent_images
    df = { "Images" => [
      image,
      image(containers: "2"),                # a container holds it
      image(created: RECENT),                # inside the age filter
      image(containers: "-1"),               # docker declined to compute; treat as unused
    ] }
    step = plan(df)["images"]
    assert_equal 2, step.count
    assert_equal 608_600_000, step.bytes, "sums UniqueSize, not Size"
    assert step.at_least, "shared layers can free more, so the figure is a floor"
  end

  # ---- build cache: dated by last use, sized by non-shared records ----

  def test_cache_step_counts_by_last_use_and_sizes_only_non_shared_records
    df = { "BuildCache" => [
      cache,
      cache(shared: "true", size: "900MB"),  # counted, but frees nothing yet
      cache(last_used: RECENT_CACHE_TS),     # inside the age filter
      # Never used: falls back to CreatedAt rather than reading as undatable.
      cache(last_used: "", created: OLD_CACHE_TS, size: "43MB"),
    ] }
    step = plan(df)["build cache"]
    assert_equal 3, step.count
    assert_equal 200_000_000, step.bytes, "shared records contribute 0 until their images go"
    assert step.at_least
  end

  # `-a` means in-use is not a filter on the way out; a record in use by a live
  # build is still a candidate, so counting it matches what the command does.
  def test_cache_step_ignores_in_use_flag
    df = { "BuildCache" => [cache(in_use: "true")] }
    assert_equal 1, plan(df)["build cache"].count
  end

  # ---- volumes: the actual bug ----

  def test_volume_step_includes_named_unused_volumes_by_default
    df = { "Volumes" => [
      volume(anonymous: true, size: "110MB"),
      volume(anonymous: false, size: "7.49GB"),
      volume(links: "1", size: "5GB"),       # attached — never a candidate
    ] }
    step = plan(df)["volumes"]
    assert_equal 2, step.count
    assert_equal 7_600_000_000, step.bytes
    assert_includes step.note, "no age filter"
  end

  def test_keep_named_volumes_takes_anonymous_only_and_says_what_it_skipped
    df = { "Volumes" => [
      volume(anonymous: true, size: "110MB"),
      volume(anonymous: false, size: "7.49GB"),
    ] }
    step = plan(df, keep_named_volumes: true)["volumes"]
    assert_equal 1, step.count
    assert_equal 110_000_000, step.bytes
    assert_includes step.note, "1 named unused volume(s) left in place"
  end

  # The regression itself: without -a, docker takes anonymous volumes only, so the
  # step frees a rounding error of what the plan (and df) advertise.
  def test_volume_prune_command_passes_dash_a_unless_named_volumes_are_kept
    default = docker_prune_commands(filter: "until=168h", keep_named_volumes: false)
    assert_equal ["docker", "volume", "prune", "-f", "-a"], default["volumes"]

    kept = docker_prune_commands(filter: "until=168h", keep_named_volumes: true)
    assert_equal ["docker", "volume", "prune", "-f"], kept["volumes"]
  end

  def test_age_filtered_commands_carry_the_requested_window
    commands = docker_prune_commands(filter: "until=72h", keep_named_volumes: false)
    assert_equal ["docker", "container", "prune", "-f", "--filter", "until=72h"], commands["containers"]
    assert_equal ["docker", "image", "prune", "-af", "--filter", "until=72h"], commands["images"]
    assert_equal ["docker", "builder", "prune", "-af", "--filter", "until=72h"], commands["build cache"]
  end

  # ---- rendering ----

  def test_missing_sections_render_as_empty_rather_than_crashing
    steps = docker_prune_plan({}, cutoff: CUTOFF)
    assert_equal [0, 0, 0, 0], steps.map(&:count)
    out = capture_stdout { render_docker_prune_plan(steps) }
    assert_includes out, "0 containers"
    assert_includes out, "total"
  end

  def test_render_marks_lower_bounds_and_totals_them
    df = { "Images" => [image], "Volumes" => [volume(size: "1GB", anonymous: false)] }
    out = capture_stdout { render_docker_prune_plan(docker_prune_plan(df, cutoff: CUTOFF)) }
    assert_match(/images\s+1 image\s+>= 304\.30MB/, out)
    assert_match(/volumes\s+1 volume\s+1\.00GB/, out)
    assert_match(/total\s+>= 1\.30GB/, out)
  end
end
