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

- **A file is a snapshot plus deltas — neither half is the file on its own** ([ADR-037](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired)). This is the load-bearing rule of the storage design; see §4a.
- **The snapshot lives in Supabase Storage**, as an object in a private `user-files` bucket at `{user_id}/{file_id}.geojson`. Written **rarely**, at checkpoints. `public.user_files` keeps identity, name, timestamps, and the snapshot's watermark, and is a **metadata row**.
- **The deltas live in Postgres** as a small, bounded change buffer — one row per feature touched since the last snapshot, written on **every edit**. Emptied at each checkpoint.
- **Auth** issues JWTs the SPA uses directly.
- **Postgres** holds everything that is *not* the snapshot: file metadata, the delta buffer, settings KV, plans/entitlements.

> **Changed 2026-08-01 — [ADR-037](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired).** ADR-035 moved the blob out of Postgres but kept **whole-document writes** — every edit burst re-uploaded the entire file, up to 50 MB. That was judged unacceptable for a paid product, and it is a **data-model** problem no change of vendor reaches. ADR-037 splits the write path: the snapshot stays where ADR-035 put it, and edits become **feature-level deltas** in Postgres. The cost of an edit no longer depends on the size of the file. Two mechanisms designed under ADR-035 are **withdrawn**: Node-issued signed upload URLs (quota no longer needs checking before a write, so [ADR-002](02-decisions.md#adr-002--client-direct-access-with-rls-not-a-node-wrapper)'s client-direct writes are restored) and the whole-document local journal of [ADR-036](02-decisions.md#adr-036--local-storage-buffers-cloud-writes-the-recovery-journal-is-promoted-indexeddb-as-a-staging-area-is-rejected) (now an outbox for undelivered deltas).

> **Changed 2026-07-27 — [ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row).** Phases 2–7a stored the blob **inline** in a `jsonb` column, with Storage "held in reserve… only if files become large enough." That reserve was called in the hard way: a **43 MB** file crashed the entire Supabase project (PostgREST OOMs materialising the payload — `520` on the write, `521` on the read-back), twice, while the anonymous IndexedDB path handled the same file fine. The blow-up happens **upstream of Postgres**, so no trigger, `CHECK`, or policy could guard it, and a client-side cap is bypassable by request replay ([ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)). The move also removes the read ceiling and the per-edit TOAST/WAL write amplification. **Authorization is unchanged in kind** — still client-direct, still RLS — the boundary simply extends to `storage.objects`, keyed on the owner path prefix.

## 3. Integration: client-direct + RLS

The Vue app talks to Supabase **directly** via `supabase-js`. Per-user authorization is enforced by **Row-Level Security (RLS)** in Postgres. The existing Node API is **not** placed in front of Supabase as a generic CRUD wrapper.

- **Auth is always direct** to Supabase Auth (login, token refresh, OAuth, password reset). Auth is never proxied through the Node API.
- The **existing Node API stays as-is** — it continues to serve format-conversion endpoints (ArcGIS/WKT/KML/etc.) and the Turnstile-gated `/session` endpoint, for both anonymous and logged-in users.
- A thin Node layer may be added **later, selectively**, only for operations that need server-enforced business rules — most likely **payments/entitlements/quotas**. Not for general CRUD.
- **RLS is the security boundary.** Every table holding user data must scope every operation to `auth.uid() = user_id`. This is the single most security-critical surface in the epic.

## 4a. Snapshot + deltas — how a save actually works

[ADR-037](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired). **Both storage paths use this model** — cloud and local/anonymous alike, so there is one model rather than one interface with two semantics.

Two writes with unrelated jobs, instead of one number trying to serve both:

| | Written | Where | Cost |
|---|---|---|---|
| **Delta** | every edit | Postgres change buffer | hundreds of bytes |
| **Snapshot** | at checkpoints | Storage object (cloud) / IndexedDB (local) | the whole document |

**Reading a file** — cold load, or opening it on another device:

1. Download the snapshot (one fetch).
2. Fetch delta rows above the snapshot's watermark (a small query — usually a few rows).
3. Apply each by feature id: replace, or remove.

The reading client is then holding the current document and may checkpoint immediately, which cleans up after whichever session left the deltas behind. **The system tidies itself by being used.**

**Checkpointing is not a merge.** The client already holds the finished document — that is what the user is looking at — so a checkpoint is *"upload what you are holding, mark it as the new base."* No fetch of the old snapshot, no replay, and **nothing server-side ever materialises the document**, which is what stops ADR-035's crash returning by another route.

Four rules, each load-bearing:

- **Deltas are assignments, never instructions.** *"Feature X is now this"* / *"feature X is gone"* — never *"move feature X three metres north."* This makes replay **idempotent**, makes ordering **per-feature** rather than global, and lets the buffer **deduplicate by feature id**, so it grows with features *touched*, not edits *made*.
- **Failure ordering:** upload the snapshot → record the watermark → delete the deltas it covers. The watermark is what stops a checkpoint deleting edits made *while it was uploading*.
- **The watermark advances to the top of the unbroken run, never to `max(incorporated)`** ([ADR-037 addendum 2](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired)). `snapshot_seq` is a scalar and cannot express a set with a hole in it, so a session holding `{11,12,13,15}` writes **13**, not 15 — otherwise every future reader skips 14, another session's edit. Readers re-apply 15 harmlessly, because deltas are assignments. The watermark update is also a **compare-and-set** against the base the checkpoint read: a session that loses replaced nothing and **must not delete any deltas**.
- **A checkpoint may only delete deltas it actually incorporated** — never simply "everything up to now." A session's incorporated set is `{seqs fetched at open} ∪ {seqs its own writes returned}`, **captured when it serialises the document** so edits made during the upload survive. It must be a **set**, not a high-water mark (`seq <= max` deletes another session's interleaved writes), and must not be a writer/session id (which would delete your own post-serialise writes *and* never clean up deltas inherited at open). The dedup upsert therefore **bumps `seq`** rather than preserving it — which is what makes delete-by-exact-seq safe with no special case: a row another session has since re-edited carries a new `seq`, does not match, and survives. See the [ADR-037 addendum](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired).
- **Whole-document operations bypass the buffer.** Import, File→New, and bulk operations write a snapshot directly and clear it. General rule: *if the delta would be bigger than the snapshot, just write the snapshot.*

**The invariant, which every code path must honour:** *a file is snapshot + deltas.* Anything that reads the snapshot object directly and forgets the deltas serves stale data — and fails quietly. Enforced two ways: the seam (§4) is the **single chokepoint** for reading a file and applying an edit, and anything that must read the object directly (publish, export bundles) **forces a checkpoint first**.

### Multi-session

**Editing one file from multiple tabs or devices is not supported** (a product position, stated in the UI — [ADR-037 addendum](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired)). It is implemented without machinery to enforce it perfectly:

| Situation | Blocked? | Data | User sees |
|---|---|---|---|
| 2nd tab, same browser | **Yes** — Web Lock | nothing at risk | "already open in another tab" + take over |
| Crashed tab | No — lock auto-released | nothing at risk | opens normally |
| 2nd device | No | per-feature last-write-wins; nothing else lost | warned on open and on change |
| Offline → reconnect | No | queued deltas win for the features they touch | silent, unless the file moved on |

- **Same browser** uses the **Web Locks API** (`navigator.locks`) — per-origin, **auto-released when the tab closes or crashes**, so there is no lease table, no heartbeat, no TTL, and no stale-lock problem. Take-over coordinates over `BroadcastChannel`. This covers the case users actually hit.
- **Cross-device is not locked.** A server lease needs expiry, and any expiry opens a window where a lapsed session returns and writes — which is precisely the offline-outbox flow this design supports, so the two interact badly. Deferred to [`04-backlog.md`](04-backlog.md).
- **Presence needs no heartbeat:** deltas newer than the snapshot that *this* session did not write mean someone else has been editing. That drives both warnings.
- **Nothing is destroyed either way**, because of the incorporated-set rule above. On a second device the blast radius is a single feature, against today's whole-document overwrite.

## 4. The storage-provider seam

A small **provider** abstraction sits between the rest of the app and the actual backend, so the app never knows which backend is in use. Both providers live in `src/services/storage/`, organised into `file/` and `settings/` subfolders (each holding that seam plus its local/remote backends). There are two seams:

1. **File seam** — the active GeoJSON blob (today the `geojson_data` / `backup_geojson_data` records). Wraps `dexieStorage` for anonymous users; routes to a Supabase-backed backend when logged in. **The seam is what makes the ADR-035 storage move a one-line change** — the cloud backend is swapped from a `user_files.geojson` provider to a Supabase Storage provider without any consumer knowing, which is exactly the Phase 0 branch-by-abstraction payoff. Per the user's call (2026-07-27) the old Postgres blob provider stays in the repo as commented dead code, **with no feature flag**, until the new path is proven — a *code* fallback only, since the `geojson` column goes stale as soon as files are written to Storage.
2. **Settings KV seam** — templates/bookmarks/preferences. Today wraps `localStorage`; routes to a Supabase-backed implementation when logged in.

> **The File seam's *interface* changes under [ADR-037](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired) (2026-08-01) — the first time it has.** `getItem`/`setItem` is a **whole-document** shape; deltas need something like `applyChange(delta)` / `getDocument()` / `checkpoint()`. Phase 0's branch-by-abstraction made the ADR-035 storage move a one-line **backend** swap, and it will **not** do the same here, because the shape of the operation changes and not merely its destination. This is the largest single piece of client work in the slice. The seam also becomes the **enforcement point for the snapshot+deltas invariant** (§4a) — the one place that knows a file is two halves.

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

public.user_files                -- METADATA ONLY (ADR-035); the bytes live in Storage
  id             uuid primary key
  user_id        uuid references auth.users(id)  -- RLS scope
  name           text
  snapshot_seq   bigint                          -- WATERMARK (ADR-037): the highest delta
                                                 -- sequence the current snapshot contains.
                                                 -- Reads fetch deltas above it; checkpoints
                                                 -- advance it AFTER the object upload lands.
  created_at     timestamptz
  updated_at     timestamptz
  -- geojson jsonb  -- REMOVED (ADR-035, Phase 7b). Kept unwritten during the
  --                -- dead-code overlap, then dropped. The FeatureCollection is
  --                -- now an object at user-files/{user_id}/{file_id}.geojson

public.file_edits               -- THE CHANGE BUFFER (ADR-037) -- bounded, not a mirror.
  seq           bigserial        -- global, monotonic; the ordering + watermark key
  file_id       uuid references user_files(id) on delete cascade
  user_id       uuid references auth.users(id)  -- RLS scope (denormalised for the policy)
  feature_id    text not null    -- TEXT, not uuid: app ids are uuidv4, gl-draw's fallback
                                 -- is a 32-char nanoid, and user-supplied ids from an
                                 -- imported file are preserved verbatim (ADR-037)
  op            text not null    -- 'upsert' | 'delete' -- ASSIGNMENTS, never instructions
  feature       jsonb            -- the whole new feature for 'upsert'; null for 'delete'
  created_at    timestamptz
  -- unique (file_id, feature_id): the buffer DEDUPLICATES -- twenty edits to one feature
  -- collapse to one row, so it grows with features TOUCHED, not edits MADE.
  -- The upsert MUST bump seq (on conflict ... do update set seq = nextval(...)), never
  -- preserve it: that is what makes a checkpoint's delete-by-exact-seq safe. A row another
  -- session has since re-edited carries a NEW seq, so it does not match and survives.
  -- Emptied at every checkpoint, so it is never a copy of the file. This is deliberately
  -- NOT `file_features` (one permanent row per feature) -- see ADR-037's rejected list.

storage.objects (Supabase-managed)              -- the snapshot store
  bucket_id = 'user-files'                       -- private bucket, explicit file_size_limit
  name      = '{user_id}/{file_id}.geojson'      -- owner prefix is the RLS key
  metadata->>'size'                              -- the ONLY authoritative byte count;
                                                 -- a client-written size column would be
                                                 -- spoofable by request replay (ADR-033).
                                                 -- NOTE it measures the SNAPSHOT, which lags
                                                 -- the live document between checkpoints.

public.user_settings
  user_id       uuid references auth.users(id)
  key           text
  value         jsonb
  -- one row per (user_id, key); templates, bookmarks, prefs

-- Payments (Phase 6 — ADR-022/ADR-030/ADR-031) — server-authoritative (auth-trigger +
-- webhook write; client reads own row; never client-writable):
public.plans                            -- tier lookup; limits are DATA (ADR-031)
  plan                   text primary key -- "free" | "basic" | "pro" (+ hidden rows)
  limit_bytes            bigint           -- per-tier storage quota
  max_files              int not null     -- per-tier file-count cap (ADR-032)
  label, rank                             -- display metadata
  description            text             -- private maintainer memo (ADR-034)

public.user_plans
  user_id                uuid primary key references auth.users(id)
  plan                   text default 'free' references plans(plan)
  status                 text             -- stripe subscription status
  stripe_customer_id     text
  stripe_subscription_id text
  current_period_end     timestamptz
  -- Every user has a row: a security-definer trigger on auth.users writes a
  -- default 'free' row on signup (ADR-031), so "free = no row" from ADR-022
  -- became "free = a default free-plan row". RLS: owner SELECT only.
  -- (The plan was named 'early_access' until the Phase 7a rename — ADR-032.)
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

The **same shape applies to the blob**, on `storage.objects`, keyed on the owner path prefix instead of a column (ADR-035). This is a **second security surface** and belongs in the two-account isolation test alongside the tables:

```sql
-- example shape; final SQL lives with the migrations
create policy "owner reads objects" on storage.objects for select to authenticated
  using (bucket_id = 'user-files' and (storage.foldername(name))[1] = auth.uid()::text);
-- …insert / update / delete mirror this; anon is revoked entirely.
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
