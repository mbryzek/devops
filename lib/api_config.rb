require 'json'
require 'open3'
require 'pathname'

class ApiConfig

  Generator = Struct.new(:key, :target, :attributes, keyword_init: true)
  Application = Struct.new(:key, :file_path, keyword_init: true)
  Block = Struct.new(:org, :group, :generators, :attributes, :applications, keyword_init: true)

  # Reserved top-level output key holding `nestedConfigs`; every other top-level
  # key is an org. Must match `nestedConfigsKey` in devops/api/ApiConfig.pkl.
  NESTED_CONFIGS_KEY = "$nested_configs".freeze

  attr_reader :blocks

  # Directories (relative to this config's repo root) that hold their own
  # `.api/config.pkl` and belong to the same `api` run. Empty for the vast
  # majority of repos, which have exactly one config.
  attr_reader :nested_configs

  # base_dir is the directory that spec_glob patterns resolve against. It
  # defaults to Dir.pwd so callers running from a repo root (the `api` command)
  # are unaffected. Callers that parse a config for a repo other than the
  # current working directory (e.g. `dev codegen sync`, which parses cloned
  # repos from an unrelated cwd) MUST pass the repo dir explicitly — otherwise a
  # spec_glob like "dao/spec/*.json" resolves against the wrong tree. Passing it
  # (rather than Dir.chdir) keeps parsing thread-safe for parallel callers.
  def initialize(path = nil, base_dir: nil)
    path ||= File.join(Dir.pwd, ".api", "config.pkl")
    @base_dir = base_dir || Dir.pwd
    if !File.exist?(path)
      Util.exit_with_error("No .api/config.pkl found at #{path}")
    end
    data = load_data(path)
    @nested_configs = Array(data[NESTED_CONFIGS_KEY])
    @blocks = parse(data)
  end

  # Returns all unique org names
  def orgs
    @blocks.map(&:org).uniq
  end

  # Returns all blocks for a given org
  def blocks_for_org(org)
    @blocks.select { |b| b.org == org }
  end

  # Finds the target directory for a given application_key and generator_key.
  #
  # If the app is explicitly listed in any block, only that block's generators
  # are considered — returning nil if the requested generator isn't configured
  # there avoids masking misconfiguration.
  #
  # If the app isn't listed in any block, falls back to the first block that
  # uses the matching generator key. This handles transitively-imported specs
  # the server auto-includes in codegen responses (the user didn't list them
  # but their files still need a target dir). Picking the first matching block
  # is fine because configs almost always use one target per generator.
  def find_target(application_key, generator_key)
    app_listed = false
    @blocks.each do |block|
      if block.applications.any? { |a| a.key == application_key }
        app_listed = true
        if gen = block.generators.find { |g| g.key == generator_key }
          return gen.target
        end
      end
    end
    return nil if app_listed
    @blocks.each do |block|
      if gen = block.generators.find { |g| g.key == generator_key }
        return gen.target
      end
    end
    nil
  end

  private

  def load_data(path)
    json = evaluate_pkl(path)
    begin
      JSON.parse(json) || {}
    rescue JSON::ParserError => e
      Util.exit_with_error("pkl produced non-JSON output for #{path}: #{e.message}")
    end
  end

  def parse(data)
    blocks = []

    data.reject { |key, _| key == NESTED_CONFIGS_KEY }.each do |org, block_list|
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
    base = Pathname.new(@base_dir)
    files = Dir.glob(File.join(@base_dir, glob)).sort
    if files.empty?
      Util.exit_with_error("spec_glob '#{glob}' matched no files (relative to #{@base_dir})")
    end
    files.map do |path|
      key = File.basename(path, ".json")
      # Keep file_path relative to base_dir so values are identical to the
      # historical cwd-relative behavior when base_dir == the repo root.
      file_path = Pathname.new(path).relative_path_from(base).to_s
      Application.new(key: key, file_path: file_path)
    end
  end

  def parse_applications(applications_hash)
    applications_hash.map do |key, file_path|
      file_path = file_path || "spec/#{key}.json"
      Application.new(key: key, file_path: file_path)
    end
  end

end
