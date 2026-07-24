# Supabase migrations

This directory is the **source of truth** for the cloud database schema and RLS (ADR-009). The Supabase projects are downstream of these files — never hand-edit schema in the dashboard and leave it undocumented here.

## Files

Migrations are applied in **filename order**:

| File | What it does |
|---|---|
| `0001_files_and_user_settings.sql` | Phase 2 schema: `public.user_files` + `public.user_settings`, the `updated_at` trigger, and owner-only RLS. |
| `0002_multi_file.sql` | Phase 3: drop the one-row-per-user index on `user_files`, add `user_files.name` (multiple named files per user). |
| `0003_storage_usage_view.sql` | Phase 5 (account area): `public.user_storage_usage`, a `security_invoker` view summing each user's GeoJSON bytes + file count, read client-direct (owner-scoped via `user_files` RLS). |
| `0004_user_profiles.sql` | Phase 5 (compliance): `public.user_profiles`, a generic per-user table (owner-only RLS) whose first columns record Terms/Privacy acceptance (`terms_accepted_at`, `terms_version`), written by the client on first login. |
| `0005_plans_and_quota.sql` | Phase 6 (monetise): `public.plans` (tier → storage limit lookup) + `public.user_plans` (server-authoritative per-user plan/Stripe state, owner-read-only), a default-plan trigger on `auth.users` (+ backfill), and a storage-quota trigger on `user_files` enforcing the per-plan byte limit. |

## How to apply (manual, for now)

We are not using the Supabase CLI yet, so apply by hand:

1. Open the **non-prod** project → **SQL Editor** → **New query**.
2. Paste the migration file's contents → **Run**.
3. Each migration is idempotent (`if not exists`, `drop policy if exists`), so re-running is safe.

When a production project exists (deferred — ADR-014), apply the same files there, in the same order. Adopting the Supabase CLI later (`supabase db push`) is compatible with keeping these files here.

**During development (pre-production), these creation scripts may be amended in place** and the tables dropped & recreated — e.g. the `user_files` rename and the removal of the `backup_geojson` column (ADR-023) were folded into `0001`/`0002` rather than added as an ALTER migration. Once a production project exists, applied migrations become **immutable** and further changes ship as new numbered files.

## Verifying

After applying `0001`:

- **Table Editor** → `user_files` and `user_settings` exist, each showing **RLS enabled**.
- **Authentication → Policies** → four owner-only policies on each table.
- **Anon is locked out** — run in the SQL Editor:
  ```sql
  set local role anon;
  select * from public.user_files;   -- expect: permission denied
  reset role;
  ```
  (The SQL Editor runs as a privileged role that bypasses RLS, so switching role is how you actually exercise the policy.)

After applying `0002`:

- **Table Editor** → `user_files` now has a **`name`** column.
- **Database → Indexes** → `user_files_one_per_user_uq` is **gone**, so a user can hold multiple `user_files` rows (the existing owner-only RLS policies already cover them).

After applying `0003`:

- **Database → Views** (or Table Editor) → `user_storage_usage` exists.
- **Owner-scoped read** — because the view is `security_invoker`, a signed-in user querying it sees only their own row. Exercise it as a real user (not the privileged SQL Editor role):
  ```sql
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<a real user_id>","role":"authenticated"}';
  select * from public.user_storage_usage;   -- expect: only that user's aggregate
  reset role;
  ```
  A user with no files simply returns **no row** (the app reports that as zero).

After applying `0004`:

- **Table Editor** → `user_profiles` exists with **RLS enabled**; columns `terms_accepted_at`, `terms_version`, timestamps.
- **Authentication → Policies** → three owner-only policies (select / insert / update); **no delete** policy (the row goes only via the account-deletion cascade).
- **Anon is locked out** — same `set local role anon; select * from public.user_profiles;` check as `0001` (expect: permission denied).

After applying `0005`:

- **Table Editor** → `plans` exists (three seeded rows: `early_access`, `basic`, `pro`) and `user_plans` exists with **RLS enabled**.
- **Every user has a plan row (backfill)** — the count matches the user count:
  ```sql
  select
    (select count(*) from auth.users)        as users,
    (select count(*) from public.user_plans) as plan_rows;   -- expect: equal
  ```
- **New signups get a default row** — the `on_auth_user_created` trigger inserts one automatically. Create a throwaway user and confirm a matching `user_plans` row appears (`plan = 'early_access'`).
- **service_role can reach both tables via PostgREST** — the Node checkout/webhook use the service_role key over PostgREST, which needs an explicit table grant (BYPASSRLS does not cover table privileges; on this project service_role did not inherit the default grants). Confirm the grants landed:
  ```sql
  select grantee, table_name, string_agg(privilege_type, ',' order by privilege_type) as privs
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee = 'service_role'
    and table_name in ('plans','user_plans')
  group by grantee, table_name;
  -- expect: plans -> SELECT ; user_plans -> INSERT,SELECT,UPDATE
  ```
  If these rows are missing, re-run `0005` (idempotent) — the server's checkout call fails with `42501 permission denied for table user_plans` without them.
- **user_plans is read-only to clients** — the owner may read but not write (only the auth trigger and the service_role webhook write it):
  ```sql
  set local role authenticated;
  set local request.jwt.claims to '{"sub":"<a real user_id>","role":"authenticated"}';
  select * from public.user_plans;                         -- expect: only that user's row
  update public.user_plans set plan = 'pro';               -- expect: 0 rows / not permitted
  reset role;
  ```
- **Quota gate** — as a real user, editing a file so its GeoJSON grows past the plan's `limit_bytes` is rejected with a `GS_QUOTA_EXCEEDED` error, while shrinking or deleting a file always succeeds (even when already over limit). Temporarily lowering a `plans.limit_bytes` below a user's current usage is a quick way to exercise the reject path without a huge file:
  ```sql
  -- e.g. drop early_access to 1 KB, attempt a grow (blocked), a shrink (allowed), then restore.
  update public.plans set limit_bytes = 1024 where plan = 'early_access';
  -- ... test writes as the user ...
  update public.plans set limit_bytes = 1073741824 where plan = 'early_access';
  ```

The full cross-user isolation proof (two real accounts can't see each other's rows) happens once the app's remote provider can write data — see `docs/05-worklog.md`.
