-- 0005_plans_and_quota.sql
-- Cloud epic — Phase 6 (monetise): the paid-plans layer.
--   * public.plans      — a lookup of tier → storage + file-count limits.
--   * public.user_plans — one server-authoritative plan row per user.
--   * a default-plan trigger on auth.users so every user has a plan row.
--   * a storage-quota trigger on user_files enforcing the per-plan byte limit.
--   * a file-count trigger on user_files enforcing the per-plan file limit.
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
--
-- Amended in place for Phase 7a (2026-07-26, pre-prod per ADR-023). Four changes,
-- all riding this single re-apply:
--   * `early_access` renamed to `free` (ADR-032) — the permanent free cloud tier.
--   * Seed limits reordered to be monotonic (free < basic < pro); the old seed
--     had basic 250 MiB sitting BELOW free 1 GiB.
--   * `plans.max_files` + the file-count trigger — the second entitlement lever
--     of ADR-032, previously chosen but unenforced.
--   * `plans.description` + the hidden `discount` / `god_mode` plans (ADR-034).

-- ============================================================================
-- 1. plans — the tier lookup. Limits are DATA (ADR-031): change a tier with a
--    row UPDATE, no code or migration. A shared, non-user-scoped lookup; every
--    authenticated user may read it (for the usage bar / upgrade UI).
--    Limit values are PROVISIONAL (finalised at go-live from beta usage data —
--    ADR-030) and expressed in 1024-based bytes to match the client's formatter.
--    Two levers, both enforced by triggers below (ADR-032): total stored bytes
--    and file count. Core editing/conversion is never gated.
-- ============================================================================
create table if not exists public.plans (
  plan        text   primary key,
  limit_bytes bigint not null,
  label       text,
  rank        int    not null default 0   -- display/upgrade ordering
);

-- Added by the Phase 7a amendment; `add column if not exists` (rather than a
-- changed create) is what keeps this script re-runnable on a project that
-- already has the Phase 6 shape. max_files is made NOT NULL after the seed
-- below, so a plan row can never silently mean "unlimited" (see section 5).
alter table public.plans add column if not exists max_files integer;
-- A maintainer's private memo of what each row is for (ADR-034). NEVER rendered
-- to users — and note `plans` is readable by any authenticated client (policy
-- below), so this is documentation, not a secret. See docs/RUNBOOK.md.
alter table public.plans add column if not exists description text;

insert into public.plans (plan, limit_bytes, label, rank, max_files, description) values
  ('free',       31457280,          'Free',      0,       3,
   'Default plan for every new cloud account.'),
  ('basic',      524288000,         'Basic',     1,      50,
   'Paid tier availabe to the public.'),
  ('pro',        21474836480,       'Pro',       2,    1000,
   'Paid tier availabel to the public.'),
  -- Hidden plans (ADR-034): real, enforced tiers that are never listed in the
  -- upgrade UI. `discount` mirrors Pro's limits — the difference is the private
  -- Stripe price, not the entitlement. `god_mode` is the maintainer's own row:
  -- sentinel limits, effectively no gate. Assignment: docs/RUNBOOK.md.
  ('discount',   21474836480,       'Discount',  50,   1000,
   'PRIVATE plan, not available to the public, used for special purposes.'),
  ('god_mode',   1125899906842624,  'God Mode',  100, 1000000,
   'PRIVATE plan, not available to the public, for myself only.')
on conflict (plan) do update
  set limit_bytes = excluded.limit_bytes,
      label       = excluded.label,
      rank        = excluded.rank,
      max_files   = excluded.max_files,
      description = excluded.description;

-- Any plan row added by hand before this amendment (or by a maintainer who
-- omitted max_files) gets the free allowance rather than a NULL that would read
-- as "unlimited" in the trigger. Then lock the column down.
update public.plans
  set max_files = (select max_files from public.plans where plan = 'free')
  where max_files is null;
alter table public.plans alter column max_files set not null;

-- (The pre-7a `early_access` row is retired in section 2, once the user_plans
-- rows that reference it have been moved across — the FK forces that order.)

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
  plan                   text        not null default 'free'
                                     references public.plans (plan),
  status                 text,                 -- Stripe subscription status
  stripe_customer_id     text,
  stripe_subscription_id text,
  current_period_end     timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

-- The `early_access` → `free` rename (ADR-032) on a project that already has the
-- Phase 6 shape: move the rows across, then the column default, then retire the
-- old lookup row. The FK from user_plans.plan is what dictates that order — the
-- `plans` row can't go until nothing references it. All three are no-ops on a
-- fresh project.
update public.user_plans set plan = 'free' where plan = 'early_access';
alter table public.user_plans alter column plan set default 'free';
delete from public.plans where plan = 'early_access';

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
--    default `free` row (the free cloud allowance) so every signed-in user
--    always has a plan the quota checks can resolve — created SERVER-SIDE, not
--    by the client (ADR-031). security definer + a pinned search_path so it
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
  values (new.id, 'free')
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
select id, 'free' from auth.users
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

  -- The user's byte limit, from their plan; fall back to free defensively
  -- (the auth.users trigger guarantees a row, so the fallback is belt-and-braces).
  select p.limit_bytes into v_limit_bytes
  from public.user_plans up
  join public.plans p on p.plan = up.plan
  where up.user_id = new.user_id;

  if v_limit_bytes is null then
    select limit_bytes into v_limit_bytes from public.plans where plan = 'free';
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

-- ============================================================================
-- 5. File-count enforcement (Phase 7a, ADR-032 — the second tier lever).
--    A BEFORE INSERT trigger rejects a NEW file once the user is at their plan's
--    max_files. INSERT only, deliberately: updates and deletes must always stay
--    open, the same humane-downgrade rule the storage trigger follows — a user
--    who drops to a smaller plan keeps every existing file editable, they just
--    can't add another until they're back under the cap.
--    security invoker, like the quota trigger, so the COUNT is RLS-scoped to the
--    writer's own rows. "Unlimited" is a sentinel (god_mode's 1e6), never NULL —
--    max_files is NOT NULL precisely so a missing value can't read as no gate.
-- ============================================================================
create or replace function public.enforce_file_count()
returns trigger
language plpgsql
security invoker
as $$
declare
  v_max_files int;
  v_count     bigint;
begin
  select p.max_files into v_max_files
  from public.user_plans up
  join public.plans p on p.plan = up.plan
  where up.user_id = new.user_id;

  -- No plan row (belt-and-braces — the auth.users trigger guarantees one): fall
  -- back to the free allowance rather than letting the insert through ungated.
  if not found then
    select max_files into v_max_files from public.plans where plan = 'free';
  end if;

  select count(*) into v_count
  from public.user_files
  where user_id = new.user_id;

  if v_count >= v_max_files then
    raise exception
      'GS_FILE_LIMIT_REACHED: file limit reached (limit % files)', v_max_files
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists user_files_enforce_file_count on public.user_files;
create trigger user_files_enforce_file_count
  before insert on public.user_files
  for each row execute function public.enforce_file_count();
