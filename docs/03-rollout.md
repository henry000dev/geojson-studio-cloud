# 03 — Rollout

> **Stability:** volatile — this is the execution plan and will change as work proceeds. For current status see [`05-worklog.md`](05-worklog.md).

---

## Branch strategy

The feature flag (ADR-005) exists precisely so we can develop on trunk instead of a long-lived branch. So:

- **Short-lived, per-phase branches** off `staging` (e.g. `feat/cloud-step0-seam`), merged back behind the flag. **Not** one giant `feat/cloud` branch that diverges for months.
- When a phase spans both code repos, use the **same branch name in both** `geojson-studio-app` and `geojson-studio-api` so the pairing is obvious.
- Dark account code ships to production **inert** behind the flag; the normal staging → production beta cadence continues uninterrupted.
- This planning repo (`geojson-studio-cloud`) is low-risk — commit docs/schema to `main` directly, or use plain branches as preferred.

Each phase below is **independently deployable**. The anonymous path keeps working at every phase.

---

## Phase 0 — Branch by abstraction (no flag, no user-visible change)

- **Branch:** `feat/cloud-step0-seam` off `staging` in `geojson-studio-app` (api untouched).
- **Goal:** introduce the provider seams while keeping behaviour identical.
- **Work** (incremental — one provider, then consumers migrated in small per-store batches with tests green between each; see [`05-worklog.md`](05-worklog.md)):
  - File-storage provider (`src/services/storage/file-storage.js`) wrapping `dexieStorage`; repoint the **4 direct importers** (`file-service`, `map-utils`, `MapView`, `draw-manager`). `auto-save-service` needs no change — `draw-manager` simply injects the provider instead of `dexieStorage`.
  - Settings-KV provider (`src/services/storage/settings-storage.js`), **synchronous**, wrapping `localStorage`; refactor the **39 direct calls across 11 files** onto it (the mechanical bulk of this phase). `session.js` (the auth credential) stays on raw `localStorage`, outside the seam (ADR-008 / ADR-011).
  - Both providers always return the local implementation. No remote, no auth check, no flag yet.
- **Validation:** the existing Playwright e2e suite passes unchanged — the proof this is a true no-op.
- **Risk:** very low (pure refactor under existing coverage).

## Phase 1 — Supabase Auth + login UI, shipped dark behind the flag

- **Goal:** prove a user can authenticate end-to-end. No data behaviour changes yet.
- **Work:**
  - Create the Supabase project (Auth only is fine to start).
  - Install `supabase-js`; **code-split** the account module so it's absent from the main bundle.
  - Add the feature-flag store (URL param → `localStorage`; see "Flag mechanics").
  - Add login/signup/logout UI, gating **only this entry point** behind the flag.
  - **Lazy-init the Supabase client** — no client construction, network calls, or auth checks when the flag is off. Dark code must be truly inert.
- **Validation:** flag off → byte-for-byte identical app. Flag on (via URL param) → dev can log in/out. No data has moved.
- **Risk:** low (auth code isolated, only reachable behind the flag).

## Phase 2 — Remote provider + auth-state routing

- **Goal:** logged-in users round-trip a GeoJSON document and settings through Supabase.
- **Work:**
  - `RemoteStorageManager` implementing the seam interface against `public.files`.
  - Equivalent remote implementation for the settings KV seam against `public.user_settings`.
  - Update the Phase 0 providers to switch implementation by **auth state**: logged-in → remote, anonymous → local.
  - Add RLS policies on every relevant table; **manually verify** they reject cross-user access before exposing the feature.
  - **Prove the round-trip with a single active document first** (the cloud equivalent of `geojson_data`, one record per user). Don't build the multi-file UI yet — this isolates "does cloud storage work?" from "build a file browser".
- **Validation:** flag-on dev account can edit, reload, and see the document persisted in Supabase; logging out returns to the local document; two accounts can't see each other's data (RLS proof).
- **Risk:** medium — RLS is the security-critical part; review and test deliberately.

## Phase 3 — Multiple files UI ("My Files")

