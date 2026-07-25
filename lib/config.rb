require 'json'

module Config
    def Config.env_from_args(args)
        args = Args.parse(ARGV, ["app"])
        Config.load(args.app).send(args.env)
    end

    def Config.from_args(args)
        args = Args.parse(ARGV, ["app"])
        Config.load(args.app)
    end

    def Config.load(app)
        Config.regenerate
        path = File.join(Config.dist_dir, "#{app}.config.json")
        if !File.exist?(path)
            Util.exit_with_error("File '#{path}' not found")
        end
        json = JSON.parse(IO.read(path))
        App.new(json['app'])
    end

    # Every configured app.
    def Config.all
        Config.regenerate
        Dir.glob(File.join(Config.dist_dir, "*.config.json")).sort.map { |p|
            App.new(JSON.parse(IO.read(p))['app'])
        }
    end

    # The app checked out at ~/code/<dir_name>. Resolves by GitHub repo rather than by
    # app name — a release script only knows the directory it runs in, and a deployable
    # can be rebranded ahead of its repo. Falls back to a by-name load so an
    # unconfigured directory still errors the old way.
    def Config.load_by_dir(dir_name)
        Config.all.find { |a| a.repo_name == dir_name } || Config.load(dir_name)
    end

    def Config.dist_dir
        File.join(File.dirname(__FILE__), "../dist")
    end

    # Rebuild dist/ from the env repo's pkl sources, at most once per process. The
    # script is absent when deploying (dist/ ships prebuilt), in which case dist/ is
    # whatever was shipped.
    def Config.regenerate
        return if @regenerated
        @regenerated = true
        gen_json = File.join(File.dirname(__FILE__), "../generate-json.rb")
        Util.run("#{gen_json} -q") if File.exist?(gen_json)
    end

    def Config.load_database(app, env)
        config = Config.load(app)
        scala_config = config.scala
        if scala_config.nil?
            Util.exit_with_error("App #{app} does not have a scala config with database info")
        end
        scala_config.send(env).database
    end
end
