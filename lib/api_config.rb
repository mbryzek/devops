require 'json'
require 'open3'

class ApiConfig

  Generator = Struct.new(:key, :target, :attributes, keyword_init: true)
  Application = Struct.new(:key, :file_path, keyword_init: true)
  Block = Struct.new(:org, :group, :generators, :attributes, :applications, keyword_init: true)

  attr_reader :blocks

  def initialize(path = nil)
    path ||= File.join(Dir.pwd, ".api", "config.pkl")
    if !File.exist?(path)
      Util.exit_with_error("No .api/config.pkl found at #{path}")
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
    json = evaluate_pkl(path)
    data = begin
             JSON.parse(json)
           rescue JSON::ParserError => e
             Util.exit_with_error("pkl produced non-JSON output for #{path}: #{e.message}")
           end

    blocks = []

    (data || {}).each do |org, block_list|
      (block_list || []).each do |block_data|
        generators = parse_generators(block_data["generators"] || {})
        attributes = block_data["attributes"] || {}
        group = block_data["group"]
        applications = if glob = block_data["spec_glob"]
                         parse_spec_glob(glob)
                       else
                         parse_applications(block_data["applications"] || {})
                       end
        blocks << Block.new(
          org: org,
          group: group,
          generators: generators,
          attributes: attributes,
          applications: applications,
        )
      end
    end

    blocks
  end

  def evaluate_pkl(path)
    stdout, stderr, status = begin
                               Open3.capture3("pkl", "eval", "-f", "json", path)
                             rescue Errno::ENOENT
                               Util.exit_with_error("pkl executable not found on PATH. Install pkl (https://pkl-lang.org) to evaluate #{path}.")
                             end
    if !status.success?
      Util.exit_with_error("pkl eval failed for #{path}:\n#{stderr}")
    end
    stdout
  end

  def parse_generators(generators_hash)
    generators_hash.map do |key, value|
      if value.is_a?(Hash)
        Generator.new(key: key, target: value["target"], attributes: value["attributes"] || {})
      else
        Generator.new(key: key, target: value, attributes: {})
      end
    end
  end

  def parse_spec_glob(glob)
    files = Dir.glob(glob).sort
    if files.empty?
      Util.exit_with_error("spec_glob '#{glob}' matched no files")
    end
    files.map do |path|
      key = File.basename(path, ".json")
      Application.new(key: key, file_path: path)
    end
  end

  def parse_applications(applications_hash)
    applications_hash.map do |key, file_path|
      file_path = file_path || "spec/#{key}.json"
      Application.new(key: key, file_path: file_path)
    end
  end

end
