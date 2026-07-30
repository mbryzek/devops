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
  RECENT_OLDER = "2026-07-28 09:05:48 -0400 EDT" # days back, still inside the window
  OLD_CACHE_TS    = "2026-05-12 03:12:25.566497142 +0000 UTC"
  RECENT_CACHE_TS = "2026-07-30 09:05:48.123456789 +0000 UTC"

  def container(state:, created: OLD, size: "20.5kB")
    { "State" => state, "CreatedAt" => created, "Size" => size }
  end

  def image(id: nil, repo: "registry/platform", tag: nil, containers: "0", created: OLD,
            unique: "304.3MB", size: "795MB")
    @image_seq = (@image_seq || 0) + 1
    { "ID" => id || "img#{@image_seq}", "Repository" => repo, "Tag" => tag || "0.0.#{@image_seq}",
      "Containers" => containers, "CreatedAt" => created, "UniqueSize" => unique, "Size" => size }
  end

  # Raw `docker buildx du --format json`: Parents is an array, Shared a real
  # boolean, and LastUsedAt is usually prose.
  def cache(id: nil, parents: [], shared: false, last_used: "2 months ago", created: OLD_CACHE_TS,
            size: "157MB")
    @cache_seq = (@cache_seq || 0) + 1
    { "ID" => id || "rec#{@cache_seq}", "Parents" => parents, "Shared" => shared,
      "LastUsedAt" => last_used, "CreatedAt" => created, "Size" => size }
  end

  def records(*raw) = raw.map { |r| docker_cache_record(r, now: NOW) }

  def volume(links: "0", size: "1.625GB", anonymous: true)
    { "Links" => links, "Size" => size,
      "Labels" => anonymous ? "com.docker.volume.anonymous=" : "com.example.keep=1" }
  end

  # keep_tags defaults to 0 so a test that says nothing about tags exercises only
  # the age-based steps; the tag sweep has its own tests.
  def plan(df, cache_by_builder: {}, keep_named_volumes: false, keep_tags: 0)
    docker_prune_plan(df, cutoff: CUTOFF, filter: "until=72h", cache_by_builder: cache_by_builder,
                      keep_named_volumes: keep_named_volumes, keep_tags: keep_tags)
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
    # Not a floor: layers unique among IMAGES can still be pinned by build cache
    # records, which is how 1.48GB of "unique" layers freed 8.63MB on a real run.
    refute step.at_least
  end

  # ---- build cache: dated by last use, sized by non-shared records ----

  def test_cache_step_counts_by_last_use_and_sizes_only_non_shared_records
    cache_by_builder = { "desktop-linux" => records(
      cache,
      cache(shared: true, size: "900MB"),      # counted, but frees nothing yet
      cache(last_used: "20 hours ago"),        # inside the age filter
      # Never used: falls back to CreatedAt rather than reading as undatable.
      cache(last_used: "", created: OLD_CACHE_TS, size: "43MB"),
    ) }
    step = plan({}, cache_by_builder: cache_by_builder)["cache/desktop-linux"]
    assert_equal 3, step.count
    assert_equal 200_000_000, step.bytes, "shared records contribute 0 until their images go"
    assert step.at_least
  end

  # The estimate that a real run proved wrong: an aged base layer that a recent
  # build still descends from is selected by buildkit's until filter and then
  # released by nothing. All 56 aged records on the box this was found on were
  # ancestors of retained ones, and the 2.54GB estimate freed 0B.
  def test_aged_cache_records_pinned_by_a_newer_descendant_are_not_counted
    cache_by_builder = { "desktop-linux" => records(
      cache(id: "base", size: "2GB"),
      cache(id: "recent", parents: ["base"], last_used: "20 hours ago", size: "10MB"),
    ) }
    step = plan({}, cache_by_builder: cache_by_builder)["cache/desktop-linux"]
    assert_equal 0, step.count
    assert_equal 0, step.bytes
    assert_includes step.note, "1 aged record(s) pinned by newer descendants"
  end

  # Pinning is transitive: the grandparent of a retained record is just as stuck.
  def test_cache_pinning_walks_the_whole_ancestor_chain
    cache_by_builder = { "desktop-linux" => records(
      cache(id: "grandparent", size: "1GB"),
      cache(id: "parent", parents: ["grandparent"], size: "1GB"),
      cache(id: "recent", parents: ["parent"], last_used: "20 hours ago", size: "10MB"),
      cache(id: "orphan", size: "500MB"),  # aged with nothing descending from it
    ) }
    step = plan({}, cache_by_builder: cache_by_builder)["cache/desktop-linux"]
    assert_equal 1, step.count, "only the orphan is actually releasable"
    assert_equal 500_000_000, step.bytes
  end

  # Two sources describe the same records with different schemas: buildx du gives
  # a Parents array and a real boolean, docker system df -v a Parent string and
  # "true"/"false". Both must normalize to the same record.
  def test_cache_records_normalize_from_either_schema
    from_buildx = docker_cache_record({ "ID" => "a", "Parents" => %w[p1 p2], "Shared" => true,
                                        "Size" => "1GB", "LastUsedAt" => "2 days ago" }, now: NOW)
    from_df = docker_cache_record({ "ID" => "a", "Parent" => "p1 p2", "Shared" => "true",
                                    "Size" => "1GB", "LastUsedAt" => (NOW - 2 * 86_400).strftime("%Y-%m-%d %H:%M:%S %z UTC") }, now: NOW)
    assert_equal %w[p1 p2], from_buildx.parents
    assert_equal from_buildx.parents, from_df.parents
    assert from_buildx.shared
    assert from_df.shared
    assert_equal 1_000_000_000, from_df.bytes
    assert_in_delta from_buildx.last_used.to_i, from_df.last_used.to_i, 1
  end

  def test_cache_parents_parse_from_either_separator
    assert_equal %w[a b], docker_cache_parents("Parent" => "a b")
    assert_equal %w[a b], docker_cache_parents("Parent" => "a,b")
    assert_equal %w[a b], docker_cache_parents("Parents" => %w[a b])
    assert_equal [], docker_cache_parents("Parents" => nil)
    assert_equal [], docker_cache_parents({})
  end

  # buildx du renders most LastUsedAt values as prose. Reading those as nil would
  # date every record as unknown and silently spare it.
  def test_parses_relative_timestamps
    assert_equal NOW - 33 * 60, docker_parse_relative_time("33 minutes ago", now: NOW)
    assert_equal NOW - 20 * 3600, docker_parse_relative_time("20 hours ago", now: NOW)
    assert_equal NOW - 4 * 86_400, docker_parse_relative_time("4 days ago", now: NOW)
    assert_equal NOW - 60, docker_parse_relative_time("About a minute ago", now: NOW)
    assert_equal NOW, docker_parse_relative_time("Less than a second ago", now: NOW)
    assert_nil docker_parse_relative_time("who knows", now: NOW)
  end

  # ---- every builder, not just the current one ----

  # `docker builder prune` only reaches the current builder. A docker-container
  # builder like bryzek-multi held 2,911 records / 5.28GB that no prune touched and
  # that `docker system df` never reported.
  def test_each_builder_gets_its_own_step_and_prune_command
    cache_by_builder = {
      "desktop-linux" => records(cache(size: "1GB")),
      "bryzek-multi"  => records(cache(size: "5GB")),
    }
    steps = plan({}, cache_by_builder: cache_by_builder)
    assert_equal 1_000_000_000, steps["cache/desktop-linux"].bytes
    assert_equal 5_000_000_000, steps["cache/bryzek-multi"].bytes
    assert_equal ["docker", "buildx", "prune", "--builder", "bryzek-multi", "-af", "--filter", "until=72h"],
                 steps["cache/bryzek-multi"].cmd
  end

  # ---- surplus tags ----

  def test_surplus_tags_keeps_the_newest_per_repository
    images = [
      image(repo: "registry/platform", created: RECENT),
      image(repo: "registry/platform", created: OLD),
      image(repo: "registry/platform", created: OLD),
      image(repo: "registry/acumen", created: OLD),
    ]
    surplus = docker_surplus_tag_images(images, keep: 1)
    assert_equal 2, surplus.length, "one kept per repo, the rest surplus"
    assert_equal ["registry/platform"], surplus.map { |i| i["Repository"] }.uniq
  end

  def test_surplus_tags_never_touches_images_a_container_holds_or_untagged_ones
    images = [
      image(repo: "registry/platform", containers: "1", created: OLD),
      image(repo: "registry/platform", containers: "1", created: OLD),
      image(repo: "<none>", created: OLD),
      image(repo: "<none>", created: OLD),
    ]
    assert_empty docker_surplus_tag_images(images, keep: 0)
  end

  # The two image rows must never bill the same image twice.
  def test_surplus_step_excludes_images_the_age_step_already_claims
    df = { "Images" => [image(id: "old1", created: OLD), image(id: "old2", created: OLD)] }
    steps = plan(df, keep_tags: 0)
    assert_equal 2, steps["images"].count
    assert_equal 0, steps["surplus tags"].count
  end

  def test_surplus_step_removes_by_id_and_reports_disabled_at_zero
    df = { "Images" => [
      image(id: "keep", created: RECENT),
      image(id: "drop", created: RECENT_OLDER),
    ] }
    step = plan(df, keep_tags: 1)["surplus tags"]
    assert_equal 1, step.count
    assert_equal ["docker", "image", "rm", "drop"], step.cmd
    assert_includes plan(df, keep_tags: 0)["surplus tags"].note, "disabled"
  end

  def test_surplus_step_has_no_command_when_nothing_is_surplus
    assert_nil plan({}, keep_tags: 5)["surplus tags"].cmd
  end

  # A hundred sha256 arguments is not an explanation of what the step does.
  def test_long_commands_are_summarized_for_display
    cmd = ["docker", "image", "rm", *Array.new(101) { |i| "sha256:#{i}" }]
    shown = docker_display_cmd(cmd)
    assert_includes shown, "docker image rm sha256:0"
    assert_includes shown, "(100 more arg(s))"
    refute_includes shown, "sha256:100"
  end

  # Every ordinary prune command must stay whole and copy-pasteable.
  def test_ordinary_commands_display_in_full
    assert_equal "docker volume prune -f -a", docker_display_cmd(["docker", "volume", "prune", "-f", "-a"])
    assert_equal "docker buildx prune --builder bryzek-multi -af --filter until=72h",
                 docker_display_cmd(["docker", "buildx", "prune", "--builder", "bryzek-multi", "-af",
                                     "--filter", "until=72h"])
    assert_equal "(nothing to remove)", docker_display_cmd(nil)
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
    assert_equal ["docker", "volume", "prune", "-f", "-a"], plan({})["volumes"].cmd
    assert_equal ["docker", "volume", "prune", "-f"], plan({}, keep_named_volumes: true)["volumes"].cmd
  end

  def test_age_filtered_commands_carry_the_requested_window
    steps = plan({}, cache_by_builder: { "desktop-linux" => records(cache) })
    assert_equal ["docker", "container", "prune", "-f", "--filter", "until=72h"], steps["containers"].cmd
    assert_equal ["docker", "image", "prune", "-af", "--filter", "until=72h"], steps["images"].cmd
    assert_equal ["docker", "buildx", "prune", "--builder", "desktop-linux", "-af", "--filter", "until=72h"],
                 steps["cache/desktop-linux"].cmd
  end

  # Cache pins image layers, so cache must run BEFORE images or the image row
  # reports ~0 while the cache row is credited with everything — exactly what a
  # real run showed: 37 images freeing 18.54MB, then 20.55GB from the cache step.
  def test_cache_steps_run_before_images
    labels = docker_prune_plan({}, cutoff: CUTOFF, filter: "until=72h",
                               cache_by_builder: { "desktop-linux" => records(cache) }).map(&:label)
    assert_equal %w[containers cache/desktop-linux images surplus\ tags volumes], labels
  end

  # ---- docker's own reclaimed totals ----

  # `docker builder prune` delegates to buildx, which prints a different line than
  # the other three prune commands. Matching only "Total reclaimed space" reported
  # every build cache prune as 0B no matter what it freed.
  def test_reads_both_spellings_of_dockers_reclaimed_total
    assert_equal 1_200_000_000, docker_parse_size(
      DOCKER_RECLAIMED_LINE.match("Total reclaimed space: 1.2GB\n")[1]
    )
    assert_equal 0, docker_parse_size(DOCKER_RECLAIMED_LINE.match("Total:\t0B\n")[1])
    assert_equal 2_540_000_000, docker_parse_size(DOCKER_RECLAIMED_LINE.match("Total:\t2.54GB\n")[1])
  end

  def test_reclaimed_total_ignores_unrelated_output
    assert_nil DOCKER_RECLAIMED_LINE.match("Deleted: sha256:abc123\n")
    assert_nil DOCKER_RECLAIMED_LINE.match("Total reclaimed space is not a line\n")
  end

  # ---- argument parsing ----

  # Same window as `aidirs prune`, and short on purpose: everything this deletes
  # is reproducible, and anything genuinely live is pinned by a newer descendant.
  def test_defaults_to_three_days
    opts = parse_docker_prune_args([])
    assert_equal 3, opts.days
    refute opts.apply
    refute opts.keep_named_volumes
  end

  def test_flags_override_the_defaults
    opts = parse_docker_prune_args(["--days", "7", "--apply", "--keep-named-volumes"])
    assert_equal 7, opts.days
    assert opts.apply
    assert opts.keep_named_volumes
  end

  def test_rejects_a_non_positive_window
    _, status = capture_stderr_and_exit { parse_docker_prune_args(["--days", "0"]) }
    refute_nil status, "--days 0 would filter nothing and must not silently pass"
  end

  # ---- rendering ----

  def test_missing_sections_render_as_empty_rather_than_crashing
    steps = docker_prune_plan({}, cutoff: CUTOFF, filter: "until=72h")
    assert_equal [0, 0, 0, 0], steps.map(&:count)
    out = capture_stdout { render_docker_prune_plan(steps) }
    assert_includes out, "0 containers"
    assert_includes out, "total"
  end

  # With no cache step in play nothing is a lower bound, so the total must not
  # wear a ">=" it hasn't earned.
  def test_render_totals_exactly_when_no_step_is_a_lower_bound
    df = { "Images" => [image], "Volumes" => [volume(size: "1GB", anonymous: false)] }
    out = capture_stdout do
      render_docker_prune_plan(docker_prune_plan(df, cutoff: CUTOFF, filter: "until=72h", keep_tags: 0))
    end
    assert_match(/images\s+1 image\s+304\.30MB/, out)
    assert_match(/volumes\s+1 volume\s+1\.00GB/, out)
    assert_match(/total\s+1\.30GB/, out)
    refute_match(/total\s+>=/, out)
  end

  def test_render_marks_the_total_as_a_bound_once_a_cache_step_is_present
    out = capture_stdout do
      render_docker_prune_plan(docker_prune_plan({}, cutoff: CUTOFF, filter: "until=72h", keep_tags: 0,
                                                 cache_by_builder: { "desktop-linux" => records(cache(size: "1GB")) }))
    end
    assert_match(%r{cache/desktop-linux\s+1 record\s+>= 1\.00GB}, out)
    assert_match(/total\s+>= 1\.00GB/, out)
  end
end
