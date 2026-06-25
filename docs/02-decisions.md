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
- **Consequences:** The flag is a **visibility toggle, not a security boundary** (Auth + RLS are the real gate). Dark code must be truly inert (lazy-init Supabase, code-split the account module). The flag is temporary scaffolding — launch ≈ flip default on and delete the flag.

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
