require 'json'

module Config
    # Passed by a script that spawns other devops scripts to say "dist/ is already
    # current". Accepted by every script that parses args through Args, and by `dev`.
    SKIP_REGENERATE_FLAG = "--skip-generate-json".freeze

    # Treat dist/ as already rebuilt for the rest of this process. The memo in
    # Config.regenerate is per-process, so without this every child of a release
    # re-runs the pkl eval the parent just ran and prints its own "==> generate-json"
    # line. Set by the arg parsers when SKIP_REGENERATE_FLAG is present.
    def Config.skip_regenerate!
        @regenerated = true
    end

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
    # app name: a deployable can be rebranded ahead of its repo (playbook-www lives in
    # mbryzek/clubaid-www), and a release script only knows the directory it runs in.
    # Falls back to a by-name load so an unconfigured directory still errors the old way.
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
