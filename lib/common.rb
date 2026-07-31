# Loads the rest of lib/ for every bin/ script, and makes lib/ the load root so
# subdirectory modules can be pulled in by name (require 'codegen/graph').
#
# __dir__ (not File.dirname(__FILE__)) is deliberate: it is always absolute.
# `require` resolves a relative path against $LOAD_PATH rather than the cwd, so
# a script invoked as `bin/db` produced "bin/../lib/api_batch_client.rb" here
# and died with LoadError before running a line of its own.
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

# Ruby block-buffers stdout whenever it is not a terminal, so a release running
# under `dev deploy` (stdout is a pipe) would hand the parent its stage lines in
# 8KB gulps — the live phase display would sit still for minutes and then jump.
# Every script here is a CLI or a release step; none is throughput-bound, so
# unbuffered output costs nothing and removes a whole class of "why is it stuck".
$stdout.sync = true

Dir.glob(File.join(__dir__, "*.rb"))
  .reject { |f| File.basename(f) == "common.rb" }
  .each { |f| require f }
