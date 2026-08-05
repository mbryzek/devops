#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'

# bin/api is a library when loaded (main is guarded by __FILE__ == $PROGRAM_NAME).
load File.expand_path('../bin/api', __dir__)

class TestApiHermetic < Minitest::Test

  def test_parse_import_key
    assert_equal ["bryzek", "platform-storage"],
      parse_import_key("https://app.apibuilder.io/bryzek/platform-storage/latest/service.json")
    assert_nil parse_import_key("not-a-service-uri")
  end

  def test_parse_batch_args_rejects_upload_and_codegen
    assert_raises(SystemExit) { parse_batch_args(["upload"]) }
    assert_raises(SystemExit) { parse_batch_args(["codegen"]) }
  end

  def test_parse_batch_args_filters
    parsed = parse_batch_args(["--app", "platform", "--group", "dao"])
    assert_equal ["platform"], parsed[:apps]
    assert_equal "dao", parsed[:group]
  end

  # payload_context_entries closes the payload set under imports, transitively,
  # and leaves unavailable imports to the registry fallback.
  def test_payload_context_entries_transitive
    Dir.mktmpdir do |dir|
      write_spec(dir, "b.json", { "name" => "b", "imports" => [import_of("c")] })
      write_spec(dir, "c.json", { "name" => "c" })
      available = {
        ["bryzek", "b"] => { path: File.join(dir, "b.json"), root: dir },
        ["bryzek", "c"] => { path: File.join(dir, "c.json"), root: dir },
      }
      applications = [
        { "organization_key" => "bryzek", "application_key" => "a",
          "original" => { "name" => "a", "imports" => [import_of("b"), import_of("registry-only")] } },
      ]
      extras = payload_context_entries(applications, available)
      assert_equal [["bryzek", "b"], ["bryzek", "c"]],
        extras.map { |e| [e["organization_key"], e["application_key"]] }
      extras.each { |e| refute_nil e["original"] }
    end
  end

  def test_payload_context_entries_skips_already_present
    applications = [
      { "organization_key" => "bryzek", "application_key" => "a",
        "original" => { "name" => "a", "imports" => [import_of("a")] } },
    ]
    assert_empty payload_context_entries(applications, {})
  end

  # sibling_spec_paths only activates under an ai/<feature>/<repo> layout and maps
  # sibling spec files by (org, app key).
  def test_sibling_spec_paths_outside_feature_dir
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "not-ai", "feature", "repo")
      FileUtils.mkdir_p(repo)
      assert_empty sibling_spec_paths(repo)
    end
  end

  # The positive half: inside `ai/<feature>/`, a sibling clone's spec files are
  # what the batch resolves from — no registry, therefore no "released, not
  # merged" gap. `dev codegen sync` clones into exactly this layout so its
  # consumer repos regenerate against the backend clones on main; if this gate
  # stops matching, the sweep silently regenerates every consumer backwards.
  def test_sibling_spec_paths_finds_specs_inside_feature_dir
    Dir.mktmpdir do |dir|
      feature = File.join(dir, "ai", "cgs.20260804-153000")
      repo = File.join(feature, "consumer")
      FileUtils.mkdir_p(repo)
      # Realpath: the scan runs off File.realpath(project_root), and a macOS
      # temp dir is reached through a /var -> /private/var symlink.
      producer = File.realpath(make_spec_repo(feature, "producer", "sibling-api"))

      found = sibling_spec_paths(repo)

      assert_equal [["bryzek", "sibling-api"]], found.keys
      assert_equal File.join(producer, "spec", "sibling-api.json"), found[["bryzek", "sibling-api"]][:path]
      assert_equal producer, found[["bryzek", "sibling-api"]][:root]
    end
  end

  # A repo is never its own sibling — its specs come from the local-spec path.
  def test_sibling_spec_paths_excludes_self
    Dir.mktmpdir do |dir|
      feature = File.join(dir, "ai", "cgs.20260804-153000")
      repo = make_spec_repo(feature, "producer", "sibling-api")
      assert_empty sibling_spec_paths(repo)
    end
  end

  # A nested codegen root (playbook-app/playwright, playbook-admin/playwright) is a
  # second OUTPUT location for the same repo, never a second repo — so the whole run
  # resolves specs through ONE chain, built from the repo root.
  #
  # Re-deriving it from the nested directory is the ISS-444 bug: sibling_spec_paths
  # gates on an ai/<feature>/<repo> layout, and for <repo>/playwright the "feature
  # dir" is the REPO, whose parent is the workspace rather than `ai`. The gate
  # failed, no siblings were found, and one `api` wrote src/generated from the
  # branch and playwright/generated from ~/code at origin/main.
  def test_spec_sources_are_resolved_once_from_the_repo_root
    Dir.mktmpdir do |dir|
      feature = File.join(dir, "ai", "i444_ufh")
      producer = File.realpath(make_spec_repo(feature, "producer", "sibling-api"))
      consumer = make_consumer_with_nested_root(feature, "consumer", nested_app: "sibling-api")

      roots = nil
      sources = nil
      # The producer tier would index the real ~/code checkouts; the assertion here
      # is about which repos it is told to SKIP, so stand it in with an empty tier.
      excluded = Dir.chdir(consumer) do
        roots = resolve_config_roots(consumer)
        with_stubbed_producers { sources = build_spec_sources(roots) }
      end

      assert_equal [consumer, File.join(consumer, "playwright")], roots.map(&:last)

      # `sibling-api` is named ONLY by the nested config. It still resolves to the
      # sibling clone's working tree — the branch — exactly as the repo root does.
      assert_equal File.join(producer, "spec", "sibling-api.json"),
        sources[["bryzek", "sibling-api"]][:path]
      assert_equal "sibling clone producer (working tree)",
        sources.resolutions[["bryzek", "sibling-api"]]

      # And the producer fallback skips the repos this session holds as working
      # trees. Derived from the nested dir this was ["playwright"], which excludes
      # nothing and lets ~/code/<producer>@origin/main answer for a branch spec.
      assert_equal ["consumer", "producer"], excluded.sort
    end
  end

  # The other way to trip ISS-444: `api` run from inside <repo>/playwright. That run
  # owns exactly one root — the nested one — so the chain has to be anchored on the
  # repo that declares it, not on the directory the command was typed in.
  def test_spec_sources_from_inside_a_nested_root_still_see_siblings
    Dir.mktmpdir do |dir|
      feature = File.join(dir, "ai", "i444_ufh")
      producer = File.realpath(make_spec_repo(feature, "producer", "sibling-api"))
      consumer = make_consumer_with_nested_root(feature, "consumer", nested_app: "sibling-api")
      nested = File.join(consumer, "playwright")

      sources = nil
      excluded = Dir.chdir(nested) do
        with_stubbed_producers { sources = build_spec_sources(resolve_config_roots(nested)) }
      end

      assert_equal File.join(producer, "spec", "sibling-api.json"),
        sources[["bryzek", "sibling-api"]][:path]
      assert_equal ["consumer", "producer"], excluded.sort
    end
  end

  # A repo root is its own owner — a parent that merely happens to hold a config
  # (never the real layout, but cheap to be sure of) does not adopt it.
  def test_owning_repo_root_of_a_repo_root_is_itself
    Dir.mktmpdir do |dir|
      repo = make_spec_repo(dir, "repo", "some-api")
      assert_equal repo, owning_repo_root(repo)
    end
  end

  # The repo root wins an app a nested root also names: same repo, one answer.
  def test_local_spec_paths_prefers_the_repo_root_over_a_nested_root
    Dir.mktmpdir do |dir|
      repo = make_spec_repo(dir, "repo", "shared-api")
      nested = File.join(repo, "playwright")
      FileUtils.mkdir_p(File.join(nested, "spec"))
      write_spec(File.join(nested, "spec"), "shared-api.json", { "name" => "shared-api" })
      nested_config = ApiConfig.new(File.join(repo, ".api", "config.pkl"), base_dir: nested)

      root_config = ApiConfig.new(File.join(repo, ".api", "config.pkl"), base_dir: repo)
      paths = local_spec_paths([[root_config, repo], [nested_config, nested]])

      assert_equal File.join(repo, "spec", "shared-api.json"), paths[["bryzek", "shared-api"]][:path]
    end
  end

  def test_ensure_publishable_rejects_non_main_branch
    with_git_repo(branch: "feature-x") do |repo|
      Dir.chdir(repo) { assert_raises(SystemExit) { ensure_publishable!(repo) } }
    end
  end

  def test_ensure_publishable_rejects_dirty_tree
    with_git_repo(branch: "main") do |repo|
      File.write(File.join(repo, "dirty.txt"), "x")
      Dir.chdir(repo) { assert_raises(SystemExit) { ensure_publishable!(repo) } }
    end
  end

  def test_ensure_publishable_accepts_clean_main_matching_origin
    with_git_repo(branch: "main", with_origin: true) do |repo|
      Dir.chdir(repo) { ensure_publishable!(repo) }
    end
  end

  def test_ensure_publishable_rejects_local_ahead_of_origin
    with_git_repo(branch: "main", with_origin: true) do |repo|
      File.write(File.join(repo, "new.txt"), "x")
      git(repo, "add", ".")
      git(repo, "commit", "-m", "ahead")
      Dir.chdir(repo) { assert_raises(SystemExit) { ensure_publishable!(repo) } }
    end
  end

  # The release publishes AFTER the deploy, so another PR merging mid-deploy
  # leaves this checkout behind origin/main. That commit is still merged, so it
  # is still publishable.
  def test_ensure_publishable_accepts_local_behind_origin
    with_git_repo(branch: "main", with_origin: true) do |repo|
      push_commit(repo, "someone-else.txt")
      git(repo, "reset", "--hard", "HEAD~1")
      Dir.chdir(repo) { ensure_publishable!(repo) }
    end
  end

  def test_ensure_publishable_rejects_diverged_from_origin
    with_git_repo(branch: "main", with_origin: true) do |repo|
      push_commit(repo, "someone-else.txt")
      git(repo, "reset", "--hard", "HEAD~1")
      File.write(File.join(repo, "mine.txt"), "x")
      git(repo, "add", ".")
      git(repo, "commit", "-m", "unpushed local work")
      Dir.chdir(repo) { assert_raises(SystemExit) { ensure_publishable!(repo) } }
    end
  end

  private

  # A repo clone the way `api` expects to find one: `.api/config.pkl` naming a
  # single app, plus that app's spec file. Same `modulepath:` amends every real
  # repo uses — ApiConfig points pkl's --module-path at the devops checkout the
  # CLI runs from, so this resolves from a temp dir with no devops sibling.
  def make_spec_repo(parent, name, app_key)
    repo = File.join(parent, name)
    FileUtils.mkdir_p(File.join(repo, ".api"))
    FileUtils.mkdir_p(File.join(repo, "spec"))
    File.write(File.join(repo, ".api", "config.pkl"), <<~PKL)
      amends "#{ApiConfig::BASE_MODULE_URI}"

      org = "bryzek"

      applications = new Listing<AppGroup> {
        new {
          names { "#{app_key}" }
          generators = module.modelOnly()
        }
      }
    PKL
    write_spec(File.join(repo, "spec"), "#{app_key}.json", { "name" => app_key })
    repo
  end

  # Replaces the producer tier with an empty one for the block, so a test never
  # indexes (or fetches) the real ~/code checkouts. Returns the `exclude:` list the
  # code under test asked for. Hand-rolled because minitest 6 dropped
  # minitest/mock; removing the singleton method restores the inherited Class#new.
  def with_stubbed_producers
    captured = nil
    ApiProducers.define_singleton_method(:new) { |exclude: [], **_rest| captured = exclude; {} }
    begin
      yield
    ensure
      ApiProducers.singleton_class.send(:remove_method, :new)
    end
    captured
  end

  # A consumer clone shaped like playbook-app: its own config plus a `playwright`
  # nested root that names an app the repo root does not.
  def make_consumer_with_nested_root(parent, name, nested_app:)
    repo = File.join(parent, name)
    FileUtils.mkdir_p(File.join(repo, "playwright", ".api"))
    FileUtils.mkdir_p(File.dirname(File.join(repo, ".api")))
    FileUtils.mkdir_p(File.join(repo, ".api"))
    File.write(File.join(repo, ".api", "config.pkl"), <<~PKL)
      amends "#{ApiConfig::BASE_MODULE_URI}"

      org = "bryzek"

      applications = new Listing<AppGroup> {
        new {
          names { "root-only-api" }
          generators = module.singleGenerator("typescript", "./src/generated")
        }
      }

      nestedConfigs {
        "playwright"
      }
    PKL
    File.write(File.join(repo, "playwright", ".api", "config.pkl"), <<~PKL)
      amends "#{ApiConfig::BASE_MODULE_URI}"

      org = "bryzek"

      applications = new Listing<AppGroup> {
        new {
          names { "#{nested_app}" }
          generators = module.singleGenerator("typescript", "./generated")
        }
      }
    PKL
    File.realpath(repo)
  end

  def push_commit(repo, name)
    File.write(File.join(repo, name), "x")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "commit #{name}")
    git(repo, "push", "origin", "main")
  end

  def import_of(app)
    { "uri" => "https://app.apibuilder.io/bryzek/#{app}/latest/service.json" }
  end

  def write_spec(dir, name, spec)
    File.write(File.join(dir, name), JSON.generate(spec))
  end

  def git(repo, *args)
    out = IO.popen(["git", "-C", repo] + args, err: [:child, :out], &:read)
    raise "git #{args.join(' ')} failed: #{out}" unless $?.success?
    out
  end

  def with_git_repo(branch:, with_origin: false)
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "repo")
      FileUtils.mkdir_p(repo)
      git(repo, "init", "-b", branch)
      git(repo, "config", "user.email", "test@test")
      git(repo, "config", "user.name", "test")
      File.write(File.join(repo, "README.md"), "test")
      git(repo, "add", ".")
      git(repo, "commit", "-m", "init")
      if with_origin
        origin = File.join(dir, "origin.git")
        git(repo, "init", "--bare", origin)
        git(repo, "remote", "add", "origin", origin)
        git(repo, "push", "-u", "origin", branch)
      end
      yield repo
    end
  end

end
