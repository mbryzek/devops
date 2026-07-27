#!/usr/bin/env ruby
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/common'
require_relative 'test_helper'

# The per-session DB name is the whole isolation guarantee of `claude-db`: two
# sessions that compute the same name share one database, and one session's
# in-flight migration then breaks the other's test run against code that never
# had it. So the name must be unique per session or the tool must refuse to
# answer — never a machine-wide default that merely looks isolated.
class TestDbImagesSessionId < Minitest::Test
  include DevTestSupport

  def setup
    @saved_sid = ENV['CLAUDE_SESSION_ID']
  end

  def teardown
    if @saved_sid.nil?
      ENV.delete('CLAUDE_SESSION_ID')
    else
      ENV['CLAUDE_SESSION_ID'] = @saved_sid
    end
  end

  def with_cwd(dir)
    Dir.chdir(dir) { yield }
  end

  # ── CLAUDE_SESSION_ID wins ────────────────────────────────────────────────

  def test_explicit_session_id_is_used_verbatim
    ENV['CLAUDE_SESSION_ID'] = 'my-feature'
    assert_equal 'my-feature', DbImages.session_id
  end

  def test_explicit_session_id_is_stripped
    ENV['CLAUDE_SESSION_ID'] = "  my-feature\n"
    assert_equal 'my-feature', DbImages.session_id
  end

  def test_blank_session_id_is_ignored
    ENV['CLAUDE_SESSION_ID'] = '   '
    Dir.mktmpdir do |tmp|
      with_cwd(tmp) do
        _stderr, status = capture_stderr_and_exit { DbImages.session_id }
        refute_nil status, 'a blank CLAUDE_SESSION_ID must not be accepted as a name'
      end
    end
  end

  # ── feature-dir fallback ──────────────────────────────────────────────────

  def test_feature_dir_name_from_the_feature_dir_itself
    assert_equal 'my-feature', DbImages.feature_dir_name("#{DbImages::AI_DIR}/my-feature")
  end

  # Every repo the session clones lives inside the feature dir, so the name must
  # not change with which repo happens to be the cwd.
  def test_feature_dir_name_is_the_same_from_any_repo_inside_it
    %w[platform workers playbook-admin/src/lib].each do |inner|
      assert_equal 'my-feature', DbImages.feature_dir_name("#{DbImages::AI_DIR}/my-feature/#{inner}")
    end
  end

  def test_feature_dir_name_is_nil_outside_the_ai_dir
    assert_nil DbImages.feature_dir_name(File.expand_path('~/code/platform'))
    assert_nil DbImages.feature_dir_name('/tmp')
  end

  def test_feature_dir_name_is_nil_for_the_ai_dir_itself
    assert_nil DbImages.feature_dir_name(DbImages::AI_DIR)
  end

  # A sibling directory whose name merely STARTS with the ai dir's path is not
  # inside it (~/code/ai-trash exists on this machine).
  def test_feature_dir_name_is_nil_for_a_sibling_with_a_prefix_name
    assert_nil DbImages.feature_dir_name("#{DbImages::AI_DIR}-trash/whatever")
  end

  # ── refusing to guess ─────────────────────────────────────────────────────

  def test_exits_with_instructions_when_nothing_identifies_the_session
    ENV.delete('CLAUDE_SESSION_ID')
    Dir.mktmpdir do |tmp|
      with_cwd(tmp) do
        stderr, status = capture_stderr_and_exit { DbImages.session_id }
        refute_nil status, 'must exit rather than invent a shared name'
        assert_includes stderr, 'CLAUDE_SESSION_ID'
        assert_includes stderr, 'refusing to share'
      end
    end
  end

  # The regression guard: the old fallback was "#{user}_#{hostname}", identical
  # for every session on the machine.
  def test_never_falls_back_to_a_machine_wide_name
    ENV.delete('CLAUDE_SESSION_ID')
    require 'socket'
    host = Socket.gethostname.split('.').first
    Dir.mktmpdir do |tmp|
      with_cwd(tmp) do
        stderr, _status = capture_stderr_and_exit { DbImages.session_id }
        refute_includes stderr, host, 'the hostname must play no part in naming a session DB'
      end
    end
  end

  # ── db_name ───────────────────────────────────────────────────────────────

  def test_db_name_sanitizes_a_feature_name
    assert_equal 'platformdb_sess_cr_login_ladder', DbImages.db_name('cr-login-ladder')
  end

  def test_db_name_fits_the_postgres_identifier_limit
    assert_operator DbImages.db_name('x' * 200).length, :<=, 63
  end
end
