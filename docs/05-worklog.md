# 05 — Worklog

> **Stability:** volatile. A dated, append-at-top log of what's been done and where things were left. **Read this first on resuming.** Newest entry at the top.

---

## 2026-07-02 — Defer production Supabase to the beta gate; Phase 4 is now non-prod-only

Planning tweak — **no code.** The user questioned why Phase 4 provisions the **production** Supabase project when we're nowhere near production-ready. Confirmed it doesn't need to, and it's more consistent with **ADR-014** ("non-prod only for now; defer prod until core is proven") to move it.

**Decision:** split the old Phase 4. Nothing between here and beta requires the prod project — the Node server layer + account deletion need only *a* `service_role` key (non-prod has one), the account area is non-prod, and even **Stripe develops in test mode** against non-prod. So:
- **Phase 4 → "Node server layer (on non-prod)"** — JWT-verify middleware + `service_role` client + account deletion, all against the existing non-prod project. Prod bullet removed.
- **Production provisioning moved to the front of Phase 6 (beta)** — the first point real users arrive and the user's explicit "non-prod is good enough" sign-off. Pins ADR-014's vague "until proven" to a concrete gate.
- **Phase 8** annotated: Stripe Checkout/webhook/portal built in **test mode** (Stripe CLI → local Node → non-prod `user_plans`); live keys + prod are the launch cutover only.

**Docs touched:** ADR-014 Consequences (added "when proven happens" → Phase 6 gate); rollout Phase 4 rewritten (non-prod, risk down to low–medium), Phase 6 gains the prod-provisioning task + gate framing, Phase 8 gains the test-mode note.

### Where to resume — Phase 4 (Node server layer, on non-prod)
- Add the server layer to `geojson-studio-api`: Supabase-JWT-verify middleware + a `service_role` client pointed at **non-prod**; first endpoint = **account deletion** (cascade via the `on delete cascade` FKs). Still open on the user's side: verify Phase 3 Slice 3c, and large-file testing → per-file size limit.

---

## 2026-07-02 — Design Q&A: staged entry topology, connection-loss resilience, delta framing (ADRs 024–025)

Planning session — **no code.** Pressure-tested four concerns for Phases 7–8 and captured the outcomes.

**Decisions (new ADRs):**
- **ADR-024 — Entry topology in two stages.** A query-string flag only affects client-side behaviour after load, so the landing can't be *both* flag-gated *and* statically SEO-served. **Stage 1:** dark preview — one SPA at root, a flag-gated `/` renders a **temporary client-rendered `Landing` component**, `/app` = editor, no infra change, no SEO (fine while dark). **Stage 2 (launch):** the ADR-021 restructure — **static SEO landing** at `/`, app → `/app`, flag deleted, temporary component removed. Resolves the earlier bare-domain contradiction: Stage 1 bare = editor, Stage 2 bare = landing.
- **ADR-025 — Connection-loss resilience (Level 1).** `supabase-js` has **no offline queue** (unlike Firestore); logged-in users keep no local copy (ADR-004). v1 = **retry-with-backoff + reconnect flush + a save-status indicator + a `beforeunload` guard** (autosave-service + a small Pinia store; no new storage). A crash-recovery journal (Level 2, a scoped ADR-004 exception) and full offline-first (Level 3) are rejected/backlogged.

