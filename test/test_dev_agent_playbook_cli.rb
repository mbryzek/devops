#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative 'test_helper'
load File.expand_path('../bin/dev', __dir__)

# `dev agent playbooks` / `dev agent playbook` — the operator surface over the
# append-only playbook rows (ISS-665).
#
# The read commands are wrappers and are tested as such: one round trip each, and
# the stdout/stderr split, because `dev agent playbook k > k.md` followed by an
# edit and `--write k.md` is the whole workflow and a version banner leaking into
# the file would silently corrupt every playbook edited that way.
#
# The WRITE tests are the point of this file. Every mistake on this path is
# permanent — there is no update and no delete on the resource, by design — so
# each gate is tested by asserting the POST does not happen. `with_stubbed_api`
# fails the test on any request it was not given, which is what makes "no write
# occurred" an assertion rather than a hope.
class TestDevAgentPlaybookCli < Minitest::Test
  include DevTestSupport

  IDENTITY = Agent::Host::Identity.new(runner_id: "agr-test", token: "tok-runner").freeze

  KEY = "pr-auto-merge".freeze
  VERSION = "2026-08-05T14:04:20.055Z".freeze
  OLDER = "2026-07-30T09:15:00.000Z".freeze

  BODY = "# Auto-merge review\n\nStep one.\nStep two.\nStep three.\n".freeze

  def row(key: KEY, body: BODY, created_at: VERSION)
    { "key" => key, "body" => body, "created_at" => created_at }
  end

  # Every command here needs a registered runner to authenticate as, and the write
  # path additionally branches on whether this process is a Claude session. Both
  # are stubbed rather than read off the box, or the suite would take a different
  # path on a runner than on a laptop — and the whole test file runs INSIDE a
  # Claude session, where `ai_session?` is true by default.
  def run_dev(session: false, stdin: nil, tty: false, api: {})
    stub_singleton(Agent::Host, :cached_identity, -> { IDENTITY }) do
      stub_singleton(ApiClient, :ai_session?, -> { session }) do
        with_stdin(stdin.to_s, tty: tty) do
          with_stubbed_api(api) do
            capture_io do
              yield
            rescue SystemExit => e
              @exit_status = e.status
            end
          end
        end
      end
    end
  end

  def with_body_file(text)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "playbook.md")
      File.write(path, text)
      yield path
    end
  end

  def versions_path(key, limit)
    "GET /agent/playbooks/#{key}/versions?limit=#{limit}&offset=0"
  end

  # ---- the catalogue ----

  def test_playbooks_lists_each_key_with_its_version_and_first_line
    out, = run_dev(api: { "GET /agent/playbooks" => [row, row(key: "weekly-review", body: "# Weekly review\n\nGo.")] }) do
      cmd_agent_playbooks([])
    end

    assert_includes out, "2 playbook(s)"
    assert_includes out, KEY
    assert_includes out, VERSION
    assert_includes out, "# Auto-merge review"
    assert_includes out, "weekly-review"
  end

  # An empty catalogue is not "nothing to see": every producer whose issue points
  # at a playbook is unclaimable, which is ISS-360's failure fleet-wide.
  def test_an_empty_catalogue_says_what_it_costs
    out, = run_dev(api: { "GET /agent/playbooks" => [] }) { cmd_agent_playbooks([]) }
    assert_includes out, "cannot be claimed"
  end

  # `agent playbooks <key>` printed that body before ISS-665 split the commands.
  # Anyone who types the old form gets told the new spelling, not a bare "unexpected
  # argument" they have to go find the answer to.
  def test_the_old_key_form_names_the_singular_command
    _, err = run_dev { cmd_agent_playbooks([KEY]) }
    assert_equal 1, @exit_status
    assert_includes err, "dev agent playbook #{KEY}"
  end

  # ---- the lint, which survived the split (ISS-633) ----
  #
  # A store-wide check, and the ONE mode here that is a check rather than a read,
  # so it is the only one that may fail the shell. Everything else has to stay
  # usable in a pipeline.

  def test_lint_over_the_store_exits_non_zero_on_a_finding
    rows = [row(key: "broken", body: "one\nwrite /Users/mbryzek/code/x\n")]
    out, = run_dev(api: { "GET /agent/playbooks" => rows }) { cmd_agent_playbooks(["--lint"]) }
    assert_equal 1, @exit_status
    assert_includes out, "broken:2: /Users/mbryzek"
  end

  def test_a_clean_store_lints_green
    out, = run_dev(api: { "GET /agent/playbooks" => [row] }) { cmd_agent_playbooks(["--lint"]) }
    assert_nil @exit_status
    assert_includes out, "No findings in 1 playbook(s)"
  end

  # The catalogue itself stays exit-0 even with a defect in the store — it is a
  # read — but the defect is flagged inline, because a lint you have to know to
  # ask for is one nobody asks for.
  def test_the_catalogue_flags_a_defect_without_failing
    rows = [row(key: "broken", body: "one\nwrite /Users/mbryzek/code/x\n")]
    out, = run_dev(api: { "GET /agent/playbooks" => rows }) { cmd_agent_playbooks([]) }
    assert_nil @exit_status
    assert_includes out, "1 lint finding(s): /Users/mbryzek"
  end

  # Same three checks, scoped to one key — what you run before --write.
  def test_linting_one_playbook_uses_the_same_checks_and_exit_rule
    api = { "GET /agent/playbooks/broken" => row(key: "broken", body: "one\nwrite /Users/mbryzek/code/x\n") }
    out, = run_dev(api: api) { cmd_agent_playbook(["broken", "--lint"]) }
    assert_equal 1, @exit_status
    assert_includes out, "broken:2: /Users/mbryzek"
  end

  def test_linting_one_clean_playbook_is_green_and_prints_no_body
    out, = run_dev(api: { "GET /agent/playbooks/#{KEY}" => row }) { cmd_agent_playbook([KEY, "--lint"]) }
    assert_nil @exit_status
    assert_includes out, "No findings in 1 playbook(s)"
    refute_includes out, "Step two."
  end

  def test_lint_is_mutually_exclusive_with_the_other_modes
    _, err = run_dev { cmd_agent_playbook([KEY, "--lint", "--versions"]) }
    assert_equal 1, @exit_status
    assert_includes err, "--lint and --versions"
  end

  # ---- reading one ----

  # stdout is the body ALONE. `dev agent playbook k > k.md` has to capture byte for
  # byte what a claiming session reads, so which version it is goes to stderr.
  def test_reading_a_playbook_puts_the_body_on_stdout_and_the_version_on_stderr
    out, err = run_dev(api: { "GET /agent/playbooks/#{KEY}" => row }) { cmd_agent_playbook([KEY]) }

    assert_equal BODY, out
    assert_includes err, "#{KEY} @ #{VERSION}"
    refute_includes out, VERSION
  end

  def test_reading_an_unknown_key_names_the_catalogue
    _, err = run_dev(api: { "GET /agent/playbooks/nope" => nil }) { cmd_agent_playbook(["nope"]) }
    assert_equal 1, @exit_status
    assert_includes err, "No playbook `nope` exists"
    assert_includes err, "dev agent playbooks"
  end

  # ---- history ----

  def test_versions_lists_newest_first_and_marks_the_current_one
    api = { versions_path(KEY, 20) => [row, row(created_at: OLDER, body: "# Auto-merge review\n\nStep one.")] }
    out, = run_dev(api: api) { cmd_agent_playbook([KEY, "--versions"]) }

    assert_includes out, "2 version(s)"
    assert_match(/#{Regexp.escape(VERSION)}\s+\(current\)/, out)
    assert_includes out, OLDER
    refute_match(/#{Regexp.escape(OLDER)}\s+\(current\)/, out)
  end

  # The whole reason copy-on-write is worth its cost: "what did that run actually
  # execute" is answerable, not inferred. A prefix is accepted because the version
  # an operator has in front of them came off an issue comment.
  def test_a_version_prefix_prints_that_past_body
    api = { versions_path(KEY, 100) => [row, row(created_at: OLDER, body: "the older procedure")] }
    out, err = run_dev(api: api) { cmd_agent_playbook([KEY, "--version", "2026-07-30"]) }

    assert_equal "the older procedure\n", out
    assert_includes err, OLDER
  end

  def test_an_ambiguous_version_prefix_refuses_rather_than_guessing
    api = { versions_path(KEY, 100) => [row, row(created_at: OLDER)] }
    _, err = run_dev(api: api) { cmd_agent_playbook([KEY, "--version", "2026-0"]) }

    assert_equal 1, @exit_status
    assert_includes err, "matches 2 versions"
  end

  def test_a_version_that_matches_nothing_points_at_the_history
    api = { versions_path(KEY, 100) => [row] }
    _, err = run_dev(api: api) { cmd_agent_playbook([KEY, "--version", "1999"]) }

    assert_equal 1, @exit_status
    assert_includes err, "--versions"
  end

  # ---- the write path ----

  # The happy path, and the only test here that lets a POST through. What is SENT
  # is asserted, not just that something was: the body is the file byte for byte,
  # since that is what every future session reads.
  def test_write_appends_the_file_after_the_diff_and_an_explicit_yes
    updated = "# Auto-merge review\n\nStep one.\nStep two REWRITTEN.\nStep three.\n"
    sent = nil
    api = {
      "GET /agent/playbooks/#{KEY}" => row,
      "POST /agent/playbooks" => ->(payload) { sent = payload; row(body: updated, created_at: "2026-08-06T12:00:00.000Z") },
    }

    with_body_file(updated) do |path|
      out, = run_dev(api: api) { cmd_agent_playbook([KEY, "--write", path, "--yes"]) }

      assert_includes out, "- Step two."
      assert_includes out, "+ Step two REWRITTEN."
      assert_includes out, "Appended #{KEY} @ 2026-08-06T12:00:00.000Z"
    end

    assert_equal({ key: KEY, body: updated }, sent)
  end

  # A human at a terminal gets the prompt rather than a flag, and answering
  # anything but yes writes nothing — the POST is unstubbed, so a write here fails
  # the test.
  def test_a_terminal_is_prompted_and_a_declined_prompt_writes_nothing
    with_body_file("# Auto-merge review\n\nSomething else entirely.\n") do |path|
      out, = run_dev(stdin: "n\n", tty: true, api: { "GET /agent/playbooks/#{KEY}" => row }) do
        cmd_agent_playbook([KEY, "--write", path])
      end

      assert_includes out, "Append this as a new version"
      assert_includes out, "Aborted. Nothing appended."
    end
  end

  def test_a_terminal_that_answers_yes_appends
    posted = false
    api = {
      "GET /agent/playbooks/#{KEY}" => row,
      "POST /agent/playbooks" => ->(_payload) { posted = true; row(created_at: "2026-08-06T12:00:00.000Z") },
    }
    with_body_file("# Auto-merge review\n\nSomething else entirely.\n") do |path|
      run_dev(stdin: "y\n", tty: true, api: api) { cmd_agent_playbook([KEY, "--write", path]) }
    end
    assert posted, "an explicit yes at a terminal must append"
  end

  # THE gate this command exists for. A session that edits a playbook is editing
  # the instructions every future session obeys, so it has to be the job it was
  # given and stated as such — never a side effect. The absent POST stub is the
  # assertion.
  def test_a_claude_session_is_refused_without_yes
    with_body_file("# Auto-merge review\n\nSomething else entirely.\n") do |path|
      _, err = run_dev(session: true, tty: true, api: { "GET /agent/playbooks/#{KEY}" => row }) do
        cmd_agent_playbook([KEY, "--write", path])
      end

      assert_equal 1, @exit_status
      assert_includes err, "inside a Claude session without --yes"
    end
  end

  # A pipe or a cron run has nobody to answer a prompt, and defaulting to yes
  # there would append on a run that never asked to.
  def test_a_non_terminal_is_refused_without_yes
    with_body_file("# Auto-merge review\n\nSomething else entirely.\n") do |path|
      _, err = run_dev(tty: false, api: { "GET /agent/playbooks/#{KEY}" => row }) do
        cmd_agent_playbook([KEY, "--write", path])
      end

      assert_equal 1, @exit_status
      assert_includes err, "stdin is not a terminal"
    end
  end

  # An append-only log whose entries may be duplicates cannot answer "what changed
  # and when", which is the only question it exists to answer. Trailing whitespace
  # is not a change because the runner strips before handing the text over, so an
  # editor adding a final newline must not become a version.
  def test_an_unchanged_body_appends_nothing_even_with_yes
    with_body_file(BODY + "\n\n") do |path|
      out, = run_dev(api: { "GET /agent/playbooks/#{KEY}" => row }) do
        cmd_agent_playbook([KEY, "--write", path, "--yes"])
      end

      assert_includes out, "already this text"
      assert_includes out, "Nothing appended"
    end
  end

  # The mistake nothing downstream reports: an append under a typo'd key succeeds,
  # permanently, while the producer keeps running the procedure the operator meant
  # to replace. --yes must NOT be enough to get past it — consent to append is not
  # consent to start a lineage.
  def test_an_unknown_key_needs_create_even_with_yes
    with_body_file(BODY) do |path|
      _, err = run_dev(api: { "GET /agent/playbooks/typo-key" => nil }) do
        cmd_agent_playbook(["typo-key", "--write", path, "--yes"])
      end

      assert_equal 1, @exit_status
      assert_includes err, "would START a new one"
      assert_includes err, "--create"
    end
  end

  def test_create_starts_a_new_lineage_and_says_it_is_new
    sent = nil
    api = {
      "GET /agent/playbooks/brand-new" => nil,
      "POST /agent/playbooks" => ->(payload) { sent = payload; row(key: "brand-new") },
    }
    with_body_file(BODY) do |path|
      out, = run_dev(api: api) { cmd_agent_playbook(["brand-new", "--write", path, "--create", "--yes"]) }

      assert_includes out, "NEW playbook, no versions yet"
      assert_includes out, "+ # Auto-merge review"
    end
    assert_equal "brand-new", sent[:key]
  end

  # A body that resolves to nothing is a hard claim failure (ISS-360). Refusing it
  # here costs an operator one message; letting it through costs a producer run.
  def test_an_empty_file_is_refused_before_any_request
    with_body_file("   \n\n") do |path|
      _, err = run_dev(api: {}) { cmd_agent_playbook([KEY, "--write", path, "--yes"]) }

      assert_equal 1, @exit_status
      assert_includes err, "empty"
    end
  end

  def test_a_missing_file_is_refused_before_any_request
    _, err = run_dev(api: {}) { cmd_agent_playbook([KEY, "--write", "/nope/nothing.md", "--yes"]) }

    assert_equal 1, @exit_status
    assert_includes err, "No such file"
  end

  # ---- argument errors ----
  #
  # All of these exit before any request, so an empty stub set is the assertion
  # that nothing was read or written on the way to the error.

  def test_the_three_modes_are_mutually_exclusive
    _, status = capture_stderr_and_exit { parse_agent_playbook_args([KEY, "--versions", "--write", "f"]) }
    assert_equal 1, status
  end

  def test_a_key_that_is_not_url_safe_is_rejected_as_an_argument_error
    out, status = capture_stderr_and_exit { parse_agent_playbook_args(["../../etc/passwd"]) }
    assert_equal 1, status
    assert_includes out, "not a valid playbook key"
  end

  def test_create_without_write_is_an_argument_error
    out, status = capture_stderr_and_exit { parse_agent_playbook_args([KEY, "--create"]) }
    assert_equal 1, status
    assert_includes out, "--create applies only to --write"
  end

  def test_yes_without_write_is_an_argument_error
    out, status = capture_stderr_and_exit { parse_agent_playbook_args([KEY, "--yes"]) }
    assert_equal 1, status
    assert_includes out, "--yes applies only to --write"
  end

  # ---- the pure pieces ----

  def test_the_diff_elides_distant_context_and_says_how_much
    before = (1..12).map { |i| "line #{i}" }.join("\n")
    after = before.sub("line 7", "line seven")
    lines = Agent::Playbook.diff_lines(before, after)

    assert_includes lines, "- line 7"
    assert_includes lines, "+ line seven"
    assert_includes lines, "  line 4"
    refute_includes lines, "  line 1"
    assert_includes lines, "  ... 3 unchanged lines"
  end

  def test_a_new_playbook_diffs_as_all_additions
    assert_equal ["+ # Title", "+ ", "+ Step one."], Agent::Playbook.diff_lines("", "# Title\n\nStep one.\n")
  end

  def test_changed_ignores_trailing_whitespace_only
    refute Agent::Playbook.changed?("a\nb", "a\nb\n\n")
    assert Agent::Playbook.changed?("a\nb", "a\nc")
    assert Agent::Playbook.changed?("a\nb", "a\n\nb")
  end

  def test_the_write_gate_defaults_to_refusing
    assert_equal :append, Agent::Playbook.write_gate(assume_yes: true, interactive: false, ai_session: true).first
    assert_equal :prompt, Agent::Playbook.write_gate(assume_yes: false, interactive: true, ai_session: false).first
    assert_equal :refuse, Agent::Playbook.write_gate(assume_yes: false, interactive: true, ai_session: true).first
    assert_equal :refuse, Agent::Playbook.write_gate(assume_yes: false, interactive: false, ai_session: false).first
  end
end
