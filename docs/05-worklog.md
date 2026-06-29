# 05 — Worklog

> **Stability:** volatile. A dated, append-at-top log of what's been done and where things were left. **Read this first on resuming.** Newest entry at the top.

---

## 2026-06-29 — Phase 3 design agreed (ADR-018); ready to implement Slice 3a

Design session for Phase 3 (multi-file "My Files") — **no code yet.** Walked the real app flows (`FileToolbar` New/Import, `file-service`, `auto-save-service`, `FileInfo`, `FileImportDialog`) and agreed the multi-file model. Recorded as **ADR-018**; Phase 3 re-sliced in [`03-rollout.md`](03-rollout.md); deferrals parked in [`04-backlog.md`](04-backlog.md).

**Decisions:**
- **Lazy, non-destructive File→New (cloud):** New starts a blank file; the row is inserted on the first edit. The previous file persists as its own row → the destructive "replace" confirm is dropped in cloud mode.
- **`backup_geojson` vestigial in cloud:** revert = reopen the previous file from My Files; the backup/undo-new-file machinery stays **local-only** (gated at the orchestration layer, not the seam). Column left in place, dropped later.
- **Provider rewrite (ships with `0002`):** active-row-**by-id** get/set/remove; serialised lazy-insert on first write; **UPDATE-by-id not upsert** (closes the switch/delete races); `clear()` made safe. `0002` drops `files_one_per_user_uq`, adds `name`.
- **Active file:** cold load opens the most-recently-updated row (none → blank); switching is in-place (clear + reset undo/redo + load, pending autosave flushed first); delete-active → blank editor; **open/import stay writable**.
- **First-login migration:** opt-in prompt when **cloud files == 0 AND local non-empty** → yes copies local into the first cloud file; self-extinguishing (no flag).
- **Unchanged:** bookmarks/templates user-global; multi-tab last-write-wins (no sync).

