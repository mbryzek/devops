#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# Every mutation on the /dev console requires `platform_admin`, which does not admit the AI
# actor. Until ISS-945 the only way to learn that was to send the request and read the 401, so
# a session following a briefing that prescribed one of these commands — and
# claude-invariants/investigate-body.md prescribes three — was left with a failed call and no
# next step.
#
# What is covered here is therefore the two halves of that: nothing may reach the network on
# behalf of the AI actor, and what comes back instead must be the `dev issues handoff` line
# that actually resolves it, carrying the invocation that was attempted.
#
# NetworkGuard reads every credential as absent, so the guard is dormant for every OTHER test
# in the suite by construction — a test opts into being the AI actor with `as_ai_actor`.
class TestDevHumanOnlyMutations < Minitest::Test
  include DevTestSupport

  PREVIEW = "GET /dev/tasks?discriminator=notify_new_membership_labels&include_completed=true&limit=201".freeze

  def setup
    @saved_issue = ENV["DEV_AGENT_ISSUE"]
    ENV["DEV_AGENT_ISSUE"] = "945"
  end

  def teardown
    ENV["DEV_AGENT_ISSUE"] = @saved_issue
  end

  # This process presents the AI actor's token, which is what `dev` does inside a Claude
  # session that has been provisioned one.
  def as_ai_actor(&block)
    stub_singleton(ApiClient, :auth_header_for, ->(_app, use_localhost:) { ["Authorization", "Basic stub"] }, &block)
  end

  # Everything the block wrote to stderr, plus its exit status, with stdout swallowed — these
  # commands print a banner before the guard runs and it is not the subject here.
  def refusal(&block)
    capture_stderr_and_exit { capture_stdout(&block) }
  end

  # ---- the refusal itself ----

  def test_tasks_delete_by_id_refuses_before_sending_anything
    # Nothing is stubbed: NetworkGuard raises NetworkBlocked on any request, so a DELETE that
    # slipped through would fail this test rather than pass it quietly.
    out, status = as_ai_actor { refusal { cmd_tasks_delete(["--app", "platform", "--id", "tas-1"]) } }

    assert_equal 1, status
    assert_match(/tasks delete: refused/, out)
    assert_match(/platform_admin/, out)
    assert_match(/dev issues handoff --from 945 --key dev-tasks-delete-by-id/, out)
    assert_match(/--command 'dev tasks delete --app platform --id tas-1'/, out)
    assert_match(/--rerun '/, out)
  end

  # The point of refusing BEFORE the request rather than reading the 401 after it: a human is
  # told the truth about `dev auth login` instead of being sent to run it.
  def test_the_refusal_does_not_blame_the_credential
    out, = as_ai_actor { refusal { cmd_tasks_requeue(["--app", "platform"]) } }
    assert_match(/`dev auth login` is not the fix/, out)
  end

  def test_every_human_only_command_refuses
    cases = {
      "tasks requeue" => [:cmd_tasks_requeue, ["--app", "platform"]],
      "tasks delete" => [:cmd_tasks_delete, ["--app", "platform", "--id", "tas-1"]],
      "invariants snooze" => [:cmd_invariants_snooze,
                              ["--app", "platform", "orphaned_clubs", "--days", "3", "--reason", "under investigation"]],
      "invariants unsnooze" => [:cmd_invariants_unsnooze, ["--app", "platform", "orphaned_clubs"]],
      "features cancel" => [:cmd_features_cancel, %w[platform some_flag]],
    }

    cases.each do |command, (fn, args)|
      out, status = as_ai_actor { refusal { send(fn, args) } }
      assert_equal 1, status, "#{command}: expected exit 1"
      assert_match(/#{Regexp.escape(command)}: refused/, out)
      assert_match(/dev issues handoff --from 945/, out, "#{command}: no handoff offered")
      assert_match(/--command 'dev #{Regexp.escape(command)} /, out, "#{command}: handoff lost the invocation")
    end
  end

  # An argument carrying a space must survive being pasted into a shell. `--reason` is the one
  # that always does.
  def test_the_handed_over_command_is_shell_safe
    out, = as_ai_actor do
      refusal do
        cmd_invariants_snooze(["--app", "platform", "orphaned_clubs", "--days", "3", "--reason", "waiting on ISS-1"])
      end
    end
    assert_match(/--command 'dev invariants snooze --app platform orphaned_clubs --days 3 --reason '\\''waiting on ISS-1'\\'''/, out)
  end

  # Outside an autonomous session there is no issue number to fill in, and a wrong one is worse
  # than a placeholder: a handoff filed against somebody else's issue is lost to both.
  def test_without_an_issue_number_the_from_is_a_placeholder
    ENV["DEV_AGENT_ISSUE"] = nil
    out, = as_ai_actor { refusal { cmd_tasks_requeue(["--app", "platform"]) } }
    assert_match(/--from <this issue's number>/, out)
  end

  # ---- what the console's READS still buy you ----

  # The preview is `platform_diagnostics`, so the AI actor is admitted to it. Spending it is
  # the difference between handing over "rows may be stranded" and handing over a number.
  def test_tasks_delete_by_discriminator_hands_over_the_live_row_count
    out, status = as_ai_actor do
      with_stubbed_api(PREVIEW => [{ "id" => "tas-1" }, { "id" => "tas-2" }]) do
        refusal { cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels"]) }
      end
    end

    assert_equal 1, status
    assert_match(/Platform: 2 task row\(s\) match 'notify_new_membership_labels'/, out)
    assert_match(/--key dev-tasks-delete-notify-new-membership-labels/, out)
  end

  # --yes skips the preview for a human, who is only being spared a prompt. The AI actor is not
  # prompting; it is filling in a handoff, so the read still runs.
  def test_yes_does_not_suppress_the_preview_for_the_ai_actor
    out, status = as_ai_actor do
      with_stubbed_api(PREVIEW => [{ "id" => "tas-1" }]) do
        refusal do
          cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels", "--yes"])
        end
      end
    end
    assert_equal 1, status
    assert_match(/1 task row\(s\) match/, out)
  end

  # ISS-921's actual situation, which cost a session a manual investigation to establish: the
  # lane was already drained. There is no work here, so there is nothing to park on a human,
  # and the run succeeds instead of failing back into the queue.
  def test_a_drained_queue_needs_no_handoff_and_is_not_a_failure
    status = nil
    out = as_ai_actor do
      with_stubbed_api(PREVIEW => []) do
        capture_stdout do
          begin
            cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels"])
          rescue SystemExit => e
            status = e.status
          end
        end
      end
    end

    assert_nil status, "a drained queue must not exit non-zero"
    assert_match(/Platform: 0 task row\(s\) match/, out)
    assert_match(/Nothing to delete/, out)
    refute_match(/issues handoff/, out)
  end

  # ---- a human is untouched ----

  # The guard keys off the credential this process would present, not off the command. With no
  # AI token the same call goes straight through, which is every one of Mike's invocations.
  def test_a_human_is_not_refused
    out = with_stubbed_api("POST /dev/task/requeues" => { "requeued" => 7 }) do
      capture_stdout { cmd_tasks_requeue(["--app", "platform"]) }
    end
    assert_match(/Platform: 7 tasks requeued/, out)
  end
end
