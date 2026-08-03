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
