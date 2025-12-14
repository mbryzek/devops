# Shared application configuration for K8s scripts
class AppConfig
  # App-specific configuration
  APPS = {
    'platform' => { artifact: 'api', port: 9300 },
    'acumen' => { artifact: 'api', port: 9200 }
  }.freeze

  # Source directory by convention: ~/code/<app_name>
  def self.source_dir(app_name)
    File.expand_path("~/code/#{app_name}")
  end

  # SBT artifact/subproject name
  def self.artifact(app_name)
    APPS.dig(app_name, :artifact) || app_name
  end

  # Application port
  def self.port(app_name)
    APPS.dig(app_name, :port) || 9000
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
