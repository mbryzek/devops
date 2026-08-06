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
  end
end
