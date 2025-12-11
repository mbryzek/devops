#!/usr/bin/env ruby

# Finds all pkl files and evaluates them to json, storing
# the result in the dist directory

load File.join(File.dirname(__FILE__), 'lib/common.rb')

args = Args.parse(ARGV)

args.info ""

if !File.directory?("dist")
    Util.run("mkdir dist")
end

cmd = "pkl eval %s --format json > dist/%s.%s.json"

# Generate nodes.pkl (global node pool)
nodes_pkl = "../env/nodes.pkl"
if File.exist?(nodes_pkl)
    Util.run("pkl eval #{nodes_pkl} --format json > dist/nodes.config.json", :quiet => args.quiet)
end

# Generate app configs
`find ../env/apps -type f -name "*.pkl"`.strip.split("\n").each do |file|
    parts = file.split("/").drop(3)
    if parts.length > 2
        raise "Script needs to be modified to handle nested directories. parts: #{parts.inspect}"
    end
    app = parts[0]
    name = parts[1].gsub(/\.pkl$/, "")
    Util.run(cmd % [file, app, name], :quiet => args.quiet)
end

args.info ""
args.info "Done"
args.info ""
