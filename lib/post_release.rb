require 'util'
require 'post_deploy_work'

# The part of a release that runs AFTER the deploy: the app is already live (the
# release script waited for the rollout), and what is left is bookkeeping.
#
# It no longer DOES that bookkeeping. `api publish`, `dev changelog` and the two
# global reconcilers are filed as issues the fleet picks up (PostDeployWork,
# ISS-814) and the release ends when the rollout is verified — which is the only
# part of it that was ever on the human's clock.
#
# Two callers, one shape:
#
#   - a standalone `release`: the release IS the whole deploy, so this files the
#     work for the one app it released.
#   - a release `dev deploy` spawned: the deploy files ONE epic for every app it
#     released, and sets PostDeployWork.defer_env so this does nothing.
#
# The `work` seam exists so the narration is testable without filing anything.
class PostRelease
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
  # app, no deploy above it and no post-deploy work of any other kind. It stays
  # INLINE deliberately: a library release is not part of `dev deploy`'s app
  # phases, so there is no epic for it to be a child of, and publishing in the
  # checkout that just released is not the drift ISS-817 was about (nothing
  # regenerates a library's specs into a working copy nobody commits — a lib
  # release is already a human sitting at a GPG prompt).
  def self.publish_specs_if_owned(bin_dir)
    Util.run(publish_cmd(bin_dir), quiet: true) if owns_specs?
  end

  def initialize(app:, dir: Dir.pwd, work: nil)
    @app = app
    @dir = dir
    @work = work
  end

  # Files this release's post-deploy work, as one narrated stage in the same
  # "label... done (12s)" form every other release stage uses (lib/deploy_
  # progress.rb parses it).
  #
  # Deliberately NOT best-effort. Inline, a failed `api publish` failed the
  # release, because a deployed API whose specs did not publish is exactly the
  # drift the hermetic design exists to prevent. Filing inherits that severity:
  # an unfiled publish is precisely as silent as an unrun one, so a filing
  # failure stops the release with the commands to run by hand.
  def run
    return if PostDeployWork.deferred?

    work = @work || PostDeployWork.new(apps: [PostDeployWork::App.new(name: @app, dir: @dir)])
    return unless work.any?

    filed = Util.step("Filing post-deploy work") do
      begin
        work.file!
      rescue StandardError => e
        Util.exit_with_error(
          "Could not file the post-deploy work for #{@app} (#{e.message}).\n" \
          "The release itself is DONE — the app is live — but nothing is tracking what is left.\n" \
          "Run these by hand:\n#{work.manual_commands.map { |c| "  #{c}" }.join("\n")}",
        )
      end
    end
    # Work moving off the critical path must not also move out of sight, so the
    # release names what it filed. Printed AFTER the stage has closed its line
    # and as whole lines: what the deploy display cannot tolerate is output
    # landing mid-stage, while "label... " is still dangling (see Util.step).
    puts "Post-deploy work filed:"
    filed.report_lines.each { |line| puts "  #{line}" }
  end
end
