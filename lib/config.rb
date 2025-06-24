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
        dir = File.dirname(__FILE__)
        gen_json = File.join(dir, "../generate-json.rb -q")
        if File.exist?(gen_json)
            # Won't exist if deploying
            Util.run(gen_json)
        end
        path = File.join(dir, "../dist/#{app}.config.json")
        if !File.exist?(path)
            Util.exit_with_error("File '#{path}' not found")
        end
        json = JSON.parse(IO.read(path))
        App.new(json['app'])
    end

    def Config.load_scala_env(app, env)
        config = Config.load(app)
        scala_config = config.scala    
        if scala_config.nil?
            Util.exit_with_error("App #{app} does not have a scala config")
        end
        scala_config.send(env)
    end
end
