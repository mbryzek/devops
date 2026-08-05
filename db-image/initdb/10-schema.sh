#!/bin/bash
# Runs once on first container start (inside docker-entrypoint-initdb.d).
# Sets up, for whichever app's image this is:
#   - $DB_ROLE            the application login role
#   - $DB_NAME            the database, schema loaded from the baked dump
#   - ${DB_NAME}_template a clone of it, flagged as a Postgres template
#
# Schema is applied as the postgres superuser so that any permission-sensitive
# DDL (extensions, etc.) succeeds.  Ownership of every application object is
# then transferred to $DB_ROLE (see transfer-ownership.sql) so the
# migration-authoring workflow works: Claude runs `sem-apply` AS that role
# against a session DB cloned from the template, and migrations issue
# ALTER/DROP/CREATE TABLE — all of which require OWNERSHIP, not just GRANT ALL.
set -euo pipefail

: "${DB_NAME:?DB_NAME is not set — the image was built without --build-arg DB_NAME}"
: "${DB_ROLE:=api}"

echo "[10-schema] Creating role $DB_ROLE and database $DB_NAME..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE ROLE $DB_ROLE WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    CREATE DATABASE $DB_NAME OWNER $DB_ROLE;
EOSQL

echo "[10-schema] Applying schema as superuser..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" \
    -f /schema/schema.sql

echo "[10-schema] Applying seed data..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" \
    -f /schema/seed.sql

echo "[10-schema] Loading SEM tracking data (scripts + bootstrap_scripts rows + sequence positions)..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" \
    -f /schema/sem-tracking.sql

# Empty for an app with no journal schema.
echo "[10-schema] Loading journal partition/queue settings..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" \
    -f /schema/journal-settings.sql

# The rows the migrations replayed at build time INSERTED. schema.sql is
# --schema-only and carries none of them, while sem-tracking.sql above records
# those same scripts as applied -- so without this every data migration is
# recorded as done in a session database whose rows it never wrote, and
# `claude-db sync` will never re-run it. That is what left agent.agent_producers
# and agent.agent_producer_playbooks empty in every session DB (ISS-559) while
# the specs that read them failed on unmodified main.
#
# After seed.sql because a migration's rows may reference a seeded tenant, and
# before the partition maintenance below because the dump is --disable-triggers
# and so needs no partition to exist. Empty when built at the baseline tag.
echo "[10-schema] Loading rows inserted by migrations..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" \
    -f /schema/migration-data.sql

# The baked dump carries the partitions that existed when the image was BUILT, and journal
# partitions are per-period. An image cut in July has no August partition, so on August 1st every
# session database cloned from it fails every insert into a journaled table with
# `no partition of relation "<table>" found for row` -- 2,372 of them in one suite (ISS-203). It
# reads exactly like a catastrophic regression in whatever branch is checked out, and it is purely
# an artifact of the image's age. Maintaining here re-bases the partitions on the day the container
# first starts, which is the day the template every session clones is actually made.
#
# The guard is what keeps this app-agnostic: an app with no journal schema has an empty
# journal-settings.sql and no journal.maintain_partitions, and gets a no-op.
echo "[10-schema] Creating journal partitions for the current period..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" <<-'EOSQL'
    DO $$
    DECLARE
      r record;
    BEGIN
      IF to_regprocedure('journal.maintain_partitions(text,text)') IS NULL THEN
        RETURN;
      END IF;
      FOR r IN SELECT journal_schema, journal_table FROM journal.settings LOOP
        PERFORM journal.maintain_partitions(r.journal_schema, r.journal_table);
      END LOOP;
    END $$;
EOSQL

# The role is passed as a custom GUC rather than a psql variable: psql does NOT
# interpolate :vars inside the dollar-quoted DO block that script is built from,
# so current_setting() is what makes it parameterisable at all. The -c and the
# -f run in ONE session, in order, so the SET is still in effect for the script.
echo "[10-schema] Transferring ownership of all application objects to $DB_ROLE..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB_NAME" \
    -c "SET db_image.role = '$DB_ROLE'" \
    -f /schema/transfer-ownership.sql

echo "[10-schema] Creating ${DB_NAME}_template from $DB_NAME..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE DATABASE ${DB_NAME}_template TEMPLATE $DB_NAME OWNER $DB_ROLE;
    UPDATE pg_database SET datistemplate = true WHERE datname = '${DB_NAME}_template';
EOSQL

echo "[10-schema] Done — $DB_NAME and ${DB_NAME}_template are ready."
