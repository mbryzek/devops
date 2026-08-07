#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'shellwords'

# bin/test-timings summarizes an sbt/ScalaTest log. What is guarded here is one
# line of its output, and the reason is not cosmetic.
#
# ScalaTest prints one "Run completed in ..." per subproject. With forked tests
# those clocks all start together — `done()` runs on the master runner in the sbt
# JVM, whose clock starts when that subproject's `executeTests` begins, while only
# the forked group inside `executeTests` carries the concurrency tag. So every
# subproject reports "start of the test phase -> end of my own turn", the numbers
# overlap almost completely, and summing them multiplies the phase by the number
# of subprojects.
#
# ISS-800 was filed off exactly that sum: 15 summaries totalling 40.8 minutes
# against a ~7 minute phase, read as "sbt is running 6 test tasks at once and the
# ISS-167 restriction is not in effect". Sampling `ps` once a second through a
# real run showed 1 forked test JVM in all 527 samples. The build was fine; the
# reading was not.
#
# So the report has to say so where the numbers are, which is what this test is
# about — not the formatting, but that the word MEANINGLESS and the pointer to
# "longest test run" both survive.
class TestTestTimings < Minitest::Test
  SCRIPT = File.expand_path('../bin/test-timings', __dir__)

  # A minimal log with the four line shapes the parser cares about: a suite
  # header, a per-test duration, the per-subproject run summaries, and sbt's
  # total time.
  def log(runs:)
    lines = ["[info] SomeSpec:", "[info] - must do a thing (250 milliseconds)"]
    runs.each { |r| lines << "[info] Run completed in #{r}." }
    lines << "[success] Total time: 606 s (0:10:06.0), completed Aug 7, 2026, 10:29:25 AM"
    lines.join("\n") + "\n"
  end

  def report_for(runs)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'run.log')
      File.write(path, log(runs: runs))
      out, err, status = Open3.capture3(SCRIPT, path, '--no-history', '--project', 'fixture')
      assert status.success?, "test-timings failed: #{err}"
      out
    end
  end

  def test_names_the_summed_run_times_as_meaningless
    out = report_for(['9 minutes, 48 seconds', '9 minutes, 48 seconds', '9 minutes, 49 seconds'])

    assert_match(/summed test runs:/, out)
    assert_match(/MEANINGLESS/, out)
    # The sum itself is printed, because the reader who is about to compute it
    # is the reader who needs to see it labelled.
    assert_match(/29m25s/, out)
    # And it has to say what to use instead, or it is just a scold.
    assert_match(/longest test run/, out)
  end

  # The critical path is the max, and it is the number the compile estimate is
  # derived from. A regression that swapped max for sum would move both.
  def test_longest_run_is_the_max_not_the_sum
    out = report_for(['9 minutes, 48 seconds', '9 minutes, 48 seconds', '9 minutes, 49 seconds'])

    assert_match(/longest test run:\s+9m49s/, out)
    assert_match(/compile \+ startup:\s+17\.0s/, out)
  end

  # One subproject cannot overlap with itself, so there is nothing to warn about
  # and the extra line would only be noise.
  def test_single_run_gets_no_warning
    out = report_for(['9 minutes, 48 seconds'])

    refute_match(/summed test runs:/, out)
  end

  # A project whose subprojects' test tasks run CONCURRENTLY (platform does, to
  # stop laying them end to end -- see its build.sbt and ISS-813) breaks the
  # premise every derived number above rests on. The summaries no longer start
  # together, so the largest is just the longest-lived subproject and the phase
  # outlasts it by however long the run went on afterwards.
  #
  # Measured on such a run: summaries spread from 7s to 47s against a 136s phase,
  # which turned a ~25s compile into a reported 1m54s. Guarded here because a
  # compile time off by 4x is worse than no compile time -- it is the number
  # somebody uses to decide the suite does not need speeding up.
  STAGGERED = ['7 seconds', '21 seconds', '31 seconds', '46 seconds'].freeze

  def test_staggered_summaries_do_not_claim_a_critical_path
    out = report_for(STAGGERED)

    assert_match(/longest test run:\s+46\.0s/, out)
    assert_match(/NOT the critical path/, out)
  end

  def test_staggered_summaries_suppress_the_compile_estimate
    refute_match(/compile \+ startup:/, report_for(STAGGERED))
  end

  # And the discrimination has to be on the numbers, not on the count: the same
  # four subprojects run one at a time still report one clock, and still get the
  # critical path and the compile estimate.
  def test_equal_summaries_still_get_the_critical_path
    out = report_for(['9 minutes, 48 seconds'] * 4)

    assert_match(/critical path across 4 subproject test runs/, out)
    assert_match(/compile \+ startup:\s+18\.0s/, out)
  end
end
