#!/usr/bin/env ruby

# Finds all k8s pkl files and evaluates them to YAML, storing
# the result in the dist/k8s directory
#
# Usage:
#   ./generate-k8s.rb --tag 1.0.0                  # Generate all manifests
#   ./generate-k8s.rb --tag 1.0.0 --app platform   # Generate for specific app

load File.join(File.dirname(__FILE__), 'lib/common.rb')

args = Args.parse(ARGV)

args.info ""

# Use absolute paths
SCRIPT_DIR = File.expand_path(File.dirname(__FILE__))
K8S_DIR = File.join(SCRIPT_DIR, "k8s")
DIST_DIR = File.join(SCRIPT_DIR, "dist/k8s")

if !File.directory?(DIST_DIR)
    FileUtils.mkdir_p(DIST_DIR)
end

# Tag is required
if args.tag.nil? || args.tag.empty?
    Util.exit_with_error("--tag is required")
end

# Build environment variables for pkl
env_vars = ["VERSION=#{args.tag}"]
env_vars << "K8S_NAMESPACE=#{args.namespace}" if args.namespace
env_prefix = env_vars.join(" ") + " "

# Find all app manifests
app_files = Dir.glob("#{K8S_DIR}/apps/*.pkl")

if args.app
    # Filter to specific app if specified
    app_files = app_files.select { |f| File.basename(f, ".pkl") == args.app }
    if app_files.empty?
        Util.exit_with_error("No pkl manifest found for app: #{args.app}")
    end
end

# Generate app manifests using the scala-play-app template
app_files.each do |file|
    app_name = File.basename(file, ".pkl")
    output_file = File.join(DIST_DIR, "#{app_name}.yaml")

    # Read app config to get port
    config_output = `cd #{K8S_DIR} && pkl eval -f json apps/#{app_name}.pkl 2>/dev/null`
    config = JSON.parse(config_output) rescue {}
    app_port = config["appPort"] || 9000

    # Build env vars for template
    app_env = "APP=#{app_name} PORT=#{app_port} #{env_prefix}"

    cmd = "cd #{K8S_DIR} && #{app_env}pkl eval templates/scala-play-app.pkl > #{output_file}"
    args.info "Generating #{output_file}"
    Util.run(cmd, :quiet => args.quiet)
end

args.info ""
args.info "Done - manifests in #{DIST_DIR}"
args.info ""
