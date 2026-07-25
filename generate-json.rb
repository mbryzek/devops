#!/usr/bin/env ruby

# Finds all pkl files and evaluates them to json, storing
# the result in the dist directory

load File.join(File.dirname(__FILE__), 'lib/common.rb')

# Both the pkl sources (../env/apps) and the output (dist) are resolved relative to
# this script, not the caller's cwd — Config.regenerate calls it from whatever app
# checkout a release is running in.
Dir.chdir(File.dirname(__FILE__))

args = Args.parse(ARGV)

args.info ""

# No env checkout (a scratch clone, or a deploy box shipping a prebuilt dist): leave
# dist alone rather than emptying it.
if !File.directory?("../env/apps")
    args.info "No ../env/apps checkout - leaving dist/ as is"
    return
end

if !File.directory?("dist")
    Util.run("mkdir dist")
end

# Write through Util.write_atomically: `dev deploy` releases several apps in
# parallel and every devops script rebuilds dist/ on load, so a redirect straight
# into dist/ would let one generator truncate a file another process is reading.
cmd = "pkl eval %s --format json > %s"

`find ../env/apps -type f -name "*.pkl"`.strip.split("\n").each do |file|
    parts = file.split("/").drop(3)
    if parts.length > 2
        raise "Script needs to be modified to handle nested directories. parts: #{parts.inspect}"
    end
    app = parts[0]
    name = parts[1].gsub(/\.pkl$/, "")
    Util.write_atomically("dist/#{app}.#{name}.json") do |tmp|
        Util.run(cmd % [file, tmp], :quiet => args.quiet)
    end
end


args.info ""
args.info "Done"
args.info ""
