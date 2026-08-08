require 'json'

module Agent
  # The credential the daily `product-owner` producer needs to log in to Acumen
  # and review it as a real user.
  #
  # Why this gets its own check rather than joining Agent::Credentials: that
  # registry reads the env repo, and this file lives under ~/.platform. The
  # split is not ideal — ISS-1109 proposes consolidating every agent credential
  # into ~/code/env/agents precisely so a second runner can sync them — but
  # until that lands, a required file with no registry entry is invisible, and
  # invisible is how a runner ends up silently unable to do a whole class of
  # work.
  #
  # Deliberately NOT part of the doctor's exit code, for the reason stated at
  # lib/agent/credentials.rb:96-102: a missing credential must not stop a runner
  # from claiming the ninety-odd percent of issues that never touch it. Absent
  # this file, exactly one producer degrades.
  module ProductOwner
    # The apps whose logins this file is expected to carry. Playbook is absent
    # on purpose: that review mints a login token from the AI token and bounces
    # through /sso/redirect, so it needs no stored password.
    REQUIRED_APPS = %w[acumen].freeze

    # :ok         present, 0600, parses, carries every required app
    # :absent     not there at all
    # :bad_mode   present but group- or world-readable — a secret on a shared
    #             machine, reported loudly and never silently chmod'ed
    # :malformed  present but not valid JSON
    # :incomplete parses, but an app the review needs has no entry
    # :unreadable exists and could not be read (permissions, io error)
    Result = Struct.new(:state, :path, :mode, :missing, :message, keyword_init: true) do
      def ok? = state == :ok

      # The literal command, for the same reason Agent::ClaudeConfig::Result#remedy
      # is a command and not a description: the one question a broken machine
      # asks is "what do I type".
      def remedy
        case state
        when :absent
          "create it: `umask 077 && $EDITOR #{path}` — one object per app, " \
            "each with url/username/password. Apps needed: #{REQUIRED_APPS.join(', ')}"
        when :bad_mode
          "`chmod 600 #{path}` — it is currently #{mode}"
        when :malformed
          "it is not valid JSON: #{message}"
        when :incomplete
          "add an entry for: #{missing.join(', ')}"
        when :unreadable
          "#{path} could not be read: #{message}"
        end
      end
    end

    module_function

    # Agent::Paths owns the resolution so DEV_AGENT_STATE_DIR stays the test
    # seam and this can never disagree with the rest of the agent's state dir.
    def path = Agent::Paths.product_owner_credentials_file

    # Read-only. `dev agent doctor` must be able to report this machine without
    # changing it — a doctor with a side effect cannot tell you what state you
    # were in when you ran it. In particular it never chmods: a file that is
    # world-readable has already been exposed, and quietly tightening it hides
    # that from the person who needs to rotate the secret.
    def state
      file = path
      return result(:absent, message: "#{file} does not exist") unless File.exist?(file)

      mode = format("%04o", File.stat(file).mode & 0o7777)
      return result(:bad_mode, mode: mode, message: "#{file} is #{mode}, expected 0600") unless mode == "0600"

      begin
        parsed = JSON.parse(File.read(file))
      rescue JSON::ParserError => e
        return result(:malformed, mode: mode, message: e.message)
      rescue SystemCallError => e
        return result(:unreadable, mode: mode, message: e.message)
      end

      missing = REQUIRED_APPS.reject { |app| complete_entry?(parsed[app]) }
      unless missing.empty?
        return result(:incomplete, mode: mode, missing: missing,
                                   message: "#{file} has no usable entry for #{missing.join(', ')}")
      end

      result(:ok, mode: mode, message: "#{file} (#{mode}), apps: #{REQUIRED_APPS.join(', ')}")
    end

    # An entry that exists but has a blank password is worse than none: the
    # session would attempt a login, fail, and report the product unreachable
    # rather than the credential missing.
    def complete_entry?(entry)
      return false unless entry.is_a?(Hash)

      %w[username password].all? { |k| entry[k].is_a?(String) && !entry[k].strip.empty? }
    end

    def result(state, mode: nil, missing: [], message: nil)
      Result.new(state: state, path: path, mode: mode, missing: missing, message: message)
    end
  end
end
