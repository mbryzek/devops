class ReleaseHelper
  attr_reader :config, :release_dir
  def initialize(app_type)
    @log_file = "/tmp/devops.release.log"
    if File.exist?(@log_file)
      File.delete(@log_file)
    end

    @pwd = `pwd`.strip
    @app = pwd.strip.split("/").last
    @release_dir = File.join("../", @app + "-release")
    if !Dir.exist?(@release_dir)
      Util.exit_with_error("Release directory #{@release_dir} does not exist")
    end
    @config = Config.load(app)
    t = helper.config.send(app_type.to_sym)
    if t.nil?
      Util.exit_with_error("No #{app_type} config found for app '#{@app}'")
    end

  end

  def run(cmd)
    File.open(@log_file, "a") { |o| o << "\n#{cmd}" }
    Util.run(cmd + ">> #{@log_file}")
    puts ""
  end

  def write_to_file(path, contents)
    File.open(path, "w") { |out| out << contents }
  end

  def maybe_tag_and_push(tag)
    if have_changes?
      run "git commit -a -m 'Release version #{tag}'"
      run "git push"
      puts ""
      puts "#{@app} Application Deployed"
    else
      puts ""
      puts "No changes to deploy"
    end
  end

  private
  def have_changes?
    diff = `git status --porcelain`.strip
    !diff.empty?
  end
end