- **Goal:** logged-in users can save and switch between multiple named files; the anonymous/local path is untouched.
- **Design:** see [ADR-018](02-decisions.md#adr-018--phase-3-multi-file-model-and-file-lifecycle) — lazy non-destructive files, an active-row-by-`id` provider, no cloud backup, an opt-in first-login migration. Sliced like Phase 2 (build green between slices; git + e2e run by the user).

### Slice 3a — schema + by-id provider + active-file state (the round-trip)

- `supabase/migrations/0002_multi_file.sql`: **drop** `files_one_per_user_uq`, **add** `name`. (Applied to non-prod by the user.)
- `src/stores/active-file.js`: holds `activeFileId` + file-list metadata; actions list / open / createNew / rename / remove; `ensureResolved()` picks the most-recently-updated row on cold load (mirrors `auth.ensureInitialised()`).
- Rewrite `remote-file-storage.js` to operate on the **active row by `id`**: getItem/setItem/removeItem by id; serialised lazy-insert on first write with no active file; **UPDATE-by-id, not upsert**; `clear()` made safe. Ships **with** the migration (the old upsert/`maybeSingle()` break once a second row exists).
- No UI yet — prove the multi-file round-trip in code / devtools.

### Slice 3b — "My Files" dialog + FileToolbar wiring

- `MyFilesDialog.vue` on `GsDialog` (see `.claude/docs/ui-conventions.md`): list (name + last-edited) / open / rename / delete / new; the active file is badged; most-recent first. Opened from a **My Files** button in `FileToolbar` (logged-in only), which also shows the active file's **name**.
- Cloud File→New becomes **non-destructive** (no backup, no replace-confirm); the existing destructive-New + backup/undo-toast path is gated to **local mode**. Switching is **in-place** (clear + reset undo/redo + load; pending autosave flushed first). Open & Import stay **writable**. Deleting the active file → blank editor.

### Slice 3c — first-login opt-in migration

- On login with **zero cloud files** AND **non-empty local work**, prompt **"Save your current local work as your first file?"** → yes copies the local GeoJSON into a new cloud file; no leaves local untouched (it reappears on logout). Zero-files trigger, self-extinguishing (ADR-018).

- **Validation:** dev account can create several files, switch, rename, delete; the **two-account RLS isolation** still holds with multiple rows (a list returns only the caller's files); anonymous user unaffected throughout.
- **Risk:** medium — the largest new UI surface plus the provider/race work; a standard dialog + state otherwise.

## Phase 4 — Free beta / early access

- **Goal:** real-world validation at zero monetary risk.
- **Work:**
  - Choose the cohort mechanism: open opt-in via URL param, an allowlist field on the user record (e.g. `beta: true`), or a server-side email allowlist (allowlist is the conventional next step once auth exists).
  - Flag stays the public visibility toggle; the allowlist gates who actually gets the feature.
  - **No payments yet.** Gather usage, fix issues, harden RLS.
- **Validation:** beta users complete the full account journey without data or security problems.
- **Risk:** low–medium (depends what beta surfaces).

## Phase 5 — Stripe + entitlements

- **Goal:** introduce paid plans.
- **Work:**
  - Stripe hosted Checkout + Customer Portal (no custom billing UI).
  - Stripe webhook → updates `public.user_plan`.
  - Define entitlements (file count, file-size, premium tools).
  - Enforce them: simple checks in RLS/Postgres functions; complex business rules in the **selective Node layer** (where the wrapper finally earns its keep — see ADR-002).
  - Grandfather or convert beta users.
- **Validation:** full subscription lifecycle handled (subscribe, cancel, fail-to-pay, downgrade).
- **Risk:** medium (money + lifecycle edge cases), but on a battle-tested storage/account stack.

---

## Flag mechanics

- **URL-presence-based, not persisted (ADR-015):** `cloudEnabled` is simply whether `?ff=cloud` is in the URL at load. No `localStorage`, no `:off` param, no URL-stripping. Default (no param) = the app behaves exactly as before; removing the param turns cloud off.
- A small reactive flag store reads the URL once and exposes `cloudEnabled`.
- **Only one thing is gated:** whether the login/account UI is visible. Everything downstream composes — without login there's no auth state, so the providers stay on local.
- **OAuth round-trip:** the Google redirect carries `ff=cloud` back via `redirectTo`, so the account UI survives the return load. The Supabase session itself persists in the SDK store but is only *surfaced* when the flag is present.
- **Visibility, not security:** even if discovered, the param only reveals a login form; Auth + RLS are the real gate. The bare domain is always vanilla, so the dark feature can never stick on a casual visitor's browser.
- **Truly dark:** lazy-init Supabase, code-split the account module, no side effects on app start when off.
- **Temporary scaffolding:** at public launch, flip the default on and delete the flag so the path becomes unconditional. Don't let flags accumulate.

## Cross-cutting concerns (apply across phases)

- **Authorization** — RLS on every user-data table, scoped to `auth.uid()`. The single security-critical surface.
- **Privacy / ToS** — storing user content brings obligations: privacy policy + terms before opening to real users; GDPR-style data export and account deletion.
- **Account deletion** — define the flow (hard-delete from `files` + `user_settings`; Supabase deletes the auth user).
- **Backups** — Supabase managed Postgres provides automated backups; confirm the tier when ready.
- **Monitoring** — basic uptime + error reporting; Supabase dashboard for DB metrics.
- **Kill-switch** — the always-present local path means flipping the flag off (or routing logged-in users to local fallback) is an instant rollback without a deploy.
