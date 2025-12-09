require 'json'

class EnvironmentVariables
    DIR = File.dirname(__FILE__)

    def initialize(vars)
        @vars = vars
    end

    def with_variable(name, value)
        all = @vars.dup
        all[name] = value
        EnvironmentVariables.new(all)
    end

    def [](name)
        @vars[name]
    end

    def EnvironmentVariables.load(app_name, environment)
        vars = {}
        [environment, 'common'].each do |filename|
            EnvironmentVariables.from_file(app_name, filename).each do |k,v|
                if vars[k.strip]
                    Util.exit_with_error("Duplicate env variable named #{k} in app #{app_name} and environment #{environment}")
                end
                vars[k] = v.strip
            end
        end
        EnvironmentVariables.new(vars)
    end

    def serialize(format, extra = {})
        all = @vars.dup.merge(extra)
        case format
        when "sh"
          then format_for_sh(all)
        when "env"
          then dotenv(all)
        when "json"
          then all.to_json
        else
          Util.exit_with_error("Unsupported format '#{format}'")
        end
    end

    private
    def format_for_sh(all)
      all.keys.sort.map { |k| "%s='%s'" % [k.strip, all[k].to_s.strip] }.join(" ")
    end

    def dotenv(all)
      all.keys.sort.map { |k| "export #{k.strip}=\"#{all[k].to_s.strip}\"" }.join("\n")
    end

    def EnvironmentVariables.from_file(app_name, filename)
        tpl_path = File.join(DIR, "../../env/apps/#{app_name}/env/#{filename}.env.tpl")
        if !File.exist?(tpl_path)
            Util.exit_with_error("Environment template file '#{tpl_path}' not found")
        end

        # Use 1Password CLI to inject secrets from the template
        output = `op inject -i "#{tpl_path}" 2>&1`
        if !$?.success?
            Util.exit_with_error("Failed to inject secrets from '#{tpl_path}': #{output}")
        end

        data = {}
        output.each_line do |l|
            key, value = l.strip.split("=", 2)
            next if key.to_s.strip.empty?
            data[key] = value
        end
        data
    end
end
