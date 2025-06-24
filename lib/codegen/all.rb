Dir.glob("#{File.dirname(__FILE__)}/*.rb")
  .select { |f| File.basename(f) != "all.rb" }
  .each { |f| load f }
