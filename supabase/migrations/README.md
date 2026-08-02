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
| `0005_plans_and_quota.sql` | Phase 6 (monetise): `public.plans` (tier → storage + file-count limits) + `public.user_plans` (server-authoritative per-user plan/Stripe state, owner-read-only), a default-plan trigger on `auth.users` (+ backfill), and a storage-quota trigger on `user_files` enforcing the per-plan byte limit. **Amended for Phase 7a** (2026-07-26): `early_access` renamed **`free`**, monotonic seed limits, `plans.max_files` + a **file-count** trigger, `plans.description` + the hidden `discount`/`god_mode` plans. |
| `0006_snapshot_and_deltas.sql` | Phase 7b-2 (ADR-037): **a file becomes a snapshot plus deltas.** The private `user-files` Storage bucket (50 MB `file_size_limit`) + owner-only RLS on `storage.objects` keyed on the `{user_id}/` path prefix — where the **snapshot** lives; `public.file_edits`, the deduplicating per-feature change buffer, with a `seq`-bumping trigger; `user_files.snapshot_seq`, the watermark; and `user_storage_usage` reworked to measure Storage bytes instead of `jsonb`. |

## How to apply (manual, for now)

We are not using the Supabase CLI yet, so apply by hand:

1. Open the **non-prod** project → **SQL Editor** → **New query**.
2. Paste the migration file's contents → **Run**.
3. Each migration is idempotent (`if not exists`, `drop policy if exists`), so re-running is safe.

When a production project exists (deferred — ADR-014), apply the same files there, in the same order. Adopting the Supabase CLI later (`supabase db push`) is compatible with keeping these files here.

**During development (pre-production), these creation scripts may be amended in place** and the tables dropped & recreated — e.g. the `user_files` rename and the removal of the `backup_geojson` column (ADR-023) were folded into `0001`/`0002` rather than added as an ALTER migration. Once a production project exists, applied migrations become **immutable** and further changes ship as new numbered files.

## Resetting non-prod to zero

Procedure: [`../../docs/RESET.md`](../../docs/RESET.md). SQL: [`../scripts/reset-non-prod.sql`](../scripts/reset-non-prod.sql).

**The reset script is deliberately not in this directory.** Everything here is applied in filename order and will eventually be handed to `supabase db push`; a nuke script numbered into that sequence would run as the last step of a deploy. It lives in `../scripts/`, which nothing applies automatically.

Two notes that belong here rather than there:

- **A full teardown replays `0001` → `0006` from empty, and that is worth more than the cleanup.** These files are amended in place during development, so the chain is rarely run end to end against an empty database — and Phase 9 provisioning depends on exactly that working ([ADR-014](../../docs/02-decisions.md)). Each clean replay is fresh evidence it does.
- **A data-only reset needs no replay at all**, and is the right choice for app testing. Reach for the teardown only when a migration file itself has changed.

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

- **Table Editor** → `plans` exists and `user_plans` exists with **RLS enabled**. Five seeded rows — three public tiers plus the two hidden ones (never listed in the upgrade UI — see [`../../docs/RUNBOOK.md`](../../docs/RUNBOOK.md)); limits must be **monotonic** on both axes:
  ```sql
  select plan, limit_bytes, max_files, rank from public.plans order by rank;
  -- expect: free      31457280         3
  --         basic     524288000       50
  --         pro       21474836480   1000
  --         discount  21474836480   1000   (hidden)
  --         god_mode  1125899906842624  1000000   (hidden)
  ```
- **The `early_access` → `free` rename landed** (Phase 7a) — the old slug is gone and no user is stranded on it:
  ```sql
  select count(*) from public.plans      where plan = 'early_access';  -- expect: 0
  select count(*) from public.user_plans where plan = 'early_access';  -- expect: 0
  ```
- **Every user has a plan row (backfill)** — the count matches the user count:
  ```sql
  select
    (select count(*) from auth.users)        as users,
    (select count(*) from public.user_plans) as plan_rows;   -- expect: equal
  ```
- **New signups get a default row** — the `on_auth_user_created` trigger inserts one automatically. Create a throwaway user and confirm a matching `user_plans` row appears (`plan = 'free'`).
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
- **Storage-quota gate** — as a real user, editing a file so its GeoJSON grows past the plan's `limit_bytes` is rejected with a `GS_QUOTA_EXCEEDED` error, while shrinking or deleting a file always succeeds (even when already over limit). Temporarily lowering a `plans.limit_bytes` below a user's current usage is a quick way to exercise the reject path without a huge file:
  ```sql
  -- e.g. drop free to 1 KB, attempt a grow (blocked), a shrink (allowed), then restore.
  update public.plans set limit_bytes = 1024     where plan = 'free';
  -- ... test writes as the user ...
  update public.plans set limit_bytes = 31457280 where plan = 'free';
  ```
- **File-count gate** (Phase 7a) — a *new* file once the user is at `max_files` is rejected with `GS_FILE_LIMIT_REACHED`, while editing and deleting existing files stay open (the same humane-downgrade rule as storage). Lower the cap below the user's current file count to exercise it:
  ```sql
  update public.plans set max_files = 1 where plan = 'free';
  -- as the user: File → New then draw (the lazy insert) is blocked; editing an
  -- existing file still saves; deleting one still works.
  update public.plans set max_files = 3 where plan = 'free';
  ```
  Both triggers are `security invoker`, so their `sum`/`count` over `user_files` are RLS-scoped to the writer — exercise them as a **real user**, not in the privileged SQL Editor role.

