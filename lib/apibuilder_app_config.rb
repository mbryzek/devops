require 'yaml'

class ApibuilderAppConfig

  Generator = Struct.new(:key, :target, :attributes, keyword_init: true)
  AppEntry = Struct.new(:org, :app, :version, :generators, keyword_init: true)

  attr_reader :entries

  def initialize(path = nil)
    path ||= File.join(`pwd`.strip, ".apibuilder", "config")
    if !File.exist?(path)
      Util.exit_with_error("No .apibuilder/config found at #{path}")
    end
    @entries = parse(path)
  end

  def find_by_app(app_name)
    @entries.select { |e| e.app == app_name }
  end

  private

  def parse(path)
    yaml = begin
             YAML.safe_load(IO.read(path), permitted_classes: [Symbol])
           rescue Psych::SyntaxError => e
             Util.exit_with_error("Invalid YAML in #{path}: #{e.message}")
           end
    entries = []

    (yaml["code"] || {}).each do |org, apps|
      (apps || {}).each do |app, config|
        version = config["version"] || "latest"
        generators = parse_generators(config["generators"] || {})
        entries << AppEntry.new(
          org: org,
          app: app,
          version: version,
          generators: generators,
        )
      end
    end

    entries
  end

  def parse_generators(generators)
    case generators
    when Hash
      # Simple format: { "generator_key" => "target_dir" }
      generators.map do |key, target|
        Generator.new(key: key, target: target, attributes: {})
      end
    when Array
      # List format with optional attributes
      generators.map do |entry|
        key = entry["generator"] or Util.exit_with_error("Generator entry missing 'generator' key: #{entry.inspect}")
        target = entry["target"] or Util.exit_with_error("Generator entry missing 'target' key: #{entry.inspect}")
        attrs = (entry["attributes"] || {}).transform_values { |v| v.is_a?(String) ? v : JSON.generate(v) }
        Generator.new(
          key: key,
          target: target,
          attributes: attrs,
        )
      end
    else
      []
    end
  end

end
