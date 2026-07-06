require 'set'
require 'api_config'

module Codegen
  # Derives the codegen-sync view of a repo's .api/config.pkl — which apibuilder
  # apps it produces vs consumes, and every generator output dir — by wrapping
  # the existing top-level ApiConfig parser (which already handles the real
  # `pkl eval -f json` shape: org-keyed blocks, generators as {key => target},
  # applications as {key => file_path}, plus spec_glob and group).
  class ApiConfig
    # apibuilder client-codegen generator keys — a block that ONLY emits these
    # means this repo consumes those apps rather than owning them. Must list
    # every client generator in use across the fleet: `typescript` (svelte/TS
    # frontends) and `elm_v2` (Elm frontends — note the `_v2`, NOT bare `elm`).
    # Miss one and that frontend is misclassified as a producer, losing its
    # dependency edges to the backend (breaks `--app <backend>` + failure gating).
    CLIENT_KEYS = %w[typescript elm_v2].freeze

    attr_reader :produced_names, :consumed_names, :target_dirs

    def initialize(produced_names:, consumed_names:, target_dirs:)
      @produced_names = produced_names
      @consumed_names = consumed_names
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
      produced = Set.new
      consumed = Set.new
      dirs = Set.new
      blocks.each do |block|
        gens = block.generators
        dirs.merge(gens.map(&:target).compact)
        names = block.applications.map(&:key)
        client = !gens.empty? && gens.all? { |g| CLIENT_KEYS.include?(g.key) }
        (client ? consumed : produced).merge(names)
      end
      new(produced_names: produced, consumed_names: consumed, target_dirs: dirs.to_a)
    end
  end
end
