-- 0002_multi_file.sql
-- Cloud epic — Phase 3: relax the single-file invariant to multiple named files.
--
-- Apply to the NON-PROD Supabase project via the SQL Editor (see ./README.md),
-- AFTER 0001. Idempotent: safe to re-run.
--
-- Phase 2 kept exactly one `user_files` row per user (`user_files_one_per_user_uq`)
-- as the cloud equivalent of the single local `geojson_data` record. Phase 3 adds
-- the "My Files" browser, so a user may now own many rows, each a named file. The
-- remote provider switches from upsert-on-`user_id` to update/insert by row `id`
-- in the same slice. See docs/02-decisions.md ADR-018.

-- ============================================================================
-- 1. Drop the one-row-per-user invariant.
--    This index must go or a second file can't be inserted, and the old
--    `upsert(onConflict: user_id)` no longer has a constraint to target.
-- ============================================================================
drop index if exists public.user_files_one_per_user_uq;

-- ============================================================================
-- 2. Add the file name.
--    Nullable: lazily-created files default to "Untitled" in the client, and
--    existing Phase 2 rows keep NULL until renamed. No backfill needed.
-- ============================================================================
alter table public.user_files add column if not exists name text;

-- Nothing else changes: `geojson`, `created_at`, `updated_at`, the `updated_at`
-- trigger, and the owner-only RLS policies from 0001 already cover multiple rows
-- per user (every policy is scoped to `auth.uid() = user_id`).
