require 'set'

# Reading a production pg_dump snapshot for the purpose of cutting a baseline
# schema (see bin/db-image baseline).
#
# A production snapshot is the only honest source for a baseline: the image then
# carries what production actually has, and drift shows up as a diff instead of
# hiding inside a reconstruction. But its DATA must never reach an image that is
# pushed to a shared registry and cloned into every Claude session — so the rows
# are dropped as the file streams, and never exist locally at all.
module DbSnapshot
  # COPY blocks always kept, whatever else is dropped. These are data rows that
  # are really SCHEMA STATE:
  #
  #   schema_evolution_manager.*  what sem-apply consults to know which scripts
  #     have already run. Drop them and the next sem-apply replays the entire
  #     script history against an already-full schema.
  #
  #   journal.settings  the table describing the journal tables, partitions and
  #     triggers. pg_dump --schema-only carries every object journal.setup()
  #     creates but none of the rows it writes (they are inserted from inside
  #     the function body), and an empty journal.settings leaves everything that
  #     iterates it silently doing nothing — that is what made
  #     MaintainPartitionsProcessorSpec fail against every session DB and left
  #     PartitionInvariants deriving zero checks.
  SCHEMA_STATE_TABLES = [
    "schema_evolution_manager.scripts",
    "schema_evolution_manager.bootstrap_scripts",
    "journal.settings"
  ].freeze

  # COPY data is terminated by a lone backslash-dot line.
  COPY_TERMINATOR = "\\.".freeze

  # The table a `COPY ... FROM stdin;` line names, unquoted, or nil.
  def DbSnapshot.copy_target(line)
    m = line.match(/\ACOPY\s+(\S+)\s/)
    return nil unless m
    m[1].gsub('"', '')
  end

  # True for statements a restore into an app-role-owned database cannot run.
  #
  # pg_dump emits `ALTER SCHEMA public OWNER TO postgres` when the source
  # cluster's public schema is owned by the bootstrap superuser. The restore
  # runs against a database owned by the application role, which cannot assign
  # ownership to postgres ("must be able to SET ROLE").
  def DbSnapshot.unrestorable?(line)
    line.start_with?("ALTER SCHEMA public OWNER TO postgres;")
  end

  # Stream `path` into `io`, keeping the schema in full and dropping every COPY
  # block whose table is not in `keep`.
  #
  # Returns [kept_tables, dropped_block_count] for reporting.
  def DbSnapshot.stream_schema_only(path, keep, io)
    keep = keep.map { |t| t.to_s.gsub('"', '') }.to_set
    kept = []
    dropped = 0
    skipping = false

    File.foreach(path) do |line|
      if skipping
        skipping = false if line.chomp == COPY_TERMINATOR
        next
      end

      next if DbSnapshot.unrestorable?(line)

      target = DbSnapshot.copy_target(line)
      if target
        if keep.include?(target)
          kept << target
        else
          dropped += 1
          skipping = true
          next
        end
      end

      io.write(line)
    end

    [kept, dropped]
  end
end
