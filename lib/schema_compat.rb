# require_relative, not require: this is loadable on its own (its test loads it
# directly), as well as through common.rb's glob over lib/.
require_relative 'schema_scripts'
require 'open3'
require 'set'

# Can this migration ship in the SAME release as the code that needs it?
#
# SchemaScripts answers a different question — expanding or contracting, migrate
# before the app or after it — and it answers it well for a DROP, where exactly
# one ordering is wrong. This module is about the shape ordering cannot rescue,
# which SchemaScripts' own header has named since ISS-317 without anything
# enforcing it:
#
#   EXPANDING     adds. Old code does not know about it. Safe applied early.
#   CONTRACTING   removes. Old code still names it. Safe applied LATE, after the
#                 app that stopped naming it has rolled out. `dev deploy all`
#                 Phase 3.
#   INCOMPATIBLE  removes AND adds in one statement — a RENAME, or a column type
#                 change. The old name breaks the OLD code the instant it
#                 commits; the new name does not exist until it does, so the NEW
#                 code breaks until then. Both orderings are wrong. There is no
#                 phase to put it in.
#
# ISS-864, 2026-08-07. `alter table issues.issues rename column producer_key to
# producer_id` shipped in platform-postgresql 0.5.66 alongside the platform
# 0.19.22 that needed it. Every read and write of the issues tables answered 500
# for the length of the gap: `dev issues` in all its forms, the admin console,
# the auto-filers, and the lease/claim endpoints the autonomous runners poll. The
# insert that noticed it failed outright, so the issue being filed was lost
# silently. Measured, 45 errors across 18:15–18:20Z.
#
# Nothing was misclassified. Replaying that script through SchemaScripts today
# reports it CONTRACTING, correctly, and the deploy would have deferred it to
# Phase 3 — which only moves the outage from the old pods to the new ones,
# `producer_id does not exist` instead of `producer_key does not exist`.
# Ordering chooses which side pays. It cannot choose neither.
#
# THE ONLY CURE IS THREE RELEASES, and it is cheap next to a production window:
#
#   N     add producer_id, backfill it from producer_key, write both. The old
#         column stays and stays populated, so N-1 keeps working.
#   N+1   code reads and writes only producer_id.
#   N+2   drop producer_key. A pure contraction — SchemaScripts sorts it into
#         Phase 3 and it is safe there.
#
# WHERE THIS FIRES, and why the severity differs by call site. Before the merge
# it is free to fix, so `dev schema lint` and `claude-db sync` REFUSE. After the
# merge both the code and the migration are on main and some ordering has to be
# chosen, so refusing the migration would only strand the new code against a
# schema it cannot use — release-db WARNS instead, loudly, every time, including
# under RELEASE_DB_AUTO_CONFIRM.
#
# THE OPT-OUT IS PER OBJECT, deliberately. A file-level "I know what I am doing"
# would be inherited by the next rename somebody adds to the same script, which
# is the failure this exists to catch, one script later. Name each one:
#
#   -- schema-compat: no-live-reader issues.producer_key -- nothing has ever
#   --   selected this column; the table shipped unreleased in this same batch
#
# ERRING TOWARD SILENCE, the same way SchemaScripts errs toward EXPANDING and
# SchemaCollisions leaves constraints untracked. A false positive here blocks a
# session's database and a release, so anything needing real SQL semantics to
# get right is left out rather than guessed:
#
#   * ONLY UNRELEASED SCRIPTS are read. A released rename is history and no
#     check can unship it — and reading the whole history would report 57 of
#     platform-postgresql's 917 scripts, which is a check nobody would keep.
#   * INDEXES, TRIGGERS AND CONSTRAINTS renames are exempt. No query names one,
#     so renaming one is invisible to the application. Measured: nothing in
#     platform's generated DAOs, its core framework or lib-query reads a
#     constraint name out of a Postgres error.
#   * AN OBJECT CREATED BY AN UNRELEASED SCRIPT has no live reader by
#     construction, so renaming it in a later unreleased script is free. That is
#     the common shape of a same-batch fixup and reading it as a finding would
#     make the check mostly noise.
#   * DYNAMIC SQL is skipped — a `format('alter table %I.%I rename to %I')`
#     inside a function body names no object this can resolve.
module SchemaCompat
  SCRIPTS_DIR = "scripts".freeze

  # One incompatible statement, and the object whose old name stops resolving.
  # `object` is the label the opt-out directive must name, and the label the
  # failure message prints, so there is exactly one spelling to copy.
  Finding = Struct.new(:script, :statement, :object, keyword_init: true)

  # `alter table t rename column a to b`. Postgres makes COLUMN optional in the
  # grammar but the DAO generator always writes it; the optional group costs
  # nothing and covers a hand-written script.
  RENAME_COLUMN = /\Aalter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(?<table>[\w".]+)\s+
                   rename\s+(?:column\s+)?(?<from>[\w"]+)\s+to\s+[\w"]+/x

  # `alter table t rename to u`, and the same for the other kinds a query can
  # name. Not `alter index` / `alter trigger` — see EXEMPT.
  RENAME_OBJECT = /\Aalter\s+(?:materialized\s+view|table|view|sequence|type|schema|foreign\s+table)\s+
                   (?:if\s+exists\s+)?(?:only\s+)?(?<from>[\w".]+)\s+rename\s+to\s+[\w"]+/x

  # `alter table t alter column c type jsonb`, which one statement may repeat
  # per column. A type change is incompatible for the same reason a rename is:
  # the old code binds and reads the old type, and Postgres refuses the mismatch
  # rather than coercing it. Scanned rather than anchored-matched, so it is only
  # consulted for a statement that already starts `alter table`.
  TYPE_CHANGE = /alter\s+(?:column\s+)?(?<column>[\w"]+)\s+(?:set\s+data\s+)?type\s+/

  # Renaming one of these is invisible to the application: no query names an
  # index, a trigger or a constraint, so the old name stopping resolving costs
  # nothing. Pairing an index rename with the column rename it belongs to is the
  # house style, so leaving them in would flag every well-written script twice.
  EXEMPT = /\Aalter\s+(?:index|trigger)\b|\brename\s+constraint\b/

  # `alter table t add column c ...`, for the columns an unreleased script adds
  # to an ALREADY-RELEASED table — those have no live reader either.
  ADD_COLUMN = /\Aalter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(?<table>[\w".]+)\s+
                add\s+(?:column\s+)?(?:if\s+not\s+exists\s+)?(?<column>[\w"]+)/x

  # The assertion that suppresses one finding. Object first so it lines up with
  # what the failure message printed; the reason is REQUIRED, because the reason
  # is the whole point — "no live reader" is a claim about released code, and a
  # claim nobody had to write down is one nobody had to check.
  DIRECTIVE = /^[ \t]*--[ \t]*schema-compat:[ \t]*no-live-reader[ \t]+(?<object>[\w".]+)[ \t]+--[ \t]*(?<reason>\S.*)$/

  # The findings in one script, given the objects that are new in this same
  # unreleased batch (and therefore have no live reader whatever happens to
  # them).
  def SchemaCompat.findings(script, sql, unreleased_objects = UnreleasedObjects.empty)
    exempted = SchemaCompat.exempted_objects(sql)
    SchemaScripts.strip_comments(sql).split(";").flat_map do |raw|
      statement = raw.strip.gsub(/\s+/, " ")
      next [] if statement.empty?
      SchemaCompat.statement_findings(script, statement)
    end.reject do |finding|
      exempted.include?(finding.object) || unreleased_objects.new?(finding.object)
    end
  end

  # Every object this script's SQL renames or retypes, as Findings. One
  # statement can yield several: `alter table t alter column a type x, alter
  # column b type y` is one statement and two incompatibilities.
  def SchemaCompat.statement_findings(script, statement)
    normalized = statement.downcase
    return [] if normalized =~ EXEMPT

    objects =
      if (m = normalized.match(RENAME_COLUMN))
        ["#{SchemaScripts.unqualify(m[:table])}.#{unquote(m[:from])}"]
      elsif (m = normalized.match(RENAME_OBJECT))
        [SchemaScripts.unqualify(m[:from])]
      elsif (m = normalized.match(/\Aalter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(?<table>[\w".]+)\s/))
        table = SchemaScripts.unqualify(m[:table])
        normalized.scan(TYPE_CHANGE).flatten.map { |column| "#{table}.#{unquote(column)}" }
      else
        []
      end

    # A `format('alter table %I.%I rename to %I', ...)` inside a function body
    # names a placeholder, not an object. Nothing this can resolve, so nothing
    # to assert about.
    objects.reject { |object| object.include?("%") }
           .map { |object| Finding.new(:script => script, :statement => statement, :object => object) }
  end

  # The objects a script's `-- schema-compat: no-live-reader <object> -- <why>`
  # lines assert nothing released reads. Read from the RAW sql: the directive is
  # a comment, and strip_comments has removed it by the time the statements are
  # scanned.
  def SchemaCompat.exempted_objects(sql)
    sql.dup.force_encoding(Encoding::UTF_8).scrub("").scan(DIRECTIVE).map { |object, _reason| object.downcase.delete('"') }.to_set
  end

  # The objects created by the unreleased batch itself — a table (or view,
  # sequence, type) some unreleased script creates, and the columns another adds
  # to an already-released table. Nothing released can name any of them.
  class UnreleasedObjects
    def UnreleasedObjects.empty = new([], [])

    # `bodies` are comment-stripped script bodies, in any order: a script may
    # rename a table an EARLIER script in the same batch created, and it may
    # also rename one a LATER script creates the successor of. Membership, not
    # ordering, is the question.
    def UnreleasedObjects.from_bodies(bodies)
      created = bodies.flat_map { |body| SchemaScripts.created_objects(body).to_a }
      columns = bodies.flat_map do |body|
        body.downcase.split(";").filter_map do |raw|
          m = raw.strip.gsub(/\s+/, " ").match(ADD_COLUMN)
          m && "#{SchemaScripts.unqualify(m[:table])}.#{m[:column].delete('"')}"
        end
      end
      new(created, columns)
    end

    def initialize(created, columns)
      @created = created.to_set
      @columns = columns.to_set
    end

    # A finding's object is new when the object itself is new, or — for a
    # `table.column` label — when the whole table is new or the column was added
    # in this same batch.
    def new?(object)
      return true if @created.include?(object) || @columns.include?(object)
      table, column = object.split(".", 2)
      !column.nil? && @created.include?(table)
    end
  end

  # Every finding across `scripts` (relative paths under repo_dir).
  def SchemaCompat.scan_scripts(repo_dir, scripts)
    bodies = scripts.filter_map do |path|
      full = File.join(repo_dir, path)
      SchemaScripts.strip_comments(File.read(full)) if File.file?(full)
    end
    unreleased = UnreleasedObjects.from_bodies(bodies)
    scripts.flat_map do |path|
      full = File.join(repo_dir, path)
      next [] unless File.file?(full)
      SchemaCompat.findings(path, File.read(full), unreleased)
    end
  end

  # The scripts on disk that are not in the latest released tag. That is the set
  # a release is about to apply, and the set it is still free to change: a
  # released script cannot be withdrawn, so reporting one would be advice nobody
  # can take.
  #
  # No tags at all means nothing has ever been released, so nothing can have a
  # live reader — the whole repo is pre-first-release and there is nothing to
  # check.
  def SchemaCompat.unreleased_scripts(repo_dir)
    tag = SchemaScripts.tags(repo_dir).first
    return [] if tag.nil?
    SchemaCompat.scripts_on_disk(repo_dir) - SchemaCompat.scripts_at(repo_dir, tag)
  end

  # The scripts on disk that `base_ref` does not have — what THIS BRANCH adds.
  # Narrower than unreleased_scripts on purpose: a session is answerable for the
  # migration it just wrote, not for somebody else's that merged and has not
  # been released yet.
  def SchemaCompat.added_scripts(repo_dir, base_ref = "origin/main")
    at_base = SchemaCompat.scripts_at(repo_dir, base_ref)
    # An unresolvable base (no remote, a bare scripts directory) leaves no
    # branch to compare, and treating every script as added would report the
    # whole history. Silence is the right failure here.
    return [] if at_base.empty?
    SchemaCompat.scripts_on_disk(repo_dir) - at_base
  end

  # Reads the working tree, like SchemaCollisions and for the same reason: a
  # session lints the migration in front of it, which it has often not committed
  # yet.
  def SchemaCompat.scripts_on_disk(repo_dir)
    Dir.glob(File.join(repo_dir, SCRIPTS_DIR, "*.sql")).sort.map { |p| File.join(SCRIPTS_DIR, File.basename(p)) }
  end

  # capture3, not capture2: an unresolvable ref is an ordinary answer here ("no
  # branch to compare"), and letting git's `fatal:` reach the terminal would put
  # a scary line in the middle of a clean `dev schema lint`.
  def SchemaCompat.scripts_at(repo_dir, ref)
    out, _err, status = Open3.capture3("git", "ls-tree", "-r", "--name-only", ref, "--", SCRIPTS_DIR, chdir: repo_dir)
    return [] unless status.success?
    out.split("\n").map(&:strip).select { |f| f.end_with?(".sql") }
  end

  def SchemaCompat.unquote(name) = name.to_s.delete('"')

  # Finding by finding, script by script — the operator's question is which
  # object, not which file.
  def SchemaCompat.describe(findings)
    findings.group_by(&:script).map do |script, group|
      ["  #{File.basename(script)}"] +
        group.map { |f| "      #{f.object}\n          #{f.statement}" }
    end.flatten.join("\n")
  end

  # What every caller prints. One text, because the reader's question is the
  # same wherever they hit it: which object, and what do I do instead.
  def SchemaCompat.failure_message(repo_dir, findings)
    <<~TEXT
      #{repo_dir} has #{findings.length} unreleased migration statement(s) that cannot ship in one release.

      Each renames or retypes an object that RELEASED code still names. There is no
      ordering that survives it: applied before the app, the running code breaks on the
      old name; applied after, the new code breaks on the new one until it lands. This is
      the ISS-864 outage — every read and write of issues.issues answered 500 for five
      minutes on 2026-08-07 — and the deploy's expanding/contracting phases cannot fix it,
      because both phases are wrong.

      #{describe(findings)}

      Split it into three releases. For a column `old` becoming `new`:

        1. add `new`, backfill it from `old`, and write BOTH. `old` stays populated, so
           the running code keeps working.
        2. change the code to read and write only `new`. Release it.
        3. drop `old`. That is a pure contraction — `dev deploy all` puts it in Phase 3,
           after the app, where it is safe.

      If nothing released actually reads the object — a table this same unreleased batch
      created, a column no code has ever selected — say so IN THE SCRIPT, once per object:

        -- schema-compat: no-live-reader #{findings.first.object} -- <why no released code names it>

      `dev schema lint --app <app>` re-checks in about a second.
    TEXT
  end

  # The gate, for the call sites where the fix is still free: before the merge,
  # the script is editable and splitting it costs a commit.
  #
  # Deliberately NOT used by release-db. By release time the code and the
  # migration are both on main, some ordering has to be chosen, and refusing the
  # migration would strand the new code against a schema it cannot use — so that
  # call site warns instead.
  def SchemaCompat.assert_none!(scripts, repo_dir, epilogue: nil)
    findings = SchemaCompat.scan_scripts(repo_dir, scripts)
    return if findings.empty?
    message = SchemaCompat.failure_message(repo_dir, findings)
    message += "\n#{epilogue}" if epilogue
    Util.exit_with_error(message)
  end

  # What release-db prints instead of refusing. Names the window it is about to
  # open, because that is the only decision left to the operator: when to open
  # it, and what to expect while it is open.
  def SchemaCompat.release_warning(tag, findings)
    <<~TEXT
      #{tag} contains #{findings.length} statement(s) that NO ORDERING makes safe:

      #{describe(findings)}

      A rename removes the old name and adds the new one in the same instant. Applying
      this before the app rolls out answers `does not exist` on every request the OLD
      code makes against these objects; applying it after does the same to the NEW code
      until it lands. Expect 500s either way, for the length of the rollout — including
      the 2–5 minutes a platform pod spends failing readiness while the JVM boots.

      This needed three releases (add, migrate the code, drop). It is too late for that
      now — both halves are on main — so the only choice left is WHEN. Prefer a quiet
      window, and expect the issues/lease endpoints the runners poll to fail while it is
      open (ISS-864).
    TEXT
  end
end