**Other Q&A (no ADR):**
- **Deltas / large files (#4)** — right smell, wrong time/mechanism. v1 keeps **whole-document writes** (matches inline-`jsonb`; deltas save upload bytes but not DB write cost until you move to **per-feature rows**). If ever needed, prefer **client-direct RPC / per-row** over Node endpoints (ADR-002). The user will **test large files** and likely impose a **per-file size limit** (Studio is an editor, not built for huge files) — which may make deltas moot.
- **RLS vs RPC vs Node endpoints** — clarified: both RLS (DB-enforced per-user `WHERE`) and RPC (a Postgres function called via `supabase.rpc`) are client-direct; Node endpoints are for **secrets, trusted callbacks, and privileged ops only** (ADR-002/020), not CRUD.

**Docs touched:** new ADR-024/025; ADR-021 status annotated (this is its Stage 2 form); rollout Phase 7 rewritten as two stages + connection-loss added to cross-cutting concerns; backlog — Storage expanded (per-file size limit, whole-doc-vs-delta), new **Resilience** section (Level 2 journal).

### Where to resume — Phase 4 (production + Node server layer)
- Unchanged: Phase 3 is complete; Phase 4 is next. ADRs 024–025 are forward-looking design capture (Phases 7 / cross-cutting) — nothing to build now.

---

## 2026-07-01 — Schema cleanup: `files` → `user_files`, drop `backup_geojson` (ADR-023)

Two schema refinements, done by **amending the creation scripts** — we're pre-production and the user dropped the non-prod tables, so no ALTER/cleanup migration (ADR-023). App build clean.

- **`0001` / `0002`** — the active-document table is now **`public.user_files`** (consistency with `user_settings` / `user_plans`), with its index (`user_files_one_per_user_uq`), policies (`user_files_*`), and trigger (`user_files_set_updated_at`) renamed to match. The **`backup_geojson` column is gone** (cloud File→New is non-destructive — ADR-018). The user re-applies `0001`+`0002` fresh.
- **`remote-file-storage.js`** — targets `user_files`; `KEY_TO_COLUMN` now maps only `geojson_data → geojson` (the local-only `backup_geojson_data` key never reaches the cloud). Build clean; chunking unchanged.
- **Docs** — new **ADR-023**; ADR-016 annotated as superseded-in-part; ADR-022 + architecture §5 (sketch, note, RLS example) + rollout + backlog references updated to `user_files`; the "drop backup_geojson" backlog item removed (done); migrations README records the pre-prod in-place-amendment policy.

### Where to resume — Phase 4 (production + Node server layer)
- Unchanged: Phase 3 is complete; Phase 4 is next. Note for prod: because these were creation-script amendments (not ALTER migrations), the **production** project just applies the current `0001`+`0002` once — there's no rename/drop to replay.

---

## 2026-07-01 — SaaS scope expansion: roadmap revamped (Phases 4–8), ADRs 019–022

Planning session — **no code.** The user set the goal explicitly: **monetise Studio as a freemium SaaS.** Discussed the shape and captured it across the docs.

**Decisions (new ADRs):**
- **ADR-019 — Freemium: free = local, paid = cloud.** The anonymous/local app is a *permanent free tier* (not a trial); cloud accounts are the paid tier; pricing is **storage-based**.
- **ADR-020 — Server layer = the existing Node API** (not Edge Functions) for the Stripe webhook, account deletion, and privileged Supabase ops (`service_role`). Makes ADR-002 concrete.
- **ADR-021 — Entry topology:** static hand-written landing at `/`, editor at `/app`; landing placed via the Dockerfile (SEO-friendly, no framework, no SSR); retires `?ff=cloud` at go-public.
- **ADR-022 — Monetisation mechanics:** `public.user_plans` (server-authoritative — webhook writes, client reads own row), **storage quota via a Postgres trigger** on `files`, Stripe Checkout + Customer Portal + webhook.

**Roadmap revamp (`03-rollout.md`); Phases 0–3 unchanged (done):**
- **P4** Production + Node server layer (prod Supabase / ADR-014 unblock; JWT-verify middleware + `service_role`; first use = account deletion).
- **P5** Account area (usage / data export / delete account / Manage-billing link) + compliance (privacy + ToS).
- **P6** Free beta / early access (allowlist) — the old Phase 4.
- **P7** Landing & go-public (static landing, app→`/app`, retire the flag).
- **P8** Monetise: Stripe + entitlements (`user_plans`, quota trigger, Checkout/webhook/portal) — the old Phase 5; payments still **last** (ADR-007).

Also: renamed the planned table `user_plan` → **`user_plans`** (plural, matching `files`/`user_settings`) across the docs; refreshed `00-overview.md` (freemium framing + glossary: free/paid tier, landing, account area, server layer), `01-architecture.md` §5 sketch, and `04-backlog.md` (plan/pricing = storage-based & user-designed; entitlement mechanics now decided).

**Q&A captured (mental models):** webhooks are one-way inbound (Stripe→Node→`user_plans`); the `public` schema is just Postgres' default namespace (not "public access" — RLS is the gate; it's the API-exposed schema); the landing is build-time static HTML served by the existing nginx (not SSR); storage quota is enforced by a DB trigger, not the client.

