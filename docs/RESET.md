# RESET — wiping non-prod back to zero

> **Stability:** stable procedure, volatile details. Follow it top to bottom. The SQL half lives in [`../supabase/scripts/reset-non-prod.sql`](../supabase/scripts/reset-non-prod.sql) — this file is the part that script cannot contain, because most of a reset does not happen in SQL.

**This deletes every account and every file, with no undo.** It is safe today only because non-prod is the only project, nobody else uses it, and production does not exist yet ([ADR-014](02-decisions.md)). All three of those will stop being true.

---

## Pick a level first

Most resets do not need the schema rebuilt. Choosing the smaller one is the difference between a fifteen-second loop and a five-minute one.

| | **Data only** | **Full teardown** |
|---|---|---|
| **Use when** | Testing app behaviour — signup, files, quotas, locking | A migration file itself has changed |
| **Clears** | All accounts and all their data | The above, plus every table, view and function |
| **Afterwards** | Nothing — schema is untouched | Replay `0001`→`0006` |
| **Time** | Seconds | A few minutes |

**Default to data only.** A full teardown is not "more thorough" for app testing — it rebuilds objects that were already correct, and every replay is another chance to apply the six files in the wrong order.

---

## The procedure

### 1. Empty the Storage bucket — dashboard, first

**Storage → `user-files` →** select the `{user_id}/` folders → delete.

**This cannot be done in SQL and must not be skipped.** `storage.protect_delete()` rejects a direct `DELETE` on `storage.objects` with `42501`, so the dashboard (or the Storage API) is the only route. Skipping it leaves objects owned by accounts that no longer exist: nothing will ever collect them, and `user_storage_usage` will keep counting them against a user id that has been reused or is simply gone.

Do this **before** the SQL, not after. Once the rows are gone you have lost the mapping from folder to account, and you are deleting folders you can no longer identify.

> This is the same constraint that makes the account-deletion sweep on `POST /api/v1/account/delete` a **compliance obligation** rather than a cleanup nicety — see [`RUNBOOK.md`](RUNBOOK.md). Every manual reset is a reminder that the automated version is still unbuilt.

### 2. Run the SQL

Open [`../supabase/scripts/reset-non-prod.sql`](../supabase/scripts/reset-non-prod.sql).

1. **Check which project the SQL Editor is pointed at.** The guard in the script is a backstop for a mistake you have already made; the header bar is how you avoid making it.
2. Run **section 0** (the guard) — always.
3. Highlight **section 1** *or* **section 2** and use **Run selection**. Not both, not the whole file.
4. Run **section 3** and check the counts against the expected values printed beneath it.

### 3. Replay the migrations — full teardown only

Apply `0001` → `0006` **in order**, from [`../supabase/migrations/`](../supabase/migrations/), then work through that directory's README verification checks. Skip this entirely after a data-only reset.

### 4. Clear browser storage

**Not just the cache.** "Cached images and files" does not touch IndexedDB, and a stale local database is exactly the state that produces confusing test results — the app reads a document that the server has never heard of.

**DevTools → Application → Storage → Clear site data**, on every browser *and profile* you have been testing in. That covers IndexedDB (the local snapshot and edit buffer), `localStorage` (settings, templates, bookmarks) and the Supabase session token — so you will be signed out, which is correct: a stale token against a deleted account produces errors that look like bugs.

### 5. Stripe test data — occasionally

Only if you have been through a checkout. Deleted accounts leave orphaned test-mode customers and subscriptions behind, and those subscriptions keep firing webhooks for users that no longer exist — which surfaces as a stream of webhook failures that has nothing to do with whatever you are testing.

**Stripe dashboard → Developers → Delete all test data.**

---

## After a reset

**Sign up fresh rather than restoring an account.** The signup path is the only thing that exercises the `on_auth_user_created` default-plan trigger and the client's terms-acceptance write, and both are easy to break without noticing — nothing else in the app touches them.

Then the first file you create is also the first end-to-end test of the snapshot + delta path on an account with no history at all, which is the one starting state that is otherwise hard to get back to.

---

## Two things that will change this procedure

**When production is provisioned (Phase 9),** its first act — before any migration — must be:

```sql
create table public.production_marker (note text);
```

The reset script's section 0 refuses to run when that table exists. It costs nothing now and is the only thing standing between a mis-pointed SQL Editor tab and a production wipe.

**When the account-deletion Storage sweep is built,** step 1 stops being manual: deleting the accounts will take their objects with them. Until then, the dashboard step is load-bearing and the two halves of a reset can drift apart if you forget it.
