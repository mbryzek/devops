require 'set'
require 'api_config'

module Codegen
  # Derives the codegen-sync view of a repo's .api/config.pkl — every apibuilder
  # app it references — by wrapping the existing top-level ApiConfig parser
  # (which handles the real `pkl eval -f json` shape: org-keyed blocks,
  # generators as {key => target}, applications as {key => file_path}, plus
  # spec_glob and group).
  #
  # It deliberately does NOT classify generators as client vs server. A repo's
  # role (a backend that owns spec files vs a frontend that only regenerates a
  # client) is decided by its STACK in Codegen::Graph. That keeps the whole
  # feature independent of generator-key names — whose source of truth lives in
  # platform's GeneratorsService — so a new/renamed generator can never silently
  # break classification (the failure mode that hid the `elm` vs `elm_v2` bug).
  class ApiConfig
    attr_reader :app_names

    def initialize(app_names:)
      @app_names = app_names
    end

    def self.load(repo_dir)
      path = File.join(repo_dir, ".api", "config.pkl")
      # base_dir must be the cloned repo, not Dir.pwd: `dev codegen sync` runs
      # from wherever it was invoked, so a spec_glob (e.g. the dao group's
      # "dao/spec/*.json") would otherwise resolve against the wrong tree.
      root = ::ApiConfig.new(path, base_dir: repo_dir)

      # A repo with nested codegen roots consumes those apps too — hackathon's
      # playwright/ root is the only reader of playwright-vote. Missing them
      # would leave the dependency graph blind to a real consumer.
      nested = root.nested_configs.filter_map do |rel|
        dir = File.expand_path(rel, repo_dir)
        nested_path = File.join(dir, ".api", "config.pkl")
        ::ApiConfig.new(nested_path, base_dir: dir) if File.exist?(nested_path)
      end

      from_blocks(([root] + nested).flat_map(&:blocks))
    end

    def self.from_blocks(blocks)
      names = Set.new
      blocks.each { |block| names.merge(block.applications.map(&:key)) }
      new(app_names: names)
    end
  end
end