**Does NOT complicate the storage seam:** the active-document I/O (autosave/load) stays uniform across both paths; the one branch is at the New-file orchestration (a genuinely different feature), and the cloud branch is the simpler one. Confirmed `fileStorage.clear()` has no app caller today (so the "delete all files" footgun isn't currently reachable — still being made safe).

### Where to resume — Phase 3 · Slice 3a
- Author `supabase/migrations/0002_multi_file.sql` (drop `files_one_per_user_uq`, add `name`); user applies to non-prod. Rewrite `remote-file-storage.js` → by-id + serialised lazy-insert + UPDATE-by-id + safe `clear()`. Add `src/stores/active-file.js` (active id + list + lifecycle + `ensureResolved()` most-recent-on-load) and wire `file-storage.js` routing. Prove the multi-file round-trip before any UI (3b).

---

## 2026-06-28 — Phase 2 · Slice 2b: settings remote provider (hydrate-on-login cache)

File round-trip + two-account RLS verified by the user. Built the cloud **settings** backend, keeping the seam synchronous (ADR-010) with **per-key routing** (architecture §6).

- **`settings-cache.js`** (new, light / main bundle) — in-memory `Map` + a synchronous `localStorage`-shaped backend; writes schedule a fire-and-forget background flush via an installed flusher. **No SDK import**, so it's main-bundle-safe.
- **`cloud-settings-bootstrap.js`** (new, dynamic / flag-on) — awaits auth; if logged in, hydrates all `user_settings` rows into the cache and installs the flusher (`upsert` on `(user_id,key)`; delete on remove/clear). Fails safe to local on error.
- **`settings-storage.js`** — per-key routing via a `CLOUD_SETTINGS_KEYS` allowlist: cloud only when the cache is active **and** the key is allowlisted; otherwise `localStorage`. Still fully synchronous.
- **`main.js`** — when the flag is on, dynamically import + `await initCloudSettings()` **before `app.mount()`**, so the cache is populated when stores read it in their `state()` factories. Flag off mounts synchronously (unchanged).

**Classification (architecture §6).** CLOUD (follows the user): `map_style`, `bookmarks`, `unit_system`, the four side-panel keys (`feature_label_property`, `feature_sort_option`, `feature_filter_property`, `filter_sync_map`), `stylingTemplates`. LOCAL (device-level): `colour_mode`, `welcomed`, `app_hint_visible`, narrow-screen flag, plus two **judgment calls** — `measurements_while_drawing` and `undo_new_file_toast_enabled` (treated as device/workflow toggles, not in §6's move list). *Flagged for user confirmation.*

> **Revised same-day (ADR-017):** user decided **all** settings should follow the account. Dropped the `CLOUD_SETTINGS_KEYS` allowlist — the settings seam now routes **every** key to the cloud cache when logged in (`resolveBackend()` again, no key check). The session credential stays local automatically (it's outside the seam — ADR-008/011). Also noted: there is no distinct "narrow-screen" key in code (the dialog reuses `welcomed`). Rebuilt clean.

> **Housekeeping:** moved the file seam's local backend from `services/file/dexie-storage-manager.js` → `services/storage/browser-file-storage.js` (file rename only — code identifiers `dexieStorage`/`DexieStorageManager` unchanged), so it sits beside its remote sibling (`remote-file-storage.js`). `services/storage/` is now the whole persistence layer; `services/file/` stays file domain logic. One import path updated (`file-storage.js`); build clean.

> **Housekeeping:** organised `services/storage/` into two subfolders — `file/` (`file-storage.js`, `browser-file-storage.js`, `remote-file-storage.js`) and `settings/` (`settings-storage.js`, `settings-cache.js`, `cloud-settings-bootstrap.js`). File moves + import-path updates only (all `@/` alias paths; ~15 importers across `src/`); no other code changes. Build clean.

**Isolation:** a fresh cloud account starts with empty cloud settings; local settings are untouched and reappear on logout (ADR-004). Opt-in local→cloud migration is Phase 3.

**Build:** clean. `cloud-settings-bootstrap-*.js` + `remote-file-storage-*.js` + `supabase-client-*.js` are separate async chunks, none in main. e2e (flag off) unaffected.

### Where to resume — Phase 3
- Multi-file "My Files" UI; **drop `files_one_per_user_uq`**, add `name`; the opt-in "save your current local work as your first file?" migration on first login. (Phase 2 is functionally complete once settings are verified.)

---

## 2026-06-28 — Phase 2 · Slice 2: remote file provider + auth-state routing

Schema applied to non-prod by the user and verified. Built the remote **file seam** and wired routing by auth state — **no call-site changes** (the Phase 0 seam paying off).

- **`src/services/storage/remote-file-storage.js`** (new) — Supabase backend implementing `getItem/setItem/removeItem/clear` against `public.files`. The two seam keys map to columns (`geojson_data`→`geojson`, `backup_geojson_data`→`backup_geojson`) on the user's single row; writes are `upsert` on `user_id` (preserving the other column); `removeItem` nulls a column; `clear` deletes the row. RLS scopes everything to the owner. Statically imports the SDK, so it's only reached via dynamic import → its own async chunk.
- **`src/services/storage/file-storage.js`** — `resolveBackend()` is now async: flag OFF → `dexieStorage` immediately (never touches auth/Supabase, still dark); flag ON → `await auth.ensureInitialised()` then route (logged-in → dynamically-imported `remoteFileStorage`, else local). Awaiting auth on the first read fixes the **startup race** so a logged-in user loads their cloud file, not stale local data.
- **`src/stores/auth.js`** — `init()` → **`ensureInitialised()`**: idempotent, awaitable, shares one module-level init promise between the account UI and the file seam.
- **`AccountMenu.vue` / `LoginDialog.vue`** — reload on sign-in success and after sign-out, so the app re-bootstraps cleanly on the correct storage path (the two paths never mix in-memory; also discards any pending local autosave timer so anonymous data can't leak to cloud). Google OAuth already reloads via redirect, and the startup await handles its return.

**Build:** clean. Chunks: `remote-file-storage-*.js` (~0.9 kB) + `supabase-client-*.js` (~202 kB) are separate async chunks; main bundle +~2 kB (light auth/flags stores), **no SDK in main**. Flag-off = unchanged, so the existing e2e (anonymous) is unaffected.

**Not yet verified — the security gate (do before trusting this):**
1. **Round-trip:** flag on, sign in, draw something (autosaves to cloud), reload → it persists; sign out → local data returns.
2. **Two-account RLS isolation:** sign in as A, save; sign in as B → B sees empty/their own, never A's; confirm in the Supabase Table Editor that each row's `user_id` matches, and that the SQL `set local role anon` check still denies.

### Where to resume — Phase 2 · Slice 2b
- Settings remote provider against `public.user_settings` + the **hydrate-on-login in-memory sync cache** (ADR-010), keeping the settings seam synchronous. Then Phase 3 (multi-file UI; drop `files_one_per_user_uq`; add `name`).

---

## 2026-06-27 — Phase 2 · Slice 1: cloud schema + RLS authored (not yet applied)

First Phase 2 slice — **schema + Row-Level Security only**, no app code. Authored `supabase/migrations/0001_files_and_user_settings.sql` (+ `supabase/migrations/README.md`) as the source of truth (ADR-009):

- **`public.files`** — the active GeoJSON doc. Phase 2 keeps **one row per user** (`files_one_per_user_uq`, dropped in Phase 3). Columns `geojson` + `backup_geojson` (the file seam writes both `geojson_data` and `backup_geojson_data`; ADR-004 keeps no IndexedDB for logged-in users). `name` deferred to Phase 3.
- **`public.user_settings`** — per-user `(key, value)`; `value` is **`text`** (lossless mirror of the seam's opaque `localStorage` strings).
- **RLS** — owner-only per-command policies (`auth.uid() = user_id`) scoped to `authenticated`; `anon` revoked. `updated_at` trigger; `on delete cascade` to `auth.users`. Decisions recorded as **ADR-016**; architecture §5 annotated.

**State:** migration **authored, not applied.** Next: user applies it to the **non-prod** project (SQL Editor), confirms tables + RLS + the `anon` lockout check (see migrations README).

### Where to resume — Phase 2 · Slice 2 (after schema applied)
- `RemoteStorageManager` implementing the **file seam** against `public.files` (upsert on `user_id`), wired into `resolveBackend()` to switch by **auth state** (logged-in → remote, anonymous → local) — no call-site changes. Prove the single active-file round-trip, then the **two-account RLS isolation** test (the hard gate). Settings remote provider + hydrate-on-login cache (ADR-010) is Slice 2b.

---

## 2026-06-27 — Phase 1: Supabase Auth wired up, shipped dark behind the flag

Supabase project exists (user-created): URL + **publishable** key (`sb_publishable_…`, not the legacy anon key — **ADR-012**) supplied. **Email** and **Google** providers enabled; **"Confirm email" is ON**, so email signups must click a confirmation link before they can sign in (the login UI says so; Google has no such step). Supabase Site URL = `http://localhost:5173` for dev.

**Built (all gated behind `?ff=cloud`, account module code-split so it's absent from the main bundle):**
- **Config / env:** `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` added to `.env.local` (real values, gitignored) and `.env.template` (placeholders); surfaced via `src/config/index.js` (`config.supabase`).
- **Feature-flag store** `src/stores/feature-flags.js` (`cloudEnabled`) — **URL-presence-based, not persisted (ADR-015):** the store reads `?ff=cloud` from the URL at construction; no `localStorage`, no `:off` param, no URL-stripping, no pre-Pinia bootstrap. Default (no param) = vanilla app. *(Revised same-day from the original persist-to-localStorage design — see the addendum below; ADR-013 superseded.)*
- **Supabase client** `src/services/auth/supabase-client.js` — lazy singleton (`getSupabaseClient()`), the only static importer of `@supabase/supabase-js`; only ever reached via dynamic `import()`, so the SDK lands in its own async chunk and never loads when the flag is off.
- **Auth store** `src/stores/auth.js` — `user`/`session` state, `isLoggedIn`, and `init()` / `signInWithPassword` / `signUpWithPassword` / `signInWithGoogle` / `signOut`; each dynamically imports the client (no SDK at app start).
- **UI** — `src/components/auth/AccountMenu.vue` (entry point in the `AppMenu` `#end` slot, before branding) + `src/components/auth/LoginDialog.vue` (email+password sign-in/sign-up tabs + "Continue with Google", built on `GsDialog`). `AppMenu` loads `AccountMenu` via `defineAsyncComponent` only when `cloudEnabled`, so flag-off never fetches the account chunk.
- **Dependency:** `@supabase/supabase-js` added.

**Inertness check (the Phase 1 acceptance criterion):** flag off → `AccountMenu` async chunk is never requested, no Supabase client constructed, no auth network calls, no account UI; only the tiny inert flag-check rides in the main bundle. Flag on (`?ff=cloud`) → "Sign in" appears; dev can sign up / sign in (email+password or Google) / sign out. No data has moved — Phases 2+ do storage routing.

**Validation:** `npm run build` clean (vite 8 / rolldown). Chunking confirms the split: `AccountMenu-*.js` (~7 kB, the account module) and `supabase-client-*.js` (~202 kB, the SDK) are **both separate async chunks**, absent from the main `index-*.js`. `@supabase/supabase-js@^2.108`. e2e to be run by the user.

### Addendum (same day) — decisions from review

- **Flag semantics simplified (ADR-015).** Reworked the flag to be **URL-presence-based, not persisted**: `cloudEnabled` = `?ff=cloud` present in the URL, read once at load. Removed the `localStorage` persistence, the `ff_cloud` constant, the `:off` param, the URL-stripping, and the pre-Pinia bootstrap in `main.js`. Added an OAuth tweak: `signInWithGoogle` sets `redirectTo` to carry `ff=cloud` back so the account UI survives the Google round-trip. Rationale: simpler mental model, and the bare domain is always vanilla so the dark feature can't stick on a browser. Rebuilt clean.
- **Environments (ADR-014).** Decided on **separate Supabase projects per environment** (dedicated prod isolated from non-prod). **For now: non-prod only** — the current project is local/non-prod; the production project and all CI/Dockerfile env-var wiring are **deferred** until core cloud functionality is proven. The team is new to Supabase, so we keep focus on functionality first.
- **Pipeline wiring deferred (explicit).** Worked out the exact mechanism (mirror the Mapbox token: `--build-arg` → Dockerfile `ARG`/`ENV` → Vite; URL as a GitHub Variable, publishable key as a Secret; env-scoped per GitHub Environment) but **did not touch** `Dockerfile.staging/production` or `deploy-*.yml`. To be done with the prod setup later.

### Where to resume — Phase 2
- Remote provider implementations behind the existing seams (`RemoteStorageManager` over `public.files`; settings KV over `public.user_settings`), switched by **auth state** (logged-in → remote, anonymous → local). RLS first, manually verified. Prove the single-active-file round-trip before any multi-file UI.

---

## 2026-06-26 — Phase 0 complete (both seams in)

**Step 2 — Settings seam done.** Added `src/services/storage/settings-storage.js` (synchronous `localStorage` mirror, same `resolveBackend()` swap-point as the file seam). Migrated all settings consumers — **39 calls across 11 files** — onto `settingsStorage` in four batches (A: leaf stores; B: `side-panel`; C: `styling-template` + `Bookmarks`; D: map/dialog components). `session.js` (6 calls) deliberately left on raw `localStorage` (ADR-008 / ADR-011). Production build clean.

**Validation.** `npm run build` clean for both steps. The Playwright e2e suite is **flaky** in this environment — different tests fail across identical runs (PC07/PC08, the large-file `file-import-real-world` RW04/07/08, `feature-editing` G02). Traced PC07/PC08: the Web-Mercator path mounts the Cloudflare **Turnstile** widget in a cross-origin iframe, whose script is denied `localStorage` ("Access is denied for this document") under the test's partitioned storage — surfaced as an uncaught page error (shows as `<anonymous>`). Third-party/environmental, and **not** in the seam's code path (convert → `apiFetch` → session store; `session.js` untouched). A clean re-run confirmed the failures move around → flakiness, not regression. Treating these as known-flaky for now.

**Phase 0 is complete:** both provider seams (file + settings) are in place as a behaviour-preserving no-op; the anonymous/local path is unchanged. Going forward, e2e is run by the user; the build is the fast local check.

### Where to resume — Phase 1 (decisions made 2026-06-26)
- **Auth methods:** email + password **and** Google OAuth.
- **Supabase project:** user is creating it (guided walk-through provided); will share the project URL + anon (public) key. App is greenfield for Supabase.
- **Sequencing:** all Phase 1 code waits until the Supabase project + keys exist, then done together — feature-flag store (`?ff=cloud` → `localStorage` → reactive `cloudEnabled`; ADR-005), `supabase-js` lazy-init client (code-split, inert when flag off), then login/signup/logout UI (email+password + Google).
- **Blocked on:** Supabase project URL + publishable key; Email and Google providers enabled in Supabase. Env vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` (in gitignored `.env.local`; documented in `.env.template`). *(Now unblocked — see 2026-06-27 entry. Key naming: publishable, not legacy anon — ADR-012.)*

---

## 2026-06-25 — Pre-Phase-0 code survey; docs reconciled; starting the seams

Surveyed the actual `geojson-studio-app` `staging` branch before writing any code, and reconciled the design docs with what's really there:

- **File seam (was "Document seam" — renamed for consistency with the "file" glossary term):** 4 direct `dexieStorage` importers — `file-service`, `map-utils`, `MapView`, `draw-manager`. `auto-save-service` is **already decoupled** via constructor injection, so it rides along when `draw-manager` injects the provider. (The doc previously said "~5 sites", lumping auto-save in as a direct importer.)
- **Settings seam:** 45 direct `localStorage` calls across 12 files (doc said 43/11). `undo-new-file-toast.js` is new since the original survey; `features-list.js` only mentions `localStorage` in comments (not a call site). `session.js` (6 calls) stays on raw `localStorage`, outside the seam.
- **Key finding:** the settings seam must be **synchronous** — Pinia stores read `localStorage` in their sync `state()` factories, so an async seam would change store semantics and break the no-op. Recorded as **ADR-010**; the session-stays-local refinement is **ADR-011**.

Updated `00-overview.md` (status + glossary), `01-architecture.md` (§4 + appendix; "Document seam" → "File seam"), `03-rollout.md` (Phase 0), and appended ADR-010/011 to `02-decisions.md`.

### Progress
- ✅ **Step 1 — File seam done.** Added `src/services/storage/file-storage.js` (a facade delegating to `dexieStorage` via a `resolveBackend()` indirection — the single place Phase 2 swaps in remote-by-auth). Repointed all 4 importers (`file-service`, `map-utils`, `MapView`, `draw-manager`); `auto-save-service` rides along via DI (`draw-manager` injects the provider). `dexieStorage` is now referenced only by the singleton + the provider.
- **Validation:** production build clean; `npm run test:e2e` → **433 passed, 11 failed**. All 11 failures are environmental, not the seam: 10 are conversion/Web-Mercator/session tests that "require backend at localhost:8080" (Node API not running here); 1 is a context-menu flake (G02, whose twin G03 passed). The seam-exercising specs (autosave, file-management, new-file restore/undo, native `.geojson` import) all passed.

### Where to resume
- **Next action:** Phase 0, Step 2 — add `src/services/storage/settings-storage.js` (synchronous `localStorage` mirror), then migrate the settings consumers in per-store batches (A: leaf stores; B: `side-panel`; C: `styling-template` + `Bookmarks`; D: map/dialog components). `session.js` stays on raw `localStorage`. Re-run the e2e suite at batch boundaries.

---

## 2026-06-23 — Planning complete; planning repo set up

- Agreed the full architecture and rollout for the Cloud epic (see [`00-overview.md`](00-overview.md) through [`04-backlog.md`](04-backlog.md)).
- Named the effort the **Cloud epic**; brand is **"Cloud"**; this planning repo is **`geojson-studio-cloud`**, a sibling to app/api/resources.
- Wrote the doc set: overview, architecture, decisions (ADR-001…009), rollout, backlog, this worklog.
- **Status:** parked, pre-implementation. No code written in either code repo yet.

### Setup tasks — all done
- ✅ `git init`, first commit, pushed to remote.
- ✅ Back-pointers added: `geojson-studio-app/CLAUDE.md` and `geojson-studio-api/CLAUDE.md` each reference `../geojson-studio-cloud` (with a "read before working on accounts/auth/cloud-storage" trigger). The pre-existing app↔api sibling pointers were kept.
- ✅ `geojson-studio-app/docs/cloud-accounts-plan.md` reduced to a one-line redirect to this repo (superseded by this doc set).

### Where to resume
- **Next action:** Phase 0 — introduce the document-storage and settings-KV provider seams as a behaviour-preserving no-op; validate by the existing Playwright suite passing unchanged. See [`03-rollout.md`](03-rollout.md#phase-0--branch-by-abstraction-no-flag-no-user-visible-change).
