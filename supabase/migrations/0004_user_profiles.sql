-- 0004_user_profiles.sql
-- Cloud epic — Phase 5: a generic per-user profile table. First use: recording
-- Terms/Privacy acceptance, written by the client on first login (ADR-027).
--
-- Apply to the NON-PROD Supabase project via the SQL Editor (see ./README.md).
-- Idempotent: safe to re-run.
--
-- One row per user, keyed by user_id → auth.users (cascade on account deletion,
-- matching user_files / user_settings). Owner-only RLS: a user reads and writes
-- only their own row. This table is the home for future per-user *account* fields
-- (display name, onboarding flags, etc.); app preferences stay in user_settings.

create table if not exists public.user_profiles (
  user_id           uuid        primary key default auth.uid()
                                references auth.users (id) on delete cascade,
  terms_accepted_at timestamptz,
  terms_version     text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- Reuse the shared updated_at trigger function created in 0001.
drop trigger if exists user_profiles_set_updated_at on public.user_profiles;
create trigger user_profiles_set_updated_at
  before update on public.user_profiles
  for each row execute function public.set_updated_at();

-- ============================================================================
-- Row-Level Security — owner-only, authenticated-only (same shape as 0001).
-- No delete policy: the row is removed only by the account-deletion cascade.
-- ============================================================================
alter table public.user_profiles enable row level security;

revoke all on public.user_profiles from anon;
grant select, insert, update on public.user_profiles to authenticated;

drop policy if exists "user_profiles_select_own" on public.user_profiles;
create policy "user_profiles_select_own" on public.user_profiles
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "user_profiles_insert_own" on public.user_profiles;
create policy "user_profiles_insert_own" on public.user_profiles
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "user_profiles_update_own" on public.user_profiles;
create policy "user_profiles_update_own" on public.user_profiles
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
