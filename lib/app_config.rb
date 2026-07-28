# Shared application configuration for K8s scripts
class AppConfig
  # App-specific configuration
  APPS = {
    'platform' => { artifact: 'api', port: 9300, run_script: 'api' },
    # Same codebase as platform, deployed to the playbook DO account.
    'playbook-api' => { artifact: 'api', port: 9300, run_script: 'api' },
    'acumen' => { artifact: 'api', port: 9200, run_script: 'acumen-acumen-api' }
  }.freeze

  # Source checkout: ~/code/<repo>. Resolved through the app's configured repo
  # rather than its name — a deployable (e.g. playbook-api) can be built from
  # another repo's checkout (platform).
  def self.source_dir(app_name)
    File.expand_path("~/code/#{Config.load(app_name).repo_name}")
  end

  # SBT artifact/subproject name
  def self.artifact(app_name)
    APPS.dig(app_name, :artifact) || app_name
  end

  # Application port
  def self.port(app_name)
    APPS.dig(app_name, :port) || 9000
  end

  # Run script name in sbt dist output
  def self.run_script(app_name)
    APPS.dig(app_name, :run_script) || app_name
  end

  # Fetch the latest tag for an app by running sem-info in its source directory
  def self.latest_tag(app_name)
    source = source_dir(app_name)
    unless File.directory?(source)
      Util.exit_with_error("Source directory not found: #{source}")
    end

    tag = Dir.chdir(source) do
      `sem-info tag latest 2>/dev/null`.strip
    end

    if tag.empty?
      Util.exit_with_error("No tags found for #{app_name}. Please create a tag first.")
    end

    tag
  end
end
