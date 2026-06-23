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

A small **provider** abstraction sits between the rest of the app and the actual backend, so the app never knows which backend is in use. There are two seams:

1. **Document seam** — the GeoJSON blob. Today wraps `dexieStorage`; routes to a Supabase-backed `RemoteStorageManager` when logged in.
2. **Settings KV seam** — templates/bookmarks/preferences. Today wraps `localStorage`; routes to a Supabase-backed implementation when logged in.

Both expose the same minimal interface: `getItem(key)`, `setItem(key, value)`, `removeItem(key)`, `clear()`.

### Current coupling (what Phase 0 refactors)

- **Document storage** — the `dexieStorage` singleton (`src/services/file/dexie-storage-manager.js`) is imported directly in ~5 call sites: `file-service.js` (primary), `auto-save-service.js`, `map-utils.js`, `draw-manager.js`, `MapView.vue`. Clean, contained seam.
- **Settings** — `localStorage` is called **directly in 43 places across 11 files** (see appendix). **No abstraction exists.** Introducing one is the bulk of Phase 0.

This client-side seam is also what delivers the "don't couple the app to Supabase" benefit *without* a server hop — the rest of the app depends on the seam, not on `supabase-js`.

## 5. Data model

The unit of saved work is a **file** — one DB row per file. Bookmarks, templates, basemap, panel preferences, and measurement units stay **user-global** (matching current single-list-per-browser behaviour).

```
auth.users                       — managed by Supabase Auth
  id (uuid), email, ...

public.files
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

-- Later, for payments:
public.user_plan
  user_id       uuid primary key references auth.users(id)
  plan          text             -- "free" | "pro" | ...
  status        text             -- stripe subscription status
  ...
```

RLS policy shape (every table, every operation):

```sql
-- example shape; final SQL lives with the migrations
create policy "owner reads"   on public.files for select using (auth.uid() = user_id);
create policy "owner inserts" on public.files for insert with check (auth.uid() = user_id);
create policy "owner updates" on public.files for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "owner deletes" on public.files for delete using (auth.uid() = user_id);
```

## 6. What moves to the cloud vs stays local

For logged-in users, settings migrate to Supabase **selectively** — device-level preferences stay local even when logged in.

| Move to Supabase (account data — follows the user) | Stay local (device-level) |
|---|---|
| Bookmarks | Supabase session JWT (**must** stay local) |
| Styling templates | Dark / colour mode |
| Basemap choice | "Welcomed" splash dismissed flag |
| Side-panel label / sort / filter preferences | App hint dismissed flag |
| Measurement units | Narrow-screen warning dismissed flag |

This split is a sensible default; revisit per key during Phases 2–3 as keys are actually migrated.

## 7. Where the existing Node API fits

Unchanged in v1. It keeps serving format conversions and the Turnstile `/session` JWT for everyone. The Supabase user JWT and the Turnstile session JWT are independent for now; unifying them is a backlog item.

---

## Appendix — files

### Document storage seam (~5 sites)
- `src/services/file/dexie-storage-manager.js` (the singleton)
- `src/constants/storage-constants.js` (`geojson_data`, `backup_geojson_data`)
- `src/services/file/file-service.js` (primary consumer)
- `src/services/auto-save/auto-save-service.js`
- `src/utils/map-utils.js`
- `src/services/draw/draw-manager.js`
- `src/views/MapView.vue`

### Settings seam — 43 direct `localStorage` calls across 11 files
- `src/stores/styling-template.js`
- `src/stores/side-panel.js`
- `src/stores/session.js`
- `src/stores/measurements.js`
- `src/stores/colour-mode.js`
- `src/stores/app-hint.js`
- `src/components/widgets/Bookmarks.vue`
- `src/components/map/MapStyleSwitcher.vue`
- `src/components/file/WelcomeSplashDialog.vue`
- `src/components/file/NarrowScreenWarningDialog.vue`
- `src/utils/map-utils.js`

### Existing backend / session
- `src/config/index.js` (`VITE_API_HOST`)
- `src/services/session-service.js` (`/session`, Turnstile exchange)
- `src/utils/api-client.js` (`apiFetch`, Bearer + 401)
- `src/composables/useTurnstileGate.js`
- `src/stores/session.js`
