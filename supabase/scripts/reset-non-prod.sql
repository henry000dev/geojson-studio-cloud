-- ============================================================================
-- reset-non-prod.sql — WIPE THE DATABASE. Development convenience only.
--
--   >>> THIS DELETES EVERY ACCOUNT AND EVERY FILE. THERE IS NO UNDO. <<<
--
-- Full procedure, including the parts that CANNOT be done in SQL:
--   ../../docs/RESET.md   <- read this first if you have not run one before
--
-- NOT A MIGRATION, and deliberately not in ../migrations/. That directory is
-- applied in filename order and will one day be handed to `supabase db push`,
-- which would run this file as the last step of a deploy. Numbering it (9999_,
-- 0007_, anything) puts it in that firing line; living here does not.
--
-- BEFORE YOU RUN: look at which project the SQL Editor is pointed at. The guard
-- in section 0 is a backstop, not a substitute for reading the header bar.
--
-- STORAGE OBJECTS ARE NOT TOUCHED BY THIS FILE and cannot be — `storage.
-- protect_delete()` rejects a direct DELETE on storage.objects with 42501. Empty
-- the bucket in the dashboard FIRST (Storage -> user-files -> delete the
-- {user_id}/ folders), or you will leave orphaned bytes that no longer belong to
-- any account and that nothing will ever clean up. This is the same constraint
-- that makes the account-deletion sweep a compliance obligation rather than a
-- nicety — see ../../docs/RUNBOOK.md.
--
-- TWO LEVELS. Run ONE section, not both — highlight it and use "Run selection".
--   * Section 1 — DATA ONLY. The everyday reset. Keeps the schema, so there is
--     nothing to replay afterwards. One statement. Use this by default.
--   * Section 2 — FULL TEARDOWN. Also drops the schema, so `0001`-`0006` must be
--     replayed afterwards. Use when a migration itself has changed.
-- Running both in order is harmless, just redundant — section 2 subsumes 1.
-- ============================================================================


-- ============================================================================
-- 0. GUARD — refuse to run against production. RUN THIS FIRST, EVERY TIME.
--
--    Costs nothing today: production does not exist yet (ADR-014), so the marker
--    does not exist and this passes silently. It is here so that the protection
--    is already in place on the day it starts to matter, rather than being
--    remembered at the moment it is most needed.
--
--    PHASE 9 PROVISIONING MUST CREATE THIS MARKER as its first act, before any
--    migration is applied:
--        create table public.production_marker (note text);
-- ============================================================================
do $$
begin
  if exists (
    select 1 from pg_tables
    where schemaname = 'public' and tablename = 'production_marker'
  ) then
    raise exception
      'REFUSING TO RUN: public.production_marker exists — this is PRODUCTION.';
  end if;
end $$;


-- ============================================================================
-- 1. DATA ONLY — the everyday reset.
--
--    One statement does all of it. Every per-user table hangs off auth.users by
--    `on delete cascade` — user_files, user_settings, user_profiles, user_plans,
--    and file_edits (twice over: by user_id, and by file_id through user_files).
--    Deleting the accounts therefore empties all of them, and auth's own tables
--    (identities, sessions, refresh tokens) go the same way.
--
--    public.plans is deliberately NOT cleared: it is seeded configuration (the
--    tier -> limits lookup), not user data. Clearing it would leave the
--    default-plan trigger with nothing to reference and break the next signup.
-- ============================================================================
delete from auth.users;


-- ============================================================================
-- 2. FULL TEARDOWN — schema as well. REPLAY 0001-0006 AFTERWARDS.
--
--    Everything below is inside one section on purpose: leaving it half-run
--    gives you a database that is neither empty nor working.
-- ============================================================================

-- The auth.users trigger goes FIRST. It references public.user_plans, and
-- dropping that table out from under it does not fail here — it fails later, at
-- the next signup, which is a much worse place to discover it.
drop trigger if exists on_auth_user_created on auth.users;

-- `cascade` carries the indexes, sequences, constraints, policies and triggers
-- that belong to each table, so they need no separate statements.
drop view  if exists public.user_storage_usage cascade;
drop table if exists public.file_edits    cascade;
drop table if exists public.user_files    cascade;
drop table if exists public.user_settings cascade;
drop table if exists public.user_profiles cascade;
drop table if exists public.user_plans    cascade;
drop table if exists public.plans         cascade;

drop function if exists public.bump_file_edit_seq()    cascade;
drop function if exists public.enforce_storage_quota() cascade;
drop function if exists public.enforce_file_count()    cascade;
drop function if exists public.handle_new_user()       cascade;
drop function if exists public.set_updated_at()        cascade;

-- storage.objects is not ours to drop, so its policies are dropped by name.
-- `0006` recreates them; they are removed here so that a policy renamed in a
-- future edit cannot survive a rebuild and quietly widen access.
drop policy if exists "user_files_objects_select_own" on storage.objects;
drop policy if exists "user_files_objects_insert_own" on storage.objects;
drop policy if exists "user_files_objects_update_own" on storage.objects;
drop policy if exists "user_files_objects_delete_own" on storage.objects;

-- The accounts.
delete from auth.users;

-- The `user-files` bucket row itself is left alone: `0006` upserts it, so a
-- replay reconciles its settings (private, 50 MB limit, MIME list) either way.
-- Deleting it would also require the bucket to be empty first.


-- ============================================================================
-- 3. VERIFY — run after either section.
-- ============================================================================
select
  (select count(*) from auth.users)                                      as users,
  (select count(*) from storage.objects where bucket_id = 'user-files')  as objects,
  (select count(*) from pg_tables where schemaname = 'public')           as public_tables;

-- Expected:
--   after section 1 — users 0, objects 0, public_tables 6 (schema intact)
--   after section 2 — users 0, objects 0, public_tables 0 (replay 0001-0006)
--
-- `objects` above 0 after either means the dashboard step was skipped or missed
-- a folder. Those bytes are now orphaned: no account owns them, the usage view
-- will still count them, and nothing will ever collect them. Go and empty the
-- bucket.
