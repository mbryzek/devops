require 'set'
require 'api_config'

module Codegen
  # Derives the codegen-sync view of a repo's .api/config.pkl — which apibuilder
  # apps it produces vs consumes, and every generator output dir — by wrapping
  # the existing top-level ApiConfig parser (which already handles the real
  # `pkl eval -f json` shape: org-keyed blocks, generators as {key => target},
  # applications as {key => file_path}, plus spec_glob and group).
  class ApiConfig
    CLIENT_KEYS = %w[typescript elm].freeze

    attr_reader :produced_names, :consumed_names, :target_dirs

    def initialize(produced_names:, consumed_names:, target_dirs:)
      @produced_names = produced_names
      @consumed_names = consumed_names
      @target_dirs = target_dirs
    end

    def self.load(repo_dir)
      path = File.join(repo_dir, ".api", "config.pkl")
      from_blocks(::ApiConfig.new(path).blocks)
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
