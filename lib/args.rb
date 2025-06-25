require 'optparse'

class Args
    attr_reader :env, :app, :file, :node, :format, :quiet, :tag, :dir, :profile, :path, :no_download
    def initialize(args)
        @quiet = !args[:quiet].to_s.empty?
        @env = args[:env]
        @app = args[:app]
        @file = args[:file]
        @node = args[:node]
        @format = args[:format]
        @tag = args[:tag]
        @dir = args[:dir]
        @profile = args[:profile]
        @path = args[:path]
        @no_download = args[:no_download] ? true : false
    end

    def info(msg)
        if !quiet?
            puts msg
        end
    end

    def quiet?
        @quiet
    end

    def Args.parse(args, required = [], options = {})
        all = Args.do_parse(args, options)
        missing = required.filter { |name| !all.include?(name.to_sym) }

        if missing.include?("app")
            if a = default_app
                all[:app] = a
                missing.delete("app")
            end
        end

        if !missing.empty?
            Util.exit_with_error("Missing required argument(s): #{missing.join(", ")}" + Args.example_args(missing))
        end
        Args.validate_args(all)
        Args.new(all)
    end

    def Args.validate_args(all)
        errors = []
        valid = Args.valid_args
        all.each do |arg, value|
            values = valid[arg.to_s]
            # Note values will be empty when this script is run on the servers as
            # we do not copy the apps directory to the servers
            if values && !values.empty?
                all = value.respond_to?(:each) ? value : [value]
                all.select { |v| !values.include?(v) }.each do |v|
                    errors << "  - #{arg} #{v}: Must be one of #{values.join(", ")}"
                end
            end
        end
        if !errors.empty?
            Util.exit_with_error("Invalid arguments:\n" + errors.join("\n"))
        end
    end

    def Args.list_apps
        valid_apps = []
        dir = Util.cleanpath(File.join(File.dirname(__FILE__), "../../env/apps"))
        Dir.glob("#{dir}/*").each do |path|
            if File.directory?(path)
                valid_apps << File.basename(path)
            end
        end
        valid_apps.sort
    end

    def Args.default_app
        wd = `pwd`.strip.split("/").last
        # Support directories like 'acumen-postgresql' and 'acumen-postgresql-15.1.0'
        dir = wd.sub(/\-\d+\.\d+\.\d+$/, "").sub(/\-postgresql$/, "")
        valid_apps = Args.list_apps
        valid_apps.include?(dir) ? dir : nil
    end

    class ArgumentValue
 
        def initialize(options)
            @options = options.map { |k, v| [k.to_sym, v] }.to_h
            @found = {}
        end

        def add(n, v)
            s = n.to_sym
            if opt = @options[s]
                case opt
                when "list"
                    @found[s] = (@found[s] || []) + [v]
                else
                    Util.exit_with_error("Invalid option #{@options[s]} for argument #{n}")
                end
            else
                if @found.has_key?(s)
                    Util.exit_with_error("Duplicate argument #{n}")
                end
                @found[s] = v
            end
        end

        def args_with_defaults
            all = @found.dup
            all[:env] ||= "production"
            all
        end
    end

    def Args.do_parse(incoming, options)
        av = ArgumentValue.new(options)
        args = incoming.dup

        opt_parser = OptionParser.new do |opts|
            opts.banner = "Usage:"

            opts.on("--env ENVIRONMENT", "Specify the environment") do |env|
                av.add("env", env)
            end

            opts.on("--app NAME", "Specify the application name") do |app|
                av.add("app", app)
            end

            opts.on("--dir DIR", "Specify the directory") do |dir|
                av.add("dir", dir)
            end

            opts.on("--profile PROFILE", "Specify the API Builder profile") do |profile|
                av.add("profile", profile)
            end

            opts.on("--path PATH", "Specify the file path") do |path|
                av.add("path", path)
            end

            opts.on("--file FILENAME", "Specify the file name") do |file|
                av.add("file", file)
            end

            opts.on("--node URI", "Specify the node URI") do |uri|
                av.add("node", uri)
            end

            opts.on("--format FORMAT", "Specify format") do |format|
                av.add("format", format)
            end

            opts.on("--tag TAG", "Specify tag") do |tag|
                av.add("tag", tag)
            end

            opts.on("--quiet", "If specified, indicate quiet mode") do
                av.add("quiet", true)
            end

            opts.on("--no-download", "If specified, do not download files") do
                av.add("no_download", true)
            end

            opts.on("-h", "--help", "Prints this help") do
                puts opts
                exit
            end
        end

        opt_parser.parse!(args)
        av.args_with_defaults
    end

    def Args.valid_args
        {
            "format" => ['json', 'sh', 'run'],
            "env" => ['production', 'development']
        }
    end

    def Args.example_args(missing)
        valid = Args.valid_args
        text = []
        missing.each do |arg|
            values = valid[arg]
            if values && !values.empty?
                text << "  - #{arg}: one of #{valid[arg].join(", ")}"
            end
        end
        if text.empty?
            ""
        else
            "\n\n" + text.join("\n")
        end
    end
end
