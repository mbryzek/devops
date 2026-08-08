require 'agent/redact'
require 'agent/shell'
require 'agent/toolchain'

module Agent
  # WHAT A BARE COMMAND NAME ACTUALLY MEANS ON THIS MACHINE (ISS-1033).
  #
  # WHY THIS EXISTS. `~/.zprofile` on this fleet sources `~/.alias`, and one line
  # of it is `alias ps='ps -ax'`. A LOGIN shell therefore defines it, and — this
  # is the part that surprises people who know bash — zsh expands aliases in
  # NON-INTERACTIVE shells too. So it is live in every session's Bash tool, and
  # live in `/bin/zsh -lc`, which is how launchd runs the tick and how
  # `dev agent run-op -- /bin/zsh -lc '<line>'` runs an operation.
  #
  # `-ax` is PREPENDED, and macOS `ps` will not let a later `-p` narrow it back
  # down — it is silently ignored. Measured on a runner, 2026-08-08:
  #
  #     ps -o command= -p 1566    | wc -l   ->  599
  #     ps -p 1566 -o command=    | wc -l   ->  599
  #     ps -o command= -p $$      | wc -l   ->  599   # even about MY OWN shell
  #     /bin/ps -p 1566 -o command= | wc -l ->    1
  #
  # A session that asks about ONE process gets the full argv of all 599, which on
  # a runner three sessions share is the exact leak ISS-961 exists to prevent —
  # `PLAYBOOK_CLAUDE_KEY` and `NEWRELIC_USER_KEY` in plaintext, into a transcript,
  # from a session that printed nothing and echoed nothing. ISS-961's answer was
  # to name the WIDE commands (`pgrep -fl`, `ps auxww`) and tell sessions to
  # prefer pids. That guidance cannot reach this, because here the NARROW command
  # is the wide one: `ps -p <pid>` reads as the careful choice and is identical to
  # `ps auxww`. Prose cannot warn you about a command that is only dangerous on
  # one machine. Reporting what the machine actually does can.
  #
  # THE SAME CLASS AS ISS-893/896, and worth seeing as one thing. There, a
  # `run-op` argv's bare `env` resolved to `~/code/devops/bin/env` rather than
  # `/usr/bin/env`, because devops' own bin precedes /usr/bin on this fleet's
  # PATH, and the operation died parsing its own flags. Alias and PATH shadowing
  # are two mechanisms for one fact: A BARE COMMAND NAME ON THIS FLEET IS NOT
  # RELIABLY THE BINARY YOU THINK IT IS. An absolute path is immune to both.
  #
  # WHAT THIS MODULE IS AND IS NOT. It REPORTS; it does not repair. Repair is not
  # available from here and pretending otherwise would be the worse bug: aliases
  # are not inherited through the environment, so the tick cannot unalias
  # anything on behalf of a session's shell, and the file that defines them is a
  # human's personal dotfile that no session may write (instructions.md §3). The
  # durable fix is a human deleting the line; this exists so that "is this machine
  # still doing it?" is a question `dev agent doctor` answers in one line, on
  # every runner, instead of being rediscovered by whichever session next loses a
  # transcript to it.
  #
  # Modelled on `Agent::Heap.profile_override`, which reports the same shape of
  # problem — a fully provisioned machine whose own login profile silently
  # overrides what the fleet intends — and deliberately shares its restraint:
  # never fatal, never a filed issue. A `ps` alias does not stop this box running
  # sessions, and failing provisioning over a cosmetic `ls -F` alongside it would
  # teach operators to skip the section that also carries the `ps` line.
  module LoginShell
    # Bounded for the reason everything in lib/agent is bounded: a .zprofile that
    # blocks (a network-backed tool initialising, a prompt on a non-tty) must cost
    # the doctor ten seconds and a missing section, never the tick's lock.
    PROBE_TIMEOUT_SECONDS = 10

    # `alias` with no arguments prints one `name=value` per line. The name half
    # cannot contain `=` or whitespace; the value half can contain anything,
    # including `=`, so the split is on the FIRST `=` and the rest is value.
    #
    # Anything that does not match is skipped rather than guessed at — an alias
    # whose body contains a newline prints across several lines, and a
    # continuation line parsed as a definition would invent an alias that does not
    # exist. Under-reporting a rare multi-line alias is the cheap direction to be
    # wrong in; inventing one sends an operator editing a file to delete a line
    # that is not there.
    DEFINITION = /\A([^=\s]+)=(.*)\z/.freeze

    # `name` is the word a session types. `expansion` is what it becomes, with the
    # quoting `alias` added for display stripped back off. `path` is the binary
    # the name would have resolved to WITHOUT the alias — nil when there is none,
    # which is the ordinary case (`la`, `cnb`, `dcps`) and not a finding.
    Alias = Struct.new(:name, :expansion, :path, keyword_init: true) do
      def shadow? = !path.nil?

      # `ps -> ps -ax`, and it is the arrow that makes the hazard legible: a
      # reader sees at a glance that the name did not become something else, it
      # became ITSELF plus flags. That is the invisible shape — the command still
      # is `ps`, it just silently does more, which is why no session reviewing its
      # own command line would spot it.
      def to_s = "#{name} -> #{expansion}"
    end

    module_function

    # ---- reading ----

    # THE LOGIN shell, not this process's. Asking the current process would answer
    # for whatever ran `dev`, which under launchd is not the shell a session gets
    # and by hand is whatever the operator happens to be sitting in — the exact
    # mistake `Agent::Toolchain.agent_path` and `Agent::Heap.login_shell_sbt_opts`
    # both exist to avoid, resolved here the same way for the same reason.
    #
    # `-l` WITHOUT `-i`, deliberately. `-l` sources .zprofile, which is where this
    # fleet's aliases come from, and it is faithful to what a session gets because
    # zsh expands aliases in non-interactive shells. Adding `-i` would additionally
    # source .zshrc and report aliases a `/bin/zsh -lc` operation never sees, and
    # would ask a shell with no tty to be interactive — a hang looking for an
    # excuse, on the one code path whose entire job is to not be one.
    #
    # `stderr: :inherit` for the reason Toolchain documents: a .zprofile that
    # prints a deprecation warning must not be spliced into the text this parses,
    # or the doctor reports aliases assembled out of somebody's warning banner.
    def probe
      result = Agent::Shell.capture("/bin/zsh", "-lc", "alias",
                                    timeout: PROBE_TIMEOUT_SECONDS, stderr: :inherit)
      result.ok? ? result.output : nil
    rescue Errno::ENOENT
      nil
    end

    # `alias` output -> Alias structs, resolved against `path`.
    #
    # The expansion is REDACTED here, at the boundary, exactly as
    # `Agent::Processes` redacts a command line on the way in and for the same
    # reason: an alias is a place a credential plausibly lives (`alias
    # gh-me='gh api -H "Authorization: token ghp_..."'`), this module's whole
    # output is destined for a terminal, and the person who later adds a line to
    # the doctor should not have to know that. Redacting at parse time means they
    # cannot leak whatever they print.
    def parse(text, path:)
      text.to_s.lines.filter_map do |line|
        match = DEFINITION.match(line.strip)
        next unless match
        name = match[1]
        Alias.new(name: name,
                  expansion: Agent::Redact.command(unquote(match[2])),
                  path: Agent::Toolchain.which(name, path: path))
      end
    end

    # zsh single-quotes a value that needs it and escapes interior quotes as
    # `'\''`. Undone for display only — nothing here re-executes the string, so
    # the goal is a line an operator can read against their own `~/.alias`, not a
    # round-trip.
    def unquote(value)
      return value unless value.start_with?("'") && value.end_with?("'") && value.length >= 2
      value[1..-2].gsub("'\\''", "'")
    end

    # ---- the finding ----

    # Every alias whose NAME is also an executable on the agent's PATH — the
    # objective form of "this word does not mean the binary". It is the name that
    # matters and never the expansion: `la='ls -al'` shadows nothing, because
    # nobody typing `la` believed they were running a binary called `la`.
    #
    # Reported without ranking, on purpose. `ps -ax` is the one that leaked a
    # transcript and `ls -F` is cosmetic, but the difference is a judgement about
    # what a session will do next, and a rule encoding it would be wrong the first
    # time somebody aliases something this module has never heard of. The listing
    # is short — three lines on the runner that prompted this — so the reader can
    # make the judgement the code should not.
    def shadowing(path: nil, text: nil)
      resolved = path || Agent::Toolchain.agent_path
      raw = text || probe
      return nil if raw.nil?
      parse(raw, path: resolved).select(&:shadow?)
    end
  end
end
