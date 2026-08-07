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
  #
  # `base_dir: dir` is not optional. A `spec_glob` block resolves its pattern
  # against ApiConfig's base_dir, which defaults to Dir.pwd — and this is asked
  # about a repo that is NOT the cwd every time `dev deploy` asks it, from
  # wherever the human typed the deploy. platform's "dao/spec/*.json" then
  # matched nothing and aborted a deploy that had already succeeded (ISS-867).
  def self.owns_specs?(dir = Dir.pwd)
    config_path = File.join(dir, ".api", "config.pkl")
    return false unless File.exist?(config_path)
    ApiConfig.new(config_path, base_dir: dir).blocks.any? do |block|
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

    # What an operator would have to run by hand, captured as the work works out
    # what it owes and never re-derived in the rescue below. `manual_commands` IS
    # `tasks`, and `tasks` is the thing most likely to have failed here — it
    # reads the released checkout's `.api` config, which aborts on a broken one —
    # so a handler that asked `tasks` what to print would die inside itself.
    commands = PostDeployWork::MANUAL_COMMANDS_FALLBACK

    filed = Util.step("Filing post-deploy work") do
      begin
        if work.any?
          commands = work.manual_commands
          work.file!
        end
      rescue SystemExit, StandardError => e
        # SystemExit is deliberately in that list and is NOT redundant: it is not
        # a StandardError, so the plain `rescue StandardError` this replaces
        # caught nothing at all when the failure came from Util.exit_with_error —
        # which is how EVERY abort under `work.any?` arrives (ISS-867).
        Util.exit_with_error(
          "Could not file the post-deploy work for #{@app} (#{Util.abort_reason(e)}).\n" \
          "The release itself is DONE — the app is live — but nothing is tracking what is left.\n" \
          "Run these by hand:\n#{commands.map { |c| "  #{c}" }.join("\n")}",
        )
      end
    end
    # `work.any?` was false: this release owes nothing, so there is nothing to
    # name below. The stage itself has already run and closed.
    return if filed.nil?

    # Work moving off the critical path must not also move out of sight, so the
    # release names what it filed. Printed AFTER the stage has closed its line
    # and as whole lines: what the deploy display cannot tolerate is output
    # landing mid-stage, while "label... " is still dangling (see Util.step).
    puts "Post-deploy work filed:"
    filed.report_lines.each { |line| puts "  #{line}" }
  end
end
