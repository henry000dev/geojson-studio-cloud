-- 0005_plans_and_quota.sql
-- Cloud epic — Phase 6 (monetise): the paid-plans layer.
--   * public.plans      — a lookup of tier → storage limit (+ display metadata).
--   * public.user_plans — one server-authoritative plan row per user.
--   * a default-plan trigger on auth.users so every user has a plan row.
--   * a storage-quota trigger on user_files enforcing the per-plan byte limit.
--
-- Apply to the NON-PROD Supabase project via the SQL Editor (see ./README.md),
-- AFTER 0001-0004. Idempotent: safe to re-run.
--
-- Design: docs/02-decisions.md ADR-022 (monetisation mechanics — user_plans,
-- storage quota via a Postgres trigger, Stripe), ADR-031 (this phase's build
-- decisions: the `plans` lookup table + the record-on-login-via-trigger,
-- server-authoritative model), ADR-030 (sequencing — built in test mode before
-- beta). Storage is the summed byte-size of a user's inline GeoJSON, measured
-- identically to the user_storage_usage view (0003) so the usage bar and the
-- gate agree.

-- ============================================================================
-- 1. plans — the tier lookup. Limits are DATA (ADR-031): change a tier with a
--    row UPDATE, no code or migration. A shared, non-user-scoped lookup; every
--    authenticated user may read it (for the usage bar / upgrade UI).
--    Limit values are PROVISIONAL (finalised at go-live from beta usage data —
--    ADR-030) and expressed in 1024-based bytes to match the client's formatter.
-- ============================================================================
create table if not exists public.plans (
  plan        text   primary key,
  limit_bytes bigint not null,
  label       text,
  rank        int    not null default 0   -- display/upgrade ordering
);

insert into public.plans (plan, limit_bytes, label, rank) values
  ('early_access', 1073741824, 'Early access', 0),  -- 1 GiB  (free cloud allowance)
  ('basic',         262144000, 'Basic',        1),  -- 250 MiB
  ('pro',          5368709120, 'Pro',          2)   -- 5 GiB
on conflict (plan) do update
  set limit_bytes = excluded.limit_bytes,
      label       = excluded.label,
      rank        = excluded.rank;

alter table public.plans enable row level security;
revoke all on public.plans from anon;
grant select on public.plans to authenticated;
-- service_role reaches this table through PostgREST (unlike GoTrue admin calls,
-- which need no table grant). On this project service_role did NOT inherit the
-- default public-schema grants, and BYPASSRLS does not cover table-level
-- privileges — so grant explicitly, or PostgREST returns 42501 "permission
-- denied for table".
grant select on public.plans to service_role;

drop policy if exists "plans_select_all" on public.plans;
create policy "plans_select_all" on public.plans
  for select to authenticated using (true);

