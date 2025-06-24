dir = File.dirname(__FILE__)

Dir.glob("#{File.dirname(__FILE__)}/*.rb")
  .select { |f| File.basename(f) != "common.rb" }
  .each { |f| load f }
