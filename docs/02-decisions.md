# 02 — Decisions (ADR log)

> **Stability:** stable, append-only. Each record captures a decision, its rationale, and the alternatives rejected — so settled questions are not re-litigated when the epic is resumed cold. Supersede rather than edit: if a decision changes, add a new ADR that references the old one.

Format per record: **Status · Context · Decision · Rationale · Alternatives rejected · Consequences.**

---

## ADR-001 — Backend is Supabase

- **Status:** Accepted.
- **Context:** Logged-in users need cloud-stored GeoJSON + settings. GeoJSON files can be several MB. Least-effort and pre-integrated are priorities. The team is one person.
- **Decision:** Use **Supabase** (Postgres + Auth + Storage).
- **Rationale:** Postgres stores the GeoJSON blob **inline** in a `jsonb`/`text` column — one store for blobs, metadata, and settings. "Just Postgres" means low lock-in (exit = `pg_dump`).
- **Alternatives rejected:**
  - **Firebase (Firestore + Cloud Storage):** Firestore's **1 MB document limit** would force a metadata-in-Firestore + blob-in-Storage split, reintroducing the two-store complexity we want to avoid.
  - **Mongo + S3 + Clerk/Auth0 (assemble yourself):** more wiring, more services to run, more lock-in surface. Architecture is identical to a BaaS, so the BaaS wins on effort.
  - **Raw S3:** object storage is not a database; it always pairs with a separate DB. Extra system for no gain at typical GeoJSON sizes.
- **Consequences:** Adopt `supabase-js`, Postgres RLS, and the Supabase Auth model. Supabase Storage held in reserve for large files only.

## ADR-002 — Client-direct access with RLS, not a Node wrapper

- **Status:** Accepted.
- **Context:** The SPA could talk to Supabase directly, or route everything through the existing Node API for a "unified" surface.
- **Decision:** **Client-direct** via `supabase-js`, authorization enforced by **RLS**. Auth always direct to Supabase Auth. The Node API is not a generic CRUD wrapper.
- **Rationale:** A wrapper means re-implementing, imperatively in Node, the per-user isolation RLS gives declaratively — same security-critical work, more code, more risk, an extra network hop for blobs. The decoupling appeal of a wrapper is obtained more cheaply with a **client-side storage-provider seam**. Proxying auth (token refresh, OAuth) is high-effort and bug-prone for zero benefit.
- **Alternatives rejected:**
  - **Full Node wrapper over Supabase:** rejected for effort/risk as above.
  - **Proxying auth through Node:** rejected outright — never proxy auth.
- **Consequences:** RLS policies are the security boundary and must be reviewed/tested deliberately. A thin Node layer may be added **later, selectively**, only for payment/entitlement logic.

## ADR-003 — Data model is users → files; settings stay user-global

- **Status:** Accepted.
- **Context:** Logged-in users want multiple saved files. The app today has a single active document and single global bookmark/template/settings sets per browser.
- **Decision:** Unit of saved work is a **file** (one row per file). Bookmarks, templates, basemap, panel prefs, and measurement units stay **user-global**.
- **Rationale:** Matches current behaviour (nothing is file-scoped today), and is the least-effort model. One DB record per file either way.
- **Alternatives rejected:**
  - **"Project" model (per-file context bundling bookmarks/view/basemap with the GeoJSON):** more data-model and UX work; deferred. Can be adopted later by extending the file row with context fields — no restructuring required.
- **Consequences:** A "My Files" browser (list/open/rename/delete/create) and an "active file" concept in state (Phase 3).

## ADR-004 — Two isolated storage paths, no sync

- **Status:** Accepted.
- **Context:** We want to keep the anonymous experience and add cloud for logged-in users.
- **Decision:** Anonymous users use local (IndexedDB + `localStorage`) only; logged-in users use Supabase only. The two paths never sync.
- **Rationale:** Removes the single hardest workstream (offline/conflict sync). Isolation means a cloud bug cannot corrupt local data, and the always-present local path is an instant kill-switch / rollback.
- **Alternatives rejected:**
  - **Local-first with sync (IndexedDB as cache, server as source of truth):** large effort (conflict resolution, the app auto-saves and has undo/redo). Explicitly out of scope.
- **Consequences:** On first login, migration is an **opt-in, per-user** "import your current local work" prompt — never a fleet-wide event.

## ADR-005 — Runtime URL-param feature flag, not an env/branch flag

- **Status:** Accepted.
- **Context:** The project deploys **staging → production sequentially** (staging is pre-production). The team is one person — no separate testers.
- **Decision:** Gate the account feature behind a **runtime URL-param flag** (`?ff=cloud` persisted to `localStorage`). It controls **only** whether the login UI is visible.
- **Rationale:** Environment-independent — the dark account code rides to production inert while the normal beta release cadence continues. A build/env flag wouldn't isolate, since whatever lands on staging ships to prod. The flag enables **trunk-based development** instead of a long-lived divergent branch.
- **Alternatives rejected:**
  - **Env/build flag (staging-on, prod-off):** doesn't isolate in a sequential pipeline.
  - **Long-lived feature branch:** reintroduces the big-bang merge the flag is meant to kill.
  - **Hosted flag service (LaunchDarkly/PostHog/Flagsmith):** unnecessary infrastructure at this scale.
