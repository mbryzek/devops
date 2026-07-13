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
-- reverse-topological order of the 29-edge FK DAG across the delete universe.
-- Multi-level subtrees are flattened into id temp tables so no delete needs deep
-- nesting. One transaction: any missed edge aborts + rolls back with zero changes.
--
-- To regenerate the table list, query pg_constraint for FKs whose confrelid is
-- a table in the delete universe, starting from clubaid.clubs.
begin;

-- Root set + flattened id sets for every multi-level / cross subtree.
create temp table _del_clubs on commit drop as
  select id from clubaid.clubs where id like 'club-%';
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
create temp table _del_ai_chats on commit drop as
  select id from clubaid.ai_chats where club_id in (select id from _del_clubs);
create unique index on _del_ai_chats (id);
create temp table _del_invocations on commit drop as
  select id from worker.invocations where club_id in (select id from _del_clubs);
create unique index on _del_invocations (id);

do $$ begin raise notice 'Clubs targeted: %', (select count(*) from _del_clubs); end $$;

-- ---- Playbook insight cluster (deepest children first) ---------------------
delete from playbook.insight_work_items            where insight_id in (select id from _del_insights);
delete from playbook.insight_section_chat_messages where insight_section_chat_id in (select id from _del_insight_section_chats);
delete from playbook.insight_section_chats         where insight_section_id in (select id from _del_insight_sections);
delete from playbook.insight_section_votes         where insight_section_id in (select id from _del_insight_sections);
delete from playbook.insight_claims
  where insight_id in (select id from _del_insights)
     or insight_section_id in (select id from _del_insight_sections)
     or insight_tool_call_id in (select id from _del_insight_tool_calls);
delete from playbook.insight_recommendations       where club_id in (select id from _del_clubs);
delete from playbook.insight_sections              where insight_id in (select id from _del_insights);
delete from playbook.insight_reviews               where insight_id in (select id from _del_insights);
delete from playbook.insight_tool_calls            where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insight_findings              where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insight_judgments             where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insight_run_stages            where insight_run_id in (select id from _del_insight_runs);
delete from playbook.insights                       where club_id in (select id from _del_clubs);
delete from playbook.insight_runs                   where club_id in (select id from _del_clubs);
delete from playbook.revenue_entries               where club_id in (select id from _del_clubs);
delete from playbook.revenue_categories             where club_id in (select id from _del_clubs);
delete from playbook.club_insight_settings          where club_id in (select id from _del_clubs);
delete from playbook.club_memory_facts              where club_id in (select id from _del_clubs);
delete from playbook.membership_categories          where club_id in (select id from _del_clubs);
delete from playbook.report_exports                 where club_id in (select id from _del_clubs);
delete from playbook.watermarks                     where club_id in (select id from _del_clubs);

-- ---- clubaid ---------------------------------------------------------------
delete from clubaid.account_links                   where credential_id in (select id from _del_credentials);
delete from clubaid.ai_messages                     where chat_id in (select id from _del_ai_chats);
delete from clubaid.ai_chats                         where club_id in (select id from _del_clubs);
delete from clubaid.upload_logs                     where club_id in (select id from _del_clubs);
delete from clubaid.uploads                          where club_id in (select id from _del_clubs);
delete from clubaid.export_watermarks               where club_id in (select id from _del_clubs);
delete from clubaid.user_club_notification_optouts  where club_id in (select id from _del_clubs);
delete from clubaid.user_clubs                       where club_id in (select id from _del_clubs);
delete from clubaid.user_invitations                where club_id in (select id from _del_clubs);

-- ---- court_reserve event/reservation cluster -------------------------------
delete from court_reserve.reservation_courts        where reservation_id in (select id from _del_reservations) or court_id in (select id from _del_cr_courts);
delete from court_reserve.reservation_players       where reservation_id in (select id from _del_reservations);
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
delete from court_reserve.guest_member_numbers      where club_id in (select id from _del_clubs);
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
delete from playbook.member_engagement_scores       where club_id in (select id from _del_clubs);
delete from playbook.member_segment_transitions     where club_id in (select id from _del_clubs);
delete from playbook.members                        where club_id in (select id from _del_clubs);

-- ---- feedback --------------------------------------------------------------
delete from feedback.comments                       where club_id in (select id from _del_clubs);

-- ---- integrations + rallyd -------------------------------------------------
delete from integrations.credentials                 where club_id in (select id from _del_clubs);
delete from integrations.disabled_integrations       where club_id in (select id from _del_clubs);
delete from rallyd.courts                            where club_id in (select id from _del_clubs);

-- ---- finally the clubs (self-FK NO ACTION handles parent/child subset) ------
delete from clubaid.clubs where id like 'club-%';

do $$
declare remaining int;
begin
  select count(*) into remaining from clubaid.clubs where id like 'club-%';
  if remaining <> 0 then raise exception 'Expected 0 club-%% remaining, found %', remaining; end if;
  raise notice 'All club-%% test clubs and dependent rows deleted.';
end $$;

commit;
