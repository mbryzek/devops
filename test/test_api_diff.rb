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

  def write_spec(name, models, imports: [])
    path = File.join(@dir, "spec", name)
    FileUtils.mkdir_p(File.dirname(path))
    spec = { "name" => File.basename(name, ".json"), "models" => models }
    if !imports.empty?
      spec["imports"] = imports.map { |key| { "uri" => "https://app.apibuilder.io/bryzek/#{key}/latest/service.json" } }
    end
    IO.write(path, JSON.pretty_generate(spec))
  end

  # Spec files this repo's config does NOT name — the shape of another repo's specs,
  # which reach the chain through a sibling clone or a producer checkout.
  def external(app_keys)
    app_keys.to_h { |key| [["bryzek", key], { path: File.join(@dir, "spec", "#{key}.json"), root: @dir }] }
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

  # The real resolution chain, built from a plain {[org, app] => source} map. The diff
  # goes through SpecSources for both things it needs of a source — where a spec
  # resolves from, and which specs exist at all — so the tests use the real class
  # rather than a hash that answers only the first.
  def sources_for(specs)
    SpecSources.new(local: specs, siblings: {}, producers: {})
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

    sources = sources_for(%w[bryzek b] => { path: File.join(@dir, "spec", "b.json"), root: @dir })
    request = build_diff_request(config_for(%w[a b]), "bryzek", [], nil, @dir, @dir, "main", sources)
    by_key = request[:form]["applications"].to_h { |app| [app["application_key"], app] }

    assert by_key.key?("b"), "an import of a changed spec must ride along, or its types stop resolving"
    refute by_key["b"].key?("previous"), "context is not a subject: it gets no verdict"
  end

  # The other direction, and the one position-aware classification is unsound without.
  # `importer` is not in this repo's config at all — it is exactly the case that gets
  # missed: another repo's spec that POSTs a model this one only ever returns.
  def test_an_importer_of_a_changed_spec_rides_along
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    write_spec("a.json", user_model(ID_AND_EMAIL))
    write_spec("importer.json", {}, imports: %w[a])
    write_spec("stranger.json", {})

    request = build_diff_request(config_for(%w[a]), "bryzek", [], nil, @dir, @dir, "main",
                                 sources_for(external(%w[importer stranger])))
    by_key = request[:form]["applications"].to_h { |app| [app["application_key"], app] }

    assert by_key.key?("importer"), "a spec that imports the subject must ride along, or its use of the subject's types is invisible"
    refute by_key["importer"].key?("previous"), "an importer is context: it gets no verdict"
    refute by_key.key?("stranger"), "a spec that neither imports nor is imported by the subject stays out"
    assert_equal %w[importer], request[:importers]
  end

  # Transitively: J POSTs a model of I that carries a model of the subject, so J's
  # evidence about the subject's types is one import hop further out.
  def test_the_importer_closure_is_transitive
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    write_spec("a.json", user_model(ID_AND_EMAIL))
    write_spec("near.json", {}, imports: %w[a])
    write_spec("far.json", {}, imports: %w[near])

    request = build_diff_request(config_for(%w[a]), "bryzek", [], nil, @dir, @dir, "main",
                                 sources_for(external(%w[near far])))

    assert_equal %w[far near], request[:importers].sort
  end

  # Importers are evidence about a VERDICT, and only a changed application gets one.
  # A new application has no prior contract, so there is nothing for an importer to
  # sharpen — and scanning every spec on disk to sharpen it would be pure cost.
  def test_a_new_application_alone_pulls_in_no_importers
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    write_spec("new.json", user_model(ID_ONLY))
    write_spec("importer.json", {}, imports: %w[new])

    request = build_diff_request(config_for(%w[a new]), "bryzek", [], nil, @dir, @dir, "main",
                                 sources_for(external(%w[importer])))

    assert_equal %w[new], request[:added]
    assert_empty request[:importers]
    assert_nil request[:form_without_importers], "with no importers there is nothing to fall back to"
  end

  # The fallback payload is the request as it was before importers existed: the same
  # subjects, the same import closure, and none of the specs that import them.
  def test_the_fallback_payload_is_the_request_without_importers
    write_spec("a.json", user_model(ID_ONLY))
    commit("base")
    write_spec("a.json", user_model(ID_AND_EMAIL))
    write_spec("importer.json", {}, imports: %w[a])

    request = build_diff_request(config_for(%w[a]), "bryzek", [], nil, @dir, @dir, "main",
                                 sources_for(external(%w[importer])))

    assert_equal %w[a importer], request[:form]["applications"].map { |a| a["application_key"] }.sort
    assert_equal %w[a], request[:form_without_importers]["applications"].map { |a| a["application_key"] }
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

  # Widening the payload widens what can fail to resolve, and the server names the side
  # it failed on. The base side is `origin/main` plus specs this branch did not write,
  # so a failure there predates the branch: drop the importer context, answer as this
  # command answered before it sent any, and say so.
  def test_a_base_side_resolution_failure_falls_back_to_the_narrow_payload
    client = RecordingClient.new(
      ApibuilderClient::Error.new("POST /apibuilder/diffs: Validation errors:\n  bryzek/cycle (previous): Import uri not found"),
    )
    request = { form: { "applications" => %w[a importer] }, form_without_importers: { "applications" => %w[a] },
                importers: %w[importer] }

    results = nil
    dropped = nil
    _out, err = capture_io { results, dropped = post_diff_with_context_fallback(client, request) }

    assert_equal :ok, results
    assert_equal "importer", dropped
    assert_equal [{ "applications" => %w[a importer] }, { "applications" => %w[a] }], client.forms
    assert_includes err, "Importer context dropped"
    assert_includes err, "bryzek/cycle (previous)", "the warning has to name what the server actually refused"
  end

  # The other side is this branch's own doing: the change broke a spec that imports it
  # badly enough that the importer no longer resolves. Retrying without that importer
  # would answer "non-breaking" for exactly the change that broke it.
  def test_a_change_side_resolution_failure_is_never_retried
    client = RecordingClient.new(
      ApibuilderClient::Error.new("POST /apibuilder/diffs: Validation errors:\n  bryzek/importer (original): Type[user] not found"),
    )
    request = { form: { "applications" => %w[a importer] }, form_without_importers: { "applications" => %w[a] },
                importers: %w[importer] }

    assert_raises(ApibuilderClient::Error) { post_diff_with_context_fallback(client, request) }
    assert_equal 1, client.forms.size, "the change side must not be retried"
  end

  # An error nothing attributed to a side is one this cannot classify, and "cannot
  # classify" is not a licence to retry with less evidence.
  def test_an_unattributed_error_is_never_retried
    refute diff_error_is_base_side_only?("POST /apibuilder/diffs: Not found (404)")
    refute diff_error_is_base_side_only?("bryzek/a (previous): x\n  bryzek/b (original): y")
    assert diff_error_is_base_side_only?("bryzek/a (previous): x\n  bryzek/b (previous): y")
  end

  # A size limit says nothing about the contents, so the narrow payload answers exactly
  # as it did before importers were sent. This is also what lets the two halves of
  # ISS-799 deploy in either order: the diffs route is capped at 1MB until platform's
  # RequestBodyLimits entry ships, and 60 importers do not fit in it.
  def test_a_payload_too_large_for_the_route_falls_back_instead_of_failing
    assert_equal "the request is larger than the server's limit for this route",
      diff_context_fallback_reason("POST /apibuilder/diffs: HTTP 413\nRequest Entity Too Large")
    assert_nil diff_context_fallback_reason("POST /apibuilder/diffs: HTTP 500\nboom")
    assert_nil diff_context_fallback_reason("POST /apibuilder/diffs: Validation errors:\n  bryzek/x (original): nope")
  end

  # A client that fails the first request and succeeds on every one after it, recording
  # each form: the fallback is about which payloads go out, in which order.
  class RecordingClient
    attr_reader :forms

    def initialize(error)
      @error = error
      @forms = []
    end

    def request(_method, _path, form)
      @forms << form
      raise @error if @forms.size == 1
      :ok
    end
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
