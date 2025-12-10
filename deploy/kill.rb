#!/usr/bin/env ruby

load File.join(File.dirname(__FILE__), '../lib/common.rb')

app = Config.from_args(ARGV)

cmd = if app.scala
        "ps -ef | grep java | grep #{app.name} | grep -v grep"
      else
        Util.exit_with_error("Kill script does not know how to terminate non scala applications")
      end

GRACEFUL_SHUTDOWN_WAIT = 15  # seconds to wait for graceful shutdown

`#{cmd}`.strip.split("\n").each do |l|
  l.split(/\s+/, 3).map(&:to_i).filter { |v| v > 1 }.take(1).each { |pid|
    # Send SIGTERM first for graceful shutdown
    `kill -15 #{pid} > /dev/null 2>&1`

    # Wait for process to terminate gracefully
    GRACEFUL_SHUTDOWN_WAIT.times do
      break unless system("kill -0 #{pid} > /dev/null 2>&1")
      sleep 1
    end

    # Force kill if still running
    if system("kill -0 #{pid} > /dev/null 2>&1")
      puts "Process #{pid} did not terminate gracefully, forcing kill"
      `kill -9 #{pid} > /dev/null 2>&1`
    end
  }
end
