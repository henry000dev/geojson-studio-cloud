# 01 — Architecture

> **Stability:** stable. This is the technical design. For the reasoning behind each choice (and the alternatives rejected), see [`02-decisions.md`](02-decisions.md).

---

## 1. Two isolated paths

- **Anonymous users:** IndexedDB (GeoJSON document) + `localStorage` (settings/templates/bookmarks), exactly as today.
- **Logged-in users:** Supabase only. No IndexedDB, nothing to sync.
- The routing decision (local vs remote) is made by **auth state**, not by the feature flag. The flag only controls whether the login UI is visible.
- The paths never sync. Isolation means a cloud fault cannot corrupt local data, and the local path is a built-in kill-switch.

## 2. Backend: Supabase

Supabase provides Postgres + Auth + Storage in one pre-integrated service.

- **GeoJSON blob lives inline** in a Postgres `jsonb`/`text` column — no practical size limit for normal files, and no separate object store to manage.
- **Auth** issues JWTs the SPA uses directly.
- **Storage** (their S3-backed blob store) is held in reserve, used only if files become large enough to warrant moving the blob out of the row (see [`04-backlog.md`](04-backlog.md)).

## 3. Integration: client-direct + RLS

The Vue app talks to Supabase **directly** via `supabase-js`. Per-user authorization is enforced by **Row-Level Security (RLS)** in Postgres. The existing Node API is **not** placed in front of Supabase as a generic CRUD wrapper.

- **Auth is always direct** to Supabase Auth (login, token refresh, OAuth, password reset). Auth is never proxied through the Node API.
- The **existing Node API stays as-is** — it continues to serve format-conversion endpoints (ArcGIS/WKT/KML/etc.) and the Turnstile-gated `/session` endpoint, for both anonymous and logged-in users.
- A thin Node layer may be added **later, selectively**, only for operations that need server-enforced business rules — most likely **payments/entitlements/quotas**. Not for general CRUD.
- **RLS is the security boundary.** Every table holding user data must scope every operation to `auth.uid() = user_id`. This is the single most security-critical surface in the epic.

## 4. The storage-provider seam

A small **provider** abstraction sits between the rest of the app and the actual backend, so the app never knows which backend is in use. Both providers live in `src/services/storage/`, organised into `file/` and `settings/` subfolders (each holding that seam plus its local/remote backends). There are two seams:

1. **File seam** — the active GeoJSON blob (today the `geojson_data` / `backup_geojson_data` records). Today wraps `dexieStorage`; routes to a Supabase-backed `RemoteStorageManager` when logged in.
2. **Settings KV seam** — templates/bookmarks/preferences. Today wraps `localStorage`; routes to a Supabase-backed implementation when logged in.

Both expose the same minimal **method surface** — `getItem(key)`, `setItem(key, value)`, `removeItem(key)`, `clear()` — but they differ in timing, and that difference is load-bearing:

- The **File seam is async** (IndexedDB/Dexie is async; every consumer already `await`s it). Wrapping it is trivial.
- The **Settings seam is synchronous**, and is *consumed synchronously*: Pinia stores read `localStorage` inside their synchronous `state()` factories (e.g. `measurements.js`, `session.js`), so state is materialised at store-construction time. A promise cannot feed that without changing store semantics — which would break the Phase 0 no-op. **The Phase 0 settings provider is therefore synchronous, a 1:1 mirror of `localStorage`.** This does not block Phase 2 (see [`02-decisions.md`](02-decisions.md) ADR-010).

### Current coupling (what Phase 0 refactors)

- **File storage** — the `dexieStorage` singleton (`src/services/storage/file/browser-file-storage.js`) is imported directly by **4 sites**: `file-service.js` (primary), `map-utils.js`, `MapView.vue`, and `draw-manager.js`. `auto-save-service.js` is **already decoupled** — it receives its storage manager by constructor injection from `draw-manager.js`, so routing it through the seam is a one-line change to what `draw-manager` injects. Clean, contained seam.
- **Settings** — `localStorage` is called **directly in 45 places across 12 files** (see appendix). **No abstraction exists.** Introducing one is the bulk of Phase 0. Of these, `session.js` (6 calls, the auth credential) **stays on raw `localStorage`** outside the seam (ADR-008 / ADR-011) — leaving **39 calls across 11 files** to migrate.

This client-side seam is also what delivers the "don't couple the app to Supabase" benefit *without* a server hop — the rest of the app depends on the seam, not on `supabase-js`.

## 5. Data model

The unit of saved work is a **file** — one DB row per file. Bookmarks, templates, basemap, panel preferences, and measurement units stay **user-global** (matching current single-list-per-browser behaviour).

