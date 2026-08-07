# The one entry point for this repo's tests.
#
# There was none until ISS-660. Every other repo the fleet touches has a command
# that means "run the suite" — `npm test`, `sbt test`, `./test.sh` — and the
# absence of one here was not cosmetic: the `pr-auto-merge` playbook verifies a
# PR by running its repo's suite before deciding anything, and devops was the one
# repo it had nothing to run. What each session invented instead was a bare
# `ruby -e` loader typed from memory, which is a verification signal only as
# reliable as the incantation, and no two of them were the same.
#
# Minitest, loaded in ONE process, which is what the suite already assumes:
# several files `load File.expand_path('../bin/dev', __dir__)` and share the
# constants that defines, so a per-file fork would be both slower and a different
# test.

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs = %w[lib test]
  t.test_files = FileList["test/test_*.rb"]
  # Ruby's -w on a 73-file suite buries the failures under warnings from code
  # this task is not testing. Failures are the output that matters here.
  t.warning = false
end

# The shell guard for `bin/app-env --format sh`, kept OUT of `rake test` on purpose.
# It shells into the sibling `env` checkout, so what it reports depends on
# whether this machine has one and whether it is unlocked — it skips, passes or
# fails on ambient state rather than on the code under test. That confound is
# exactly what made the credentials test read green on laptops and red on the
# runners (ISS-613), and a merge decision must not be made from a signal that
# moves with the machine. Run it deliberately, on a machine you know.
desc "Shell guard: bin/app-env --format sh writes nothing but assignments to stdout"
task "test:app_env_stdout" do
  sh File.expand_path("test/app-env-stdout-is-evalable.sh", __dir__)
end

task default: :test