After applying `0006`:

- **The bucket exists, is private, and carries the size limit** — this is the per-file guardrail's server-side home, so the number matters:
  ```sql
  select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'user-files';
  -- expect: user-files | false | 50000000 | {application/geo+json,application/json,text/plain}
  ```
  `public = true` here would expose every user's files to the internet — treat a wrong value as a stop-work.
- **Four owner-only policies on `storage.objects`**, and none for `anon`:
  ```sql
  select policyname, cmd, roles from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and policyname like 'user_files_objects_%'
  order by policyname;
  -- expect: four rows (select/insert/update/delete), all {authenticated}
  ```
- **`file_edits` exists with RLS enabled**, `feature_id` is **`text`** (not `uuid` — a uuid column would reject ids from imported files), and the dedup index is unique:
  ```sql
  select column_name, data_type from information_schema.columns
  where table_schema = 'public' and table_name = 'file_edits' order by ordinal_position;
  -- expect: seq bigint | file_id uuid | user_id uuid | feature_id TEXT | op text
  --         | feature jsonb | created_at timestamptz

  select indexname, indexdef from pg_indexes
  where schemaname = 'public' and tablename = 'file_edits';
  -- expect: file_edits_file_feature_uq to be UNIQUE on (file_id, feature_id)
  ```
- **The `seq` bump fires on update — a STOP-WORK check.** The single most
  load-bearing object in this migration: it is what makes a checkpoint's
  delete-by-exact-seq safe. An updated row must come back with a **higher** `seq`
  than it went in with.

  Nothing to do with Storage — no upload, and an empty bucket at this stage is
  correct. It needs only a real `user_files` row to hang the FKs off. Run as the
  normal SQL Editor role: the trigger fires regardless of role, and RLS is
  covered by the `anon` check below.

  **Two statements, and they cannot be merged into one.** Data-modifying CTEs in
  a single statement all see the same snapshot, so a seed and an upsert of the
  same row in one query fails with `21000: ON CONFLICT DO UPDATE command cannot
  affect row a second time`. The seed has to commit before the upsert can
  conflict with it. Paste this as one query — separate statements, one run:
  ```sql
  -- 1. Seed the probe row (a plain INSERT: nothing to conflict with yet).
  with probe as (select id as file_id, user_id from public.user_files limit 1)
  insert into public.file_edits (file_id, user_id, feature_id, op, feature)
  select file_id, user_id, 'zz-seq-probe', 'upsert', '{"pass":1}'::jsonb from probe;

  -- 2. Write it again through the REAL path — the same upsert the client issues.
  --    `before` reads the pre-update snapshot, so the two seqs are comparable.
  with before as (select seq from public.file_edits where feature_id = 'zz-seq-probe'),
  probe as (select id as file_id, user_id from public.user_files limit 1),
  after as (
    insert into public.file_edits (file_id, user_id, feature_id, op, feature)
    select file_id, user_id, 'zz-seq-probe', 'upsert', '{"pass":2}'::jsonb from probe
    on conflict (file_id, feature_id) do update set feature = excluded.feature
    returning seq
  )
  select
    (select seq from before) as insert_seq,
    (select seq from after)  as update_seq,
    case when (select seq from after) > (select seq from before)
         then 'PASS — the trigger bumped the seq'
         else 'FAIL — STOP. The trigger did not fire.'
    end as verdict;
  ```
  Read the verdict, **then** clean up in a second run — keeping the delete out of
  the first paste so it cannot swallow the result set:
  ```sql
  delete from public.file_edits where feature_id = 'zz-seq-probe';
  ```
  **`FAIL` means stop.** Equal seqs mean a checkpoint would delete a row another
  session had since re-edited, destroying their work silently — the exact failure
  the design is built to prevent. Re-run `0006` (it is idempotent) and confirm the
  trigger exists before going further:
  ```sql
  select tgname from pg_trigger where tgrelid = 'public.file_edits'::regclass and not tgisinternal;
  -- expect: file_edits_bump_seq
  ```

  *No rows returned at all* just means the account has no files yet — create one
  in the app, or against a throwaway row:
  ```sql
  insert into public.user_files (user_id, name)
  select id, 'zz-seq-probe-file' from auth.users limit 1;
  -- ...run the probe above, then:
  delete from public.user_files where name = 'zz-seq-probe-file';
  ```
- **Anon is locked out** — same `set local role anon; select * from public.file_edits;` check as `0001` (expect: permission denied).
- **The usage view reads Storage, not `jsonb`** — it should no longer reference `user_files.geojson` at all:
  ```sql
  select * from public.user_storage_usage;   -- as a real user; bytes come from storage.objects
  ```
  A user with files but no uploaded snapshots yet correctly reads `bytes = 0` — the figure measures the **snapshot**, so it lags the live document between checkpoints by design.
- **Two-account isolation on `storage.objects`** is a *new security surface* and belongs in the same test as the tables: account A must not be able to read, overwrite, or delete an object under account B's `{user_id}/` prefix. Exercise it over real HTTP with two signed-in users, not in the SQL Editor.

The full cross-user isolation proof (two real accounts can't see each other's rows) happens once the app's remote provider can write data — see `docs/05-worklog.md`.