```
auth.users                       — managed by Supabase Auth
  id (uuid), email, ...

public.user_files
  id            uuid primary key
  user_id       uuid references auth.users(id)   -- RLS scope
  name          text
  geojson       jsonb            -- the FeatureCollection, inline
  created_at    timestamptz
  updated_at    timestamptz

public.user_settings
  user_id       uuid references auth.users(id)
  key           text
  value         jsonb
  -- one row per (user_id, key); templates, bookmarks, prefs

-- Later, for payments (Phase 8 / ADR-022) — server-authoritative (webhook writes,
-- client reads own row; never client-writable):
public.user_plans
  user_id                uuid primary key references auth.users(id)
  plan                   text             -- "basic" | "pro" | ...  (free = local, no row)
  status                 text             -- stripe subscription status
  stripe_customer_id     text
  stripe_subscription_id text
  current_period_end     timestamptz
```

> **Phase 2 implementation note (ADR-016, amended by ADR-023).** The active-document table is **`public.user_files`** (renamed from `files` for consistency — ADR-023). The first migration (`supabase/migrations/0001_files_and_user_settings.sql`) refines this sketch: `user_settings.value` is **`text`** (the settings seam round-trips opaque `localStorage` strings, so text is a lossless mirror), `name` is **deferred to Phase 3**, and `user_files` carries a temporary **one-row-per-user** unique index for the Phase 2 single-active-file model (dropped in `0002`). There is **no `backup_geojson` column** — cloud File→New is non-destructive, so the backup/undo machinery is local-only (ADR-018/023).

RLS policy shape (every table, every operation):

```sql
-- example shape; final SQL lives with the migrations
create policy "owner reads"   on public.user_files for select using (auth.uid() = user_id);
create policy "owner inserts" on public.user_files for insert with check (auth.uid() = user_id);
create policy "owner updates" on public.user_files for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner deletes" on public.user_files for delete using (auth.uid() = user_id);
```

## 6. What moves to the cloud vs stays local

For logged-in users, **all settings follow the account** (ADR-017) — every settings-seam key is stored per-user in Supabase. The original plan kept "device-level" prefs local; that was a soft default and has been superseded.

The **only** thing that stays device-local is the **Supabase session JWT** — and that is not a setting: it's a credential that never passes through the settings seam (raw `localStorage` in `stores/session.js`; **must** stay local — ADR-008 / ADR-011).

> **Phase 2 · Slice 2b — implemented (ADR-017).** The settings seam routes **all** keys to the cloud cache when logged in (`src/services/storage/settings/settings-storage.js`); no per-key allowlist. Keys that now follow the account include `map_style`, `bookmarks`, `unit_system`, the side-panel prefs, `stylingTemplates`, plus the formerly-local `colour_mode`, `welcomed`, `app_hint_visible`, `measurements_while_drawing`, `undo_new_file_toast_enabled`. (Note: there is no separate "narrow-screen warning" key in code — that dialog reuses `welcomed`.) The synchronous interface is preserved by an in-memory cache hydrated before mount (ADR-010).

## 7. Where the existing Node API fits

Unchanged in v1. It keeps serving format conversions and the Turnstile `/session` JWT for everyone. The Supabase user JWT and the Turnstile session JWT are independent for now; unifying them is a backlog item.

---

## Appendix — files

> Counts verified against the `staging` branch on 2026-06-25; the original "~5 sites" / "43 across 11" figures had drifted.

### File seam — the `dexieStorage` singleton + its consumers
- `src/services/storage/file/browser-file-storage.js` (the singleton)
- `src/constants/storage-constants.js` (`geojson_data`, `backup_geojson_data` keys)
- `src/services/file/file-service.js` (primary consumer, ~10 calls)
- `src/utils/map-utils.js` (1 call; also a settings-seam consumer)
- `src/views/MapView.vue` (1 call)
- `src/services/draw/draw-manager.js` (no direct blob I/O — it *injects* `dexieStorage` into `AutoSaveService`)
- `src/services/auto-save/auto-save-service.js` (already decoupled via constructor injection; not a direct importer)

### Settings seam — 45 direct `localStorage` calls across 12 files
Migrated to the seam (39 calls / 11 files):
- `src/stores/side-panel.js` (17)
- `src/stores/measurements.js` (5)
- `src/components/file/WelcomeSplashDialog.vue` (4)
- `src/stores/styling-template.js` (2)
- `src/stores/colour-mode.js` (2)
- `src/stores/app-hint.js` (2)
- `src/stores/undo-new-file-toast.js` (2) — *added since the original survey*
- `src/components/widgets/Bookmarks.vue` (2)
- `src/components/map/MapStyleSwitcher.vue` (1)
- `src/components/file/NarrowScreenWarningDialog.vue` (1)
- `src/utils/map-utils.js` (1; also a file-seam consumer)

Deliberately **not** migrated:
- `src/stores/session.js` (6) — the auth credential; stays on raw `localStorage` (ADR-008 / ADR-011).

Note: `src/stores/features-list.js` surfaces in a naive `localStorage` text search but references it only in **comments** — it has no real call sites and is not part of this work.

### Existing backend / session
- `src/config/index.js` (`VITE_API_HOST`)
- `src/services/session-service.js` (`/session`, Turnstile exchange)
- `src/utils/api-client.js` (`apiFetch`, Bearer + 401)
- `src/composables/useTurnstileGate.js`
- `src/stores/session.js`
