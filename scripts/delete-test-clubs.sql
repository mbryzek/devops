-- dev-script: targets=local
-- Delete every test-generated club (id like 'club-%') and all dependent rows.
--
-- Re-runnable developer utility for purging accumulated test clubs (created by
-- scalatest runs) from the local platformdb. Club ids are name-derived
-- (InternalClubsDao.generateId -> makeUrlSafe(name.toLowerCase)), and every test
-- helper names its clubs "Club <x>" (see integrations/test/.../ClubHelpers
-- .createClub), so 'club-%' is exactly the set of test clubs. Real clubs
-- ("Bounce HQ", "Baltimore") get ids like bounce-hq / baltimore and are NOT
-- matched.
--
-- targets=local because the match is not prod-safe: in production a real club
-- could be named "Club Med" -> "club-med" and would match.
--
-- All FKs onto these tables are NO ACTION (no cascade). Delete order is the full
-- reverse-topological order of the FK DAG across the delete universe.
-- Multi-level subtrees are flattened into id temp tables so no delete needs deep
-- nesting. One transaction: any missed edge aborts + rolls back with zero changes.
--
-- To find tables missing from this script (new FKs land here over time), run the
-- transitive closure of FK children from playbook.clubs and diff it against the
-- `delete from` lines below:
--
--   with recursive edges as (
--     select cn.nspname||'.'||c.relname as child, fn.nspname||'.'||f.relname as parent
--     from pg_constraint con
--     join pg_class c on c.oid=con.conrelid join pg_namespace cn on cn.oid=c.relnamespace
--     join pg_class f on f.oid=con.confrelid join pg_namespace fn on fn.oid=f.relnamespace
--     where con.contype='f'
--   ), closure as (
--     select child from edges where parent='playbook.clubs'
--     union
--     select e.child from edges e join closure cl on e.parent=cl.child
--   ) select distinct child from closure order by 1;
--
-- Two nets now catch that drift instead of leaving it to whoever remembers to run
-- the query above:
--   * the drift guard near the bottom, which asks the catalog for every table
--     carrying a club_id column and fails NAMING any that still holds targeted
--     rows (this also covers the two club_id columns that have no FK at all);
--   * the FK constraints themselves, for indirect children reached through a
--     parent rather than through club_id.
-- Being hand-maintained at all is the real defect: ISS-827 replaces this script
-- with an itemized delete generated from the club reference registry.
begin;
-- A concurrent scalatest run inserting into a child table would otherwise make the
-- final clubs delete fail on an FK it cannot see. `for update` on the root set takes
-- the same row lock an FK insert needs (FOR KEY SHARE), so child inserts against a
-- targeted club block until we commit; lock_timeout turns a live test run into a fast,
-- legible failure instead of an indefinite wait.
set local lock_timeout = '10s';

-- Root set + flattened id sets for every multi-level / cross subtree.
-- Every delete below is scoped to this snapshot: clubs created after it (by a test run
-- racing this script) are left entirely alone and cleaned up by the next run.
create temp table _del_clubs on commit drop as
  select id from playbook.clubs where id like 'club-%' for update;
create unique index on _del_clubs (id);

create temp table _del_insights on commit drop as
  select id from playbook.insights where club_id in (select id from _del_clubs);
create unique index on _del_insights (id);
create temp table _del_insight_sections on commit drop as
  select id from playbook.insight_sections where insight_id in (select id from _del_insights);
create unique index on _del_insight_sections (id);
create temp table _del_insight_section_chats on commit drop as
  select id from playbook.insight_section_chats where insight_section_id in (select id from _del_insight_sections);
create unique index on _del_insight_section_chats (id);
create temp table _del_insight_runs on commit drop as
  select id from playbook.insight_runs where club_id in (select id from _del_clubs);
create unique index on _del_insight_runs (id);
create temp table _del_insight_tool_calls on commit drop as
  select id from playbook.insight_tool_calls where insight_run_id in (select id from _del_insight_runs);
create unique index on _del_insight_tool_calls (id);
create temp table _del_reservations on commit drop as
  select id from court_reserve.reservations where club_id in (select id from _del_clubs);
create unique index on _del_reservations (id);
create temp table _del_cr_courts on commit drop as
  select id from court_reserve.courts where club_id in (select id from _del_clubs);
