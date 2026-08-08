require 'api_client'

# The production data a claimed session can READ, told to it before it plans —
# the same contract `Agent::Credentials` provides for external-API keys, for the
# one signal that is not a key at all.
#
# WHY THIS EXISTS. ISS-1056 was filed by the `product-owner` producer with
# evidence it had gathered from acumen's own API: `GET /g/<group>/duplicate/
# transactions?status=pending_review` returns HTTP 500 for row ordinals 673, 674,
# 675, 676, 677, 679 and 680 and 200 for 678, "checked one row at a time with
# limit=1". The session that fixed it concluded there was "no credential for
# trueacumen.com on this runner", established the root cause entirely from git
# archaeology, and shipped a migration naming four stale enum values it had
# INFERRED and a delete of rows it had never counted (ISS-1062).
#
# The credential was on the machine the whole time. `~/.platform/devops_acumen`
# is a live session, `ApiClient::SESSION_CONFIG` has known how to present it
# since acumen shipped, and the producer had just used it. Re-running the
# producer's own probe from a session takes six seconds and reproduces the
# ordinals exactly. Nothing was missing except the sentence that says so — the
# recipe was written down in ONE place, the body of the `product-owner` playbook,
# which a fix session never reads.
#
# So this is not a new capability. It is the existing one, named in the
# assignment block, where a session reads it before it decides what it can
# establish. Same lesson as ISS-565/ISS-570 and stated there: an absent
# credential looks exactly like a credential nobody thought to look for.
#
# PRESENCE ONLY, AND NO NETWORK. `check` reports WHETHER a credential file is
# there and never carries its contents, so it is safe to render into prompt.md —
# which lands in the log tree and gets quoted into issue comments.
#
# It deliberately does not VALIDATE the session by calling the API, even though
# unlike an API key a stored session expires and one round-trip would settle it.
# Prompt building would then depend on the network, and the failure is asymmetric:
# a transient blip reported as "NOT available" tells a session to give up on
# evidence it could in fact have gathered, which is precisely the outcome this
# module exists to prevent. Presence is the cheap, deterministic half; validity is
# settled at the point of use, by one call the prompt tells the session to make,
# against a command whose expiry path hands back the `dev issues handoff` line
# (`dev auth login --app acumen` is interactive and no session can run it).
module Agent
  module ProdRead
    # One readable production API, the identity a session reads it AS, and what
    # it must not do with what comes back.
    #
    # `guardrails` is per-target rather than a shared footer because they are not
    # the same rules. Acumen is Mike's real household finances, so its rules are
    # about what may be QUOTED out of a read; the platform host is our own
    # operational data and carries no such constraint. Collapsing them would
    # either under-warn on acumen or cargo-cult a finance warning onto a query
    # stats table.
    # `confirm_path` is per-target and is not decorative: it is the cheapest GET
    # this identity is actually entitled to, and one API's is another API's 404.
    # Acumen answers `/sessions/current` because the credential IS a session; the
    # platform host has no such route for an API token and returns 404 for it,
    # which a session would read as "the credential is broken" — the confident
    # wrong diagnosis this whole module exists to stop.
    # `allowed_group` is the one guardrail here that is ENFORCED rather than
    # written down, and the asymmetry is deliberate. Acumen's stored session is
    # Mike's, and `multi_groups` is true on it: `Cameron`, `Julien` and
    # `Bergen Youth Enrichment` are other people's households, reachable from this
    # credential by nothing more than a different `/g/<key>/` in a path a session
    # is otherwise typing offsets into. Every other rule in `guardrails` governs
    # what may be QUOTED, which no code can check; this one governs what is
    # REQUESTED, which is one regex. Prose is the wrong instrument for the only
    # rule a typo can break.
    #
    # It is a literal on purpose. Reading the group out of `/sessions/current` at
    # call time would mean "whichever household the session happens to have
    # selected", which is not a guardrail — it is a description of the state the
    # guardrail exists to constrain.
    #
    # nil where the concept does not apply: the platform host has no per-tenant
    # path prefix and the AI actor's authorization is enforced server-side.
    Target = Struct.new(:app, :product, :host, :identity, :answers, :example, :confirm_path,
                        :allowed_group, :guardrails, :how_to_provide, keyword_init: true) do
      # The group a path addresses, or nil for one that addresses none
      # (`/sessions/current`). Only meaningful where `allowed_group` is set.
      def group_in(path) = path.to_s[%r{\A/g/([^/?#]+)}, 1]

      # nil when the request is permitted; otherwise why it is not.
      def refusal_for(path)
        return nil if allowed_group.nil?

        group = group_in(path)
        return nil if group.nil? || group == allowed_group
        "path addresses the `#{group}` group, and only `#{allowed_group}` may be read. The other " \
          "groups on this session are other people's households."
      end

      # The file a SESSION will actually present for this app, which is not
      # always the file a human would. `ApiClient.auth_header_for` sends the AI
      # actor's token for everything on the platform host and acumen's own stored
      # session for acumen, so the probe follows that same split.
      #
      # Asking `ApiClient.credential_for?` instead would be wrong here even
      # though it looks more direct: it branches on `CLAUDECODE`, which is set in
      # the session and unset in the dispatcher that builds the prompt, so the
      # answer would describe whichever process happened to ask (ISS-613).
      def credential_file
        app == "acumen" ? ApiClient.session_file("acumen", false) : ApiClient.ai_token_file(false)
      end
    end

    TARGETS = [
      Target.new(
        app: "acumen",
        product: "Acumen",
        host: "https://api.trueacumen.com",
        identity: "Mike's own logged-in session, with `Bryzek Family` already selected",
        answers: "confirming an on-screen or per-row observation in a `product-owner:acumen:*` issue " \
                 "rather than inferring it from the repos — the gap that shipped an inferred migration " \
                 "in ISS-1056 (ISS-1062)",
        example: "dev prod get --app acumen '/g/bryzek/duplicate/transactions?status=pending_review&limit=1&offset=675'",
        confirm_path: "/sessions/current",
        allowed_group: "bryzek",
        guardrails: [
          "**Read-only, and only `Bryzek Family`** (`/g/bryzek/...`). The session can reach other " \
          "households and `dev prod get` refuses them — those are other people's finances.",
          "**Never quote a real merchant name, amount, balance or account identifier** into an issue, " \
          "PR, comment, plan, commit message or test fixture. Cite shapes, counts and percentages — " \
          "\"seven rows in this group fail to decode\" — never a transaction.",
          "**Never initiate or complete a Plaid link or reauthentication flow.** That is a bank login " \
          "and is prohibited outright by §3.",
        ],
        how_to_provide: "a human runs `dev auth login --app acumen` on this runner — it is an " \
                        "interactive password prompt, so no session can do it",
      ),
      Target.new(
        app: "platform",
        product: "Platform",
        host: "https://idempotent.io",
        identity: "#{ApiClient::AI_USER_LABEL} (user `#{ApiClient::AI_USER_ID}`), the AI actor's own API token",
        answers: "reading the /dev console and any other platform GET directly, when the shaped commands " \
                 "(`dev invariants check`, `dev queries top`, `dev issues show`) do not answer the question",
        example: "dev prod get --app platform '/dev/invariant/checks?examples=100'",
        confirm_path: "/dev/features",
        guardrails: [
          "**Reads only.** Every mutation on the /dev console requires `platform_admin`, which does not " \
          "admit the AI actor by design; `dev prod get` cannot send one and would 401 if it could.",
        ],
        how_to_provide: "a human runs `dev auth ai provision` on this runner",
      ),
    ].freeze

    # What `check` reports. Carries a STATUS, never a session id — see the module
    # comment.
    Found = Struct.new(:target, :status, keyword_init: true) do
      def app = target.app
      def present? = status == :present

      def explanation
        present? ? "#{target.identity}, stored on this runner" : "no credential at #{target.credential_file}"
      end
    end

    # Whether a credential file holds anything. An empty file is treated as
    # absent on purpose: `ApiClient.session_id_for` and `ai_token` both return nil
    # for one, so reporting it as present would promise a credential the request
    # path then refuses.
    DEFAULT_PROBE = lambda do |path|
      File.file?(path) && !File.read(path).strip.empty?
    rescue SystemCallError
      false
    end

    module_function

    # Status only, for the session prompt and anything else that prints. Returns
    # Array<Found>; never returns a credential.
    #
    # `probe` is injectable for the reason `Credentials.check`'s `env` is: the
    # answer depends on the state of the machine asking, and a test that cannot
    # pin it is not a test of this code but a statement about the box it ran on.
    # Every runner has these files, so a defaulted probe would assert `:present`
    # on the fleet and nowhere else (ISS-613).
    def check(targets: TARGETS, probe: DEFAULT_PROBE)
      targets.map do |target|
        Found.new(target: target, status: probe.call(target.credential_file) ? :present : :missing)
      end
    end
  end
end
