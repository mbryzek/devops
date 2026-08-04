#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `dev tasks delete` is the only command that removes production rows outright, and its
# --discriminator form removes rows nobody has looked at individually. What is covered
# here is therefore mostly about what it must NOT do: never delete without a selection,
# never treat --id and --discriminator as one action, and never wipe a queue on a run
# with nobody at the keyboard to answer the prompt.
class TestDevTasksDelete < Minitest::Test
  include DevTestSupport

  PREVIEW = "GET /dev/tasks?discriminator=notify_new_membership_labels&include_completed=true&limit=201".freeze

  # ---- argument validation ----

  def test_no_selection_is_refused
    out, status = capture_stderr_and_exit { cmd_tasks_delete(["--app", "platform"]) }
    assert_equal 1, status
    assert_match(/nothing selected/, out)
    assert_includes out, "  Usage: #{usage_for('tasks delete')}"
  end

  def test_id_and_discriminator_together_are_refused
    out, status = capture_stderr_and_exit do
      cmd_tasks_delete(["--app", "platform", "--id", "tas-1", "--discriminator", "one_time"])
    end
    assert_equal 1, status
    assert_match(/mutually exclusive/, out)
  end

  def test_stray_argument_is_refused
    out, status = capture_stderr_and_exit { cmd_tasks_delete(["--app", "platform", "--id", "tas-1", "--typo"]) }
    assert_equal 1, status
    assert_match(/unexpected argument\(s\): --typo/, out)
  end

  def test_flags_requiring_values_say_so
    %w[--id --discriminator].each do |flag|
      out, status = capture_stderr_and_exit { cmd_tasks_delete(["--app", "platform", flag]) }
      assert_equal 1, status, "#{flag}: expected exit 1"
      assert_match(/#{Regexp.escape(flag)} requires a value/, out)
    end
  end

  def test_repeated_id_flags_accumulate
    ids, discriminator, assume_yes = parse_tasks_delete_args(["--id", "tas-1", "--id", "tas-2"])
    assert_equal %w[tas-1 tas-2], ids
    assert_nil discriminator
    refute assume_yes
  end

  # ---- deleting by id ----

  def test_delete_by_id_sends_exactly_those_ids_and_reports_the_count
    sent = nil
    out = with_stubbed_api(
      "DELETE /dev/tasks" => ->(body) { sent = body; { "deleted" => 2 } }
    ) do
      capture_stdout { cmd_tasks_delete(["--app", "platform", "--id", "tas-1", "--id", "tas-2"]) }
    end

    assert_equal({ "task_ids" => %w[tas-1 tas-2] }, sent)
    assert_match(/Platform: 2 tasks deleted/, out)
  end

  # An explicit id list is a targeted removal, so it does not prompt — and must not
  # quietly acquire the whole-queue preview call either.
  def test_delete_by_id_does_not_preview_or_prompt
    out = with_stubbed_api("DELETE /dev/tasks" => { "deleted" => 1 }) do
      with_stdin("", tty: true) { capture_stdout { cmd_tasks_delete(["--app", "platform", "--id", "tas-1"]) } }
    end
    refute_match(/\[y\/N\]/, out)
  end

  # ---- deleting by discriminator ----

  def test_discriminator_previews_the_count_then_deletes_on_yes
    sent = nil
    out = with_stubbed_api(
      PREVIEW => [{ "id" => "tas-1" }, { "id" => "tas-2" }, { "id" => "tas-3" }],
      "DELETE /dev/tasks" => ->(body) { sent = body; { "deleted" => 3 } }
    ) do
      with_stdin("y\n", tty: true) do
        capture_stdout { cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels"]) }
      end
    end

    assert_match(/Platform: 3 task row\(s\) match 'notify_new_membership_labels'/, out)
    assert_equal({ "discriminator" => "notify_new_membership_labels" }, sent)
    assert_match(/Platform: 3 tasks deleted/, out)
  end

  def test_discriminator_declined_deletes_nothing
    out = with_stubbed_api(PREVIEW => [{ "id" => "tas-1" }]) do
      with_stdin("n\n", tty: true) do
        capture_stdout { cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels"]) }
      end
    end
    # The DELETE is simply not stubbed: issuing it would flunk as an unstubbed request.
    assert_match(/Aborted\. Nothing deleted\./, out)
  end

  # The case this guard exists for: a cron run, a subprocess, a Claude session. There is
  # nobody to answer, and answering "yes" for them would wipe a live queue.
  def test_discriminator_without_a_terminal_refuses_instead_of_assuming_yes
    out = nil
    err, status = capture_stderr_and_exit do
      with_stubbed_api(PREVIEW => [{ "id" => "tas-1" }]) do
        with_stdin("", tty: false) do
          out = capture_stdout { cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels"]) }
        end
      end
    end
    assert_equal 1, status
    assert_match(/Pass --yes/, err)
    refute_match(/deleted/, out.to_s)
  end

  def test_yes_skips_the_prompt_entirely
    out = with_stubbed_api("DELETE /dev/tasks" => { "deleted" => 4 }) do
      with_stdin("", tty: false) do
        capture_stdout do
          cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels", "--yes"])
        end
      end
    end
    # No preview request is stubbed: --yes must not make one, since nothing reads it.
    assert_match(/Platform: 4 tasks deleted/, out)
  end

  # The preview reads one page. Reporting a full page as an exact count would understate
  # a queue of thousands right where the operator is deciding whether to wipe it.
  def test_preview_marks_a_full_page_as_a_lower_bound
    rows = Array.new(TASK_PREVIEW_LIMIT) { |i| { "id" => "tas-#{i}" } }
    out = with_stubbed_api(
      PREVIEW => rows,
      "DELETE /dev/tasks" => { "deleted" => 9_000 }
    ) do
      with_stdin("y\n", tty: true) do
        capture_stdout { cmd_tasks_delete(["--app", "platform", "--discriminator", "notify_new_membership_labels"]) }
      end
    end
    assert_match(/Platform: 200\+ task row\(s\)/, out)
  end
end
