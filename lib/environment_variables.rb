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
        when "run"
        then run_sh(all)
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
    def run_sh(all)
      env = format_for_sh(all)
      <<-EOF
#!/bin/sh

#{env} sbt -no-share
EOF
    end

    def EnvironmentVariables.from_file(app_name, filename)
        path = File.join(DIR, "../apps/#{app_name}/env/#{filename}.env")
        if !File.exist?(path)
            Util.exit_with_error("Environment file '#{path}' not found")
        end
        data = {}
        IO.readlines(path).each do |l|
            key, value = l.strip.split("=", 2)
            next if key.to_s.strip.empty?
            data[key] = value
        end
        data
    end
end
