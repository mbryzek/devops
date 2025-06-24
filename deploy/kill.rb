#!/usr/bin/env ruby

load File.join(File.dirname(__FILE__), '../lib/common.rb')

app = Config.from_args(ARGV)

cmd = if app.scala
        "ps -ef | grep java | grep #{app.name} | grep -v grep"
      else
        Util.exit_with_error("Kill script does not know how to terminate non scala applications")
      end

`#{cmd}`.strip.split("\n").each do |l|
  l.split(/\s+/, 3).map(&:to_i).filter { |v| v > 1 }.take(1).each { |pid|
    `kill -9 #{pid} > /dev/null 2>&1`
  }
end
