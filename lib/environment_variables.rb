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

    # True when the app has env files for this environment (load exits when
    # they are missing — callers that want to skip instead probe here first).
    def EnvironmentVariables.configured?(app_name, environment)
        [environment, 'common'].all? { |f|
            File.exist?(File.join(DIR, "../../env/apps/#{app_name}/env/#{f}.env"))
        }
    end

    # Password for the app's database, parsed from CONF_DB_PROD_URL (format:
    # ...?user=x&password=y&...). nil when the app has no CONF_DB_PROD_URL;
    # exits when the URL exists but carries no password (malformed).
    def EnvironmentVariables.db_password(app_name, environment)
        db_url = EnvironmentVariables.load(app_name, environment)['CONF_DB_PROD_URL']
        return nil if db_url.nil?
        if i = db_url.index("?")
            db_url[(i + 1)..].split("&").each do |p|
                k, v = p.split("=", 2)
                return v if k == "password"
            end
        end
        Util.exit_with_error("Could not extract password from CONF_DB_PROD_URL for #{app_name}")
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
        env_path = File.join(DIR, "../../env/apps/#{app_name}/env/#{filename}.env")
        if !File.exist?(env_path)
            Util.exit_with_error("Environment file '#{env_path}' not found.")
        end

        # Check if file is encrypted (git-crypt locked files start with GITCRYPT header)
        header = File.binread(env_path, 10)
        if header&.start_with?("\x00GITCRYPT")
            env_dir = File.join(DIR, "../../env")
            STDERR.puts "Environment file is encrypted. Running git-crypt unlock..."
            Util.run("cd #{env_dir} && git-crypt unlock", :quiet => true)
        end

        data = {}
        File.readlines(env_path).each do |l|
            key, value = l.strip.split("=", 2)
            next if key.to_s.strip.empty?
            data[key] = value
        end
        data
    end
end
