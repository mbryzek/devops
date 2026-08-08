require 'agent/api'

# The playbook a producer's issue POINTS AT, and how a claiming runner resolves
# that pointer (ISS-505, ISS-523, ISS-526).
#
# The pointer exists because the alternative — copying the playbook's full text
# into every filed issue — freezes it. An issue filed on Friday and claimed on
# Tuesday would run Friday's procedure, and every improvement made in between
# would apply to nothing already in the queue. The producers exist precisely so
# these runbooks improve continuously, so there must be ONE copy of the plan and
# it must be the current one.
#
# WHAT CHANGED IN THE CUTOVER. A pointer used to be a path into this machine's
# devops checkout (`agent/bodies/weekly-review.md`) and the version it named was
# a git sha. `devops/agent/` is deleted now: the playbooks are append-only rows
# in the platform (ISS-523) and a pointer is a KEY. The three properties that
# made the pointer worth having are unchanged, and two of them are stronger:
#
#   resolved at CLAIM time   Not at file time. Latest-at-claim is the entire
#                            point, and it no longer depends on this machine's
#                            checkout being current — a runner that has not
#                            pulled in a week still reads today's playbook.
#   the version is RECORDED  The row's `created_at` goes on the issue as a
#                            comment. Copy-on-write is what makes that worth
#                            recording: the version a run names still EXISTS and
#                            can be read back, which a git sha only gave us
#                            while the file was still in git.
#   an abstract stays INLINE Unchanged, and now written by the platform when it
#                            files: a body that is nothing but a key renders as
#                            an empty box in admin.
module Agent
  module Playbook
    # A pointer that does not resolve is a HARD failure, never a silent fallback
    # to generic triage. ISS-360 is the cautionary tale: a producer ported
    # without its playbook fell back to claude-issues/default-body.md and filed
    # issues instead of shipping PRs for a week, with nothing anywhere saying so.
    class MissingError < StandardError; end

    # THE contract line between the platform that writes an issue body and the
    # runner that later reads it back — the same shape it has always had, with a
    # playbook key where the repo path used to be. Deliberately strict: anchored
    # to the start of a line and backticked, so prose that merely mentions a
    # playbook — including an issue describing this very mechanism — cannot be
    # mistaken for a pointer.
    #
    # WHAT CHANGED IN ISS-843. The suffix used to be a single unnamed value,
    # `(target: platform)`, substituted for a hardcoded `{child}`. A producer's
    # parameter BINDINGS are now carried by name — `(app: platform)`,
    # `(app: platform, child: acumen)` — and each one substitutes `{name}` in the
    # playbook body. Same mechanism, no longer limited to one value and no longer
    # requiring the playbook to call every subject `{child}` whatever it is.
    #
    # The platform refuses a binding value containing `,` `(` `)` or a backtick
    # precisely so this line stays parseable (InternalAgentProducersDao), which is
    # what lets the value pattern below stay this simple.
    MARKER = "Playbook:".freeze
    MARKER_RE = /^#{MARKER} `([^`\n]+)`(?: \(([^)\n]*)\))?[ \t]*$/.freeze

    # One `name: value` pair inside that suffix. The name is url-safe-lower, which
    # is what the platform validates a parameter name to be.
    BINDING_RE = /([a-z0-9][a-z0-9_-]*): ([^,)\n]+)/.freeze

    # The pointer is read back out of an issue body, which is human-editable, so
    # the key is treated as untrusted input before it becomes a path segment: the
    # same url-safe-lower shape the platform validates on write, and nothing else.
    SAFE_KEY_RE = /\A[a-z0-9][a-z0-9._-]*\z/.freeze

    Pointer = Struct.new(:key, :bindings, keyword_init: true)

    # A playbook this runner actually READ: the text it got, and the version it
    # got it at.
    Resolved = Struct.new(:key, :bindings, :text, :version, keyword_init: true) do
      # The exact shape ISS-505 asks the session to record, with the version in
      # place of the sha:
      #   Playbook: dependency-upgrade-app @ 2026-08-05T14:04:20Z
      def label = "#{key} @ #{version}"
    end

    module_function

    # Bindings render in NAME ORDER, matching what the platform writes
    # (ProducerIssueBody): a pointer that reordered itself would show up as a diff
    # in every issue body for no reason.
    def pointer_line(key, bindings: {})
      pairs = bindings.to_h.reject { |_, value| value.to_s.empty? }.sort_by { |name, _| name.to_s }
      suffix = pairs.empty? ? "" : " (#{pairs.map { |name, value| "#{name}: #{value}" }.join(', ')})"
      "#{MARKER} `#{key}`#{suffix}"
    end

    # The pointer in an issue body, or nil when there is none — which is every
    # human-written issue, all of which carry their brief inline and must keep
    # working untouched.
    def pointer_in(body)
      match = MARKER_RE.match(body.to_s)
      return nil unless match
      Pointer.new(key: match[1], bindings: bindings_in(match[2]))
    end

    # Values are stripped, so `(app: platform, child: acumen)` round-trips whether
    # or not the writer padded them.
    def bindings_in(suffix)
      suffix.to_s.scan(BINDING_RE).to_h { |name, value| [name, value.strip] }
    end

    # nil (no pointer) or a Resolved. Raises MissingError when a pointer IS
    # present and this runner cannot resolve it — see MissingError.
    def resolve_in(body, token:, use_localhost:)
      pointer = pointer_in(body)
      pointer && resolve(pointer, token: token, use_localhost: use_localhost)
    end

    def resolve(pointer, token:, use_localhost:)
      key = validated_key(pointer.key)
      row = Agent::Api.playbook(key, token: token, use_localhost: use_localhost)
      # A 404 here is the ISS-360 failure and must stop the claim: the issue says
      # it ships a procedure and this runner cannot produce it, so running the
      # session anyway means running a DIFFERENT job than the one scheduled.
      raise MissingError, "playbook `#{key}` does not exist in the platform" if row.nil?

      text = row["body"].to_s.strip
      raise MissingError, "playbook `#{key}` resolved to an empty body" if text.empty?

      Resolved.new(
        key: key,
        bindings: pointer.bindings,
        text: substitute(text, pointer.bindings),
        version: row["created_at"],
      )
    rescue ApiError, SessionExpired => e
      # A platform the runner cannot reach is NOT a missing playbook, but it has
      # the same consequence for this claim and the same right answer: do not
      # start a session that would do the wrong job. The message says which it
      # was so the issue's comment sends an investigation the right way.
      raise MissingError, "playbook `#{pointer.key}` could not be read from the platform (#{e.class}: #{e.message})"
    end

    # `{name}` -> its binding, for every binding on the pointer. A token with no
    # binding is LEFT ALONE rather than blanked, for the same reason the platform
    # leaves it: an unsubstituted `{app}` in a command is visible to the session
    # reading it, where a blank silently produces a command that runs against the
    # wrong thing.
    def substitute(text, bindings)
      bindings.to_h.reduce(text) { |acc, (name, value)| acc.gsub("{#{name}}", value.to_s) }
    end

    def validated_key(key)
      raise MissingError, "playbook key `#{key}` is not a valid key" unless SAFE_KEY_RE.match?(key.to_s)
      key.to_s
    end

    # ---- the hardcoded-home detector (ISS-633) ----
    #
    # ONE playbook is read by EVERY runner, and the runners do not share a home
    # directory: Mike's MacBook is `/Users/mbryzek` and the Mac mini is
    # `/Users/athena`. So an absolute path under somebody's home is a playbook
    # that is correct on one machine and wrong on the other, and it fails in the
    # worst available way — a session told to write `/Users/mbryzek/...` on the
    # mini either errors, or helpfully creates the parents and writes into a tree
    # nothing reads. Nothing anywhere says so, and the consumer just goes quiet.
    #
    # That is not hypothetical and it is not one path: three playbooks ended by
    # writing a status file under `/Users/mbryzek/code/openclaw/...` while running
    # nightly on a runner whose home is `/Users/athena` (ISS-503, ISS-612,
    # ISS-633). The home-relative form is already what the Ruby side uses
    # (`Briefing::DATA_DIR` is `File.expand_path("~/code/openclaw/...")`), so this
    # is prose drifting from code that was always right.
    #
    # A username segment, not a bare `/Users/`: `/Users/<someone>/code` is a
    # placeholder that a reader substitutes and `grep '/Users/'` is a command, and
    # neither is a path anything will try to write. The distinction is exactly
    # what keeps the clean state meaningful — a detector with a standing false
    # positive is one nobody runs twice.
    HOME_PATH_RE = %r{/(?:Users|home)/[A-Za-z0-9][A-Za-z0-9._-]*}.freeze

    HomePath = Struct.new(:key, :line, :path, keyword_init: true) do
      def rule = :home_path
      def to_s = "#{key}:#{line}: #{path}"
    end

    # Every hardcoded home path in one playbook body, in line order. Empty is the
    # normal case and the one worth keeping true.
    def home_paths_in(body, key: nil)
      body.to_s.each_line.with_index(1).flat_map do |line, number|
        line.scan(HOME_PATH_RE).uniq.map { |path| HomePath.new(key: key, line: number, path: path) }
      end
    end

    # The same question asked of the whole store — what `dev agent playbooks
    # --lint` runs, and what the meta-review's D4 detector calls now that
    # `agent/bodies/*.md` (which it used to grep) is deleted.
    def home_paths_in_all(rows)
      rows.flat_map { |row| home_paths_in(row["body"], key: row["key"]) }
    end

    # ---- the unwritable-target detector (ISS-644) ----
    #
    # The sibling of the hardcoded home, pointed the other way. A hardcoded home
    # is an instruction that works on ONE runner; these two are instructions that
    # work on NO runner, and they fail the same silent way — nothing errors while
    # the session does the work, so a run that recorded nothing is indistinguishable
    # from a run that had nothing to record.
    #
    #   unpushable  A write anywhere in `~/code/claude` outside `plans/`. The
    #               autonomous-session push guard (`agent/githooks/pre-push`)
    #               refuses that push, and it refuses it at the END of the run:
    #               the session has already done the thinking, already written the
    #               file, and only then discovers the write cannot leave the
    #               machine. `daily-perf-prs` pointed its dedup ledger at
    #               `~/code/claude/perf-ledger.md` and no unattended run ever
    #               recorded an entry for weeks (ISS-632).
    #
    #   reaped      A write to a TOP-LEVEL file under `plans/` that is meant to be
    #               long-lived state. `dev prune plans` `git rm`s top-level plan
    #               files whose last commit is older than 14 days and never
    #               touches subdirectories, so state kept there survives exactly
    #               as long as it is written every fortnight — and then quietly
    #               does not. That is why the same ledger ended up at
    #               `plans/data/perf-ledger.md` and not `plans/perf-ledger.md`.
    #
    # State and snapshot cannot be told apart by path, so the proxy is the one
    # thing a per-run snapshot always carries and state never does: a date in the
    # filename. `weekly-review` writes `plans/{child}-weekly-<date>.md` every week
    # and is exactly the file this must not flag.

    #   handwritten A write into the morning briefing's status directory,
    #               `~/code/openclaw/openclaw-workspace/data/`. That is outside
    #               the workspace `agent/instructions.md` §3 confines a session
    #               to, and §3's stated remedy — clone it — accomplishes nothing,
    #               because the briefing reads the original path. So the playbook
    #               and the guardrail contradicted each other every night and the
    #               session had to pick one unaided; the reading that honours the
    #               guardrail drops the briefing update, and a dropped section is
    #               invisible rather than stale (ISS-1022). `dev agent status-file
    #               <key> --write FILE` is the command that write is now.

    # The home a path is written relative to, in every form a playbook spells it.
    # Shared by the two repo/directory matchers below so a new spelling is
    # understood by both at once.
    HOME_PREFIX_RE = %r{(?:~|\$HOME|\$\{HOME\}|/(?:Users|home)/[A-Za-z0-9][A-Za-z0-9._-]*)}.freeze

    # `~/code/claude` in any of the forms a playbook writes it. A bare mention of
    # the repo is NOT a target — `git -C ~/code/claude pull` and the prose that
    # explains the push guard both name it — so a target always has a path tail.
    CLAUDE_REPO_RE = %r{#{HOME_PREFIX_RE}/code/claude}.freeze

    # Placeholders are part of a path here: the playbooks write `{child}` and
    # `<date>` into the very filenames this classifies, and a matcher that stopped
    # at `<` would see `plans/x-weekly-` and call a dated snapshot undated.
    PATH_TAIL_RE = %r{(?:/[A-Za-z0-9._*+%$(){}<>-]+)+}.freeze

    # Prose puts a path mid-sentence and a shell puts one inside `$( )`, so the
    # greedy tail above swallows the sentence's punctuation and gives back
    # `plans/x.md.` or `plans/x.md)`. Both are the same path with litter on the
    # end, and a finding that reports the litter reads as a different file.
    PATH_LITTER_RE = /[.,;:]+\z/.freeze

    CLAUDE_PATH_RE = /#{CLAUDE_REPO_RE}(#{PATH_TAIL_RE})/.freeze

    # The briefing's status directory. Unlike the repo above, the DIRECTORY alone
    # is already a finding and the filename is optional: "write the status file
    # into `~/code/openclaw/openclaw-workspace/data/`" is the same instruction as
    # naming the file, and both are outside the workspace.
    BRIEFING_DIR_RE = %r{#{HOME_PREFIX_RE}/code/openclaw/openclaw-workspace/data}.freeze

    BRIEFING_PATH_RE = /#{BRIEFING_DIR_RE}(?:#{PATH_TAIL_RE})?/.freeze

    # `git -C ~/code/claude add plans/data/perf-ledger.md` — the commit sequence a
    # playbook spells out, where the repo and the path are separate arguments and
    # no prose verb appears anywhere. This form is a write by construction, so it
    # needs no cue; it is also the exact line ISS-632 got wrong.
    GIT_ADD_RE = /\bgit\s+-C\s+#{CLAUDE_REPO_RE}\s+add\s+([^\n`]+)/.freeze

    PLANS_SEGMENT = "plans".freeze

    # What a per-run snapshot's filename carries and long-lived state's never does.
    DATE_TOKEN_RE = /
      <\s*(?:date|today|yyyy-mm-dd|iso-date)\s*> | \{\s*date\s*\} |
      %Y-%m-%d | \$\(\s*date | \d{4}-\d{2}-\d{2} | \byyyy-mm-dd\b
    /xi.freeze

    # A path alone proves nothing — `~/code/claude/rules/*.mdc` is READ by half the
    # store and must never be flagged — so the finding is the verb, not the path.
    # Shell redirects and `tee` count; the prose verbs are the ones that actually
    # appear in playbook sentences.
    WRITE_CUE_RE = /
      \btee\b
      | \S\s*>{1,2}\s*[`'"(]*\z
      | \b(?:
          append(?:s|ed|ing)? | writ(?:e|es|ing|ten) | record(?:s|ed|ing)? |
          sav(?:e|es|ed|ing) | creat(?:e|es|ed|ing) | updat(?:e|es|ed|ing) |
          edit(?:s|ed|ing)? | commit(?:s|ted|ting)? | add(?:s|ed|ing)? |
          stor(?:e|es|ed|ing) | overwrit(?:e|es|ing|ten) | rewrit(?:e|es|ing|ten) |
          persist(?:s|ed|ing)? | touch(?:es|ed|ing)?
        )\b
    /xi.freeze

    # The suppressor. A cue AFTER the path has to count — a definition names its
    # target first and says what it is for second ("`LEDGER = ~/code/claude/…` —
    # records terminal outcomes", which is the line ISS-632 actually got wrong) —
    # and that is exactly what makes "Read the relevant `~/code/claude/rules/*.mdc`
    # before writing code" match on `writing`. So a READ verb already governing the
    # path wins: the sentence is a pointer at something to read, whatever verb it
    # goes on to use about something else. This is the read-verb allowlist ISS-644
    # named as the fallback if matching on the write verb alone proved noisy.
    READ_CUE_RE = /
      \b(?:
        read(?:s|ing)? | see | consult(?:s|ed|ing)? | refer(?:s|red|ring)? |
        check(?:s|ed|ing)? | inspect(?:s|ed|ing)? | review(?:s|ed|ing)? |
        follow(?:s|ed|ing)? | grep | cat | per | accord(?:ing)? |
        document(?:s|ed)? | describ(?:e|es|ed) | design
      )\b
    /xi.freeze

    # A sentence ends the verb's reach. `:` is in here for a reason: "Design:
    # `~/code/claude/plans/…-design.md`. Read it if …" is a pointer at a document,
    # and the word before the colon must not be allowed to govern the path.
    SENTENCE_BREAK_RE = /(?<=[.!?:])\s/.freeze

    # A list item, heading, quote or table row starts a new thought, so the line
    # above it never governs the path. This is what keeps "- Read the relevant
    # `~/code/claude/rules/*.mdc` before writing code" clean: the cue on that line
    # sits AFTER the path, and the line above is not allowed to supply one.
    BLOCK_START_RE = /\A\s*(?:[-*+]\s|\d+[.)]\s|\#+\s|>\s|\||```)/.freeze

    REASONS = {
      unpushable: "outside `plans/` — the push guard refuses this write from an unattended session",
      reaped: "a top-level `plans/` file with no date in its name — `dev prune plans` removes it after 14 days",
      handwritten_status: "the briefing's status directory, outside the workspace §3 confines a session to — " \
                          "write it with `dev agent status-file`",
    }.freeze

    # The one-line remedy `--lint` prints once per rule it hit. Every rule a
    # finding can carry has an entry, so a detector cannot ship without saying
    # what to do about what it found.
    REMEDIES = {
      home_path: "Use `~/…` — one playbook is read by every runner and they do not share a home.",
      unpushable: "Write under `plans/` — `agent/githooks/pre-push` refuses every other path in `~/code/claude`.",
      reaped: "Put long-lived state in a `plans/` SUBDIRECTORY — `dev prune plans` only reaps top-level files.",
      handwritten_status: "Record it with `dev agent status-file <key> --write FILE` — a session may not edit " \
                          "that directory by hand, and cloning it (§3's remedy) is not one the briefing reads.",
    }.freeze

    WriteTarget = Struct.new(:key, :line, :path, :rule, keyword_init: true) do
      def to_s = "#{key}:#{line}: #{path} — #{REASONS.fetch(rule)}"
    end

    # The path without the sentence's punctuation on the end. A closing paren only
    # comes off when nothing in the path opened it, so `plans/run-$(date +%F).md`
    # survives whole and `(see ~/code/claude/plans/x.md)` does not keep the paren.
    def trim_path(path)
      trimmed = path.sub(PATH_LITTER_RE, "")
      trimmed = trimmed.chop.sub(PATH_LITTER_RE, "") while trimmed.end_with?(")") &&
                                                            trimmed.count(")") > trimmed.count("(")
      trimmed
    end

    # nil when a path is fine, otherwise the rule it breaks. Takes the path
    # RELATIVE to `~/code/claude`, so both spellings — the full path and the
    # `git -C … add` argument — are judged by one piece of code.
    def target_rule(relative_path)
      segments = relative_path.split("/").reject(&:empty?)
      return nil if segments.empty?
      return :unpushable unless segments.first == PLANS_SEGMENT
      # `plans/` itself, or anything in a subdirectory, is safe: the guard permits
      # it and the reaper does not descend.
      return nil unless segments.length == 2
      DATE_TOKEN_RE.match?(segments.last) ? nil : :reaped
    end

    # The text that GOVERNS a path — back to the start of its sentence, which may
    # begin on the line above, because markdown prose wraps and the verb lands
    # there routinely ("… and PR grouping to\n`~/code/claude/plans/…`").
    def governing_text(previous_line, prefix)
      previous = previous_line.to_s
      joined =
        if prefix.match?(BLOCK_START_RE) || previous.strip.empty? || previous.match?(BLOCK_START_RE)
          prefix
        else
          "#{previous.rstrip} #{prefix}"
        end
      index = joined.rindex(SENTENCE_BREAK_RE)
      index ? joined[(index + 1)..].to_s : joined
    end

    # Everything after the path that still belongs to the same sentence. Stopping
    # at the break is what keeps "`~/code/claude/rules/*.mdc`. Work end-to-end"
    # from borrowing a verb out of the sentence that follows it.
    def rest_of_sentence(suffix)
      index = suffix.index(SENTENCE_BREAK_RE)
      index ? suffix[0...index] : suffix
    end

    def write_context?(previous_line, prefix, suffix)
      governing = governing_text(previous_line, prefix)
      return true if WRITE_CUE_RE.match?(governing)
      return false if READ_CUE_RE.match?(governing)
      WRITE_CUE_RE.match?(rest_of_sentence(suffix))
    end

    # Every write in one playbook body that no unattended session can land, in
    # line order. Empty is the normal case and the one worth keeping true.
    def write_targets_in(body, key: nil)
      lines = body.to_s.lines
      findings = lines.each_with_index.flat_map do |line, index|
        previous = index.zero? ? "" : lines[index - 1]
        git_add_targets(line, key: key, number: index + 1) +
          spelled_out_targets(line, previous, key: key, number: index + 1) +
          briefing_targets(line, previous, key: key, number: index + 1)
      end
      findings.uniq { |finding| [finding.line, finding.path, finding.rule] }
    end

    def git_add_targets(line, key:, number:)
      line.scan(GIT_ADD_RE).flat_map do |(args)|
        args.split(/\s+/).reject { |arg| arg.empty? || arg.start_with?("-") }.filter_map do |arg|
          path = trim_path(arg)
          rule = target_rule(path)
          rule && WriteTarget.new(key: key, line: number, path: path, rule: rule)
        end
      end
    end

    # The briefing's status directory, under the same write-context rule as the
    # rest: this path is legitimately NAMED in prose that explains the mechanism
    # ("the file the morning briefing reads"), and a detector that flagged every
    # mention of it would be one nobody runs twice. Only the instruction to write
    # there is a finding, and its remedy is a command, not a different path — so
    # there is nothing to classify beyond "this is that directory".
    def briefing_targets(line, previous, key:, number:)
      findings = []
      line.to_enum(:scan, BRIEFING_PATH_RE).each do
        match = Regexp.last_match
        next unless write_context?(previous, line[0...match.begin(0)], match.post_match)
        findings << WriteTarget.new(key: key, line: number, path: trim_path(match[0]), rule: :handwritten_status)
      end
      findings
    end

    def spelled_out_targets(line, previous, key:, number:)
      findings = []
      line.to_enum(:scan, CLAUDE_PATH_RE).each do
        match = Regexp.last_match
        tail = trim_path(match[1])
        rule = target_rule(tail)
        next unless rule
        next unless write_context?(previous, line[0...match.begin(0)], match.post_match)
        findings << WriteTarget.new(key: key, line: number, path: trim_path(match[0]), rule: rule)
      end
      findings
    end

    def write_targets_in_all(rows)
      rows.flat_map { |row| write_targets_in(row["body"], key: row["key"]) }
    end

    # Every defect the store can be checked for mechanically, per playbook and in
    # line order — what `dev agent playbooks --lint` runs and what the
    # meta-review's D4 detector calls.
    def lint_all(rows)
      rows.flat_map do |row|
        body = row["body"]
        key = row["key"]
        (home_paths_in(body, key: key) + write_targets_in(body, key: key)).sort_by(&:line)
      end
    end

    # ---- the write path (`dev agent playbook <key> --write FILE`, ISS-665) ----
    #
    # Reading a playbook is a wrapper around a GET. WRITING one is not, and the
    # difference is what this section exists for: a playbook is an instruction
    # every future session obeys, which puts it in the same class as
    # `agent/instructions.md` and the `~/code/claude` rules a pre-push hook
    # protects. Until this existed, the only devops-side write was a session
    # hand-rolling `ApiClient.request(..., :post, "/agent/playbooks", ...)` —
    # a production table edited through a path with no key validation, no diff
    # and no confirmation (ISS-665, hit while fixing ISS-660).
    #
    # Three gates, and each one guards a failure the append-only design makes
    # PERMANENT rather than merely wrong:
    #
    #   the diff        Nobody appends a version without seeing what changes. A
    #                   playbook has no local copy to `git diff` against — the
    #                   current version lives only in the platform — so the diff
    #                   has to be computed here or it does not exist at all.
    #   --create        A typo'd key does not fail. It starts a NEW lineage that
    #                   no producer points at, permanently, while the fix the
    #                   operator meant to make silently never lands and the
    #                   producer keeps running the old procedure. The one gate
    #                   that catches a mistake nothing downstream would report.
    #   --yes           Explicit consent, always. A human at a terminal is
    #                   prompted; anything else (a session, a pipe, cron) is
    #                   REFUSED unless --yes was passed, so an autonomous run
    #                   cannot rewrite the instructions the next autonomous run
    #                   obeys as a side effect of doing something else.

    # Number of unchanged lines kept on each side of a change. Anything longer is
    # elided, so a one-line fix to a long playbook reads as a one-line fix.
    DIFF_CONTEXT = 3

    # Whether two bodies differ in a way worth appending a version for.
    #
    # Compared rstrip'd rather than byte for byte because `resolve` strips before
    # handing the text to a session: a version whose only difference is a trailing
    # newline changes NOTHING any session reads, and appending it would put a row
    # in the history that answers "what changed" with "nothing". The round trip
    # this enables is the point — `dev agent playbook k > k.md`, edit, `--write
    # k.md` — and an editor that adds a final newline must not make that a write.
    def changed?(current_body, proposed_body)
      current_body.to_s.rstrip != proposed_body.to_s.rstrip
    end

    # The diff an operator confirms against, as an array of display lines.
    #
    # Pure Ruby rather than shelling out to diff(1) with two temp files. This is
    # the LAST thing shown before a permanent append, so it must not depend on a
    # binary being on PATH, on temp files landing, or on a subprocess exit status
    # being read correctly — and a playbook is a page of markdown, so the O(n*m)
    # LCS table is never the cost.
    def diff_lines(before, after, context: DIFF_CONTEXT)
      render_diff(diff_ops(body_lines(before), body_lines(after)), context)
    end

    # Trailing whitespace is stripped for the same reason `changed?` ignores it:
    # the session reads a stripped body, so a phantom final empty line rendered
    # as a change would be a change nothing downstream can see.
    def body_lines(body)
      text = body.to_s.rstrip
      text.empty? ? [] : text.split("\n", -1)
    end

    # [kind, text] pairs (:same / :del / :add) in output order, from the standard
    # longest-common-subsequence table. Split out from rendering so the alignment
    # is testable independently of how it is displayed.
    def diff_ops(before, after)
      n = before.length
      m = after.length
      lcs = Array.new(n + 1) { Array.new(m + 1, 0) }
      (n - 1).downto(0) do |i|
        (m - 1).downto(0) do |j|
          lcs[i][j] = before[i] == after[j] ? lcs[i + 1][j + 1] + 1 : [lcs[i + 1][j], lcs[i][j + 1]].max
        end
      end

      ops = []
      i = 0
      j = 0
      while i < n && j < m
        if before[i] == after[j]
          ops << [:same, before[i]]
          i += 1
          j += 1
        elsif lcs[i + 1][j] >= lcs[i][j + 1]
          ops << [:del, before[i]]
          i += 1
        else
          ops << [:add, after[j]]
          j += 1
        end
      end
      ops.concat(before[i..].map { |line| [:del, line] })
      ops.concat(after[j..].map { |line| [:add, line] })
      ops
    end

    # Unified-diff markers with long unchanged runs elided. Deliberately not real
    # `@@` hunk headers: line numbers into a body that exists only as a database
    # column are a number the operator cannot look anything up by, and the count
    # of elided lines is the thing they actually want ("did I miss a section").
    MARKERS = { same: "  ", del: "- ", add: "+ " }.freeze

    def render_diff(ops, context)
      keep = ops.each_index.select do |index|
        ops[index][0] != :same ||
          [distance_to_change(ops, index, -1), distance_to_change(ops, index, 1)].min <= context
      end

      out = []
      previous = nil
      keep.each do |index|
        gap = previous.nil? ? index : index - previous - 1
        out << elision(gap) if gap.positive?
        kind, text = ops[index]
        out << "#{MARKERS.fetch(kind)}#{text}"
        previous = index
      end
      trailing = ops.length - (previous.nil? ? 0 : previous + 1)
      out << elision(trailing) if trailing.positive?
      out
    end

    # One marker per dropped run, so an elision is visible AS an elision. A diff
    # that silently omits lines is worse than no diff: it looks complete.
    def elision(count)
      "  ... #{count} unchanged line#{count == 1 ? '' : 's'}"
    end

    # Steps from `index` to the nearest changed op in `direction`, or Infinity
    # when there is none — an unchanged run at the very top or bottom of the file
    # has no change on that side and is elided rather than kept as context.
    def distance_to_change(ops, index, direction)
      i = index + direction
      steps = 1
      while i >= 0 && i < ops.length
        return steps unless ops[i][0] == :same
        i += direction
        steps += 1
      end
      Float::INFINITY
    end

    # What the write path is allowed to do: [:append, nil], [:prompt, nil], or
    # [:refuse, message].
    #
    # The default is REFUSE, not prompt. A prompt is only correct when there is
    # somebody to answer it, and the two callers who are not are exactly the two
    # this gate exists for: an autonomous session (which would answer its own
    # prompt) and a pipe or cron (where `$stdin.gets` returns nil and any
    # "default" is a decision nobody made). `--yes` is the one explicit thing
    # either of them can pass, which is what makes an autonomous playbook edit a
    # deliberate act rather than a side effect.
    def write_gate(assume_yes:, interactive:, ai_session:)
      return [:append, nil] if assume_yes

      if ai_session
        return [:refuse, "Refusing to append a playbook version from inside a Claude session without --yes. " \
                         "A playbook is an instruction every future session obeys, so editing one has to be the " \
                         "job this session was given, stated explicitly — never a side effect of doing something " \
                         "else. Re-run with --yes if it is."]
      end

      unless interactive
        return [:refuse, "Refusing to append a playbook version without confirmation (stdin is not a terminal). " \
                         "Pass --yes."]
      end

      [:prompt, nil]
    end
  end
end
