class ReleaseHelper

  attr_reader :config, :release_dir, :pwd, :app_config, :app

  def initialize(app_type)
    @log_file = "/tmp/devops.release.log"
    if File.exist?(@log_file)
      File.delete(@log_file)
    end

    @pwd = `pwd`.strip
    # The checkout directory names the repo, which is not always the app name (a
    # deployable can be rebranded ahead of its repo). Resolve the config by repo, then
    # use its canonical app name for everything downstream (release dir, Cloudflare
    # project, tags).
    @config = Config.load_by_dir(@pwd.split("/").last)
    @app = @config.name
    if app_type == "sveltekit"
      @release_dir = nil
    else
      @release_dir = File.join("../", @app + "-release")
      if !Dir.exist?(@release_dir)
        Util.exit_with_error("Release directory #{@release_dir} does not exist")
      end
    end
    @app_config = @config.send(app_type.to_sym)
    if @app_config.nil?
      Util.exit_with_error("No #{app_type} config found for app '#{@app}'")
    end

  end

  # Both runners hand off to Util.run in quiet mode. Quiet mode makes this
  # process's stdout a stage stream — Util.step's "label... done (12s)" lines,
  # which `dev deploy` parses to drive its live phase display — so a command
  # that streams its own output onto it is at best noise in the log and at
  # worst mistaken for a stage event. Util.run appends everything to the
  # release log instead, and on failure prints its tail plus the log path.
  def run(cmd)
    return Util.run(cmd) if Util.quiet?

    File.open(@log_file, "a") { |o| o << "\n#{cmd}" }
    Util.run(cmd + ">> #{@log_file}")
    puts ""
  end

  # run_system differs from run only in that it keeps the command's output on
  # the terminal (npm/wrangler narrate themselves). Quiet mode is exactly the
  # case where we do not want that, so the distinction disappears there.
  #
  # Quiet mode also closes stdin. These commands are non-interactive by
  # construction — a build, or a wrangler deploy that names its project
  # precisely so it cannot prompt — but "by construction" is not "enforced", and
  # with stdout redirected to the log a tool that decided to ask something
  # (wrangler's first-run telemetry question, a Pages project it cannot resolve)
  # would block forever on a prompt nobody could see. `dev deploy` already runs
  # every release with a closed stdin; this gives a by-hand release the same
  # fast, logged failure instead of an invisible hang.
  def run_system(cmd)
    return Util.run("#{cmd} < /dev/null") if Util.quiet?

    puts cmd
    if !system(cmd)
      puts ""
      puts "ERROR: Command #{cmd} exited with non zero status"
      puts ""
      exit(1)
    end
  end

  def write_to_file(path, contents)
    File.open(path, "w") { |out| out << contents }
  end

  def maybe_tag_and_push(tag)
    if have_changes?
      run "git commit -a -m 'Release version #{tag}'"
      run "git push"
      Util.detail("")
      Util.detail("#{@app} Application Deployed")
    else
      Util.detail("")
      Util.detail("No changes to deploy")
    end
  end

  private
  def have_changes?
    diff = `git status --porcelain`.strip
    # Filter out untracked files (lines starting with ??)
    tracked_changes = diff.lines.reject { |line| line.start_with?('??') }.join
    !tracked_changes.strip.empty?
  end
end