- **Consequences:** The flag is a **visibility toggle, not a security boundary** (Auth + RLS are the real gate). Dark code must be truly inert (lazy-init Supabase, code-split the account module). The flag is temporary scaffolding — launch ≈ flip default on and delete the flag. **Mechanism refined by [ADR-015](#adr-015--the-cloud-feature-flag-is-url-presence-based-not-persisted):** the flag is URL-presence-based, *not* persisted to `localStorage`.

## ADR-006 — Single codebase, no separate app

- **Status:** Accepted.
- **Context:** One option for a large feature is to fork a new "v2" app and migrate.
- **Decision:** Ship everything in the existing `geojson-studio-app` / `geojson-studio-api` codebases behind the flag.
- **Rationale:** The editor is identical for anonymous users; a fork would duplicate the whole app to add one gated feature, then end in a big-bang migration. The isolation a fork seems to offer is provided instead by the flag + the always-present local path.
- **Alternatives rejected:** Separate app + later migration — higher effort and risk, opposite of incremental.
- **Consequences:** Account code lives on trunk, shipped dark, grown incrementally alongside ongoing beta work.

## ADR-007 — Payments deferred to last

- **Status:** Accepted.
- **Context:** The end state includes paid plans, but charging users while the foundation is unproven is risky.
- **Decision:** Build accounts + cloud storage first; add **Stripe** (hosted Checkout + Customer Portal + webhook → `plan` flag) as the **final phase**, after a free beta.
- **Rationale:** No one ever pays while the foundation is still being proven. Payments are an isolated layer that doesn't block the rest.
- **Alternatives rejected:** Build accounts and billing together up front — more upfront work before any validation.
- **Consequences:** Entitlements/quotas are where the *selective* Node layer (ADR-002) earns its keep. Plan specifics are TBD (see [`04-backlog.md`](04-backlog.md)).

## ADR-008 — The session JWT always stays local

- **Status:** Accepted.
- **Context:** Settings migrate to the cloud for logged-in users.
- **Decision:** The Supabase session token (the credential itself) lives only in `localStorage`/the SDK store and is **never** written to the cloud DB.
- **Rationale:** It is a credential, not user content; storing it server-side is both pointless and a risk.
- **Consequences:** The settings-migration split (architecture §6) explicitly keeps the token, and other device-level flags, local.

## ADR-009 — Repository & docs structure

- **Status:** Accepted.
- **Context:** The epic spans two separate code repos that know nothing about each other, plus a growing set of design docs and (later) Supabase schema.
- **Decision:** A dedicated sibling repo **`geojson-studio-cloud`** holds the docs and shared substrate (later: SQL schema, RLS, migrations, entitlements config). Matches the existing `geojson-studio-resources` sibling-repo pattern.
- **Rationale:** This material belongs to neither app nor api. A dedicated repo (not a folder in `resources`) keeps evolving planning/schema separate from static assets and gives it its own history. Named after the **brand** so the technical and product names are unified.
- **Alternatives rejected:** Folder inside `geojson-studio-resources` (mixes concerns); plain non-git folder (loses history); a single monolithic `cloud-accounts-plan.md` (volatile and stable content churn together).
- **Consequences:** Each code repo carries a one-line pointer back to this repo. Branch strategy is short-lived per-phase branches off `staging` with the **same branch name across both code repos** — not one mega-branch (see [`03-rollout.md`](03-rollout.md)).

## ADR-010 — The settings-KV seam is synchronous

- **Status:** Accepted.
- **Context:** Phase 0 introduces a settings provider in front of `localStorage`. The eventual Supabase-backed implementation (Phase 2) is necessarily async. The instinct is to make the seam async now so both implementations share one shape.
- **Decision:** The settings seam is **synchronous** in Phase 0 — a 1:1 mirror of the `localStorage` API.
- **Rationale:** Settings are consumed synchronously. Pinia stores read `localStorage` inside their synchronous `state()` factories (e.g. `measurements.js`, `session.js`, `undo-new-file-toast.js`), materialising state at store-construction time. Converting the seam to async would force every such store to hydrate from a promise — changing store semantics and initial-render behaviour, and breaking the Phase 0 "behaviour-preserving no-op" that the Playwright suite is meant to prove. The file seam is async only because Dexie already is and every consumer already awaits it; the two seams need not share timing, only their method names.
- **Alternatives rejected:**
  - **Async settings seam now:** rejected — turns a mechanical no-op into a semantics-changing refactor of every settings store, defeating the point of Phase 0.
- **Consequences:** Phase 2 keeps the sync interface by hydrating a user's settings into an in-memory cache once on login (async), after which `getItem` reads the cache and `setItem` writes the cache plus a background flush to Supabase. Settings are small KV pairs, so caching them wholesale on login is cheap. The file seam stays async throughout.

## ADR-011 — The session store stays on raw localStorage, outside the settings seam

- **Status:** Accepted. Refines [ADR-008](#adr-008--the-session-jwt-always-stays-local).
- **Context:** Phase 0 routes settings `localStorage` access through the new settings seam. `stores/session.js` holds the Turnstile session JWT in `localStorage`. The settings seam is exactly the abstraction that gains a remote (Supabase) branch in Phase 2.
- **Decision:** `session.js` is **not** migrated to the settings seam; it continues to call `localStorage` directly.
- **Rationale:** ADR-008 already mandates that the session credential never leaves the device. Keeping it off the seam makes that guarantee **structural** rather than a per-key exception someone must remember when wiring up remote routing — the credential simply never touches the code path that can reach the cloud. It is already cleanly isolated (one store, two constants), so excluding it costs nothing.
- **Alternatives rejected:**
  - **Migrate `session.js` to the seam and pin its keys to local in Phase 2:** rejected — relies on a per-key carve-out in the cloud-routing logic; one mistake leaks a credential. Structural exclusion is safer for zero extra effort.
- **Consequences:** The settings-seam migration covers 11 files / 39 calls, not 12 / 45. When Supabase Auth lands (Phase 1+), its session token likewise stays in the SDK/`localStorage` store, never the settings seam.

## ADR-012 — Use the Supabase publishable key, not the legacy anon key

- **Status:** Accepted.
- **Context:** Phase 1 needs a client-side Supabase API key. Supabase now issues two interchangeable client keys: the original JWT-format **anon** key (now labelled *legacy*) and a newer opaque **publishable** key (`sb_publishable_…`). Both are safe to ship in the browser; both are gated by RLS, not by secrecy.
- **Decision:** Configure the client with the **publishable** key. Env var is named for what it is: **`VITE_SUPABASE_PUBLISHABLE_KEY`** (not the originally-planned `VITE_SUPABASE_ANON_KEY`).
- **Rationale:** Supabase's own dashboard now steers new projects to the publishable key and marks the anon key legacy; the publishable key can be rotated independently of the JWT signing secret. Naming the env var `PUBLISHABLE` keeps the code honest about which key is in use. No functional difference to `supabase-js` — it is passed in the same key argument.
- **Alternatives rejected:**
  - **Legacy anon key:** still works, but on the deprecation path; no reason to adopt the older mechanism for greenfield code.
- **Consequences:** Docs and `.env.template` reference `VITE_SUPABASE_PUBLISHABLE_KEY`. The **secret** keys — `service_role` / secret key, the JWT signing secret, and the Google OAuth client secret — are never shipped or committed (the publishable key is the only Supabase key in the client).

## ADR-013 — The cloud feature flag reads raw localStorage at bootstrap, outside the settings seam

- **Status:** **Superseded by [ADR-015](#adr-015--the-cloud-feature-flag-is-url-presence-based-not-persisted).** The flag is no longer persisted, so it doesn't touch `localStorage` at all — this carve-out is moot. Mirrors [ADR-011](#adr-011--the-session-store-stays-on-raw-localstorage-outside-the-settings-seam).
- **Context:** ADR-005 persists the `?ff=cloud` flag to `localStorage`. The settings seam (Phase 0) is the abstraction that gains a remote (Supabase) branch in Phase 2.
- **Decision:** The feature-flag value is read/written via **raw `localStorage`** at app bootstrap, **not** through the settings seam.
- **Rationale:** The flag decides whether the login UI exists at all, so it must be resolvable **before** any auth state or remote routing exists — it logically precedes login. Routing it through a seam that can later point at the cloud would be circular (you'd need to be logged in to read the flag that lets you log in). It is also inherently **device-level** (which browser shows the cloud UI), like the session token, so structural exclusion keeps it off the cloud path for free. The URL→`localStorage` parse runs before Pinia is created so stores see the resolved value in their synchronous `state()` factories.
- **Alternatives rejected:**
  - **Flag through the settings seam:** rejected — circular (needs auth to resolve the gate to auth) and would sync a device-level visibility toggle to the cloud.
- **Consequences:** `feature-flags` store and the bootstrap parser use `localStorage` directly. Like `session.js`, the flag is a deliberate, documented exception to "settings go through the seam". *(Now moot under ADR-015 — the flag is no longer persisted.)*

## ADR-014 — Separate Supabase projects per environment; non-prod set up first

- **Status:** Accepted.
- **Context:** `VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY` are inlined at build time, per environment. The app deploys staging → production. A Supabase project bundles its own users, data, Auth URL configuration, OAuth redirect allow-list, and keys.
- **Decision:** Use **separate Supabase projects per environment** (at minimum a dedicated **production** project isolated from non-prod). For now, configure **only the non-prod project**; defer the production project and all CI / Dockerfile env-var wiring until the core cloud functionality is proven.
- **Rationale:** Isolation — non-prod testing (throwaway signups, destructive schema/RLS changes) must never touch production users or data. Auth URL config and the Google OAuth callback are project-level and keyed to each environment's origin, so one shared project would have to allow-list every environment at once. Per-project keys map cleanly onto environment-scoped GitHub Variables/Secrets. Deferring prod keeps focus on functionality while the stack is new to the team.
- **Alternatives rejected:**
  - **One shared Supabase project across environments:** rejected — staging activity pollutes production data/users, and a single project must allow-list every origin.
- **Consequences:** Schema + RLS must be kept in sync across projects via **migrations held in this repo** (ADR-009). Production project creation and pipeline/env wiring are **deferred, tracked tasks** (see [`05-worklog.md`](05-worklog.md)). The current project serves local/non-prod. Each environment threads its URL+key the same way the Mapbox token already is: `--build-arg` → Dockerfile `ARG`/`ENV` → Vite (URL as a GitHub *Variable*, publishable key as a *Secret*, mirroring `VITE_API_HOST` / `VITE_MAPBOX_ACCESS_TOKEN`).

## ADR-015 — The cloud feature flag is URL-presence-based, not persisted

- **Status:** Accepted. Supersedes the persistence mechanism of [ADR-005](#adr-005--runtime-url-param-feature-flag-not-an-envbranch-flag); obsoletes [ADR-013](#adr-013--the-cloud-feature-flag-reads-raw-localstorage-at-bootstrap-outside-the-settings-seam).
- **Context:** ADR-005 chose a runtime URL-param flag. As first implemented it **persisted** `?ff=cloud` to `localStorage` (`ff_cloud=1`) so it survived reloads, with `?ff=cloud:off` to clear. That added a second piece of hidden state: the app could be in "cloud mode" with no visible URL cue, and escaping it needed a special off-param.
- **Decision:** `cloudEnabled` is derived **solely from the presence of `?ff=cloud` in the current URL** at load. Nothing is written to `localStorage`; the param is **not** stripped; there is no `:off` param (removing the param *is* off). Default (no param) = the app behaves exactly as before.
- **Rationale:** Simpler and more predictable — the URL is the single source of truth, the param stays in the address bar as the cue, and the bare domain is always vanilla, so the dark feature can never "stick" for a casual visitor or leak via a persisted flag. Removing persistence also removes the only reason the flag touched `localStorage`, retiring ADR-013's carve-out.
- **Alternatives rejected:**
  - **Persist to `localStorage` + `?ff=cloud:off` (original):** rejected — extra hidden state and a non-obvious toggle model.
- **Consequences:** Reloads keep `?ff=cloud` because it isn't stripped. The OAuth redirect carries `ff=cloud` back via `redirectTo` so the account UI survives the round-trip. A logged-in Supabase session still persists in the SDK store but is only *surfaced* when the flag is present (visibility-only, consistent with ADR-005). The `feature-flags` store reads the URL; no storage-key constant, no bootstrap parser, no `main.js` pre-Pinia step.

## ADR-016 — Phase 2 schema shape (refines the architecture §5 sketch)

- **Status:** Accepted. Implements [ADR-003](#adr-003--data-model-is-users--files-settings-stay-user-global) and the [`01-architecture.md`](01-architecture.md) §5 data model; first migration is `supabase/migrations/0001_files_and_user_settings.sql`. **Superseded in part by [ADR-023](#adr-023--rename-to-user_files-drop-the-backup_geojson-column):** the table is now `user_files` and the `backup_geojson` column was removed (creation scripts amended pre-production).
- **Context:** Phase 2 needs concrete tables for the active GeoJSON document and the settings KV, plus RLS. The architecture §5 sketch (`files{id,user_id,name,geojson}`, `user_settings{user_id,key,value jsonb}`) is the end-state; the first migration only needs what Phase 2 uses, and the storage seams impose a couple of concrete shapes.
- **Decision:** Ship `public.files` and `public.user_settings` with these refinements to the sketch:
  - **One row per user in `files`** — a unique index on `user_id` (`files_one_per_user_uq`), a temporary Phase-2 invariant matching the single local `geojson_data` record; **Phase 3 drops it** for multi-file.
  - **`name` deferred to Phase 3** — unused without a multi-file UI.
  - **`files.backup_geojson` column** — the file seam writes two keys (`geojson_data` + `backup_geojson_data`); ADR-004 forbids logged-in users from using IndexedDB, so the backup blob must live in the cloud row.
  - **`user_settings.value` is `text`, not `jsonb`** — the settings seam round-trips opaque `localStorage` strings; `text` is a lossless 1:1 mirror with no wrap/unwrap.
  - **`user_id default auth.uid()`** so the client may omit it (the `with check` policy still enforces ownership).
  - **RLS to `authenticated` only, owner-scoped (`auth.uid() = user_id`)**, with explicit per-command policies and `revoke all … from anon`; anonymous visitors never touch these tables.
  - **`updated_at` trigger** (`set_updated_at`) for DB-authoritative timestamps; **`on delete cascade`** to `auth.users` for account deletion.
- **Rationale:** Build only what Phase 2 exercises, keep the migration legible, and let the seam contracts (object blob → `jsonb`; opaque string → `text`; two file-seam keys → two columns) drive the column choices. RLS scoped to `authenticated` keeps the anonymous path structurally unable to reach cloud tables.
- **Alternatives rejected:**
  - **`value jsonb` for settings:** rejected — forces wrap/unwrap of opaque strings (some already JSON-encoded), changing the seam's string-in/string-out contract.
  - **Backup stays local in cloud mode:** rejected — violates ADR-004 (no IndexedDB for logged-in users).
  - **Multi-row `files` + `name` now:** rejected — unused in Phase 2; the temporary unique index keeps the round-trip a trivial upsert and is cleanly dropped in Phase 3.
- **Consequences:** Phase 3 migration drops `files_one_per_user_uq` and adds `name` (+ created/updated already present). The remote file provider upserts on `user_id`; the remote settings provider stores/returns `value` verbatim. RLS is verified by the two-account test before the feature is exposed.

## ADR-017 — All user settings follow the account (no device-level carve-out)

- **Status:** Accepted. Supersedes the device-level/account split in [`01-architecture.md`](01-architecture.md) §6 and the Slice 2b `CLOUD_SETTINGS_KEYS` allowlist.
- **Context:** §6 proposed migrating settings *selectively* — keeping "device-level" prefs (colour mode, dismissed-splash/hint flags, etc.) on `localStorage` even when logged in. It was explicitly a *"sensible default … revisit per key"* (also a backlog item), not a constraint. The only firm rule is [ADR-008](#adr-008--the-session-jwt-always-stays-local): the session **credential** stays local — but it is not a setting and already lives outside the settings seam ([ADR-011](#adr-011--the-session-store-stays-on-raw-localstorage-outside-the-settings-seam)).
- **Decision:** For logged-in users, **all settings-seam keys follow the account** (route to the cloud cache). Drop the per-key allowlist. The settings seam reverts to a single `resolveBackend()` (cloud cache when active, else `localStorage`).
- **Rationale:** Users expect their preferences to follow them across devices; the "device-level" rationale was soft caution, not a technical or security need. Removing the allowlist also removes a hidden source of drift (string literals mirrored from individual stores). The credential exclusion is preserved for free because it never passes through the seam.
- **Alternatives rejected:**
  - **Keep the §6 allowlist:** rejected — the user wants all prefs synced; the split added complexity for no clear benefit.
  - **Carve out specific keys (e.g. dark mode, dismissed flags):** considered; the only material nuances are that dismissed flags won't re-show on a new device (usually desired) and colour mode's "system" option still tracks each device's OS. Neither warrants a carve-out.
- **Consequences:** Every settings key persists per-user in `public.user_settings`. A fresh account starts with empty settings (local ones untouched; opt-in migration is Phase 3). Note: in code there is no separate "narrow-screen warning" key — that dialog reuses the `welcomed` flag — so §6's table slightly overstated the local set.

## ADR-018 — Phase 3 multi-file model and file lifecycle

- **Status:** Accepted. Implements [ADR-003](#adr-003--data-model-is-users--files-settings-stay-user-global) (users → files) and refines the Phase 2 single-row model ([ADR-016](#adr-016--phase-2-schema-shape-refines-the-architecture-5-sketch)); drives `supabase/migrations/0002_multi_file.sql`.
- **Context:** Phase 3 turns the one cloud row per user into multiple named files with an "active file" concept and a "My Files" browser. The single-file model baked in behaviours that multi-file changes: File→New was *destructive* (it replaced the one document), which is the entire reason `backup_geojson` + the "undo new file" toast exist; the remote provider stored exactly one row, writing via `upsert(onConflict: user_id)` and reading via `maybeSingle()` — both lean on `files_one_per_user_uq`.
- **Decision:**
  - **Lazy, non-destructive File→New (cloud path).** New starts a blank in-memory file with *no* active row; the row is inserted on the **first edit** (first autosave). Each used New becomes its own row; repeated New without editing creates nothing. Nothing is replaced (the previous file is already its own row), so the destructive "this will replace your file" confirm is dropped in cloud mode.
  - **`backup_geojson` is vestigial in the cloud.** With New non-destructive, "revert" is just reopening the previous file from My Files. The cloud path never writes `backup_geojson_data`; `createNewFile`/`undoNewFile`/`discardBackup` + the undo-new-file toast stay **local-path-only** (gated by auth state at the *orchestration* layer — `FileToolbar`/`file-service` — not in the seam). The column stays (nullable, unused), dropped in a later cleanup migration.
  - **Remote provider becomes active-row-by-`id`.** `getItem/setItem/removeItem` target the active file by `id` (not the user's sole row). First write with no active file **inserts** a row — serialised through a single in-flight creation promise so exactly one is born — and adopts its id. `setItem` is an **UPDATE-by-id, not an upsert**, so a write racing a delete or a file-switch can't resurrect a deleted row or land on the wrong file. `clear()` is made **safe** (active-row-only / inert) so it can never mean "delete every file". This rewrite ships **with** `0002` dropping `files_one_per_user_uq` (the old upsert/`maybeSingle()` break the instant a second row exists).
  - **Active file resolution & switching.** Cold load (flag-on, logged-in) opens the **most-recently-updated** row (`order by updated_at desc limit 1`); none → blank editor. Switching is **in-place** (clear draw + reset undo/redo + load the row), with any pending autosave **flushed/cancelled first** so it commits to the correct file. **Deleting the active file resets the editor to blank.**
  - **Open and Import keep the file writable** (consistent with today; not read-only).
  - **First-login migration is opt-in via a zero-files trigger.** On login with **zero cloud files** AND **non-empty local work**, prompt *"Save your current local work as your first file?"*. Yes → copy the local GeoJSON into a new cloud file; No/dismiss → nothing (local untouched, reappears on logout). The condition is self-extinguishing — any created file ends it — so no dismissed-flag for v1.
  - **Names** default to "Untitled", suffixed when taken ("Untitled 2"); names are **not unique** (the row `id` is the key).
  - **Unchanged:** bookmarks/templates stay **user-global** (ADR-003), not per-file; multi-tab/device stays **last-write-wins** (ADR-004 — no sync; multi-file adds no conflict handling).
- **Rationale:** Multi-file is a genuinely different feature, so a single auth-state branch at the New-file *orchestration* is honest and keeps the storage **seam uniform** — the active-document I/O (autosave/load/`map-utils`) never changes, which is what isolation (ADR-004) actually protects. Lazy creation gives "each new file is its own entry" without littering My Files with empty rows. By-id + UPDATE semantics close the switch/delete races that upsert-on-`user_id` would open. The zero-files migration trigger needs no extra state and can't nag a user who has adopted the cloud.
- **Alternatives rejected:**
  - **Eager file creation** (insert an empty row per New): clutters My Files, needs empty-row cleanup.
  - **Reinterpreting the existing seam calls in the provider** so the consumer flow is byte-identical across paths: rejected — "create a new file" is a higher-level intent than get/set/remove and differs fundamentally between a single-doc and a multi-file store (`removeItem("geojson_data")` would blank the current file instead of preserving it).
  - **Full page-reload on file open** (like sign-in/out): simpler isolation, but a reload flash and it needs a persisted active-file pointer; in-place switch is nicer and needs none. (Trade-off accepted: a *cold* refresh reopens the most-recent file, not the exact one being viewed — a last-opened pointer is backlogged.)
  - **Read-only on open:** considered; the user chose writable for simplicity/consistency.
- **Consequences:** `0002_multi_file.sql` drops `files_one_per_user_uq` and adds `name`, shipping with the provider rewrite. New code: `stores/active-file.js` (active id + list + lifecycle, `ensureResolved()` mirroring `auth.ensureInitialised()`) and `MyFilesDialog.vue` (Phase 3b). The backup/undo-new-file path is gated to local mode. RLS is unchanged (owner-scoped, already multi-row safe) and re-verified in the two-account gate. Deferred (see [`04-backlog.md`](04-backlog.md)): import-as-new-named-file, File Info metadata, export filename, dropping `backup_geojson`, a last-opened pointer, My Files search/pagination, a migration dismissed-flag.

## ADR-019 — The Cloud epic is a freemium SaaS: free = local, paid = cloud

- **Status:** Accepted. Reframes the epic's commercial scope; builds on [ADR-004](#adr-004--two-isolated-storage-paths-no-sync) (two paths) and [ADR-007](#adr-007--payments-deferred-to-last) (payments last).
- **Context:** The epic began as "optional accounts + cloud-saved work behind a flag." The goal is now explicit: **monetise** GeoJSON Studio as a small freemium SaaS. This crystallises the commercial model on top of the two-paths architecture already built.
- **Decision:** The product is **freemium**, with a split that maps directly onto the existing isolated paths:
  - **Free tier = the local/anonymous app** — the browser-only experience (IndexedDB + `localStorage`), usable forever with no account. It is a **permanent free tier, not a time-limited trial**.
  - **Paid tier(s) = cloud** — accounts + cloud-saved files across devices, gated by a subscription. Cloud storage itself is the paid value; paid tiers differ by **storage quota** (**pricing is storage-based**, since the dominant cloud cost is Supabase storage).
- **Rationale:** The two-paths design (ADR-004) already *is* the free tier, so "use the free version without signing up" needs no trial logic — it's the anonymous path. Storage-based pricing aligns price with the actual cost driver. Keeps the free experience first-class (an existing non-goal to remove it).
- **Alternatives rejected:**
  - **Time-limited trial of cloud:** rejected — the local app is a genuinely useful permanent free product; time-boxing it adds expiry machinery for no gain.
  - **Feature-gated free *cloud* tier:** possible later; v1 keeps it simple — cloud = paid.
- **Consequences:** Introduces paid plans ([ADR-022](#adr-022--monetisation-mechanics-user_plans-storage-quota-via-postgres-trigger-stripe)), a landing page that frames free-vs-paid ([ADR-021](#adr-021--app-entry-topology-static-landing-at--app-at-app)), and a self-service account area. The `?ff=cloud` flag becomes pre-launch scaffolding retired at go-public. Concrete tiers/prices are the user's to design (backlog).

## ADR-020 — The server-side layer is the existing Node API (not Edge Functions)

- **Status:** Accepted. Makes [ADR-002](#adr-002--client-direct-access-with-rls-not-a-node-wrapper)'s "thin Node layer, added later, selectively" concrete.
- **Context:** Payments (Stripe webhook), account deletion, and privileged Supabase writes need server-side code that can't be client-direct (secrets, `service_role`, signature verification). Two candidate hosts: extend the existing `geojson-studio-api` (Node/Express, already deployed), or adopt Supabase **Edge Functions** (Deno, colocated with Supabase).
- **Decision:** **Extend the existing Node API.** Cloud/payment endpoints are new routes there, organised by concern (payment / conversion / storage / dataset). No Edge Functions.
- **Rationale:** The team already runs, deploys, and knows the Node API — least-effort, least new infrastructure. Neither Stripe (backend-agnostic) nor Supabase (`service_role` usable from any server) constrains this. Avoids introducing a second runtime (Deno) to a team still new to Supabase.
- **Alternatives rejected:**
  - **Supabase Edge Functions:** Supabase-native and fine for webhooks, but a new runtime + deploy path for no benefit the Node API doesn't already provide here. A hybrid (webhook-only edge function) was considered and rejected for the same reason.
- **Consequences:** The Node API's prod env gains new secrets — Supabase **`service_role`** key, Stripe secret key, Stripe **webhook signing secret** (wired like [ADR-014](#adr-014--separate-supabase-projects-per-environment-non-prod-set-up-first)'s frontend build-args). Authenticated cloud endpoints **verify the caller's Supabase JWT** server-side; the Turnstile session JWT and the Supabase user JWT coexist (see the backlog's "unify the JWTs"). The Stripe webhook route must read the **raw body** for signature verification (skip global JSON parsing there). `service_role` stays server-only, never shipped.

## ADR-021 — App entry topology: static landing at `/`, app at `/app`

- **Status:** Accepted. Extends the flag decisions ([ADR-005](#adr-005--runtime-url-param-feature-flag-not-an-envbranch-flag)/[ADR-015](#adr-015--the-cloud-feature-flag-is-url-presence-based-not-persisted)) toward go-public. **Delivered in two stages — see [ADR-024](#adr-024--entry-topology-in-two-stages-client-rendered-preview-then-static-seo-landing); this ADR describes the Stage 2 launch form.**
- **Context:** Today the bare domain *is* the editor SPA. A freemium SaaS needs a marketing front door (features, pricing, a "use the free version" entry, sign-up). The app is a Vue SPA served as **static files by nginx on Cloud Run** (Docker); `vue-router` is already present, and nginx already has SPA fallback.
- **Decision:**
  - **`/` = a landing page**, **`/app` = the editor** (Vite `base: '/app/'`, router base `/app/`).
  - The landing is **hand-written static HTML** (a `landing/` source folder, no framework) — **not** a client-rendered SPA route — so it's crawlable for SEO. It's placed by the **Dockerfile** (COPY `landing/` → nginx root; app build → `/app/`), i.e. automatic in CI; nginx gains an `/app/` location beside the root.
  - The landing's **free-tier entry** routes to the anonymous `/app` (no account); **sign-up/login** routes to the cloud experience.
  - This is the **go-public** step that **retires the `?ff=cloud` flag** (ADR-005 always framed it as temporary scaffolding — launch = default-on / delete).
- **Rationale:** A static landing is far more indexable than the SPA shell (better SEO even for the free tool) and fits the existing nginx-static / Cloud-Run model with **no new runtime** (build-time HTML, not SSR). Hand-written HTML is least-effort for one marketing page and stays featherweight. The free-tier button reusing the anonymous path is the ADR-004 / ADR-019 payoff.
- **Alternatives rejected:**
  - **SSR (render per request):** needs a live render server — overkill for a marketing page.
  - **Landing as an SPA route, or an SSG framework (Astro/vite-ssg):** viable, but a client-rendered route is SEO-weak and a framework is unnecessary weight for one page; revisit if the marketing site grows.
- **Consequences:** The app moves under `/app/` (Vite base + router base + nginx location + Supabase Auth **Site URL / redirect allow-list** updated per environment). Old `/` bookmarks now land on marketing. Mostly config + a static page.

## ADR-022 — Monetisation mechanics: `user_plans`, storage quota via Postgres trigger, Stripe

- **Status:** Accepted. Implements the paid side of [ADR-019](#adr-019--the-cloud-epic-is-a-freemium-saas-free--local-paid--cloud); realises [ADR-007](#adr-007--payments-deferred-to-last) (Stripe) via the Node layer ([ADR-020](#adr-020--the-server-side-layer-is-the-existing-node-api-not-edge-functions)).
- **Context:** Paid cloud needs plan state, quota enforcement, and billing. Pricing is **storage-based**; GeoJSON is stored inline in Postgres (ADR-001/016), so "storage used" is the summed byte-size of a user's files.
- **Decision:**
  - **`public.user_plans`** (plural, matching `user_files` / `user_settings`), one row per user: `user_id` PK → `auth.users`, `plan`, `status` (Stripe sub status), `stripe_customer_id`, `stripe_subscription_id`, `current_period_end`. **Server-authoritative:** RLS lets a user **read** their own row; there is **no client write policy** — only the Node API (`service_role`) writes it. Optional `public.plans` lookup (`plan → limit_bytes`, price).
  - **Quota enforced by a Postgres trigger** on `user_files` (`before insert/update`): sum the user's GeoJSON bytes incl. the pending write, compare to the plan's limit, `raise exception` if over. Since writes are client-direct (RLS), the trigger is the real gate; the client shows a usage bar (UX only). **Downgrade-over-limit is humane** — block growth, allow deletes/shrinking; never delete data.
  - **Stripe:** hosted **Checkout** + **Customer Portal** (the portal covers billing history / invoices / cancellation — no custom billing UI); a **webhook** (Node, raw-body signature verify) is the *only* inbound channel and keeps `user_plans` in sync. **Grant entitlements on the webhook, never on the browser's return** from Checkout.
- **Rationale:** Inline-Postgres storage makes usage a trivial `sum(octet_length(...))` and enforcement plain Postgres (robust; Node isn't needed to *enforce*, only to *set* the plan via the webhook). Server-authoritative plan state is essential — a client must never grant itself a plan. Stripe's hosted surfaces minimise custom billing code.
- **Alternatives rejected:**
  - **Client- or RLS-`with check`-only quota:** rejected — aggregate-across-rows checks belong in a trigger; client checks are UX, not a gate.
  - **Plan columns on `auth.users`:** rejected — Supabase-managed schema; business state lives in your own `public` tables.
  - **Custom billing UI:** rejected — the Stripe Customer Portal covers it.
- **Consequences:** New migration(s) for `user_plans` (+ maybe `plans`) and the quota trigger, shipped with Phase 8. The Node API gains checkout / webhook / billing-portal routes (ADR-020). "Storage" today = Postgres DB size (not the separate Supabase Storage product); if files grow large, the backlog's move-to-Storage item is the cost lever — quota enforcement is unchanged. Concrete tiers/prices/limits are the user's to design (backlog).

## ADR-023 — Rename to `user_files`, drop the `backup_geojson` column

- **Status:** Accepted. Supersedes the table name + `backup_geojson` column of [ADR-016](#adr-016--phase-2-schema-shape-refines-the-architecture-5-sketch); completes the "drop backup" direction of [ADR-018](#adr-018--phase-3-multi-file-model-and-file-lifecycle).
- **Context:** ADR-016 shipped the active-document table as `public.files` with a `backup_geojson` column (mirroring the file seam's two keys). Phase 3 (ADR-018) made cloud File→New non-destructive, so `backup_geojson` is never written — it was flagged for a later cleanup migration. Separately, `files` is the odd one out beside `user_settings` and `user_plans`. We are **pre-production** (no prod Supabase project — ADR-014), and the non-prod tables were dropped.
- **Decision:**
  - Rename `public.files` → **`public.user_files`** (consistency with `user_settings` / `user_plans`), including its index (`user_files_one_per_user_uq`), policies (`user_files_*`), and trigger (`user_files_set_updated_at`).
  - **Drop the `backup_geojson` column** — the cloud never uses it (ADR-018).
  - Realise both by **amending the creation scripts** (`0001`/`0002`) in place and dropping/recreating the tables, **not** by adding an ALTER/cleanup migration — valid because we're pre-production (nothing applied is immutable yet).
- **Rationale:** Editing the creation scripts keeps the applied schema clean (no vestigial column ever exists, no rename churn) while we still can. Naming consistency across the three per-user tables. The backup column was already agreed vestigial in the cloud (ADR-018).
- **Alternatives rejected:**
  - **An ALTER `0003` migration (rename + drop column):** the correct approach *once production exists*, but adds cruft when the tables can simply be recreated clean. (Drafted, then discarded in favour of editing the creation scripts.)
  - **Keep `files` / the backup column:** rejected — the inconsistency and the dead column are avoidable now.
- **Consequences:** `0001`/`0002` create `public.user_files` with no backup column; the remote provider (`remote-file-storage.js`) targets `user_files` and maps only `geojson_data → geojson` (the local `backup_geojson_data` key is local-only and never reaches it). The migrations README records the pre-prod in-place-amendment policy: once prod exists, migrations become immutable and changes ship as new numbered files.

## ADR-024 — Entry topology in two stages: client-rendered preview, then static SEO landing

- **Status:** Accepted. Refines [ADR-021](#adr-021--app-entry-topology-static-landing-at--app-at-app) (its launch form) and the flag decisions ([ADR-005](#adr-005--runtime-url-param-feature-flag-not-an-envbranch-flag)/[ADR-015](#adr-015--the-cloud-feature-flag-is-url-presence-based-not-persisted)).
- **Context:** ADR-021 fixes the *launch* topology (static HTML landing at `/`, editor at `/app`). But that topology has to be **built and previewed before launch**, and the `?ff=cloud` flag is a **query-string** signal — it can only change client-side behaviour *after* the page loads. It cannot make nginx serve a different static document, and a crawler hits the bare URL with **no** flag at all. So the landing cannot be *both* flag-gated *and* statically SEO-served at the same time — those are two lifecycle stages, bridged by the flag.
- **Decision:** Deliver the entry topology in two stages:
  - **Stage 1 — dark preview (behind `?ff=cloud`).** Everything stays **one SPA at root** (Vite base `/`, router base `/`). Add a `/` route that branches on the flag — present → a **temporary client-rendered `Landing` component**, absent → today's editor — and an `/app` route → editor. `?ff=cloud` **propagates through navigation** (the same trick the OAuth `redirectTo` already uses). **No infrastructure change:** nginx's existing SPA fallback already resolves `/app` to the shell. This preview landing is client-rendered, so it has **no SEO** — acceptable precisely because the flag is dark and nothing crawls it. Bare `/` here = the editor (today's behaviour, untouched).
  - **Stage 2 — launch (Phase 7).** The physical restructure of ADR-021: **hand-written static HTML** landing served by nginx at `/`, the SPA relocated under `/app` (Vite base `/app/`, router base `/app/`, nginx `/app` location, Supabase redirect allow-list), and the **flag deleted**. SEO turns on **here** — only now is the landing a real static document at the bare URL. Bare `/` now = the landing (per ADR-021), replacing Stage 1's editor-at-root.
- **Rationale:** Lets the whole landing + `/app` topology **ship dark and be previewed** like every other epic slice, without prematurely committing to the nginx/Vite/router restructure or paying for SEO tooling before it matters. Separates "does the topology feel right?" (cheap, client-side) from "is it crawlable?" (a launch concern). Resolves the apparent bare-domain contradiction by assigning each behaviour to its stage: Stage 1 bare = editor, Stage 2 bare = landing.
- **Alternatives rejected:**
  - **nginx branching on the `?ff=cloud` query arg** to serve a different static file: fragile, and useless for SEO (crawlers send no query param) — the flag is a client concern by design (ADR-015).
  - **Building the static landing + `/app` restructure up front (skip Stage 1):** couples an early preview to irreversible base-path/nginx changes and loses the ship-dark property.
- **Consequences:** Stage 1 adds a throwaway `Landing` component + two routes + flag propagation, with **zero infra change**. Stage 2 is the ADR-021 work (static `landing/`, base changes, flag retirement) and is where the launch bare-domain topology takes effect. The temporary `Landing` component is **deleted at Stage 2**.

## ADR-025 — Connection-loss resilience for cloud edits (Level 1: retry + reconnect flush + save status)

- **Status:** Accepted. Applies across the logged-in/cloud path; scopes an explicit non-goal (offline-first) against [ADR-004](#adr-004--two-isolated-storage-paths-no-sync).
- **Context:** `supabase-js` has **no offline persistence, queue, or sync** for database operations (unlike Firestore) — offline, a write simply fails. Logged-in users keep **no IndexedDB copy** (ADR-004), so a dropped connection can lose autosaved edits. But the edited FeatureCollection lives **in memory** (draw-manager / Pinia), so it is only *truly* lost if the tab closes/reloads while still offline. Two failure horizons: (1) **tab open, connection returns**; (2) **tab closed while offline**. This is *connection-loss resilience*, deliberately **not** offline-first.
- **Decision:** v1 handles connection loss at **"Level 1"**:
  - **Retry-with-backoff** on the remote autosave write plus a **flush on reconnect** (via the `online` event / the next successful autosave). The in-memory state is the source of truth; on reconnect the latest state is pushed. Covers horizon 1.
  - A **visible save-status indicator** ("Saving… / All changes saved / Offline — retrying, don't close") surfacing the write state, plus a **`beforeunload` guard** that warns when unsaved changes exist. Turns horizon 2 from *silent* loss into a *warned* choice.
  - Lives in the **autosave-service + a small "save-status" Pinia store** surfaced in the UI. **No new durable storage.**
- **Rationale:** Covers the common case (brief blips with the tab open) cheaply, and makes the dangerous case **legible rather than silent**. Matches the product's nature (a client-side editor, not a collaborative sync tool) and honours ADR-004 (no second copy, no sync).
- **Alternatives rejected:**
  - **Level 2 — a crash-recovery journal** (persist pending state to IndexedDB, offer "recover unsaved changes?" on next load): covers horizon 2 fully, but is a **deliberate, scoped exception to ADR-004** (logged-in users otherwise touch no IndexedDB — it's a one-way, self-clearing recovery journal, *not* a sync path). **Backlogged**; build only if users actually report lost work.
  - **Level 3 — full offline-first** (op-queue + conflict resolution): rejected — contradicts ADR-004 ("no sync") and is out of scope for a single-active-document editor.
- **Consequences:** The autosave path gains retry/backoff + reconnect flush + a status store/indicator + a `beforeunload` guard. No schema or storage change. Level 2 (recovery journal) is backlogged with the ADR-004 carve-out noted.
