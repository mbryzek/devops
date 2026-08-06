# require_relative, not require: this is loadable on its own (its test loads it
# directly), as well as through common.rb's glob over lib/.
require_relative 'schema_scripts'

# Would `sem-apply` get through these scripts at all, on a database built from
# scratch?
#
# Nothing asked that between `gh pr merge` and whoever needed a database next.
# ISS-592: platform-postgresql #506 and #507 merged 23 seconds apart, each
# carrying a migration that created issues.issue_intake_senders / _messages /
# _message_files from a different draft of the same DAO spec. Neither branch
# could see the other's script; main had both. The first thing to replay them in
# order was a session running `claude-db start`, which got
#
#   ERROR: relation "issue_intake_senders" already exists
#
# and with it a HALTED sem — every migration after the collision is blocked too,
# not just the two that collided, and the block lasts until somebody edits a
# released script. That is 15 minutes of luck on a Wednesday and an unbounded
# amount of it on a Friday or at a release.
#
# THE MODEL. Scripts are replayed in the order sem-apply runs them (filename,
# ascending), tracking which named objects exist. A CREATE of something already
# live, with no guard, is exactly the statement Postgres refuses. That is a pure
# text pass with no database, so it runs anywhere in about a second — a `dev
# schema lint`, a preflight in claude-db, a hard gate in release-db.
#
# It reads the WHOLE history rather than the scripts added since the last tag,
# which is what makes it strictly better than a diff-based lint: it also catches
# a new script colliding with an ALREADY-RELEASED one, which no
# scripts-since-the-tag comparison can see. Replaying released scripts costs
# nothing in false alarms — a collision between two released scripts is
# impossible, because sem stopped at the first one and the release would not
# have completed.
#
# ERRING TOWARD SILENCE, deliberately, the same way SchemaScripts errs toward
# EXPANDING. A false collision here blocks a release AND every session's
# database, so anything that would need real SQL semantics to get right is left
# out rather than guessed:
#
#   * CONSTRAINTS are not tracked. `alter table t add constraint c` twice does
#     halt sem, but `drop table x cascade` silently drops the inbound foreign
#     keys of OTHER tables — modelling that needs the reference graph, and
#     without it 20260701-120000.sql reads as two collisions it does not have.
#   * FUNCTIONS are not tracked. Overloading makes the identity a signature, not
#     a name, and the house style is `create or replace` anyway.
#   * TEMP tables are skipped: they belong to the session that made them, so two
#     scripts creating `_decouple` are not in conflict.
#   * `alter table ... set schema` is not modelled. It does not appear in any of
#     the 904 scripts; if it ever does, it can only cause a MISSED collision.
#
# Measured against all 904 platform-postgresql scripts at main: zero findings.
# Against the tree as it stood between #507 and the fix, seven — the three
# tables and four of the indexes.
module SchemaCollisions
  SCRIPTS_DIR = "scripts".freeze

  # Objects whose name must be unique within their schema, and whose second
  # unguarded CREATE is therefore a hard error rather than a no-op.
  OBJECT_KINDS = %w[table view sequence type index].freeze

  # `create [unlogged] [temp] [or replace] [unique] [materialized] <kind>
  #  [concurrently] [if not exists] <name> [on <table>]`
  #
  # Anchored at the start of the statement on purpose: a `create table` inside a
  # dollar-quoted function body or a DO block survives the naive `;` split as a
  # mid-statement fragment, and reading those as real creates would invent
  # collisions. Missing one can only cost a finding.
  CREATE = /
    \Acreate\s+
    (?:unlogged\s+)?
    (?:(?:global|local)\s+)?
    (?<temp>(?:temp|temporary)\s+)?
    (?<replace>or\s+replace\s+)?
    (?:unique\s+)?
    (?:materialized\s+)?
    (?<kind>#{OBJECT_KINDS.join('|')})\s+
    (?:concurrently\s+)?
    (?<guard>if\s+not\s+exists\s+)?
    (?<name>[\w".]+)
    (?:\s+on\s+(?<on>[\w".]+))?
  /x

  # `drop <kind> [if exists] a, b, c [cascade]`. The comma list is not an edge
  # case — ten scripts drop a whole feature's tables in one statement, and
  # reading only the first name leaves the rest live forever.
  DROP = /\Adrop\s+(?:materialized\s+)?(?<kind>#{OBJECT_KINDS.join('|')})\s+(?:if\s+exists\s+)?(?<names>.+)\z/

  CREATE_SCHEMA = /\Acreate\s+schema\s+(?<guard>if\s+not\s+exists\s+)?(?<name>[\w"]+)/
  DROP_SCHEMA   = /\Adrop\s+schema\s+(?:if\s+exists\s+)?(?<names>.+)\z/

  # Every script sets its own search_path and puts it back to public at the end,
  # and the generated migrations name their tables UNQUALIFIED underneath it —
  # which is the whole reason this has to be tracked. Both ISS-592 scripts say
  # `set search_path to issues;` and then `create table issue_intake_senders`;
  # without the search_path they look like two different tables.
  SEARCH_PATH = /\Aset\s+(?:local\s+)?search_path\s+(?:to|=)\s+(?<list>.+)\z/

  RENAME_TABLE = /\Aalter\s+table\s+(?:if\s+exists\s+)?(?<from>[\w".]+)\s+rename\s+to\s+(?<to>[\w".]+)/
  RENAME_INDEX = /\Aalter\s+index\s+(?:if\s+exists\s+)?(?<from>[\w".]+)\s+rename\s+to\s+(?<to>[\w".]+)/

  # Both of these MOVE a live object rather than adding one, and both are in use
  # here: `alter schema privatedinkers rename to rallyd` carried 20 tables, and
  # 27 statements move a table into hoa / playbook / clubaid with SET SCHEMA.
  # Without them those objects stay recorded under a name nothing will ever
  # create again, and a genuine second CREATE of the name they moved TO goes
  # unnoticed.
  ALTER_SCHEMA_RENAME = /\Aalter\s+schema\s+(?<from>[\w"]+)\s+rename\s+to\s+(?<to>[\w"]+)/
  SET_SCHEMA = /\Aalter\s+(?:materialized\s+)?(?<kind>#{OBJECT_KINDS.join('|')})\s+(?:if\s+exists\s+)?(?<name>[\w".]+)\s+set\s+schema\s+(?<schema>[\w"]+)/

  # The default search_path every script starts under. sem-apply runs each
  # script in its own psql session, so a script that never sets one is in public.
  DEFAULT_SCHEMA = "public".freeze

  Collision = Struct.new(:script, :kind, :name, :first_script, keyword_init: true) do
    def to_s
      "#{kind} #{name} — created by #{first_script}, created again by #{script}"
    end
  end

  # Every collision in a schema repo's scripts directory, in the order
  # sem-apply would hit them.
  def SchemaCollisions.scan(repo_dir)
    replay = Replay.new
    SchemaCollisions.scripts(repo_dir).each do |path|
      replay.apply(File.basename(path), File.read(path))
    end
    replay.collisions
  end

  # sem-apply's own ordering: every *.sql under scripts/, by filename.
  def SchemaCollisions.scripts(repo_dir)
    Dir[File.join(repo_dir, SCRIPTS_DIR, "*.sql")].sort
  end

  # The scripts a collision implicates, first-created before second-created, so a
  # caller can say which two PRs need to talk to each other.
  def SchemaCollisions.scripts_involved(collisions)
    collisions.flat_map { |c| [c.first_script, c.script] }.uniq.sort
  end

  def SchemaCollisions.describe(collisions)
    collisions.group_by(&:script).map { |script, found|
      ["  #{script}"] + found.map { |c| "      #{c.kind} #{c.name} — already created by #{c.first_script}" }
    }.flatten.join("\n")
  end

  # What every caller prints. One text, because the reader's question is the
  # same wherever they hit it: which two scripts, and what do I do about it.
  def SchemaCollisions.failure_message(repo_dir, collisions)
    <<~TEXT
      #{repo_dir} cannot be applied to a database built from scratch.

      #{collisions.length} object(s) are created twice, and Postgres answers the second CREATE with
      `already exists`. That HALTS sem-apply: every migration after the collision is
      blocked too, not just the pair that collided.

      #{describe(collisions)}

      This is what two branches adding the same generated migration looks like (ISS-592).
      Neither script can be withdrawn once released, so the fix is to edit the LATER one —
      keep the DAO generator's leading `drop table if exists`, so it recreates rather than
      collides, and carry over any data the earlier script seeded.

      `dev schema lint --app <app>` re-checks in about a second.
    TEXT
  end

  # The gate. Every caller that is about to replay scripts uses this: a collision
  # is not a thing to warn about and continue past, because the apply it precedes
  # cannot succeed.
  #
  # `epilogue` is for the caller that has to say what it did NOT do — release-db
  # aborts before anything leaves the machine, and an operator reading a wall of
  # red needs to be told that.
  def SchemaCollisions.assert_none!(repo_dir, epilogue: nil)
    found = SchemaCollisions.scan(repo_dir)
    return if found.empty?
    message = SchemaCollisions.failure_message(repo_dir, found)
    message += "\n#{epilogue}" if epilogue
    Util.exit_with_error(message)
  end

  # The live set of named objects, advanced one statement at a time.
  class Replay
    attr_reader :collisions

    def initialize
      @live = {}         # [kind, qualified name] => the script that created it
      @index_table = {}  # qualified index name => the table it is on
      @collisions = []
    end

    def apply(script, sql)
      @script = script
      @schema = DEFAULT_SCHEMA
      SchemaCollisions.statements(sql).each { |statement| apply_statement(statement) }
    end

    private

    def apply_statement(statement)
      if (m = statement.match(SEARCH_PATH))
        # `set search_path to a, b` — a bare CREATE lands in the first entry.
        @schema = unquote(m[:list].split(",").first.to_s.strip)
        return
      end

      return drop_schema(m[:names]) if (m = statement.match(DROP_SCHEMA))
      return create_schema(m) if (m = statement.match(CREATE_SCHEMA))
      return drop_objects(m[:kind], m[:names]) if (m = statement.match(DROP))
      return create_object(m) if (m = statement.match(CREATE))
      return rename_schema(unquote(m[:from]), unquote(m[:to])) if (m = statement.match(ALTER_SCHEMA_RENAME))
      return set_schema(m) if (m = statement.match(SET_SCHEMA))
      return move("table", qualify(unquote(m[:from])), qualify(unquote(m[:to]))) if (m = statement.match(RENAME_TABLE))
      return move("index", qualify(unquote(m[:from])), qualify(unquote(m[:to]))) if (m = statement.match(RENAME_INDEX))
    end

    def create_schema(m)
      record(["schema", unquote(m[:name])], guarded: !m[:guard].nil?)
    end

    # A schema drop takes everything in it with it, which is how a feature that
    # was rebuilt under a new design does not read as a collision with itself.
    def drop_schema(names)
      each_name(names) do |raw|
        schema = unquote(raw)
        @live.delete(["schema", schema])
        @live.keys.each { |key| @live.delete(key) if key[1].start_with?("#{schema}.") }
        @index_table.keys.each { |index| @index_table.delete(index) if index.start_with?("#{schema}.") }
      end
    end

    def create_object(m)
      return if m[:temp]
      kind = m[:kind]
      name = unquote(m[:name])
      # `create index on t(...)` leaves Postgres to name it, so there is no name
      # to collide — the parser sees `on` where a name would be.
      return if kind == "index" && name == "on"

      qualified = qualify(name)
      # `create or replace view` overwrites rather than erroring, so it is a
      # guard in the same sense `if not exists` is.
      record([kind, qualified], guarded: !m[:guard].nil? || !m[:replace].nil?)
      @index_table[qualified] = qualify(unquote(m[:on])) if kind == "index" && m[:on]
    end

    def drop_objects(kind, names)
      each_name(names) do |raw|
        qualified = qualify(unquote(raw))
        @live.delete([kind, qualified])
        drop_indexes_on(qualified) if kind == "table"
      end
    end

    # Dropping a table drops its indexes with it. Not an optional refinement:
    # `drop table if exists x; create table x; create index x_id_idx on x` is the
    # standard re-runnable shape, and without this every index in every such
    # script reads as a collision — 133 of them across platform-postgresql.
    def drop_indexes_on(table)
      @index_table.select { |_, on| on == table }.each_key do |index|
        @live.delete(["index", index])
        @index_table.delete(index)
      end
    end

    # A rename or a schema move FREES the old name — 20260702-120000.sql renames
    # user_last_sessions out of the way and then creates a NEW table under it,
    # which is not a collision and must not read as one.
    def move(kind, from, to)
      key = [kind, from]
      @live[[kind, to]] = @live.delete(key) if @live.key?(key)
      if kind == "table"
        # Postgres carries a table's indexes with it, under both a rename and a
        # SET SCHEMA, so a later `drop table <new name>` still clears them.
        @index_table.each { |index, on| @index_table[index] = to if on == from }
      elsif kind == "index" && @index_table.key?(from)
        @index_table[to] = @index_table.delete(from)
      end
    end

    def set_schema(m)
      name = qualify(unquote(m[:name]))
      move(m[:kind], name, "#{unquote(m[:schema])}.#{name.split('.').last}")
    end

    def rename_schema(from, to)
      @live[["schema", to]] = @live.delete(["schema", from]) if @live.key?(["schema", from])
      # Tables first, so their indexes are re-pointed at the new table name
      # before the indexes themselves are re-keyed.
      moving = @live.keys.select { |_kind, name| name.start_with?("#{from}.") }
      moving.sort_by { |kind, _name| kind == "table" ? 0 : 1 }.each do |kind, name|
        move(kind, name, "#{to}.#{name.split('.').last}")
      end
    end

    def record(key, guarded:)
      first = @live[key]
      if first && !guarded
        @collisions << Collision.new(:script => @script, :kind => key[0], :name => key[1], :first_script => first)
      end
      @live[key] = first || @script
    end

    # A drop may name several objects, and may end in CASCADE or RESTRICT.
    def each_name(names)
      names.sub(/\s+(?:cascade|restrict)\z/, "").split(",").map(&:strip).reject(&:empty?).each { |n| yield n }
    end

    def qualify(name)
      name.include?(".") ? name : "#{@schema}.#{name}"
    end

    def unquote(name)
      name.to_s.delete('"')
    end
  end

  # One script's statements, lowercased, comments removed and whitespace
  # collapsed — the same treatment (and the same `;` split, naive for the same
  # reason) SchemaScripts.contracting_statements gives them.
  def SchemaCollisions.statements(sql)
    SchemaScripts.strip_comments(sql).downcase.split(";").filter_map do |raw|
      statement = raw.strip.gsub(/\s+/, " ")
      statement.empty? ? nil : statement
    end
  end
end
