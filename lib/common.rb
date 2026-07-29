# Loads the rest of lib/ for every bin/ script, and makes lib/ the load root so
# subdirectory modules can be pulled in by name (require 'codegen/graph').
#
# __dir__ (not File.dirname(__FILE__)) is deliberate: it is always absolute.
# `require` resolves a relative path against $LOAD_PATH rather than the cwd, so
# a script invoked as `bin/db` produced "bin/../lib/api_batch_client.rb" here
# and died with LoadError before running a line of its own.
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

Dir.glob(File.join(__dir__, "*.rb"))
  .reject { |f| File.basename(f) == "common.rb" }
  .each { |f| require f }