-- ============================================================================
-- 2. user_plans — per-user plan + Stripe linkage. SERVER-AUTHORITATIVE: the
--    client may READ its own row, but never write it (a browser must never be
--    able to grant itself a plan). Writes come only from the default-plan
--    trigger (section 3, security definer) and the Node Stripe webhook
--    (service_role, which bypasses RLS). Hence: no insert/update/delete grant
--    or policy for `authenticated`. See ADR-022.
-- ============================================================================
create table if not exists public.user_plans (
  user_id                uuid        primary key
                                     references auth.users (id) on delete cascade,
  plan                   text        not null default 'early_access'
                                     references public.plans (plan),
  status                 text,                 -- Stripe subscription status
  stripe_customer_id     text,
  stripe_subscription_id text,
  current_period_end     timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

-- Reuse the shared updated_at trigger function created in 0001.
drop trigger if exists user_plans_set_updated_at on public.user_plans;
create trigger user_plans_set_updated_at
  before update on public.user_plans
  for each row execute function public.set_updated_at();

alter table public.user_plans enable row level security;
revoke all on public.user_plans from anon;
revoke all on public.user_plans from authenticated;   -- deny-by-default, then:
grant select on public.user_plans to authenticated;    -- read-only for the owner
-- The Node server (checkout + Stripe webhook) is the ONLY writer, via the
-- service_role PostgREST client. BYPASSRLS lets it skip the RLS *policies*, but
-- table-level privileges are SEPARATE and are NOT bypassed — and on this project
-- service_role did not inherit the default public grants. Grant them explicitly
-- (read for getUserPlan/portal lookup; insert/update for the webhook upsert),
-- else the writes fail with 42501 "permission denied for table user_plans".
grant select, insert, update on public.user_plans to service_role;

drop policy if exists "user_plans_select_own" on public.user_plans;
create policy "user_plans_select_own" on public.user_plans
  for select to authenticated using (auth.uid() = user_id);
-- No insert/update/delete policy for the client: those operations have no grant
-- and no policy, so RLS denies them to every browser session. Only service_role
-- (the server) writes, via the explicit grant above.

-- ============================================================================
-- 3. Default plan for every user. A trigger on auth.users insert writes a
--    default `early_access` row (the free cloud allowance) so every signed-in
--    user always has a plan the quota check can resolve — created SERVER-SIDE,
--    not by the client (ADR-031). security definer + a pinned search_path so it
--    runs with the privileges needed to write user_plans regardless of the
--    signup path (email/OAuth). Existing users are backfilled once below.
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.user_plans (user_id, plan)
  values (new.id, 'early_access')
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- One-time backfill: give every pre-existing user a default plan row.
insert into public.user_plans (user_id, plan)
select id, 'early_access' from auth.users
on conflict (user_id) do nothing;

-- ============================================================================
-- 4. Storage-quota enforcement. A BEFORE INSERT/UPDATE trigger on user_files
--    rejects a write that would grow the user's total stored bytes past their
--    plan limit. Because writes are client-direct (RLS), this trigger is the
--    real gate; the client's usage bar is UX only (ADR-022). security invoker
--    so the SUM over user_files is naturally RLS-scoped to the writer's own
--    rows (their own total). Never fires on DELETE — deletes always shrink.
-- ============================================================================
create or replace function public.enforce_storage_quota()
returns trigger
language plpgsql
security invoker
as $$
declare
  v_new_bytes   bigint;
  v_old_bytes   bigint;
  v_used_bytes  bigint;
  v_limit_bytes bigint;
begin
  v_new_bytes := coalesce(octet_length(new.geojson::text), 0);
  v_old_bytes := case
                   when tg_op = 'UPDATE' then coalesce(octet_length(old.geojson::text), 0)
                   else 0
                 end;

  -- Humane downgrade (ADR-022): never block a write that keeps usage flat or
  -- shrinks it — even for a user already over their limit. Only growth is gated.
  if v_new_bytes <= v_old_bytes then
    return new;
  end if;

  -- The user's byte limit, from their plan; fall back to early_access defensively
  -- (the auth.users trigger guarantees a row, so the fallback is belt-and-braces).
  select p.limit_bytes into v_limit_bytes
  from public.user_plans up
  join public.plans p on p.plan = up.plan
  where up.user_id = new.user_id;

  if v_limit_bytes is null then
    select limit_bytes into v_limit_bytes from public.plans where plan = 'early_access';
  end if;

  -- Current usage across the user's OTHER files (exclude the row being written),
  -- plus the pending bytes. Same measure as public.user_storage_usage (0003).
  select coalesce(sum(octet_length(geojson::text)), 0) into v_used_bytes
  from public.user_files
  where user_id = new.user_id and id <> new.id;

  if v_used_bytes + v_new_bytes > v_limit_bytes then
    raise exception
      'GS_QUOTA_EXCEEDED: storage limit reached (limit % bytes, would use % bytes)',
      v_limit_bytes, v_used_bytes + v_new_bytes
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists user_files_enforce_quota on public.user_files;
create trigger user_files_enforce_quota
  before insert or update on public.user_files
  for each row execute function public.enforce_storage_quota();
