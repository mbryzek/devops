require 'json'

class EnvironmentVariables
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

    # The env file backing one (app, environment) pair. Every reader here goes
    # through this so the layout is stated once.
    def EnvironmentVariables.file_path(app_name, filename)
        EnvRepo.path("apps/#{app_name}/env/#{filename}.env")
    end

    # True when the app has env files for this environment (load exits when
    # they are missing — callers that want to skip instead probe here first).
    def EnvironmentVariables.configured?(app_name, environment)
        [environment, 'common'].all? { |f|
            File.exist?(EnvironmentVariables.file_path(app_name, f))
        }
    end

    # One variable, read WITHOUT the auto-unlock `load` performs.
    #
    # `load` is release tooling: it runs from a human's terminal, and unlocking
    # git-crypt on the way past is a convenience there. Asking it for a single
    # key would inherit that side effect, and a command whose job is "tell me
    # whether this secret is set" must not decrypt the secrets repo to answer.
    # Agent sessions are forbidden from unlocking it at all, so a locked file is
    # a reportable state rather than something to fix silently.
    #
    # Returns [:present, value], [:missing, nil], [:locked, nil] or
    # [:no_file, nil]. Same precedence as `load`: the environment file wins over
    # common.env.
    #
    # :no_file is separate from :missing on purpose. They call for opposite
    # responses — one is "add the variable", the other is "you are not looking at
    # the env repo at all" (EnvRepo resolves ../../env relative to the devops
    # checkout, so a devops clone inside a feature dir has no sibling env/).
    # Collapsing them reports a wrong diagnosis with total confidence.
    def EnvironmentVariables.lookup(app_name, environment, key)
        seen = false
        [environment, 'common'].each do |filename|
            path = EnvironmentVariables.file_path(app_name, filename)
            next unless File.exist?(path)
            seen = true
            return [:locked, nil] if EnvRepo.locked?(path)
            File.readlines(path).each do |line|
                k, v = line.strip.split("=", 2)
                next unless k.to_s.strip == key
                value = v.to_s.strip
                return [:present, value] unless value.empty?
            end
        end
        seen ? [:missing, nil] : [:no_file, nil]
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

    # Both serializations below are SHELL, and their whole contract is that the
    # caller evals them (`eval "$(bin/app-env --format sh)"`, and `dotenv` emits
    # `export`). The values are the git-crypt'd app secrets -- passwords, tokens,
    # connection strings -- so quoting them is not cosmetic.
    #
    # Single quotes with the standard '\'' break-out, rather than double quotes:
    # inside double quotes the shell still expands $VAR, `cmd` and \, so a
    # password containing a $ silently eval'd to the wrong value and one
    # containing a backtick ran a command. Inside single quotes nothing is
    # special except the single quote itself, which this closes, escapes and
    # reopens.
    # The block form of gsub is load-bearing: in a replacement STRING, `\'` is a
    # backreference meaning "everything after the match", so the obvious
    # `gsub("'", "'\\''")` silently produces garbage rather than an escape.
    def sh_quote(value)
      "'#{value.to_s.strip.gsub("'") { "'\\''" }}'"
    end

    def format_for_sh(all)
      all.keys.sort.map { |k| "#{k.strip}=#{sh_quote(all[k])}" }.join(" ")
    end

    def dotenv(all)
      all.keys.sort.map { |k| "export #{k.strip}=#{sh_quote(all[k])}" }.join("\n")
    end

    def EnvironmentVariables.from_file(app_name, filename)
        env_path = EnvironmentVariables.file_path(app_name, filename)
        if !File.exist?(env_path)
            Util.exit_with_error("Environment file '#{env_path}' not found.")
        end

        # Check if file is encrypted (git-crypt locked files start with GITCRYPT header)
        if EnvRepo.locked?(env_path)
            env_dir = EnvRepo.root
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
