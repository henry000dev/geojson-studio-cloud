-- 0001_files_and_user_settings.sql
-- Cloud epic — Phase 2 schema + Row-Level Security.
--
-- Apply to the NON-PROD Supabase project via the SQL Editor (see ../migrations/README.md).
-- Idempotent: safe to re-run.
--
-- Security model: every row is owned by `user_id`. RLS restricts all access to the
-- owner, and only the `authenticated` role may touch these tables — anonymous
-- visitors (`anon`) get nothing. See docs/02-decisions.md ADR-002 (RLS is the
-- boundary) and ADR-016 (these schema choices).

-- ============================================================================
-- 1. files — the user's active GeoJSON document
--    Phase 2: one row per user (the cloud equivalent of the local `geojson_data`
--    record). Phase 3 relaxes this to multiple named files per user.
-- ============================================================================
create table if not exists public.files (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null default auth.uid()
                              references auth.users (id) on delete cascade,
  geojson         jsonb,                 -- active document    (file-seam key "geojson_data")
  backup_geojson  jsonb,                 -- safety copy         (file-seam key "backup_geojson_data")
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- Phase 2 invariant: exactly one file per user (no multi-file UI yet). This makes
-- the provider write a trivial upsert on `user_id`. Phase 3 DROPS this index.
create unique index if not exists files_one_per_user_uq on public.files (user_id);

-- ============================================================================
-- 2. user_settings — per-user KV mirror of the settings seam.
--    `value` is text: the settings seam round-trips opaque localStorage strings,
--    so text is a lossless 1:1 mirror (ADR-016).
-- ============================================================================
create table if not exists public.user_settings (
  user_id     uuid        not null default auth.uid()
                          references auth.users (id) on delete cascade,
  key         text        not null,
  value       text,
  updated_at  timestamptz not null default now(),
  primary key (user_id, key)
);

-- ============================================================================
-- 3. updated_at trigger — DB-authoritative timestamps (the client can't forget).
-- ============================================================================
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists files_set_updated_at on public.files;
create trigger files_set_updated_at
  before update on public.files
  for each row execute function public.set_updated_at();

drop trigger if exists user_settings_set_updated_at on public.user_settings;
create trigger user_settings_set_updated_at
  before update on public.user_settings
  for each row execute function public.set_updated_at();

-- ============================================================================
-- 4. Row-Level Security — the authorization boundary.
--    Enable RLS (deny-by-default), grant table privileges to `authenticated`
--    only, revoke from `anon`, then add owner-only per-command policies.
-- ============================================================================
alter table public.files         enable row level security;
alter table public.user_settings enable row level security;

revoke all on public.files         from anon;
revoke all on public.user_settings from anon;
grant select, insert, update, delete on public.files         to authenticated;
grant select, insert, update, delete on public.user_settings to authenticated;

-- files policies (owner-only)
drop policy if exists "files_select_own" on public.files;
create policy "files_select_own" on public.files
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "files_insert_own" on public.files;
create policy "files_insert_own" on public.files
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "files_update_own" on public.files;
create policy "files_update_own" on public.files
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "files_delete_own" on public.files;
create policy "files_delete_own" on public.files
  for delete to authenticated using (auth.uid() = user_id);

-- user_settings policies (owner-only)
drop policy if exists "user_settings_select_own" on public.user_settings;
create policy "user_settings_select_own" on public.user_settings
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "user_settings_insert_own" on public.user_settings;
create policy "user_settings_insert_own" on public.user_settings
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "user_settings_update_own" on public.user_settings;
create policy "user_settings_update_own" on public.user_settings
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "user_settings_delete_own" on public.user_settings;
create policy "user_settings_delete_own" on public.user_settings
  for delete to authenticated using (auth.uid() = user_id);