create unique index on _del_cr_courts (id);
create temp table _del_credentials on commit drop as
  select id from integrations.credentials where club_id in (select id from _del_clubs);
create unique index on _del_credentials (id);
create temp table _del_invocations on commit drop as
  select id from worker.invocations where club_id in (select id from _del_clubs);
create unique index on _del_invocations (id);
create temp table _del_issues on commit drop as
  select id from issues.issues where club_id in (select id from _del_clubs);
create unique index on _del_issues (id);
create temp table _del_checklist_items on commit drop as
  select id from playbook.checklist_items where club_id in (select id from _del_clubs);
create unique index on _del_checklist_items (id);
create temp table _del_executions on commit drop as
  select id from playbook.executions where club_id in (select id from _del_clubs);
create unique index on _del_executions (id);
create temp table _del_members on commit drop as
  select id from playbook.members where club_id in (select id from _del_clubs);
create unique index on _del_members (id);
create temp table _del_member_messages on commit drop as
  select id from playbook.member_messages where club_id in (select id from _del_clubs);
create unique index on _del_member_messages (id);
create temp table _del_people on commit drop as
  select id from playbook.people where club_id in (select id from _del_clubs);
create unique index on _del_people (id);

do $$ begin raise notice 'Clubs targeted: %', (select count(*) from _del_clubs); end $$;

