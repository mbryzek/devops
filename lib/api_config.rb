require 'yaml'
require 'open3'

class ApiConfig

  Generator = Struct.new(:key, :target, :attributes, keyword_init: true)
  Application = Struct.new(:key, :file_path, keyword_init: true)
  Block = Struct.new(:org, :group, :generators, :attributes, :applications, keyword_init: true)

  SCHEMA_MODULE_PATH = File.expand_path("../core", __dir__)
  SCHEMA_FILE = File.join(SCHEMA_MODULE_PATH, "api_config.pkl")

  attr_reader :blocks

  # api_dir: path to the `.api` directory (defaults to `<cwd>/.api`).
  # If `<api_dir>/config.pkl` exists, it is used (evaluated via `pkl eval`).
  # Otherwise `<api_dir>/config` (legacy YAML) is used.
  def initialize(api_dir = nil)
    api_dir ||= File.join(Dir.pwd, ".api")
    pkl_path = File.join(api_dir, "config.pkl")
    yaml_path = File.join(api_dir, "config")

    source, source_label = if File.exist?(pkl_path)
                             [evaluate_pkl(pkl_path), pkl_path]
                           elsif File.exist?(yaml_path)
                             [IO.read(yaml_path), yaml_path]
                           else
                             Util.exit_with_error("No config.pkl or config found in #{api_dir}")
                           end

    @blocks = parse(source, source_label)
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

  def evaluate_pkl(pkl_path)
    Util.assert_installed("pkl", "https://github.com/apple/pkl")
    if !File.exist?(SCHEMA_FILE)
      Util.exit_with_error("PKL schema not found at #{SCHEMA_FILE}")
    end
    stdout, stderr, status = Open3.capture3(
      "pkl", "eval", "-f", "yaml",
      "--module-path", SCHEMA_MODULE_PATH,
      pkl_path
    )
    if !status.success?
      Util.exit_with_error("pkl eval failed for #{pkl_path}:\n#{stderr}")
    end
    stdout
  end

  def parse(source, source_label)
    yaml = begin
             YAML.safe_load(source, permitted_classes: [Symbol])
           rescue Psych::SyntaxError => e
             Util.exit_with_error("Invalid YAML in #{source_label}: #{e.message}")
           end

    blocks = []

    (yaml || {}).each do |org, block_list|
      (block_list || []).each do |block_data|
        generators = parse_generators(block_data["generators"] || {})
        attributes = block_data["attributes"] || {}
        group = block_data["group"]
        applications = if glob = block_data["spec_glob"]
                         parse_spec_glob(glob)
                       else
                         parse_applications(block_data["applications"] || [])
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

  def parse_generators(generators_hash)
    generators_hash.map do |key, target|
      Generator.new(key: key, target: target, attributes: {})
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

  # Accepts either:
  #   - Array of app keys: ["platform", "platform-cluster"]  (from PKL config)
  #   - Hash of {key => file_path_or_nil}:                   (from YAML config)
  def parse_applications(applications)
    entries = case applications
              when Array then applications.map { |k| [k, nil] }
              when Hash  then applications.to_a
              else
                Util.exit_with_error("Invalid 'applications' value: expected list or map, got #{applications.class}")
              end
    entries.map do |key, file_path|
      file_path = file_path || "spec/#{key}.json"
      Application.new(key: key, file_path: file_path)
    end
  end

end
