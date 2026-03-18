require 'yaml'

class ApiConfig

  Generator = Struct.new(:key, :target, :attributes, keyword_init: true)
  Application = Struct.new(:key, :file_path, keyword_init: true)
  Block = Struct.new(:org, :generators, :attributes, :applications, keyword_init: true)

  attr_reader :blocks

  def initialize(path = nil)
    path ||= File.join(`pwd`.strip, ".api", "config")
    if !File.exist?(path)
      Util.exit_with_error("No .api/config found at #{path}")
    end
    @blocks = parse(path)
  end

  # Returns all unique org names
  def orgs
    @blocks.map(&:org).uniq
  end

  # Returns all blocks for a given org
  def blocks_for_org(org)
    @blocks.select { |b| b.org == org }
  end

  # Finds the target directory for a given application_key and generator_key
  def find_target(application_key, generator_key)
    @blocks.each do |block|
      if block.applications.any? { |a| a.key == application_key }
        if gen = block.generators.find { |g| g.key == generator_key }
          return gen.target
        end
      end
    end
    nil
  end

  private

  def parse(path)
    yaml = begin
             YAML.safe_load(IO.read(path), permitted_classes: [Symbol])
           rescue Psych::SyntaxError => e
             Util.exit_with_error("Invalid YAML in #{path}: #{e.message}")
           end

    blocks = []

    (yaml || {}).each do |org, block_list|
      (block_list || []).each do |block_data|
        generators = parse_generators(block_data["generators"] || {})
        attributes = block_data["attributes"] || {}
        applications = parse_applications(block_data["applications"] || {})
        blocks << Block.new(
          org: org,
          generators: generators,
          attributes: attributes,
          applications: applications,
        )
      end
    end

    blocks
  end

  def parse_generators(generators_hash)
    generators_hash.map do |key, target|
      Generator.new(key: key, target: target, attributes: {})
    end
  end

  def parse_applications(applications_hash)
    applications_hash.map do |key, file_path|
      file_path = file_path || "spec/#{key}.json"
      Application.new(key: key, file_path: file_path)
    end
  end

end