### Where to resume — Phase 4 (production + Node server layer)
- Create the **production Supabase project** + wire per-environment `VITE_SUPABASE_*` build args (ADR-014). Add the **server layer to `geojson-studio-api`**: a Supabase-JWT-verify middleware + a `service_role` client; first endpoint = **account deletion**. Then Phase 5. No app-repo cloud code is blocked on this — the Phase 3 follow-ups in `04-backlog.md` can be picked up any time too.

---

## 2026-07-01 — Phase 3 · Slice 3c authored (first-login opt-in migration) — Phase 3 code-complete

Built the last piece of Phase 3: the one-time, opt-in offer to copy a user's LOCAL work into their new cloud account. Build clean; **pending the user's manual check.** Phase 3 (3a–3c) is now **code-complete, awaiting verification.**

- **`CloudMigrationPrompt.vue`** (new, code-split, cloud-only) — on mount it self-gates: shows the prompt only when the cloud account is **empty** (`activeFileStore.activeFileId === null` after `ensureResolved` ⟺ zero files) **and** there's **non-empty local work** (reads `dexieStorage.getItem(geojson_data)` directly — the one deliberate cross-path read, ADR-004). "Save to cloud" → `createNew("Untitled")` + `fileStorage.setItem(geojson_data, localWork)` + `reloadFromStorage()` (loads it into the editor). "Not now" → nothing. **The local copy is never moved or deleted.**
- **`FileToolbar.vue`** — renders it `v-if="isCloudMode"` (self-gates further from there), passing `:fileService`. Same code-split pattern as `MyFilesDialog`.

**Self-extinguishing (no dismissed-flag).** After a "Save" — or after the user creates any cloud file — the account is no longer empty, so it never prompts again. Declining and creating nothing re-offers next login; acceptable for v1 (a dismissed-flag is backlogged).

**Build:** clean (vite 8 / rolldown, ~1.4s). `CloudMigrationPrompt-*.js` (~1.8 kB) is its **own async chunk**; no SDK in main; flag-off path unchanged.

**Not yet verified — to test (closes Phase 3):**
1. Fresh account (zero cloud files) with local work → on login, prompt appears; **Save to cloud** → the local work becomes the first cloud file (shows in My Files + editor); log out → local copy still intact.
2. **Not now** → nothing migrated, local intact; prompt re-offers next login (until a cloud file exists).
3. Account that already has cloud files → **no** prompt.
4. Empty local (no features) → **no** prompt.
5. Flag-off / anonymous → component never loads.

