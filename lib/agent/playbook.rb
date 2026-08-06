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

    # Substituted into a shared playbook so ONE row can carry the exact command
    # each child of an epic runs (`--app {child}`). The platform writes the child
    # name onto the pointer as `(target: ...)`; this is what it gets substituted
    # into.
    CHILD_TOKEN = "{child}".freeze

    # THE contract line between the platform that writes an issue body and the
    # runner that later reads it back — the same shape it has always had, with a
    # playbook key where the repo path used to be. Deliberately strict: anchored
    # to the start of a line and backticked, so prose that merely mentions a
    # playbook — including an issue describing this very mechanism — cannot be
    # mistaken for a pointer.
    MARKER = "Playbook:".freeze
    MARKER_RE = /^#{MARKER} `([^`\n]+)`(?: \(target: ([^)\n]+)\))?[ \t]*$/.freeze

    # The pointer is read back out of an issue body, which is human-editable, so
    # the key is treated as untrusted input before it becomes a path segment: the
    # same url-safe-lower shape the platform validates on write, and nothing else.
    SAFE_KEY_RE = /\A[a-z0-9][a-z0-9._-]*\z/.freeze

    Pointer = Struct.new(:key, :target, keyword_init: true)

    # A playbook this runner actually READ: the text it got, and the version it
    # got it at.
    Resolved = Struct.new(:key, :target, :text, :version, keyword_init: true) do
      # The exact shape ISS-505 asks the session to record, with the version in
      # place of the sha:
      #   Playbook: dependency-upgrade-app @ 2026-08-05T14:04:20Z
      def label = "#{key} @ #{version}"
    end

    module_function

    def pointer_line(key, target: nil)
      suffix = target.to_s.empty? ? "" : " (target: #{target})"
      "#{MARKER} `#{key}`#{suffix}"
    end

    # The pointer in an issue body, or nil when there is none — which is every
    # human-written issue, all of which carry their brief inline and must keep
    # working untouched.
    def pointer_in(body)
      match = MARKER_RE.match(body.to_s)
      return nil unless match
      Pointer.new(key: match[1], target: match[2])
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
        target: pointer.target,
        text: pointer.target.to_s.empty? ? text : text.gsub(CHILD_TOKEN, pointer.target.to_s),
        version: row["created_at"],
      )
    rescue ApiError, SessionExpired => e
      # A platform the runner cannot reach is NOT a missing playbook, but it has
      # the same consequence for this claim and the same right answer: do not
      # start a session that would do the wrong job. The message says which it
      # was so the issue's comment sends an investigation the right way.
      raise MissingError, "playbook `#{pointer.key}` could not be read from the platform (#{e.class}: #{e.message})"
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

    # `~/code/claude` in any of the forms a playbook writes it. A bare mention of
    # the repo is NOT a target — `git -C ~/code/claude pull` and the prose that
    # explains the push guard both name it — so a target always has a path tail.
    CLAUDE_REPO_RE = %r{(?:~|\$HOME|\$\{HOME\}|/(?:Users|home)/[A-Za-z0-9][A-Za-z0-9._-]*)/code/claude}.freeze

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
    }.freeze

    # The one-line remedy `--lint` prints once per rule it hit. Every rule a
    # finding can carry has an entry, so a detector cannot ship without saying
    # what to do about what it found.
    REMEDIES = {
      home_path: "Use `~/…` — one playbook is read by every runner and they do not share a home.",
      unpushable: "Write under `plans/` — `agent/githooks/pre-push` refuses every other path in `~/code/claude`.",
      reaped: "Put long-lived state in a `plans/` SUBDIRECTORY — `dev prune plans` only reaps top-level files.",
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
          spelled_out_targets(line, previous, key: key, number: index + 1)
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
  end
end
