require 'set'
require 'open3'
require 'json'

module Codegen
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
      stdout, status = Open3.capture2("pkl", "eval", "-f", "json", path)
      raise "pkl eval failed for #{path}" unless status.success?
      parse(JSON.parse(stdout))
    end

    def self.parse(data)
      produced = Set.new
      consumed = Set.new
      dirs = Set.new
      Array(data["applications"]).each do |group|
        gens = Array(group["generators"])
        dirs.merge(gens.map { |g| g["target"] }.compact)
        names = Array(group["names"])
        client = !gens.empty? && gens.all? { |g| CLIENT_KEYS.include?(g["key"]) }
        (client ? consumed : produced).merge(names)
      end
      new(produced_names: produced, consumed_names: consumed, target_dirs: dirs.to_a)
    end
  end
end
