# Supabase migrations

This directory is the **source of truth** for the cloud database schema and RLS (ADR-009). The Supabase projects are downstream of these files — never hand-edit schema in the dashboard and leave it undocumented here.

## Files

Migrations are applied in **filename order**:

| File | What it does |
|---|---|
| `0001_files_and_user_settings.sql` | Phase 2 schema: `public.user_files` + `public.user_settings`, the `updated_at` trigger, and owner-only RLS. |
| `0002_multi_file.sql` | Phase 3: drop the one-row-per-user index on `user_files`, add `user_files.name` (multiple named files per user). |

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

The full cross-user isolation proof (two real accounts can't see each other's rows) happens once the app's remote provider can write data — see `docs/05-worklog.md`.
