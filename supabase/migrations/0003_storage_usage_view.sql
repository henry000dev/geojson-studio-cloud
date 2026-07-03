-- 0003_storage_usage_view.sql
-- Cloud epic — Phase 5 (account area): per-user storage usage, read client-direct.
--
-- Apply to the NON-PROD Supabase project via the SQL Editor (see ./README.md).
-- Idempotent: safe to re-run.
--
-- A read-only view summing each user's stored GeoJSON bytes. `security_invoker`
-- makes the view execute with the *querying* user's privileges, so the owner-only
-- RLS already on `public.user_files` applies and each caller sees only their own
-- aggregate — no separate policy on the view is needed. Reading your own usage
-- needs no secret, so this stays client-direct (`supabase.from("user_storage_usage")`);
-- see docs/02-decisions.md ADR-027, and ADR-022 (storage = the summed byte-size of
-- a user's files). Bytes are measured on the logical JSON text (octet_length of the
-- jsonb cast to text) — an intuitive, predictable figure for a usage display.

create or replace view public.user_storage_usage
with (security_invoker = on) as
select
  user_id,
  count(*)::int                                         as file_count,
  coalesce(sum(octet_length(geojson::text)), 0)::bigint as bytes
from public.user_files
group by user_id;

-- Anonymous visitors never touch cloud data; only authenticated owners read their
-- own aggregate (enforced by user_files' RLS via security_invoker).
revoke all on public.user_storage_usage from anon;
grant select on public.user_storage_usage to authenticated;
