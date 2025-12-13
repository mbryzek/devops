#!/usr/bin/env ruby

# Finds all k8s pkl files and evaluates them to YAML, storing
# the result in the dist/k8s directory
#
# Usage:
#   ./generate-k8s.rb                    # Generate all manifests
#   ./generate-k8s.rb --app platform     # Generate for specific app
#   ./generate-k8s.rb --version v1.0.0   # Generate with specific version

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

# Build environment variables for pkl
env_vars = []
env_vars << "VERSION=#{args.version}" if args.version
env_vars << "K8S_NAMESPACE=#{args.namespace}" if args.namespace
env_prefix = env_vars.empty? ? "" : env_vars.join(" ") + " "

# Find all app manifests
app_files = Dir.glob("#{K8S_DIR}/apps/*.pkl")

if args.app
    # Filter to specific app if specified
    app_files = app_files.select { |f| File.basename(f, ".pkl") == args.app }
    if app_files.empty?
        Util.exit_with_error("No pkl manifest found for app: #{args.app}")
    end
end

# Generate app manifests
app_files.each do |file|
    app_name = File.basename(file, ".pkl")
    output_file = File.join(DIST_DIR, "#{app_name}.yaml")

    cmd = "cd #{K8S_DIR} && #{env_prefix}pkl eval apps/#{app_name}.pkl > #{output_file}"
    args.info "Generating #{output_file}"
    Util.run(cmd, :quiet => args.quiet)
end

# Generate job manifests if app is specified and job-suffix provided
if args.app && args.job_suffix
    job_file = File.join(K8S_DIR, "jobs/db-migration.pkl")
    if File.exist?(job_file)
        output_file = File.join(DIST_DIR, "#{args.app}-migration.yaml")
        job_env = env_prefix + "APP=#{args.app} JOB_SUFFIX=#{args.job_suffix} "

        cmd = "cd #{K8S_DIR} && #{job_env}pkl eval jobs/db-migration.pkl > #{output_file}"
        args.info "Generating #{output_file}"
        Util.run(cmd, :quiet => args.quiet)
    end
end

args.info ""
args.info "Done - manifests in #{DIST_DIR}"
args.info ""
