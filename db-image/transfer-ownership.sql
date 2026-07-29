-- Transfer ownership of every application object to the database's owning role.
--
-- The schema is applied as the postgres superuser (so any permission-sensitive
-- DDL succeeds), which leaves every object owned by postgres.  The
-- migration-authoring workflow runs `sem-apply` AS the application role against
-- a session DB, and its migrations issue ALTER TABLE / DROP TABLE / CREATE
-- TABLE — all of which require OWNERSHIP, not just GRANT ALL.  This script
-- makes that role the owner of every object in non-system schemas.
--
-- We do NOT use REASSIGN OWNED BY postgres because in PG 15+ postgres owns
-- system-required objects (e.g. the public schema) that cannot be reassigned.
-- Instead a targeted ALTER ... OWNER TO loop transfers only the objects in
-- non-system schemas, leaving system/extension objects with postgres.
--
-- The role is read from the `db_image.role` GUC, which the caller SETs in the
-- same session (psql does not interpolate :variables inside a dollar-quoted
-- block, so a psql variable cannot reach in here).  Shared by the image init
-- script and by `db-image`'s scratch builds.
DO $$
DECLARE
    r record;
    owner_role text := current_setting('db_image.role');
BEGIN
    -- Non-system schemas: make the role the owner so it can CREATE new objects.
    FOR r IN
        SELECT nspname
        FROM pg_namespace
        WHERE nspname NOT LIKE 'pg_%'
          AND nspname <> 'information_schema'
    LOOP
        EXECUTE format('ALTER SCHEMA %I OWNER TO %I', r.nspname, owner_role);
    END LOOP;

    -- Relations: tables, partitioned tables, sequences, views, matviews,
    -- foreign tables.  Skip extension-member objects (deptype 'e').
    -- Indexes/toast inherit ownership from their table.  Serial/identity
    -- sequences linked to a table column (deptype 'a'/'i') CANNOT have
    -- their owner changed independently — they follow the owning table's
    -- owner automatically when we ALTER TABLE below, so skip them here.
    FOR r IN
        SELECT n.nspname,
               c.relname,
               c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT LIKE 'pg_%'
          AND n.nspname <> 'information_schema'
          AND c.relkind IN ('r','p','S','v','m','f')
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_class'::regclass
                AND d.objid = c.oid
                AND d.deptype = 'e'
          )
          AND NOT (
              c.relkind = 'S' AND EXISTS (
                  SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_class'::regclass
                    AND d.objid = c.oid
                    AND d.refclassid = 'pg_class'::regclass
                    AND d.deptype IN ('a','i')
              )
          )
    LOOP
        EXECUTE format(
            CASE r.relkind
                WHEN 'S' THEN 'ALTER SEQUENCE %I.%I OWNER TO %I'
                WHEN 'v' THEN 'ALTER VIEW %I.%I OWNER TO %I'
                WHEN 'm' THEN 'ALTER MATERIALIZED VIEW %I.%I OWNER TO %I'
                WHEN 'f' THEN 'ALTER FOREIGN TABLE %I.%I OWNER TO %I'
                ELSE 'ALTER TABLE %I.%I OWNER TO %I'
            END,
            r.nspname, r.relname, owner_role);
    END LOOP;

    -- Functions and procedures (ALTER ROUTINE handles both).
    -- Skip extension-member routines.
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT LIKE 'pg_%'
          AND n.nspname <> 'information_schema'
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_proc'::regclass
                AND d.objid = p.oid
                AND d.deptype = 'e'
          )
    LOOP
        EXECUTE format('ALTER ROUTINE %s OWNER TO %I', r.sig, owner_role);
    END LOOP;

    -- Standalone composite/enum/domain types (skip those auto-created for
    -- tables, which are reassigned with their table, and extension types).
    FOR r IN
        SELECT n.nspname, t.typname
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname NOT LIKE 'pg_%'
          AND n.nspname <> 'information_schema'
          AND t.typtype IN ('c','e','d')
          AND NOT EXISTS (
              SELECT 1 FROM pg_class c
              WHERE c.oid = t.typrelid AND c.relkind <> 'c'
          )
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_type'::regclass
                AND d.objid = t.oid
                AND d.deptype = 'e'
          )
    LOOP
        EXECUTE format('ALTER TYPE %I.%I OWNER TO %I', r.nspname, r.typname, owner_role);
    END LOOP;
END;
$$;
