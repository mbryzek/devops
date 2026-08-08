#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/common'
require_relative 'test_helper'

# The post-deploy work a release leaves behind, as issues rather than as steps it
# runs inline (ISS-814/816/817).
#
# What is under test is the SHAPE of what gets filed, because every constraint on
# it came from a failure and none of them is visible at the call site:
#
#   - ONE epic per deploy, not one per app: an epic per app would mint five
#     containers for one deploy and bury the queue `dev issues claim` reads.
#   - The two reconcilers are ONE child: both are global, which is exactly why
#     running (or filing) them per app is redundant (ISS-810).
#   - Category `infrastructure`, filed producer-style through Agent::Api: the CLI
#     refuses that category on purpose, and it is the one that advances a chore
#     with no PR straight to `deployed`.
#   - Every child says what to run through `dev agent run-op`: without that
#     record a clean chore classifies as `nothing_to_do` and a producer-filed
#     issue is DISMISSED with the work never done (ISS-815).
class TestPostDeployWork < Minitest::Test
  include DevTestSupport

  NOW = Time.utc(2026, 8, 7, 16, 40, 0)

  # Files nothing. Records the forms and hands back sequential issue numbers, so
  # a test can assert on what would have been filed AND on the parent/child
  # wiring the numbers carry.
  class FakeApi
    attr_reader :forms

    def initialize(fail_on: nil)
      @forms = []
      @fail_on = fail_on
    end

    def create_issue(form, use_localhost:)
      raise ApiError, "no AI API token stored" if @fail_on && form[:title].to_s.include?(@fail_on)
      @forms << form
      { "number" => 100 + @forms.length }
    end
  end

  def work(apps: %w[platform], spec_owners: %w[platform], api: FakeApi.new)
    @api = api
    PostDeployWork.new(
      apps: apps.map { |name| PostDeployWork::App.new(name: name, dir: "/code/#{name}") },
      now: NOW, api: api,
      owns_specs: ->(app) { spec_owners.include?(app.name) },
    )
  end

  def titles(forms) = forms.map { |f| f[:title] }

  # ---- what a deploy owes ----

  def test_a_spec_owning_app_owes_a_publish_a_changelog_when_tracked_and_the_reconcilers
    tasks = work(apps: %w[playbook-admin], spec_owners: %w[playbook-admin]).tasks
    assert_equal [
      "Publish playbook-admin apibuilder specs and PR the generated churn",
      "Record the changelog for playbook-admin",
      "Reconcile feature flags and issue statuses after playbook-admin",
    ], tasks.map(&:title)
  end

  # A frontend whose .api config references registry apps only has no local spec
  # file to publish — the same gate that used to skip the publish stage entirely.
  def test_an_app_that_owns_no_specs_owes_no_publish
    tasks = work(apps: %w[rallyd], spec_owners: []).tasks
    refute(tasks.any? { |t| t.title.include?("Publish") })
  end

  def test_only_changelog_tracked_apps_owe_a_changelog
    refute(work(apps: %w[acumen], spec_owners: []).tasks.any? { |t| t.title.include?("changelog") })
  end

  # The publish is per app because each one is a different clone with a different
  # generated diff, and therefore a different PR.
  def test_each_spec_owning_app_owes_its_own_publish
    tasks = work(apps: %w[platform acumen], spec_owners: %w[platform acumen]).tasks
    assert_equal ["Publish platform apibuilder specs and PR the generated churn",
                  "Publish acumen apibuilder specs and PR the generated churn"],
                 tasks.select { |t| t.title.include?("Publish") }.map(&:title)
  end

  # ISS-810, restated as a filing rule: both reconcilers are global, so a deploy
  # of any size owes exactly ONE child for the pair of them.
  def test_the_two_reconcilers_are_one_child_however_many_apps_released
    tasks = work(apps: %w[platform acumen rallyd hackathon], spec_owners: %w[platform]).tasks
    reconcile = tasks.select { |t| t.title.start_with?("Reconcile") }
    assert_equal 1, reconcile.length
    assert_includes reconcile.first.commands, "dev features reconcile --apply"
    assert_includes reconcile.first.commands, "dev issues reconcile --apply"
  end

  # Neither reconciler may be app-scoped: they evaluate everything outstanding,
  # which is the whole reason one run covers a deploy of any size. Tokenised —
  # `--apply` contains `--app`.
  def test_no_reconcile_command_is_app_scoped
    reconcile = work(apps: %w[platform], spec_owners: []).tasks.last
    reconcile.commands.each { |cmd| refute_includes cmd.split, "--app" }
  end

  def test_a_deploy_with_no_apps_owes_nothing_and_files_nothing
    w = work(apps: [], spec_owners: [])
    refute w.any?
    assert_nil w.file!
    assert_empty @api.forms
  end

  # ---- what gets filed ----

  def test_one_epic_is_filed_for_the_whole_deploy_with_every_task_as_a_child
    filed = work(apps: %w[platform acumen], spec_owners: %w[platform acumen]).file!

    epics = @api.forms.select { |f| f[:type] == "epic" }
    assert_equal 1, epics.length
    assert_equal "Post-deploy work for platform, acumen", epics.first[:title]

    children = @api.forms.reject { |f| f[:type] == "epic" }
    assert_equal 3, children.length
    assert(children.all? { |f| f[:parent_number] == filed.epic })
    assert_equal filed.children.map(&:last), titles(children)
  end

  # The category the CLI refuses on purpose, and the reason this files through
  # Agent::Api rather than shelling out to `dev issues create`.
  def test_everything_is_filed_as_an_unclaimed_infrastructure_issue
    work(apps: %w[platform]).file!
    @api.forms.each do |form|
      assert_equal "infrastructure", form[:category]
      assert_equal false, form[:claim_on_create]
    end
  end

  # The executor clones the repos an issue names before the session starts, so
  # the publish child has to name the app it publishes — and the chores, which
  # run from anywhere, must not name one they would only clone for nothing.
  def test_only_the_publish_child_names_a_repository
    work(apps: %w[playbook-admin], spec_owners: %w[playbook-admin]).file!
    by_title = @api.forms.to_h { |f| [f[:title], f] }
    assert_equal ["playbook-admin"], by_title["Publish playbook-admin apibuilder specs and PR the generated churn"][:repositories]
    refute by_title["Record the changelog for playbook-admin"].key?(:repositories)
    refute by_title["Reconcile feature flags and issue statuses after playbook-admin"].key?(:repositories)
  end

  # Every child closes out through Agent::Ops, not through the session's account
  # of itself. A body that names the bare command instead would produce a session
  # with nothing mechanical to classify (ISS-815).
  def test_every_child_tells_the_session_to_run_its_command_through_run_op
    work(apps: %w[playbook-admin], spec_owners: %w[playbook-admin]).file!
    @api.forms.reject { |f| f[:type] == "epic" }.each do |form|
      assert_includes form[:body], "dev agent run-op", "#{form[:title]} must close out through run-op"
      assert_includes form[:body].downcase, "by hand",
                      "#{form[:title]} must tell the session not to close the issue by hand"
    end
  end

  # `api publish` writes generated code into whatever checkout it runs in, so
  # aiming it at the shared ~/code/<app> checkout drops that diff where nobody
  # is watching — the failure ISS-817 moved this work to the fleet to end, and
  # a directory CLAUDE.md forbids working in either way. The task must send the
  # session to a clone of its own.
  def test_the_publish_child_clones_rather_than_using_the_shared_checkout
    work(apps: %w[platform]).file!
    publish = @api.forms.find { |f| f[:title].to_s.start_with?("Publish") }
    assert_includes publish[:body], "git clone --depth 1 --no-single-branch"
    refute_includes publish[:body], "cd ~/code/platform",
                    "the publish task must never send a session into the shared checkout"
  end

  # `--depth` alone sets a refspec that tracks only main, and then `gh pr create`
  # aborts with "you must first push the current branch to a remote" even when the
  # branch IS pushed — which would strand the regen PR half of this very task.
  # The two flags travel together or the shallow clone is a trap.
  def test_the_shallow_clone_keeps_a_full_refspec
    work(apps: %w[platform]).file!
    publish = @api.forms.find { |f| f[:title].to_s.start_with?("Publish") }
    # Only the clone COMMANDS, not the prose that explains why a bare --depth is
    # a trap — that paragraph says `--depth N` on purpose.
    clone_lines = publish[:body].lines.grep(/git clone/)
    refute_empty clone_lines
    clone_lines.each do |line|
      assert_includes line, "--no-single-branch",
                      "a bare --depth breaks gh pr create for the regen PR: #{line.strip}"
    end
  end

  # The severity that must not be lost in the move: a publish failure used to
  # fail the release, so the issue may not be quietly dismissed instead.
  def test_the_publish_child_forbids_dismissing_a_failed_publish
    work(apps: %w[platform]).file!
    publish = @api.forms.find { |f| f[:title].to_s.start_with?("Publish") }
    assert_includes publish[:body], "not something to dismiss"
    assert_includes publish[:body], "generated/"
  end

  def test_the_report_names_the_epic_and_every_child
    filed = work(apps: %w[platform]).file!
    assert_equal ["ISS-101 (epic)",
                  "  ISS-102 Publish platform apibuilder specs and PR the generated churn",
                  "  ISS-103 Reconcile feature flags and issue statuses after platform"],
                 filed.report_lines
  end

  # A filing failure has to leave the caller able to say what did not happen —
  # an unfiled publish is exactly as silent as an unrun one.
  def test_a_filing_failure_raises_and_the_manual_commands_are_available
    w = work(apps: %w[platform], api: FakeApi.new(fail_on: "Post-deploy work for"))
    assert_raises(ApiError) { w.file! }
    assert_equal ["git clone --depth 1 --no-single-branch git@github.com:mbryzek/platform.git " \
                  "~/code/ai/publish-platform && cd ~/code/ai/publish-platform && api publish",
                  "dev features reconcile --apply",
                  "dev issues reconcile --apply"], w.manual_commands
  end

  # The deploy tells the releases it spawns to file nothing, and a standalone
  # release reads that. Asserted through both sides rather than a literal, so a
  # rename cannot leave the halves disagreeing silently.
  def test_the_deploy_environment_is_what_a_release_reads_as_deferred
    PostDeployWork.defer_env.each { |k, v| ENV[k] = v }
    assert PostDeployWork.deferred?
  ensure
    ENV.delete(PostDeployWork::DEFER_ENV)
  end

  def test_deferred_is_false_without_the_environment_variable
    ENV.delete(PostDeployWork::DEFER_ENV)
    refute PostDeployWork.deferred?
  end
end
