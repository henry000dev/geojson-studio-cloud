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

- **Status:** Accepted. Implements [ADR-003](#adr-003--data-model-is-users--files-settings-stay-user-global) and the [`01-architecture.md`](01-architecture.md) §5 data model; first migration is `supabase/migrations/0001_files_and_user_settings.sql`.
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
