require 'util'

# The part of a release that runs AFTER the deploy: the app is already live
# (the release script waited for the rollout), but the release is not over.
#
# Every one of these steps is slow — `api publish` alone uploads 100+ apibuilder
# applications and waits on codegen — and none of them used to narrate anything.
# `dev deploy` showed the app sitting on a ticking clock with no stage under it
# for a minute or more after "Rolling out... done", which reads as a hung
# release. So each step is a Util.step stage, in the same "label... done (12s)"
# form every other release stage uses and lib/deploy_progress.rb already parses.
#
# The `run` seam exists so the narration is testable without releasing anything;
# in production it is Util.run.
class PostRelease
  # Only these apps feed the changelog pipeline.
  CHANGELOG_TRACKED = %w[playbook-admin playbook-app playbook-www].freeze

  # The two reconcilers that gate on "what is production running". A release is
  # the only event that can change either answer, which is why they hang off
  # this rather than a cron nobody would remember to install.
  #
  # Deliberately NOT scoped to the app just released. A feature removal (or a
  # fixed issue) usually waits on more than one app, so releasing platform can
  # be what clears one that was also waiting on playbook-app. Both commands
  # evaluate everything outstanding, so one call per release covers all of it.
  RECONCILERS = [
    ["features", "feature-flag cleanup"],
    ["issues", "fixed -> deployed transitions"],
  ].freeze

  # Publishing specs is the release's job and nobody else's: dev `api` runs are
  # hermetic and never write the registry, so `latest` means "what is released"
  # — the specs of the API actually running in prod.
  def self.publish_cmd(bin_dir) = File.join(bin_dir, "api") + " publish"

  # Does this checkout own apibuilder specs? A frontend's .api config references
  # registry apps only, and has no local spec file to publish.
  def self.owns_specs?(dir = Dir.pwd)
    config_path = File.join(dir, ".api", "config.pkl")
    return false unless File.exist?(config_path)
    ApiConfig.new(config_path).blocks.any? do |block|
      block.applications.any? { |app| File.exist?(File.join(dir, app.file_path)) }
    end
  end

  # Used by the library branch of bin/release (lib-ai owns specs), which has no
  # app and so runs none of the rest of this.
  def self.publish_specs_if_owned(bin_dir)
    Util.run(publish_cmd(bin_dir), quiet: true) if owns_specs?
  end

  DEFAULT_RUN = ->(cmd, ignore_error:) { Util.run(cmd, quiet: true, ignore_error: ignore_error) }

  def initialize(app:, bin_dir:, skip_regenerate_flag:, owns_specs: self.class.owns_specs?, run: DEFAULT_RUN)
    @app = app
    @bin_dir = bin_dir
    @skip_regenerate_flag = skip_regenerate_flag
    @owns_specs = owns_specs
    @run = run
  end

  def run
    publish_specs
    record_changelog
    reconcile
  end

  private

  # Deliberately NOT best-effort: a deployed API whose specs failed to publish is
  # exactly the drift the hermetic design exists to prevent, so a publish failure
  # fails the release (Util.run exits). Recover by fixing the cause and running
  # `api publish` standalone — the deploy itself has already happened.
  #
  # No stage line at all when the checkout owns no specs, rather than a stage
  # that always says done (0s).
  def publish_specs
    return unless @owns_specs
    Util.step("Publishing apibuilder specs") do
      @run.call(self.class.publish_cmd(@bin_dir), ignore_error: false)
    end
  end

  # Records this app's changelog in platform now that the tag exists. Runs the
  # whole pipeline (capture then build): the notes are served from the API, so
  # nothing is baked into a build and there is no reason to defer the model step
  # to a manual run.
  def record_changelog
    return unless CHANGELOG_TRACKED.include?(@app)
    best_effort("Recording changelog",
                dev_cmd("changelog", "--app", @app),
                "run `dev changelog --app #{@app}` later")
  end

  def reconcile
    RECONCILERS.each do |command, description|
      best_effort("Reconciling #{description}",
                  dev_cmd(command, "reconcile", "--apply"),
                  "run `dev #{command} reconcile --apply` later")
    end
  end

  def dev_cmd(*parts) = [File.join(@bin_dir, "dev"), *parts, @skip_regenerate_flag].join(" ")

  # A hook whose failure must never fail a release that has already succeeded —
  # both reconcilers are fail-closed, so skipping a run only defers work, and
  # feature_removals_must_be_processed_within_a_week catches one that has stopped
  # running entirely. step_failed! only changes how the stage RENDERS ("failed
  # (4s)" rather than a done that hides it); it does not abort.
  def best_effort(label, cmd, recovery)
    Util.step(label) do
      next if @run.call(cmd, ignore_error: true)
      Util.detail("#{label} failed (ignored) — #{recovery}")
      Util.step_failed!
    end
  end
end
