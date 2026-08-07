require 'util'

# The two reconcilers that gate on "what is production running": feature-flag
# cleanup and the issue `fixed -> deployed` pass. A release is the only event
# that can change either answer, which is why they hang off a deploy rather than
# a cron nobody would remember to install.
#
# Neither is scoped to the app that just released, deliberately. A feature
# removal (or a fixed issue) usually waits on more than one app, so releasing
# platform can be what clears one that was also waiting on playbook-app. Both
# commands evaluate everything outstanding.
#
# That global scope is exactly why they belong to the DEPLOY and not to each
# app's release. `dev deploy` releases apps in parallel, so hanging these off
# every release ran each of them once per app, simultaneously: five apps meant
# five unsynchronised `--apply` writers against the same feature-flag and issue
# state, of which runs two through five could only re-evaluate what run one had
# already applied. At ~7s each — the slowest steps on the post-release path —
# the redundancy was paid in wall clock on every multi-app deploy (ISS-810).
#
# So `dev deploy` runs this ONCE, after every phase has finished, and sets
# DEFER_ENV on the releases it spawns so their own PostRelease skips it. A
# standalone `release` (no deploy above it) sees no such variable and keeps its
# single run — the release is the whole deploy in that case.
#
# The `run` seam exists so the narration is testable without reconciling
# anything; in production it is Util::STEP_RUN.
class Reconcilers
  # Set by `dev deploy` on every release it spawns: "I will run the reconcilers
  # myself once we are all done, do not run them per app."
  DEFER_ENV = "DEVOPS_DEFER_RECONCILE".freeze

  COMMANDS = [
    ["features", "feature-flag cleanup"],
    ["issues", "fixed -> deployed transitions"],
  ].freeze

  # True inside a release spawned by `dev deploy`, false for a standalone one.
  def self.deferred? = ENV[DEFER_ENV] == "1"

  # The environment a deploy adds to the releases it spawns. A hash so it merges
  # into the env `dev deploy` already passes (RELEASE_AUTO_TAG and friends).
  def self.defer_env = { DEFER_ENV => "1" }.freeze

  def initialize(bin_dir:, skip_regenerate_flag:, run: Util::STEP_RUN)
    @bin_dir = bin_dir
    @skip_regenerate_flag = skip_regenerate_flag
    @run = run
  end

  # Best-effort, both of them: a reconcile hiccup must never fail a deploy whose
  # apps are already live. Both reconcilers are fail-closed, so skipping a run
  # only defers work, and feature_removals_must_be_processed_within_a_week
  # catches one that has stopped running entirely.
  def run
    COMMANDS.each do |command, description|
      Util.best_effort_step("Reconciling #{description}",
                            "run `dev #{command} reconcile --apply` later") do
        @run.call(dev_cmd(command), ignore_error: true)
      end
    end
  end

  private

  def dev_cmd(command)
    [File.join(@bin_dir, "dev"), command, "reconcile", "--apply", @skip_regenerate_flag].join(" ")
  end
end