-- ---- change-journal queues for journaled tables in the delete universe -----
-- Deleting a club's rows here does NOT clean up journal_<schema>.q_<table> /
-- journal_<schema>.<table> for any table under `journal.setup(...)` (see e.g.
-- dao/psql/court_reserve.members.sql). Left behind, those entries later fail their
-- journal actor's apply step with an FK violation ("Detail: Key (club_id)=(...) is
-- not present in table clubs") once the parent row here is gone. The actor treats
-- that as a permanent/poison entry and drops it (BaseJournalActor.dropPoison), so
-- nothing breaks, but every run of this script otherwise leaves that WARN noise for
-- the actor to discover later. Purge the queues/history proactively instead.
--
-- journal_<schema>.<table>.parent_id = the journaled row's own `id` (its PK), NOT
-- club_id, so each purge below joins back through an id set scoped to the targeted
-- clubs. q_<table> only has journal_id (no FK to the journal table, no club_id), so
-- it must be purged via the journal table's parent_id, in q_ -> journal order (queue
-- rows would otherwise reference a since-deleted journal row).
--
-- Tables here = the intersection of this script's delete universe and every
-- `journal.setup(...)` call in dao/psql/*.sql as of this writing. If a table gains
-- journal.setup(...) later, or this script starts deleting from a new journaled
-- table, add its purge here too.
create temp table _del_cr_members on commit drop as
  select id from court_reserve.members where club_id in (select id from _del_clubs);
create unique index on _del_cr_members (id);
create temp table _del_cr_memberships on commit drop as
  select id from court_reserve.memberships where club_id in (select id from _del_clubs);
create unique index on _del_cr_memberships (id);
create temp table _del_cr_member_membership_intervals on commit drop as
  select id from court_reserve.member_membership_intervals where club_id in (select id from _del_clubs);
create unique index on _del_cr_member_membership_intervals (id);

delete from journal_court_reserve.q_members
  where journal_id in (select id from journal_court_reserve.members where parent_id in (select id from _del_cr_members));
delete from journal_court_reserve.members where parent_id in (select id from _del_cr_members);

delete from journal_court_reserve.q_memberships
  where journal_id in (select id from journal_court_reserve.memberships where parent_id in (select id from _del_cr_memberships));
delete from journal_court_reserve.memberships where parent_id in (select id from _del_cr_memberships);

delete from journal_court_reserve.q_member_membership_intervals
  where journal_id in (select id from journal_court_reserve.member_membership_intervals where parent_id in (select id from _del_cr_member_membership_intervals));
delete from journal_court_reserve.member_membership_intervals where parent_id in (select id from _del_cr_member_membership_intervals);

delete from journal_playbook.q_member_messages
  where journal_id in (select id from journal_playbook.member_messages where parent_id in (select id from _del_member_messages));
delete from journal_playbook.member_messages where parent_id in (select id from _del_member_messages);

-- playbook.clubs' own journal entries: parent_id here IS the club id directly.
delete from journal_playbook.q_clubs
  where journal_id in (select id from journal_playbook.clubs where parent_id in (select id from _del_clubs));
delete from journal_playbook.clubs where parent_id in (select id from _del_clubs);

-- ---- Playbook insight cluster (deepest children first) ---------------------
delete from playbook.insight_work_items            where insight_id in (select id from _del_insights);
delete from playbook.insight_section_chat_messages where insight_section_chat_id in (select id from _del_insight_section_chats);
delete from playbook.insight_section_chats         where insight_section_id in (select id from _del_insight_sections);
delete from playbook.insight_section_votes         where insight_section_id in (select id from _del_insight_sections);
delete from playbook.insight_claims
  where insight_id in (select id from _del_insights)
     or insight_section_id in (select id from _del_insight_sections)
     or insight_tool_call_id in (select id from _del_insight_tool_calls);
delete from playbook.checklist_item_insights
  where checklist_item_id in (select id from _del_checklist_items)
     or insight_id in (select id from _del_insights)
     or insight_section_id in (select id from _del_insight_sections);
-- Checklist cluster. checklist_items hangs off checklist_generations, which hangs off
-- insights, so the whole chain has to precede the insights delete below. Within it:
-- member_message_emails -> member_messages -> execution_recipients -> executions ->
-- checklist_items (member_messages also hangs off execution_recipients, so it goes first).
delete from playbook.member_message_emails          where message_id in (select id from _del_member_messages);
delete from playbook.member_messages                where club_id in (select id from _del_clubs);
delete from playbook.execution_recipients
  where execution_id in (select id from _del_executions)
     or member_id in (select id from _del_members);
delete from playbook.executions                     where club_id in (select id from _del_clubs);
delete from playbook.checklist_item_checks          where checklist_item_id in (select id from _del_checklist_items);
delete from playbook.checklist_item_comments        where checklist_item_id in (select id from _del_checklist_items);
delete from playbook.checklist_item_reviews         where checklist_item_id in (select id from _del_checklist_items);
-- playbook_rule_logs references checklist_items AND insights AND clubs, so it has to
-- precede both. (It was named insight_rule_logs when this script was written.)
delete from playbook.playbook_rule_logs             where club_id in (select id from _del_clubs);
delete from playbook.checklist_items                 where club_id in (select id from _del_clubs);
delete from playbook.checklist_generations          where club_id in (select id from _del_clubs);
delete from playbook.insight_sections              where insight_id in (select id from _del_insights);
delete from playbook.insight_reviews               where insight_id in (select id from _del_insights);
delete from playbook.insight_tool_calls            where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insight_findings              where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insight_judgments             where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insight_run_stages            where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insights                       where club_id in (select id from _del_clubs);
delete from playbook.insight_runs                   where club_id in (select id from _del_clubs);
delete from playbook.revenue_entries               where club_id in (select id from _del_clubs);
delete from playbook.revenue_daily_totals           where club_id in (select id from _del_clubs);
delete from playbook.revenue_categories             where club_id in (select id from _del_clubs);
delete from playbook.club_revenue_targets           where club_id in (select id from _del_clubs);
delete from playbook.club_insight_settings          where club_id in (select id from _del_clubs);
delete from playbook.club_memory_facts              where club_id in (select id from _del_clubs);
delete from playbook.report_exports                 where club_id in (select id from _del_clubs);
delete from playbook.watermarks                     where club_id in (select id from _del_clubs);

-- ---- playbook club chats (messages -> chats) --------------------------------
delete from playbook.club_chat_messages
  where club_chat_id in (select id from playbook.club_chats where club_id in (select id from _del_clubs));
delete from playbook.club_chats                      where club_id in (select id from _del_clubs);

-- ---- playbook ---------------------------------------------------------------
delete from playbook.user_club_notification_optouts  where club_id in (select id from _del_clubs);
delete from playbook.user_clubs                       where club_id in (select id from _del_clubs);
delete from playbook.user_invitations                where club_id in (select id from _del_clubs);

-- ---- court_reserve event/reservation cluster -------------------------------
delete from court_reserve.reservation_courts        where reservation_id in (select id from _del_reservations) or court_id in (select id from _del_cr_courts);
delete from court_reserve.reservation_players       where reservation_id in (select id from _del_reservations);
-- reservation_coaches -> (reservations, playbook.coaches): both parents are in the
-- delete universe, and a row can hang off either side, so scope to both.
delete from court_reserve.reservation_coaches
  where reservation_id in (select id from _del_reservations)
     or coach_id in (select id from playbook.coaches where club_id in (select id from _del_clubs));
delete from court_reserve.event_registrants         where club_id in (select id from _del_clubs);
delete from court_reserve.event_summaries           where club_id in (select id from _del_clubs);
delete from court_reserve.reservations              where club_id in (select id from _del_clubs);
delete from court_reserve.event_occurrences         where club_id in (select id from _del_clubs);
delete from court_reserve.events                    where club_id in (select id from _del_clubs);
delete from court_reserve.courts                     where club_id in (select id from _del_clubs);
delete from court_reserve.upload_csvs               where club_id in (select id from _del_clubs);
delete from court_reserve.uploads                   where club_id in (select id from _del_clubs);

-- ---- worker (via court_reserve.worker_requests) ----------------------------
delete from court_reserve.worker_reports            where club_id in (select id from _del_clubs);
delete from worker.invocation_logs                  where invocation_id in (select id from _del_invocations);
delete from court_reserve.worker_requests           where club_id in (select id from _del_clubs);
delete from worker.invocations                       where club_id in (select id from _del_clubs);

-- ---- court_reserve independent tables --------------------------------------
delete from court_reserve.audit_events              where club_id in (select id from _del_clubs);
delete from court_reserve.club_crawler_states       where club_id in (select id from _del_clubs);
delete from court_reserve.clubs                      where club_id in (select id from _del_clubs);
delete from court_reserve.direct_fetch_windows      where club_id in (select id from _del_clubs);
delete from court_reserve.families                   where club_id in (select id from _del_clubs);
delete from court_reserve.member_membership_intervals where club_id in (select id from _del_clubs);
delete from court_reserve.members                    where club_id in (select id from _del_clubs);
delete from court_reserve.report_urls                where club_id in (select id from _del_clubs);
delete from court_reserve.sales_details              where club_id in (select id from _del_clubs);
delete from court_reserve.sales_summaries            where club_id in (select id from _del_clubs);
delete from court_reserve.sales_categories           where club_id in (select id from _del_clubs);
delete from court_reserve.sessions                   where club_id in (select id from _del_clubs);
delete from court_reserve.transactions               where club_id in (select id from _del_clubs);
delete from court_reserve.refunds                    where club_id in (select id from _del_clubs);

-- ---- court_reserve gap-scan cluster (windows -> sweeps) ---------------------
delete from court_reserve.gap_scan_windows          where club_id in (select id from _del_clubs);
delete from court_reserve.gap_scan_sweeps           where club_id in (select id from _del_clubs);
delete from court_reserve.gap_scan_states           where club_id in (select id from _del_clubs);
delete from court_reserve.gap_scan_findings         where club_id in (select id from _del_clubs);

-- ---- court_reserve memberships (memberships -> membership_types) ------------
delete from court_reserve.memberships               where club_id in (select id from _del_clubs);
delete from court_reserve.membership_types          where club_id in (select id from _del_clubs);

-- ---- playbook members (scores/transitions -> members) ----------------------
delete from playbook.memberships                    where club_id in (select id from _del_clubs);
delete from playbook.member_engagement_scores       where club_id in (select id from _del_clubs);
delete from playbook.member_segment_transitions     where club_id in (select id from _del_clubs);
delete from playbook.member_engagement_backfills    where club_id in (select id from _del_clubs);
delete from playbook.member_membership_intervals    where club_id in (select id from _del_clubs);
delete from playbook.member_email_optouts           where club_id in (select id from _del_clubs);
delete from playbook.member_identity_rejections     where club_id in (select id from _del_clubs);
-- person_members links people <-> members; a row can hang off either side.
delete from playbook.person_members
  where member_id in (select id from _del_members)
     or person_id in (select id from _del_people);
delete from playbook.members                        where club_id in (select id from _del_clubs);
delete from playbook.people                         where club_id in (select id from _del_clubs);

-- ---- playbook coaches ------------------------------------------------------
-- court_reserve.reservations.coach_id references coaches, so this must run after
-- the reservation cluster above.
delete from playbook.coaches                        where club_id in (select id from _del_clubs);

-- ---- issues (tickets/attachments/comments/fixes -> issues) -----------------
-- log_review_tickets FK-references issues.issues, and a Court Reserve finding scoped to a
-- single club carries that club_id — so its ticket must go before the issue it points at.
delete from court_reserve.log_review_tickets        where issue_id in (select id from _del_issues);
delete from agent.agent_producer_runs               where issue_id in (select id from _del_issues);
delete from issues.issue_leases                     where issue_id in (select id from _del_issues);
delete from issues.issue_apps                       where issue_id in (select id from _del_issues);
delete from issues.issue_attachments                where issue_id in (select id from _del_issues);
delete from issues.issue_comments                   where issue_id in (select id from _del_issues);
delete from issues.issue_fixes                      where issue_id in (select id from _del_issues);
delete from issues.issue_repositories               where issue_id in (select id from _del_issues);
-- issue_links references issues twice (issue_id, linked_issue_id): a link is dead if
-- EITHER end is going away, so scope to both.
delete from issues.issue_links
  where issue_id in (select id from _del_issues)
     or linked_issue_id in (select id from _del_issues);
delete from issues.issue_intake_message_files
  where issue_intake_message_id in
    (select id from issues.issue_intake_messages where issue_id in (select id from _del_issues));
delete from issues.issue_intake_messages            where issue_id in (select id from _del_issues);
delete from issues.issues                           where club_id in (select id from _del_clubs);

-- ---- integrations + playbook courts ----------------------------------------
delete from integrations.credential_access_audits    where credential_id in (select id from _del_credentials);
delete from integrations.credentials                 where club_id in (select id from _del_clubs);
delete from integrations.disabled_integrations       where club_id in (select id from _del_clubs);
delete from playbook.courts                          where club_id in (select id from _del_clubs);

-- ---- user_tracking ---------------------------------------------------------
delete from user_tracking.page_views                where club_id in (select id from _del_clubs);

-- ---- club onboarding state -------------------------------------------------
delete from playbook.club_onboardings               where club_id in (select id from _del_clubs);

-- ---- drift guard ------------------------------------------------------------
-- Every `delete from` above is hand-maintained, so a new club-scoped table lands
-- here unnoticed. Rather than a second hand-maintained list to diff against, ask
-- the catalog: any table carrying a club_id column that still has rows pointing at
-- a targeted club is a table this script has drifted away from. Names it directly
-- instead of leaving the FK abort below to report a constraint nobody recognises,
-- and covers the two club_id columns that have no FK at all
-- (court_reserve.worker_reports, worker.invocations). journal_* is excluded: those
-- are append-only audit mirrors handled explicitly above.
do $$
declare
  t record;
  n bigint;
  drifted text[] := '{}';
begin
  for t in
    select c.table_schema as s, c.table_name as tbl
      from information_schema.columns c
      join information_schema.tables tt
        on tt.table_schema = c.table_schema and tt.table_name = c.table_name
     where c.column_name = 'club_id'
       and tt.table_type = 'BASE TABLE'
       and c.table_schema not like 'journal\_%'
     order by 1, 2
  loop
    execute format(
      'select count(*) from %I.%I where club_id in (select id from _del_clubs)',
      t.s, t.tbl
    ) into n;
    if n > 0 then
      drifted := drifted || format('%s.%s (%s rows)', t.s, t.tbl, n);
    end if;
  end loop;
  if cardinality(drifted) > 0 then
    raise exception
      'delete-test-clubs.sql has drifted: these club-scoped tables still hold rows for the targeted clubs: %',
      array_to_string(drifted, ', ');
  end if;
end $$;

-- ---- finally the clubs (self-FK NO ACTION handles parent/child subset) ------
delete from playbook.clubs where id in (select id from _del_clubs);

do $$
declare remaining int;
begin
  select count(*) into remaining from playbook.clubs c
    where exists (select 1 from _del_clubs d where d.id = c.id);
  if remaining <> 0 then raise exception 'Expected 0 targeted clubs remaining, found %', remaining; end if;
  raise notice 'All targeted club-%% test clubs and dependent rows deleted.';
end $$;

commit;
