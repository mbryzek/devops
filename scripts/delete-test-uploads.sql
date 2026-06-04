-- dev-script: targets=local
-- Remove locally-created test clubs (tst%) and everything that references them.
-- Test clubs are created by scalatest runs. Deletes must run child-before-parent
-- to satisfy every FK back to rallyd.clubs.
--
-- Approach: collect the target club ids into a temp table ONCE, then every delete
-- selects from that temp table. To delete a different set of clubs in the future,
-- change only the SELECT that populates tmp_delete_club_ids below.
--
-- Order: (1) transitive children with no direct club_id (join through their parent),
--        (2) all tables keyed directly on club_id, ordered so children precede parents,
--        (3) rallyd.clubs itself (child clubs before their parents).
--
-- To regenerate the table list, query pg_constraint for FKs whose confrelid is
-- rallyd.clubs (see git history of this file).

-- Wrapped in one transaction so the whole cleanup is atomic and so the temp
-- table's ON COMMIT DROP fires only after every delete has run.
begin;

-- Collect every club id to delete: test clubs plus any club whose parent is a test
-- club (children's dependent rows are keyed by the child's own id, not the parent's).
create temporary table tmp_delete_club_ids on commit drop as
select id from rallyd.clubs where id like 'tst%' or parent_id like 'tst%';

-- (1) Transitive children that lack a direct club_id column
delete from court_reserve.reservation_courts
 where court_id in (select id from court_reserve.courts where club_id in (select id from tmp_delete_club_ids))
    or reservation_id in (select id from court_reserve.reservations where club_id in (select id from tmp_delete_club_ids));
delete from court_reserve.reservation_players
 where reservation_id in (select id from court_reserve.reservations where club_id in (select id from tmp_delete_club_ids));
delete from clubaid.account_links
 where credential_id in (select id from integrations.credentials where club_id in (select id from tmp_delete_club_ids));
delete from court_reserve.worker_reports where club_id in (select id from tmp_delete_club_ids);

-- (2) Tables keyed directly on club_id (children before their in-schema parents)
delete from clubaid.upload_logs where club_id in (select id from tmp_delete_club_ids);
delete from clubaid.uploads where club_id in (select id from tmp_delete_club_ids);
delete from clubaid.export_watermarks where club_id in (select id from tmp_delete_club_ids);
delete from clubaid.user_clubs where club_id in (select id from tmp_delete_club_ids);
delete from clubaid.user_invitations where club_id in (select id from tmp_delete_club_ids);

delete from court_reserve.login_verifications where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.schedule_entries where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.worker_requests where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.upload_csvs where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.uploads where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.audit_events where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.club_crawler_states where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.event_registrations where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.event_summaries where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.events where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.families where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.guest_member_numbers where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.member_membership_intervals where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.members where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.reservations where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.sales_transactions where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.transactions where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.courts where club_id in (select id from tmp_delete_club_ids);
delete from court_reserve.clubs where club_id in (select id from tmp_delete_club_ids);

delete from integrations.credentials where club_id in (select id from tmp_delete_club_ids);
delete from integrations.disabled_integrations where club_id in (select id from tmp_delete_club_ids);

delete from playbook.revenue_entries where club_id in (select id from tmp_delete_club_ids);
delete from playbook.revenue_categories where club_id in (select id from tmp_delete_club_ids);
delete from playbook.watermarks where club_id in (select id from tmp_delete_club_ids);

delete from rallyd.courts where club_id in (select id from tmp_delete_club_ids);

-- (3) The clubs themselves: child clubs (parent_id self-FK) before their parents
delete from rallyd.clubs
 where id in (select id from tmp_delete_club_ids)
   and parent_id in (select id from tmp_delete_club_ids);
delete from rallyd.clubs where id in (select id from tmp_delete_club_ids);

-- Commit: applies all deletes and drops tmp_delete_club_ids (ON COMMIT DROP).
commit;
