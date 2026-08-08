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
    # WHERE a credential is read from. Two layouts exist in the env repo and the
    # difference is not cosmetic: `apps/<app>/env/*.env` holds what an APP boots
    # with, `api_keys/<file>` holds what a HUMAN or a tool authenticates with.
    # Putting a tooling credential in an app's env file is what produced ISS-635
    # — `NEWRELIC_USER_KEY` sat in `apps/platform/env/production.env`, was read by
    # no application anywhere, was never rotated with the live key, and answered
    # 401 to every session that followed the playbook's instruction to source it.
    #
    # Both answer with the same four states so `probe` does not care which it got.
    AppEnv = Struct.new(:app, :environment, keyword_init: true) do
      def label = "env/apps/#{app}/env (#{environment})"
      def read(name) = EnvironmentVariables.lookup(app, environment, name)
    end

    # One credential per file; the whole file IS the value. `file` rather than
    # `name` because the two differ on purpose — the file is named for the
    # SERVICE (`newrelic`), the variable for what the service calls the thing
    # (`NEWRELIC_USER_KEY`).
    KeyFile = Struct.new(:file, keyword_init: true) do
      def label = "env/api_keys/#{file}"
      def read(_name) = EnvRepo.read_secret("api_keys/#{file}")
    end

    # The same directory, for a service whose credential is a TUPLE: one file per
    # service, KEY=VALUE lines inside it, each `Credential` reading its own name
    # out of it. Court Reserve is the case — a login is an email AND a password,
    # and neither half authenticates anything on its own.
    #
    # Not two `KeyFile`s, and the difference is provisioning rather than taste.
    # Two files can be half-written, which produces the one state nobody planned
    # for: a session told it HAS a Court Reserve credential, holding an email and
    # no password. One file is either there or it is not.
    #
    # Not `AppEnv` either, for the ISS-635 reason stated above: this is what a
    # TOOL authenticates with, not what an app boots with, and a tooling
    # credential filed under an app's env is one no application reads and nobody
    # rotates.
    KeyVars = Struct.new(:file, keyword_init: true) do
      def label = "env/api_keys/#{file}"
      def read(name) = EnvRepo.read_var("api_keys/#{file}", name)
    end

    # One credential, where it is read from, and what stops working without it.
    #
    # `name` is both the key looked up in the env repo AND the environment
    # variable the session receives — deliberately the same string, so a session
    # reading its assignment can use the name it was told without a translation
    # step.
    #
    # `usage_example` is per-credential and not decorative: the assignment block
    # tells a session how to PASS the key, and one API's header is another API's
    # 401. It must be a shape that carries `$NAME` rather than a value.
    #
    # There is no `required` flag and no exit code riding on this. A missing
    # credential must not stop a runner from claiming the ninety-odd percent of
    # issues that never touch an external API; what it must do is stop a session
    # from DISCOVERING the gap halfway through, which is what the prompt section
    # is for.
    Credential = Struct.new(:name, :source, :required_by, :how_to_provide, :usage_example,
                            keyword_init: true) do
      def source_label = source.label
    end

    # One half of the Court Reserve login. Everything except the variable name is
    # shared by CONSTRUCTION rather than by copy: two entries describing one
    # credential must not be able to drift into telling a session two different
    # stories about where its login comes from.
    def self.court_reserve(name)
      Credential.new(
        name: name,
        source: KeyVars.new(file: "court-reserve"),
        required_by: "logging in to Court Reserve from a crawler harness — `recon-refunds.ts` in the " \
                     "workers repo, and any live re-crawl — the only way a session can VERIFY a change " \
                     "to crawler behaviour against the live site rather than arguing it from recorded " \
                     "production console logs and letting the next scheduled crawl be the test (ISS-1012). " \
                     "A harness run connects DIRECTLY, where production always crawls through a " \
                     "residential proxy, so expect a Cloudflare challenge and keep live runs few — a " \
                     "flagged test account helps nobody",
        how_to_provide: "put CR_EMAIL and CR_PASSWORD in the env repo at api_keys/court-reserve, as one " \
                        "KEY=VALUE file (both halves or neither). It MUST be a login scoped to a Court " \
                        "Reserve TEST org — picklejar-test — never a real club's credential and never an " \
                        "account with write access: every session on this runner inherits whatever is " \
                        "put here",
        # A shell assignment PREFIX, deliberately, rather than a tidier bare
        # command. The prefix is consumed by the shell — the harness is exec'd
        # with argv `npx tsx recon-refunds.ts`, and the values reach it only
        # through its environment — so this satisfies "pass it explicitly"
        # without putting a secret on a command line that `ps` shows to every
        # sibling session for the several minutes a crawl takes (ISS-961, §4).
        usage_example: 'CR_EMAIL="$CR_EMAIL" CR_PASSWORD="$CR_PASSWORD" RECON_OUT=/tmp/recon ' \
                       'npx tsx recon-refunds.ts',
      )
    end

    CREDENTIALS = [
      Credential.new(
        name: "PLAYBOOK_CLAUDE_KEY",
        # `development`, not `production`, and the distinction is not cosmetic
        # even though today both resolve through common.env to the same value:
        # the day someone splits them, a session on a laptop must be the one
        # holding the development key.
        source: AppEnv.new(app: "platform", environment: "development"),
        required_by: "calling api.anthropic.com directly — the only way a session can VERIFY code " \
                     "whose subject is the Claude API's own behaviour, rather than designing it " \
                     "against the documentation and shipping the request shape unproven (ISS-565)",
        how_to_provide: "set PLAYBOOK_CLAUDE_KEY in the env repo's apps/platform/env/common.env " \
                        "(it is already there in a healthy checkout — an absence usually means the " \
                        "repo is locked or missing, not that the key was never issued)",
        usage_example: 'curl -H "x-api-key: $PLAYBOOK_CLAUDE_KEY" -H "anthropic-version: 2023-06-01" ...',
      ),
      # ISS-635. The playbooks that read production out of NewRelic told the
      # session to source this key from `bin/app-env --app platform --env production`,
      # and that instruction failed twice over: the value there is revoked (401),
      # and `--format sh` emits bare assignments, so `eval`ing it sets a shell
      # variable that no child process ever sees. Both failures are SILENT — an
      # unset key produces an empty NRQL result, which reads exactly like a
      # healthy graph. Handing the live key down removes the instruction, and
      # with it both ways of misreading it.
      Credential.new(
        name: "NEWRELIC_USER_KEY",
        source: KeyFile.new(file: "newrelic"),
        required_by: "querying NewRelic NerdGraph (account 7724695) — the ONLY production signal the " \
                     "daily error-triage and platform-memory playbooks run on, and an unauthenticated " \
                     "query returns an empty result set rather than an error (ISS-635)",
        how_to_provide: "put a live NewRelic USER key (NRAK-...) in the env repo at api_keys/newrelic " \
                        "— NOT in an app's env file, which no application reads and nobody rotates",
        usage_example: 'curl -X POST https://api.newrelic.com/graphql ' \
                       '-H "Content-Type: application/json" -H "API-Key: $NEWRELIC_USER_KEY" ...',
      ),
      # ISS-1023, and it is ISS-565's shape a third time. ISS-1012 changed how the
      # refunds crawler asks Court Reserve for a date window — behaviour whose
      # only real test is a live crawl — and the session had no Court Reserve
      # login, so `recon-refunds.ts` (the repo's own harness, which exists for
      # exactly this) could not be run at all. workers#207 shipped with its
      # central behaviour argued from production console logs, and the first
      # scheduled crawl after deploy became the actual test, on real clubs.
      #
      # THE PAIR IS THE POINT: two entries, one file. See `KeyVars`.
      #
      # WHY THIS IS NOT DEAD WEIGHT WHILE THAT FILE IS ABSENT. Listing a
      # credential nobody has provisioned yet is the ENTIRE ISS-570 mechanism:
      # `credentials_section` renders an absent credential as "cannot be closed
      # out here", names `dev issues workaround`, and says it BEFORE the session
      # plans. Today a crawler session is told nothing about Court Reserve at
      # all, so it works the gap out for itself once the code already exists —
      # which is the failure, not the missing secret. The day the file lands,
      # every session gets the login with no further change here.
      court_reserve("CR_EMAIL"),
      court_reserve("CR_PASSWORD"),
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
        when :no_file  then "#{credential.source_label} does not exist — usually no env repo beside this devops " \
                            "checkout, which is expected when `dev` runs from a clone inside a feature dir " \
                            "rather than ~/code/devops"
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

      status, value = credential.source.read(credential.name)
      [status, value, status == :present ? :env_repo : nil]
    end
  end
end