### Where to resume — Phase 4 (free beta / early access)
- Once 3c is verified, Phase 3 is done. Phase 4: pick the cohort mechanism (allowlist is the conventional step once auth exists), keep the flag as the public visibility toggle, gather usage, harden RLS. **No payments yet** (that's Phase 5 — Stripe + entitlements). Also still open: the deferred Phase 3 follow-ups in `04-backlog.md` (import-as-named-file, File Info metadata, drop `backup_geojson`, etc.) can be picked up any time.

---

## 2026-06-29 — Phase 3 · Slice 3b authored (My Files dialog + toolbar wiring)

Built the My Files UI on top of 3a. Build clean; **pending the user's manual round-trip + flag-off e2e.**

- **`MyFilesDialog.vue`** (new) — `GsDialog` list (name + last-edited, most-recent first; active file badged "Current"); per-row **open / rename (inline) / delete (confirm)**; footer **New File** (primary) + Close. Opened from the toolbar; refreshes its list on show. Code-split into its own async chunk.
- **`FileToolbar.vue`** — adds a **My Files button labelled with the active file's name** (cloud only) + the dialog. **File→New is now branched by auth state:** cloud → non-destructive (`startNewBlank` + `reloadFromStorage`, no confirm/backup); local → the existing destructive-New + backup/undo-toast flow, untouched.
- **`file-service.reloadFromStorage()`** (new) — storage-agnostic editor reload (clear → load the active doc from the seam → reset undo/redo, or blank if none). Drives in-place switch, cloud New, and delete-active→blank. file-service stays **decoupled** from the active-file store (the caller sets which row is active first).
- **`active-file.js`** — added `activeFileName` state (toolbar label) + `adoptActiveFile`/`startNewBlank`; `rename`/`remove` keep the label in step; `_resolve` seeds id+name.
- **`remote-file-storage.js`** — `resolveMostRecentFileId` → `resolveMostRecentFile` (returns `{id, name}`); lazy-insert + `clear()` use `adoptActiveFile`.

**Autosave flush — not needed (revises the 3b design note).** Autosave has no debounce (it runs per draw op) and the remote `setItem` captures the target `id` **before** its network call, so an in-flight save always commits to the file that was active when the draw happened; `clearAll()` is silent (no autosave). So an explicit "flush before switch" is unnecessary — the by-id capture is the race guard.

**Build:** clean (vite 8 / rolldown, ~1.2s). `MyFilesDialog-*.js` (~4.7 kB) is its **own async chunk**; `remote-file-storage-*.js` (~1.9 kB) + `supabase-client-*.js` (~202 kB) still separate; **no SDK in main**. The light active-file store rides in main. Flag-off path structurally unchanged.

**Not yet verified — to test before 3c:**
1. Open / switch / rename / delete files from the dialog; the toolbar name label tracks the active file.
2. Cloud File→New starts a blank file with **no confirm**; drawing creates a fresh row; the old file is still in My Files.
3. Delete the **active** file → editor resets to blank.
4. Two-account isolation still holds (B never sees A's files in the list).
5. **Flag-off e2e unchanged** (anonymous path untouched).

### Where to resume — Phase 3 · Slice 3c
- First-login opt-in migration: on login with **zero cloud files** AND **non-empty local work**, prompt *"Save your current local work as your first file?"* → yes seeds a new file from the local GeoJSON (`activeFileStore.createNew` + write the local doc); no leaves local untouched. Mirror `cloud-settings-bootstrap.js`'s flag-on hook; it's a post-mount prompt (interactive), not a pre-mount await.

---

## 2026-06-29 — Phase 3 · Slice 3a authored (multi-file storage + active-file state)

Slice 3a built — the multi-file storage round-trip, **no UI yet** (that's 3b). Build clean; **pending the user applying `0002` + the verification gate below.**

- **`supabase/migrations/0002_multi_file.sql`** (cloud repo) — drops `files_one_per_user_uq`, adds `files.name`. Owner-only RLS / triggers / columns from `0001` already cover multiple rows. (migrations README updated.)
- **`src/stores/active-file.js`** (new) — holds `activeFileId` + the `files` list; actions `ensureResolved` (cold load → most-recently-updated row, once, idempotent like `auth.ensureInitialised`), `refreshList`, `createNew`, `rename`, `remove`. Main-bundle-safe: every Supabase action dynamically imports the remote module, so no SDK in main.
- **`remote-file-storage.js`** — rewritten from single-row upsert to **active-row-by-`id`**: getItem/setItem/removeItem target `activeFileId`; **UPDATE-by-id, not upsert**; first write with no active file does a **serialised lazy-insert** (one in-flight promise → no duplicate rows) and adopts the id; `clear()` is now **active-row-only** (can't wipe the library). Adds lifecycle exports (`resolveMostRecentFileId` / `listFiles` / `createFile` / `renameFile` / `deleteFile`).
- **`file-storage.js`** — the logged-in branch now `await useActiveFileStore().ensureResolved()` before returning the remote backend, so the startup read loads the user's most-recent file.

**Build:** clean (vite 8 / rolldown, ~1.2s). Chunks confirm the split held: `remote-file-storage-*.js` (~1.9 kB) and `supabase-client-*.js` (~202 kB) stay **separate async chunks**; the light active-file store rides in main, **no SDK in main**. Flag-off = unchanged → anonymous e2e unaffected.

**Not yet verified — the Phase 3 gate (do before 3b):**
1. Apply `0002` to the **non-prod** project; confirm the `name` column exists and `files_one_per_user_uq` is gone.
2. **Round-trip:** flag on, sign in, draw → a row is lazily created (one row, named "Untitled"); reload → it reopens. In devtools, `useActiveFileStore().createNew("B")` etc. to make a second file, switch `activeFileId`, reload → the most-recently-updated opens.
3. **Two-account RLS with multiple rows:** A creates files; B sees only their own; the `set local role anon` check still denies.

### Where to resume — Phase 3 · Slice 3b
- My Files dialog (`GsDialog`) + FileToolbar wiring (active-file name label, My Files button); cloud File→New non-destructive (gate the local backup / undo-toast path by auth state); in-place file switch (clear + reset undo/redo + load, **flush pending autosave first**); delete-active → blank editor.

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
