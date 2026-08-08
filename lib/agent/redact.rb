# Secret material taken out of text that is about to be shown to somebody
# (ISS-961).
#
# WHY THIS EXISTS. A process command line is PUBLIC on these runners. `ps -U
# <uid>` shows every argument of every process the agent user owns, to every
# other process the agent user owns — and three agent sessions share one Mac
# mini. So the moment a session types a resolved credential into a command, that
# credential is readable by every sibling session for as long as the process
# lives, with nothing anywhere saying so.
#
# That is not hypothetical. A session running `api publish` under ISS-943 ran a
# routine `pgrep -fl api` to poll for its own backgrounded job. The pattern `api`
# matched OTHER sessions' long-running `npm run dev` shells — and matched them
# partly ON the secret, because `sk-ant-api03-...` contains the string it was
# searching for. Both keys the fleet hands its sessions, `PLAYBOOK_CLAUDE_KEY`
# and `NEWRELIC_USER_KEY`, went into that session's transcript in plaintext. The
# session had done nothing wrong: it never printed a credential, never echoed
# one, never pasted one. A generic process listing did it on its behalf.
#
# WHAT THIS MODULE IS FOR, AND WHAT IT IS NOT. It is the second of two defences
# and deliberately the weaker one. The first is that a secret must never be in an
# argv at all — `agent/instructions.md` §4 now says so in the terms that make it
# actionable (always `$NAME`, never the value; and a credential must never ride
# on a LONG-RUNNING command). This one covers the case where that fails anyway,
# for everything devops itself reads out of `ps`: `Agent::Processes` parses full
# command lines for the leak sweep, holds them in a public struct field, and the
# obvious next improvement to that sweep is to SAY which processes it reaped.
# The redaction runs at parse time so that improvement cannot leak, rather than
# leaving a hazard for whoever writes it.
#
# It is pattern-based, never value-based, which is a deliberate limit in both
# directions. It cannot be defeated by a key this fleet does not know it has, and
# it does not need to be handed the secrets to work — a redactor that had to read
# the env repo would be a second place credentials live, which is worse than the
# leak. The cost is that a novel token shape passes through, so this is a net,
# not a seal.
#
# SHAPE-PRESERVING IS A HARD REQUIREMENT, not a nicety. `Agent::Processes`
# classifies a process by matching TOOL_SHELL and CLAUDE_SESSION against exactly
# the string this returns, and its own comment spells out the failure that
# matters: a pattern that stops matching means the sweep finds nothing and "a
# runner buried under leaked processes reports exactly what a clean one does".
# So every rule here replaces a VALUE and leaves the surrounding structure —
# the `NAME=`, the `://`, the header name, the whitespace — exactly as it was.
# test_dev_agent_redact.rb asserts both matchers still fire on redacted input.
module Agent
  module Redact
    PLACEHOLDER = "[redacted]".freeze

    # Environment-variable names whose value is a secret by virtue of the name.
    # Matched case-insensitively against a whole `NAME=` token, so `SBT_OPTS`,
    # `CONF_DB_DEV_URL` and `DEPLOYMENT_NODES` are untouched and
    # `PLAYBOOK_CLAUDE_KEY`, `NEWRELIC_USER_KEY`, `SENDGRID_API_TOKEN` and
    # `PLAY_CRYPTO_SECRET` are not.
    #
    # `PASS` rather than `PASSWORD` so `PASSWD`, `PASSPHRASE` and a bare `PASS`
    # are all covered by one alternative; the surrounding `[A-Z0-9_]*` is what
    # lets it sit anywhere in the name.
    SECRET_NAME = /[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASS|CREDENTIAL|AUTH)[A-Z0-9_]*/i.freeze

    # A shell assignment, with the three quotings a command line actually
    # carries: bare, single-quoted, double-quoted.
    ASSIGNMENT = /\b(#{SECRET_NAME})=(?:'[^']*'|"[^"]*"|\S*)/.freeze

    # `$NAME`, `${NAME}`, `"$NAME"` — a REFERENCE to a secret, which is not a
    # secret and is deliberately left intact.
    #
    # This is diagnostic information, not tidiness. `KEY=$KEY` is a session doing
    # exactly what §4 tells it to; `KEY=sk-ant-...` is a session that inlined the
    # value and is the reason someone is reading this listing at all. Collapsing
    # both to `KEY=[redacted]` would destroy the one distinction that says which
    # of the two happened.
    VARIABLE_REFERENCE = /\A["']?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?["']?\z/.freeze

    # Tokens that are a credential wherever they appear, quoted or not, because
    # the issuer stamped a recognisable prefix on them. Unanchored on purpose:
    # these turn up inside quotes, inside a URL query string and inside an
    # `eval '...'`, and every delimiter Ruby offers would exclude one of those.
    # The prefixes are specific enough that a false positive costs a placeholder
    # in a log line, which is the cheap direction to be wrong in.
    #
    # The two this fleet actually hands out lead the list; the rest are here
    # because a session holds `gh` credentials and may well paste one, and a
    # redactor that only knows the keys we expect to leak is the redactor that
    # misses the one that does.
    ISSUED_TOKEN = %r{
      (?:
        sk-ant-[A-Za-z0-9_-]+      | # Anthropic  (PLAYBOOK_CLAUDE_KEY)
        NRAK-[A-Za-z0-9]+          | # NewRelic user key (NEWRELIC_USER_KEY)
        NRJS-[A-Za-z0-9]+          | # NewRelic browser key
        gh[pousr]_[A-Za-z0-9]+     | # GitHub classic / OAuth / user / server
        github_pat_[A-Za-z0-9_]+   | # GitHub fine-grained PAT
        glpat-[A-Za-z0-9_-]+       | # GitLab
        xox[abdprs]-[A-Za-z0-9-]+  | # Slack
        AKIA[0-9A-Z]{16}           | # AWS access key id
        sk-[A-Za-z0-9]{20,}          # OpenAI and lookalikes; LAST, so sk-ant- wins
      )
    }x.freeze

    # `scheme://user:password@host`. The credential in a connection string is the
    # userinfo password, and it is the one secret on this list that a session is
    # positively encouraged to put on a command line — `CONF_DB_DEV_URL` is
    # exported next to sbt on every Scala run. The session DB's password is not
    # interesting; the production one in the same shape is, and neither this
    # module nor `ps` can tell them apart.
    URL_PASSWORD = %r{(://[^\s:/@]+:)[^\s@/]+(@)}.freeze

    # `-H "x-api-key: sk-..."`, `-H 'Authorization: Bearer ...'`, `--header
    # "API-Key: NRAK-..."`. The exact shape `Agent::Credentials` teaches every
    # session to use, so it is the shape most likely to be in an argv on this
    # fleet. Redacted by HEADER NAME rather than by value, which is what catches
    # a token whose issuer stamped nothing recognisable on it.
    #
    # The value is `[^"'\s]+` — a single whitespace-free token, never "everything
    # up to the closing quote". An UNQUOTED `-H x-api-key: foo -X POST` would
    # otherwise have the rest of the command swallowed into the placeholder,
    # which loses the shape this whole module promises to preserve. Every real
    # token is one word; the only header value with a space in it is the
    # `Bearer`/`Basic` scheme, and that is matched separately and kept.
    AUTH_HEADER = /(?<![\w-])((?:x-api-key|api-key|authorization|x-auth-token|private-token)\s*:\s*)
                   (?:(bearer|token|basic)\s+)?
                   [^"'\s]+/ix.freeze

    module_function

    # The one entry point. Returns a string of the same shape with every value
    # the rules above recognise replaced by PLACEHOLDER.
    #
    # Order matters exactly once: ASSIGNMENT runs first so `KEY=sk-ant-...`
    # collapses to one placeholder rather than leaving a bare `KEY=` in front of
    # a second one, which reads like an empty variable and is a confusing thing
    # to hand somebody debugging a runner.
    def command(text)
      return text if text.nil?
      out = text.to_s.gsub(ASSIGNMENT) do |match|
        name = ::Regexp.last_match(1)
        value = match[(name.length + 1)..]
        value.match?(VARIABLE_REFERENCE) ? match : "#{name}=#{PLACEHOLDER}"
      end
      out = out.gsub(AUTH_HEADER) do
        scheme = ::Regexp.last_match(2)
        "#{::Regexp.last_match(1)}#{scheme ? "#{scheme} " : ''}#{PLACEHOLDER}"
      end
      out = out.gsub(URL_PASSWORD) { "#{::Regexp.last_match(1)}#{PLACEHOLDER}#{::Regexp.last_match(2)}" }
      out.gsub(ISSUED_TOKEN, PLACEHOLDER)
    end

    # Whether `command` would change anything — for a caller that wants to say
    # "this line carried a credential" without carrying it.
    def secret?(text) = command(text) != text.to_s
  end
end
