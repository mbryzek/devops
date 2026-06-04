-- dev-script: targets=local,production app=platform
-- Truncate court_reserve (+ derived clubaid/playbook) data for a fresh upload.
--
-- One-off data cleanup (human-run, NOT a SEM migration).
--
-- Context: the Event Summary ingestion bug (CsvEventSummaryParser read the
-- wrong CR columns) corrupted court_reserve staging data — Event Summary rows
-- collapsed to one-per-(name,category) with a 1/1/1900 date. The fix reworks
-- the schema + parser; to get clean data we re-run the CourtReserve crawl +
-- upload end to end. This script wipes the CR-DERIVED data tables so the
-- fresh upload repopulates them from scratch.
--
-- event_summaries is intentionally omitted: it is dropped + recreated by the
-- structural migration in scripts/, so it is already empty.
--
-- Run against the target DB (pin local platformdb explicitly; never prod
-- without intent). All listed tables are truncated together so FKs among
-- them are satisfied in one statement.

set search_path to court_reserve;

truncate table
  court_reserve.audit_events,
  court_reserve.courts,
  court_reserve.event_registrations,
  court_reserve.events,
  court_reserve.families,
  court_reserve.members,
  court_reserve.reservation_courts,
  court_reserve.reservation_players,
  court_reserve.reservations,
  court_reserve.sales_transactions,
  court_reserve.transactions,
  court_reserve.uploads,
  court_reserve.upload_csvs
  cascade;

set search_path to public;

truncate table clubaid.uploads, clubaid.upload_logs, clubaid.export_watermarks;
truncate table playbook.revenue_categories, playbook.revenue_entries, playbook.transaction_types, playbook.watermarks;

-- NOT truncated — operational config / credentials / crawler state, NOT
-- re-derived by a data upload. Wiping these would break the integration
-- (e.g. integrations holds CR credentials, organizations maps clubs -> CR
-- orgs). Confirm with Mike before adding any of these:
--   club_crawler_states, disabled_workers, integrations, log_review_runs,
--   log_review_tickets, login_verifications, organizations, proxy_instances,
--   schedule_entries, worker_configs, worker_reports,
--   worker_requests
