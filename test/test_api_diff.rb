#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'json'

# bin/api is a library when loaded (main is guarded by __FILE__ == $PROGRAM_NAME).
load File.expand_path('../bin/api', __dir__)
require_relative '../lib/api_config'

# `api diff` decides three things before the server sees anything, and each one is a
# fact about this checkout that no diff of two specs could recover:
#
#   which applications CHANGED  — only those get `previous`, and only those get a verdict
#   which are NEW               — no spec at the base ref, so there is no contract to break
#   which are GONE              — deleted specs are invisible to a per-application diff,
#                                 because a deleted application is not in the config to ask about
#
# The classification of a difference is apibuilder's and is tested in platform's
# ServiceDiffSpec; what is tested here is the request this builds and the exit code it
# turns the answer into.
class TestApiDiff < Minitest::Test

  def setup
    @dir = Dir.mktmpdir("api-diff")
    git("init", "--initial-branch", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def git(*args)
    out, status = Open3.capture2("git", "-C", @dir, *args, err: File::NULL)
    raise "git #{args.join(' ')} failed" unless status.success?
    out
  end

  def write_spec(name, models)
    path = File.join(@dir, "spec", name)
    FileUtils.mkdir_p(File.dirname(path))
    IO.write(path, JSON.pretty_generate({ "name" => File.basename(name, ".json"), "models" => models }))
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-m", message)
  end

  def config_for(app_keys)
    applications = app_keys.map { |key| ApiConfig::Application.new(key: key, file_path: "spec/#{key}.json") }
    block = ApiConfig::Block.new(org: "bryzek", group: nil, generators: [], attributes: {}, applications: applications)
    Struct.new(:blocks, :orgs) do
      def blocks_for_org(_org) = blocks
    end.new([block], ["bryzek"])
  end

  def build(app_keys, base: "main")
    build_diff_request(config_for(app_keys), "bryzek", [], nil, @dir, @dir, base, nil)
  end

  def user_model(fields) = { "user" => { "fields" => fields } }

  ID_ONLY = [{ "name" => "id", "type" => "string" }].freeze
  ID_AND_EMAIL = [{ "name" => "id", "type" => "string" }, { "name" => "email", "type" => "string" }].freeze

  def test_only_changed_applications_carry_previous
    write_spec("a.json", user_model(ID_ONLY))
    write_spec("b.json", user_model(ID_ONLY))
    commit("base")
    write_spec("a.json", user_model(ID_AND_EMAIL))

    request = build(%w[a b])
    by_key = request[:form]["applications"].to_h { |app| [app["application_key"], app] }

    assert_equal %w[a], request[:changed]
    assert_equal ID_ONLY, by_key["a"]["previous"].dig("models", "user", "fields")
    assert_equal ID_AND_EMAIL, by_key["a"]["original"].dig("models", "user", "fields")

    # b did not change and nothing being diffed imports it, so it is not sent at all:
    # the payload is the subjects plus their import closure, not the whole repo.
    refute by_key.key?("b")
  end

  # The closure is what keeps an unchanged spec's types resolvable, and it is computed
  # from the subjects rather than from the config — so a spec nobody imports and nobody
  # changed never enters the request.
  def test_an_unchanged_import_of_a_changed_spec_rides_along
    write_spec("a.json", user_model(ID_ONLY))
    write_spec("b.json", user_model(ID_ONLY))
    commit("base")
    write_spec("a.json", user_model(ID_AND_EMAIL))
    IO.write(
      File.join(@dir, "spec", "a.json"),
      JSON.pretty_generate(
        JSON.parse(IO.read(File.join(@dir, "spec", "a.json")))
          .merge("imports" => [{ "uri" => "https://app.apibuilder.io/bryzek/b/latest/service.json" }]),
      ),
    )

    sources = { %w[bryzek b] => { path: File.join(@dir, "spec", "b.json"), root: @dir } }
    request = build_diff_request(config_for(%w[a b]), "bryzek", [], nil, @dir, @dir, "main", sources)
    by_key = request[:form]["applications"].to_h { |app| [app["application_key"], app] }

    assert by_key.key?("b"), "an import of a changed spec must ride along, or its types stop resolving"
    refute by_key["b"].key?("previous"), "context is not a subject: it gets no verdict"
  end

  # A reformatted spec is not a contract change. Sending it as one would make every
  # whitespace edit something a human has to classify.
  def test_a_reformatted_spec_is_not_a_change
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    IO.write(File.join(@dir, "spec", "a.json"), JSON.generate(JSON.parse(IO.read(File.join(@dir, "spec", "a.json")))))

    assert_equal [], build(%w[a])[:changed]
  end

  def test_a_new_spec_has_no_prior_contract
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    write_spec("new.json", user_model(ID_ONLY))

    request = build(%w[a new])
    assert_equal %w[new], request[:added]
    assert_equal [], request[:changed]
    refute request[:form]["applications"].find { |app| app["application_key"] == "new" }.key?("previous")
  end

  def test_a_deleted_spec_is_reported_even_though_it_left_the_config
    write_spec("a.json", user_model(ID_ONLY))
    write_spec("gone.json", user_model(ID_ONLY))
    commit("base")
    FileUtils.rm(File.join(@dir, "spec", "gone.json"))

    # The config no longer lists `gone`, exactly as it would not after the deletion.
    request = build(%w[a])
    assert_equal ["spec/gone.json"], request[:deleted]

    applications = summarize_diff(request, [])
    removed = applications.find { |app| app["status"] == "removed" }
    assert removed["diffs"].all? { |d| d["breaking"] }, "deleting a contract is breaking"
  end

  def test_a_missing_spec_file_is_uncheckable_not_a_finding
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    FileUtils.rm(File.join(@dir, "spec", "a.json"))

    assert_raises(ApiDiffError) { build(%w[a]) }
  end

  # An unresolvable base makes every spec look new — "no prior contract, nothing to
  # break" — which is a verdict, and the wrong one. It has to be an error instead.
  def test_an_unfetched_base_ref_is_uncheckable_not_a_finding
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")

    assert_raises(ApiDiffError) { diff_assert_ref!(@dir, "origin/does-not-exist") }
    assert_raises(ApiDiffError) { build(%w[a], base: "origin/does-not-exist") }
  end

  def test_summarize_marks_breaking_from_the_servers_own_discriminator
    request = { org: "bryzek", added: [], deleted: [] }
    results = [{
      "organization_key" => "bryzek",
      "application_key" => "a",
      "diffs" => [
        { "discriminator" => "diff_breaking", "description" => "model removed: user", "is_material" => true },
        { "discriminator" => "diff_non_breaking", "description" => "model added: group", "is_material" => true },
      ],
    }]

    diffs = summarize_diff(request, results).first["diffs"]
    assert_equal [true, false], diffs.map { |d| d["breaking"] }
  end

  def test_parse_diff_args_defaults_to_origin_main
    parsed = parse_diff_args(["diff"])
    assert_equal "origin/main", parsed[:base]
    assert_equal [], parsed[:apps]
    refute parsed[:json]
  end

  def test_parse_diff_args_flags
    parsed = parse_diff_args(["diff", "--base", "HEAD~1", "--app", "platform", "--app", "issues", "--group", "dao", "--json"])
    assert_equal "HEAD~1", parsed[:base]
    assert_equal %w[platform issues], parsed[:apps]
    assert_equal "dao", parsed[:group]
    assert parsed[:json]
  end

  # ApibuilderClient keys its methods by symbol, so `"POST"` reaches the server as an
  # abort rather than a request — and an abort here is a spec change nobody classified.
  def test_the_diff_is_posted_with_a_method_the_client_supports
    recorder = Struct.new(:calls) do
      def request(method, path, body)
        calls << [method, path, body]
        []
      end
    end.new([])

    post_diff(recorder, { "applications" => [] })
    method, path, = recorder.calls.first

    assert ApibuilderClient::HTTP_METHODS.key?(method), "ApibuilderClient cannot send #{method.inspect}"
    assert_equal "/apibuilder/diffs", path
  end

  # The three exit codes are the whole contract with pr_auto_merge: a check that broke
  # must not be indistinguishable from a check that passed, nor from a finding.
  def test_exit_codes_are_distinct
    assert_equal 0, API_DIFF_EXIT_NON_BREAKING
    assert_equal 1, API_DIFF_EXIT_BREAKING
    assert_equal 2, API_DIFF_EXIT_UNCHECKABLE
  end
end
