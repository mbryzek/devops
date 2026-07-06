require 'set'
require 'api_config'

module Codegen
  # Derives the codegen-sync view of a repo's .api/config.pkl — every apibuilder
  # app it references and every generator output dir — by wrapping the existing
  # top-level ApiConfig parser (which handles the real `pkl eval -f json` shape:
  # org-keyed blocks, generators as {key => target}, applications as
  # {key => file_path}, plus spec_glob and group).
  #
  # It deliberately does NOT classify generators as client vs server. A repo's
  # role (a backend that uploads specs vs a frontend that only regenerates a
  # client) is decided by its STACK in Codegen::Graph. That keeps the whole
  # feature independent of generator-key names — whose source of truth lives in
  # platform's GeneratorsService — so a new/renamed generator can never silently
  # break classification (the failure mode that hid the `elm` vs `elm_v2` bug).
  class ApiConfig
    attr_reader :app_names, :target_dirs

    def initialize(app_names:, target_dirs:)
      @app_names = app_names
      @target_dirs = target_dirs
    end

    def self.load(repo_dir)
      path = File.join(repo_dir, ".api", "config.pkl")
      # base_dir must be the cloned repo, not Dir.pwd: `dev codegen sync` runs
      # from wherever it was invoked, so a spec_glob (e.g. the dao group's
      # "dao/spec/*.json") would otherwise resolve against the wrong tree.
      from_blocks(::ApiConfig.new(path, base_dir: repo_dir).blocks)
    end

    def self.from_blocks(blocks)
      names = Set.new
      dirs = Set.new
      blocks.each do |block|
        names.merge(block.applications.map(&:key))
        dirs.merge(block.generators.map(&:target).compact)
      end
      new(app_names: names, target_dirs: dirs.to_a)
    end
  end
end
