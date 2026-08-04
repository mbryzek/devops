#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

# bin/api is a library when loaded (main is guarded by __FILE__ == $PROGRAM_NAME).
load File.expand_path('../bin/api', __dir__)

# The ~/code producer fallback and the source announcement. Together these are
# what makes a bare `api` in a consumer checkout resolve against MERGED main
# instead of silently regenerating backwards from the registry (2026-08-04:
# 167 svelte-check errors on a clean playbook-app main).
class TestApiProducers < Minitest::Test

  def setup
    # Never touch the network from a test; every fixture origin is a local path,
    # so fetching would work, but the point of the fixtures is the ref state.
    ENV[ApiProducers::SKIP_FETCH_ENV] = "1"
    ApiProducers.reset_cache!
  end

  def teardown
    ENV.delete(ApiProducers::SKIP_FETCH_ENV)
    ApiProducers.reset_cache!
  end

  def test_indexes_specs_from_producer_repos
    with_code_root do |root|
      make_producer(root, "platform", specs: { "spec/club.json" => { "name" => "club" } },
                                      dao_specs: { "dao/spec/db-club.json" => { "name" => "db-club" } })
      make_producer(root, "acumen", specs: { "spec/acumen.json" => { "name" => "acumen" } })

      producers = ApiProducers.new(code_root: root, repos: %w[platform acumen lib-ai])

      assert_equal %w[acumen club db-club], producers.app_keys.sort
      assert_equal "platform", producers[["bryzek", "club"]][:repo]
      assert_nil producers[["bryzek", "not-a-producer-app"]]
    end
  end

  # The whole point of reading through `git show`: ~/code/platform is Mike's own
  # checkout and is routinely dirty and on a feature branch. Neither may leak
  # into a consumer's regen.
  def test_reads_merged_main_not_the_working_tree
    with_code_root do |root|
      dir = make_producer(root, "platform", specs: { "spec/club.json" => { "name" => "merged" } })
      write_spec(File.join(dir, "spec"), "club.json", { "name" => "dirty-working-tree" })
      write_spec(File.join(dir, "spec"), "branch-only.json", { "name" => "branch-only" })

      producers = ApiProducers.new(code_root: root, repos: %w[platform])
      source = producers[["bryzek", "club"]]

      assert_equal "merged", JSON.parse(spec_contents(source))["name"]
      assert_nil producers[["bryzek", "branch-only"]]
    end
  end

  # A producer this session already holds as a working tree (this repo, or a
  # sibling clone in the same feature dir) is dropped entirely, so a repo is
  # never resolved half from its own branch and half from origin/main.
  def test_excludes_repos_the_session_already_has
    with_code_root do |root|
      make_producer(root, "platform", specs: { "spec/club.json" => { "name" => "club" } })
      make_producer(root, "acumen", specs: { "spec/acumen.json" => { "name" => "acumen" } })

      producers = ApiProducers.new(exclude: ["platform"], code_root: root, repos: %w[platform acumen])

      assert_equal %w[acumen], producers.app_keys
    end
  end

  # Spec file names ARE application keys, so a name appearing in two producers
  # has no unambiguous source. Refuse to guess.
  def test_duplicate_spec_file_names_across_producers_fail_loudly
    with_code_root do |root|
      make_producer(root, "platform", specs: { "spec/club.json" => { "name" => "club" } })
      make_producer(root, "acumen", specs: { "spec/club.json" => { "name" => "club" } })

      producers = ApiProducers.new(code_root: root, repos: %w[platform acumen])

      assert_raises(SystemExit) { producers[["bryzek", "club"]] }
    end
  end

  def test_duplicate_spec_file_names_within_one_producer_fail_loudly
    with_code_root do |root|
      make_producer(root, "platform",
                    specs: { "spec/club.json" => { "name" => "club" } },
                    dao_specs: { "dao/spec/club.json" => { "name" => "club" } })

      producers = ApiProducers.new(code_root: root, repos: %w[platform])

      assert_raises(SystemExit) { producers[["bryzek", "club"]] }
    end
  end

  # A checkout that has never fetched (no origin/main) or is absent entirely is
  # skipped — the run continues on the registry, which is what it did before.
  def test_missing_repo_or_ref_is_skipped_not_fatal
    with_code_root do |root|
      no_origin = File.join(root, "acumen")
      FileUtils.mkdir_p(no_origin)
      git(no_origin, "init", "-b", "main")

      producers = ApiProducers.new(code_root: root, repos: %w[platform acumen])

      assert_empty producers.app_keys
    end
  end

  # A repo with nestedConfigs builds one resolution chain per codegen root; the
  # producers must be fetched and indexed once for the process, not per root.
  def test_index_is_built_once_per_process
    with_code_root do |root|
      dir = make_producer(root, "platform", specs: { "spec/club.json" => { "name" => "club" } })

      first = ApiProducers.new(code_root: root, repos: %w[platform])
      assert_equal %w[club], first.app_keys

      FileUtils.rm_rf(dir)
      assert_equal %w[club], ApiProducers.new(code_root: root, repos: %w[platform]).app_keys
    end
  end

  def test_read_payload_from_producer_injects_project_from_that_ref
    with_code_root do |root|
      make_producer(root, "platform", specs: { "spec/club.json" => { "name" => "club" } },
                                      build_sbt: %(name := "platform"\n))
      source = ApiProducers.new(code_root: root, repos: %w[platform])[["bryzek", "club"]]

      assert_equal({ "name" => "platform" }, read_payload(source)["attributes"]["project"])
    end
  end

  # --- SpecSources: precedence and announcement ---

  def test_resolution_precedence_and_recorded_sources
    local = { ["bryzek", "a"] => { path: "/x/a.json", root: "/x", label: "working tree (.)" } }
    siblings = { ["bryzek", "b"] => { path: "/s/b.json", root: "/s", label: "sibling clone platform (working tree)" },
                 ["bryzek", "a"] => { path: "/s/a.json", root: "/s", label: "sibling clone platform (working tree)" } }
    producers = { ["bryzek", "c"] => { git: true, label: "~/code/platform@origin/main (abc1234, 2 hours ago)" } }
    sources = SpecSources.new(local: local, siblings: siblings, producers: producers)

    assert_equal "/x/a.json", sources[["bryzek", "a"]][:path], "local must win over a sibling"
    assert_equal "/s/b.json", sources[["bryzek", "b"]][:path]
    assert sources[["bryzek", "c"]][:git]
    assert_nil sources[["bryzek", "d"]]

    assert_equal(
      {
        ["bryzek", "a"] => "working tree (.)",
        ["bryzek", "b"] => "sibling clone platform (working tree)",
        ["bryzek", "c"] => "~/code/platform@origin/main (abc1234, 2 hours ago)",
        ["bryzek", "d"] => SpecSources::REGISTRY_LABEL,
      },
      sources.resolutions
    )
  end

  # The announcement is the fix for the actual incident: `api` knew it had fallen
  # back to the registry and said nothing. Registry prints last, with its apps.
  def test_announce_groups_by_source_and_prints_registry_last
    sources = SpecSources.new(
      local: { ["bryzek", "ui"] => { path: "/x/ui.json", root: "/x", label: "working tree (.)" } },
      siblings: {},
      producers: { ["bryzek", "club"] => { git: true, label: "~/code/platform@origin/main (abc1234, 2 hours ago)" } },
    )
    sources[["bryzek", "ui"]]
    sources[["bryzek", "club"]]
    sources[["bryzek", "clubaid-legacy"]]

    out, _ = capture_io { sources.announce }
    lines = out.lines.map(&:rstrip)

    assert_equal "==> Spec sources:", lines.first
    assert_includes out, "~/code/platform@origin/main (abc1234, 2 hours ago) — 1"
    assert_includes out, "club"
    assert_equal "        clubaid-legacy", lines.last
    assert_includes lines[-2], SpecSources::REGISTRY_LABEL
  end

  def test_announce_is_silent_when_nothing_was_resolved
    out, _ = capture_io { SpecSources.new(local: {}, siblings: {}, producers: {}).announce }
    assert_empty out
  end

  # local_repo_names is what feeds `exclude`: this repo plus every sibling clone.
  def test_local_repo_names_covers_this_repo_and_siblings
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "consumer")
      FileUtils.mkdir_p(repo)
      siblings = { ["bryzek", "club"] => { path: "/ai/f/platform/spec/club.json", root: "/ai/f/platform" } }

      assert_equal %w[consumer platform], local_repo_names(repo, siblings).sort
    end
  end

  private

  # A producer checkout the way `api` finds one under ~/code: a clone whose
  # origin/main carries the given specs.
  def make_producer(code_root, name, specs: {}, dao_specs: {}, build_sbt: nil)
    origin_parent = File.join(code_root, ".origins")
    FileUtils.mkdir_p(origin_parent)
    origin = File.join(origin_parent, "#{name}.git")
    git(origin_parent, "init", "--bare", origin)

    dir = File.join(code_root, name)
    FileUtils.mkdir_p(dir)
    git(dir, "init", "-b", "main")
    git(dir, "config", "user.email", "test@test")
    git(dir, "config", "user.name", "test")
    git(dir, "remote", "add", "origin", origin)
    specs.merge(dao_specs).each do |rel, spec|
      FileUtils.mkdir_p(File.join(dir, File.dirname(rel)))
      write_spec(File.join(dir, File.dirname(rel)), File.basename(rel), spec)
    end
    File.write(File.join(dir, "build.sbt"), build_sbt) if build_sbt
    git(dir, "add", ".")
    git(dir, "commit", "-m", "specs")
    git(dir, "push", "-u", "origin", "main")
    dir
  end

  def with_code_root
    Dir.mktmpdir { |dir| yield File.realpath(dir) }
  end

  def write_spec(dir, name, spec)
    File.write(File.join(dir, name), JSON.generate(spec))
  end

  def git(dir, *args)
    out = IO.popen(["git", "-C", dir] + args, err: [:child, :out], &:read)
    raise "git #{args.join(' ')} failed: #{out}" unless $?.success?
    out
  end

end
