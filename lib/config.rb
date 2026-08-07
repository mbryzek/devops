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
    # app name — a release script only knows the directory it runs in, and a deployable
    # can be rebranded ahead of its repo. Falls back to a by-name load so an
    # unconfigured directory still errors the old way.
    def Config.load_by_dir(dir_name)
        Config.all.find { |a| a.repo_name == dir_name } || Config.load(dir_name)
    end

    # The canonical checkout's generated config, used only as a fallback (see
    # Config.resolve_dist_dir). ~/code/devops is the checkout `dev agent tick`
    # runs out of and fast-forwards, and the one an interactive session works in,
    # so on any box that has one its dist/ is current.
    CANONICAL_DIST_DIR = File.expand_path("~/code/devops/dist").freeze

    # dist/ as this checkout owns it. Resolved from __dir__, so it is the devops
    # root of whichever checkout is running — never a sibling-directory guess.
    def Config.local_dist_dir
        File.expand_path(File.join(__dir__, "../dist"))
    end

    def Config.dist_dir
        local = Config.local_dist_dir
        dir = Config.resolve_dist_dir(local, CANONICAL_DIST_DIR)
        Config.announce_dist_fallback(dir) if dir != local
        dir
    end

    # Where app config is read from, given this checkout's dist/ and the canonical
    # one.
    #
    # dist/ is gitignored generated output, rebuilt by generate-json.rb from the
    # pkl sources in the git-crypt'd env repo. A devops clone in an agent
    # workspace has neither: it cannot unlock env (agent/instructions.md §3), so
    # generate-json.rb prints "No ../env/apps checkout - leaving dist/ as is" and
    # every bin/ script that reads app config dies on its first lookup — which is
    # to say `bin/dev`, `bin/claude-db`, `bin/db-image` and `bin/api` could not be
    # RUN from the workspace that a change to them has to be developed in
    # (ISS-546). Falling back to the canonical checkout's copy leaks nothing: this
    # is hostnames, ports and usernames, no credentials — and it is already on the
    # box, generated, a directory away.
    #
    # Read-through, deliberately, rather than seeding a copy into the clone:
    # nothing writes to dist_dir, so there is no second writer racing
    # generate-json.rb's atomic writes and no snapshot that can go stale
    # independently of the checkout it was taken from.
    #
    # Local ALWAYS wins when it has configs. A deploy box ships a prebuilt dist/
    # inside the artifact and has no env checkout either; it must never be
    # silently served some developer checkout's copy, and returning `local` when
    # neither is populated keeps the "file not found" error naming the path the
    # caller expected.
    def Config.resolve_dist_dir(local, canonical)
        return local if Config.configured_dist?(local)
        return canonical if canonical != local && Config.configured_dist?(canonical)
        local
    end

    # A directory counts only if it actually holds app configs — an empty or
    # half-created dist/ must fall back rather than win by existing.
    def Config.configured_dist?(dir)
        !dir.to_s.empty? && !Dir.glob(File.join(dir, "*.config.json")).empty?
    end

    # Say so, once per process. Silence would be worse than the original error:
    # a "File '/Users/.../code/devops/dist/foo.config.json' not found" raised from
    # a workspace clone is baffling until you know config is being read from
    # somewhere other than the checkout you are editing.
    #
    # stderr, for the reason Util.run gives: stdout is a data channel here
    # (bin/app-env emits shell the caller evals, bin/db emits a URL).
    def Config.announce_dist_fallback(dir)
        return if @announced_dist_fallback
        @announced_dist_fallback = true
        msg = "==> app config from #{dir} (this checkout has no dist/ and no ../env/apps to rebuild it)"
        Util.quiet? ? Util.log(msg) : $stderr.puts(msg)
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
