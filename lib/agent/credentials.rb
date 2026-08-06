require 'environment_variables'

# The external-API credentials a claimed session is given, and — when one is
# absent — the fact that it is absent, told to the session before it plans
# (ISS-570).
#
# WHY THIS EXISTS. ISS-565 asked for a check that validates our structured-output
# schemas by asking the Claude API. The session built it, tested its offline
# behaviour, and could not exercise a single request against api.anthropic.com,
# because `PLAYBOOK_CLAUDE_KEY` was unset in its environment. It designed the
# request shape against the documentation instead and said so.
#
# The credential was on the machine the whole time. `env/apps/platform/env`
# carries it — it is how the platform itself talks to Claude in production — and
# `Agent::Tick#child_env` simply never passed it down, so every session ran
# blind to a secret sitting one directory away from the checkout it was started
# from. That is the entire bug: not a missing key, a key nobody handed over.
#
# TWO PUBLIC FACES, AND THE SPLIT IS THE SAFETY PROPERTY. `check` reports
# WHETHER a credential resolves and never carries its value, so it is safe to
# print, log, and render into a prompt. `resolve` returns values, is called from
# exactly one place (the spawn environment), and its result is never printed.
# Keeping them apart is what stops a doctor listing, a tick log line, or an
# exception's `inspect` from leaking a live API key into a file a PR might
# quote.
#
# WHY NOT `ANTHROPIC_API_KEY`. That name is exactly the one that must never
# appear here. The process this environment is handed to IS `claude`, and the
# CLI resolves `ANTHROPIC_API_KEY` as its own credential — so exporting the key
# under that name would silently move every autonomous session off Mike's
# subscription and onto per-token API billing, for every issue in the queue,
# with nothing in the output to say so. The session gets `PLAYBOOK_CLAUDE_KEY`,
# the same name `core/conf/base.conf` already reads, and passes it explicitly to
# whatever it is verifying. A test asserts this rather than trusting the comment.
#
# WHY THE ENV REPO AND NOT THE LAUNCHD ENVIRONMENT. It is where the secret
# already lives, versioned and git-crypt'd, which is the mechanism ISS-570 asked
# for; adding a second home for the same key is a second thing to rotate. Reads
# go through `EnvironmentVariables.lookup`, which deliberately does NOT unlock
# git-crypt on the way past — a locked repo is a state this REPORTS (:locked), a
# state a session is forbidden from fixing, and the one thing a "tell me whether
# this secret is set" call must never do as a side effect.
module Agent
  module Credentials
    # One credential, where it is read from, and what stops working without it.
    #
    # `name` is both the key looked up in the env repo AND the environment
    # variable the session receives — deliberately the same string, so a session
    # reading its assignment can use the name it was told without a translation
    # step.
    #
    # There is no `required` flag and no exit code riding on this. A missing
    # credential must not stop a runner from claiming the ninety-odd percent of
    # issues that never touch an external API; what it must do is stop a session
    # from DISCOVERING the gap halfway through, which is what the prompt section
    # is for.
    Credential = Struct.new(:name, :app, :environment, :required_by, :how_to_provide,
                            keyword_init: true) do
      def source_label = "env/apps/#{app}/env (#{environment})"
    end

    CREDENTIALS = [
      Credential.new(
        name: "PLAYBOOK_CLAUDE_KEY",
        app: "platform",
        # `development`, not `production`, and the distinction is not cosmetic
        # even though today both resolve through common.env to the same value:
        # the day someone splits them, a session on a laptop must be the one
        # holding the development key.
        environment: "development",
        required_by: "calling api.anthropic.com directly — the only way a session can VERIFY code " \
                     "whose subject is the Claude API's own behaviour, rather than designing it " \
                     "against the documentation and shipping the request shape unproven (ISS-565)",
        how_to_provide: "set PLAYBOOK_CLAUDE_KEY in the env repo's apps/platform/env/common.env " \
                        "(it is already there in a healthy checkout — an absence usually means the " \
                        "repo is locked or missing, not that the key was never issued)",
      ),
    ].freeze

    # What `check` reports. Carries a STATUS, never a value — see the module
    # comment. `source` is where the answer came from: :process_env when the
    # runner's own environment already carries it, :env_repo when it was read
    # out of the env checkout, nil when it did not resolve at all.
    Found = Struct.new(:credential, :status, :source, keyword_init: true) do
      def name = credential.name
      def present? = status == :present
      def absent? = !present?

      # Why it did not resolve, phrased for whoever has to act on it. The three
      # absent states call for three different responses and collapsing them
      # would report a confident wrong diagnosis: :missing is "add the
      # variable", :locked is "this machine cannot read the secrets repo", and
      # :no_file is "you are not looking at an env repo at all".
      def explanation
        case status
        when :present  then "resolved from #{source == :process_env ? "the runner's environment" : credential.source_label}"
        when :missing  then "not set in #{credential.source_label}"
        when :locked   then "#{credential.source_label} is git-crypt LOCKED on this machine, and neither " \
                            "the tick nor a session may unlock it"
        when :no_file  then "no env repo beside this devops checkout (#{credential.source_label} does not exist) " \
                            "— expected when `dev` runs from a clone inside a feature dir rather than ~/code/devops"
        end
      end
    end

    module_function

    # Status only, for the doctor, the session prompt, and anything else that
    # prints. Returns Array<Found>; never returns a secret.
    #
    # `env` is the process environment to read, and it is a parameter for the
    # same reason `probe`'s is: the answer depends on TWO sources, and a caller
    # that can only control one of them cannot control the answer. See `probe`.
    def check(credentials: CREDENTIALS, env: ENV)
      credentials.map do |credential|
        status, _value, source = probe(credential, env: env)
        Found.new(credential: credential, status: status, source: source)
      end
    end

    # The values to ADD to a spawned session's environment. The one caller is
    # `Agent::Tick#child_env`, and its result is never logged.
    #
    # Credentials the runner's own environment already carries are deliberately
    # omitted: `Process.spawn` merges this hash over an inherited ENV, so the
    # child gets those anyway, and re-listing them would pull a secret through
    # more code for no effect.
    def resolve(credentials: CREDENTIALS, env: ENV)
      credentials.each_with_object({}) do |credential, resolved|
        status, value, source = probe(credential, env: env)
        next unless status == :present && source == :env_repo
        resolved[credential.name] = value
      end
    end

    # [status, value, source]. The single read, so `check` and `resolve` cannot
    # disagree about what this machine has.
    #
    # The process environment wins over the env repo so an operator can override
    # one key from `.zprofile` without editing (or unlocking) the secrets repo.
    #
    # That precedence makes every result depend on the AMBIENT ENVIRONMENT of
    # whatever process is asking, which is why `env` is injectable all the way
    # out to `check` and `resolve` rather than only here. A caller that stubs
    # `EnvironmentVariables.lookup` but leaves `env` defaulted has not pinned the
    # answer at all — the process environment short-circuits before the stub is
    # ever consulted, and the assertion silently becomes a statement about the
    # machine. Exactly that failed on the agent runners and nowhere else
    # (ISS-613): ISS-570 exports PLAYBOOK_CLAUDE_KEY into every spawned session,
    # so the fleet the credential feature was built for is the one fleet whose
    # environment defeats a test of it.
    def probe(credential, env: ENV)
      inherited = env[credential.name].to_s
      return [:present, inherited, :process_env] unless inherited.empty?

      status, value = EnvironmentVariables.lookup(credential.app, credential.environment, credential.name)
      [status, value, status == :present ? :env_repo : nil]
    end
  end
end
