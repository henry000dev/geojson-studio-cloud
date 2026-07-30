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
  - `RemoteStorageManager` implementing the seam interface against `public.user_files`.
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

> **Phases 4–8 revamped (2026-07-01)** when the epic's scope expanded from "cloud storage behind a flag" to a **freemium SaaS** (ADR-019). The old Phase 4 (beta) / Phase 5 (Stripe) are now Phase 6 / Phase 8, with production+server, account area, and the landing inserted. Payments stay **last** (ADR-007).
> **Re-sequenced again (2026-07-06, [ADR-030](02-decisions.md#adr-030--monetisation-built-before-beta-charging-still-goes-live-last)):** the monetisation *build* moved ahead of beta so beta exercises a production-like system, quotas included — old Phase 8 → **Phase 6**, old Phase 6 (beta) → **Phase 8**, old Phase 7's Stage 2 folded into a new **Phase 9 — Go-live** (Stage 1, the preview landing, was already delivered in the UI/UX revamp). *Charging* real users still comes last.

## Phase 4 — Node server layer (on non-prod)

- **Goal:** add the server-side layer the paid product needs — built and tested entirely against the **existing non-prod** Supabase project. **No production project yet** (that's deferred to the beta gate — now Phase 8, ADR-014).
- **Why no prod here:** nothing in Phases 4–5, and not even the Stripe build (now Phase 6 — ADR-030), requires the production project. The Node layer only needs *a* Supabase project with a `service_role` key — non-prod already has one. Provisioning prod now would just create a production footprint to maintain long before any real user touches it. See [ADR-014](02-decisions.md#adr-014--separate-supabase-projects-per-environment-non-prod-set-up-first).
- **Work** (design captured in [ADR-026](02-decisions.md#adr-026--server-side-supabase-integration-jwt-verification-getuser-service_role-admin-client-account-deletion); all wired to **non-prod**):
  - Add `@supabase/supabase-js` to `geojson-studio-api`; build a **verify client** (publishable key) + a **`service_role` admin client** from injected config (`services/supabaseClients.js`).
  - **`createSupabaseAuth` middleware** (mirrors `createSessionAuth`): verifies the caller's Supabase JWT via **`supabase.auth.getUser`**, attaches `req.supabaseUser`, else `401`. Reusable by the Phase 5 account area.
  - **`POST /api/v1/account/delete`** (`routes/accountRoute.js` + controller + `services/accountService.js`): deletes **the caller's own account only** (`req.supabaseUser.id`, never a body id) via `admin.deleteUser` → cascades to `user_files` + `user_settings`; tolerant of a repeat call. Mounted as a new `/api/v1/account` group with its own tight rate limiter; **no change to the Turnstile-gated convert/dataset paths**.
  - New env/secrets (non-prod): `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (**secret, server-only**), `ACCOUNT_API_ENABLED` (ships dark). Documented in `.env.template`.
- **Validation:** with `ACCOUNT_API_ENABLED` on, a real non-prod dev-login token → `POST /api/v1/account/delete` verifies the JWT and deletes the user; confirm `user_files`/`user_settings` rows cascade away; a bad/absent token → `401`; a repeat call → clean success. Jest tests inject **stubbed** Supabase clients (no live network).
- **Risk:** low–medium — server secret (`service_role`) handling and the self-only-deletion authz must be right, but there's no production footprint to get wrong yet.

## Phase 5 — Account area + compliance

- **Goal:** self-service account management (ADR-019) and the compliance basics for holding user data. Design agreed as [ADR-027](02-decisions.md#adr-027--phase-5-account-area--compliance). **All client-direct — no new Node endpoints** (deletion reuses the Phase 4 endpoint); two small read-oriented non-prod migrations. Sliced like earlier phases (build green between slices; git + e2e run by the user).

### Slice 5a — compliance static pages

- `public/privacy.html` + `public/terms.html`: hand-written static HTML mirroring `public/about.html` (self-contained, same theming; served by the existing nginx static/SPA-fallback — **no infra change**, crawlable). Draft content authored now; the user finalises the legal text later. Linked from the footer / about; consumed by 5c's signup checkbox and the account page.
- **Validation:** both pages render at `/privacy.html` and `/terms.html` in dev and a production build; styling matches `about.html`; flag-off / anonymous unaffected.

### Slice 5b — My Account page (usage · export · delete)

- `supabase/migrations/0003_storage_usage_view.sql`: `public.user_storage_usage` (`security_invoker = on`; `sum(octet_length(geojson::text))` + `count(*)`; `grant select` to `authenticated`, revoke `anon`). Applied to non-prod by the user.
- `/account` route → lazy, code-split `AccountView.vue`; a guard redirects non-flag / logged-out visitors to `/`; navigation propagates `?ff=cloud`; an **Account** entry is added to the `AccountMenu` overlay. Shows **email** (auth store), **storage used** (client-direct read of the view), **Export my data** (client-direct fetch of `user_files` + `user_settings` → one downloadable JSON bundle), and **Delete account** (calls the Phase 4 `POST /api/v1/account/delete` with the Supabase bearer token → sign out → anonymous `/`). A **"Manage billing"** link is a stub until the monetisation build (now Phase 6 — ADR-030).
- **Validation:** a logged-in dev sees their email + a correct storage figure; export downloads a complete bundle; delete removes the account (cascade confirmed) and drops to the anonymous path; a second account sees only its own usage/export (RLS on the view); flag-off unaffected. `ACCOUNT_API_ENABLED` must be on for delete.

### Slice 5c — terms acceptance

- `supabase/migrations/0004_user_profiles.sql`: `public.user_profiles` (one row per user, `user_id` PK → `auth.users` `on delete cascade`; `terms_accepted_at`, `terms_version`, timestamps; owner-scoped RLS select/insert/update; `updated_at` trigger). Applied to non-prod by the user.
- The signup tab gains a **required** "I agree to the Terms and Privacy Policy" checkbox gating **both** Create-account and Continue-with-Google, linking to 5a's pages. A first-login `recordTermsAcceptance()` hook (flag-on, post-auth, beside `cloud-settings-bootstrap.js`) idempotently writes `terms_accepted_at`/`terms_version` when the profile row is absent (see ADR-027: no authenticated write is possible at the signup instant under confirm-email / OAuth).
- **Validation:** signup is blocked until the box is ticked (email + Google); after first login a `user_profiles` row exists with the timestamp/version; a repeat login neither duplicates nor overwrites it; flag-off / anonymous never touches the table.

- **Validation (phase):** a user can read usage, export their data, delete their account (cascade verified), and must accept terms to sign up; privacy + terms pages published. Two-account RLS holds on the usage view + profile table.
- **Risk:** low–medium — mostly app-repo UI plus two small read-oriented migrations; the only privileged op (delete) already exists and is tested.

> **Near-term re-sequencing (2026-07-03).** With Phases 0–5 done and verified on non-prod (laptop only), the immediate focus is **validating + polishing the cloud experience on a real deployed environment** before the production gate (beta — now Phase 8, ADR-030). The `cloud-epic` branch is deployed to **`staging.geojsonstudio.com`** ([ADR-028](02-decisions.md#adr-028--deploy-the-cloud-epic-branch-to-staging-option-2) — Option 2: `cloud-epic` → staging; `main` → production unchanged). Order of work:
> 1. **Reconfigure branches/deploys** — repoint staging to `cloud-epic` (both repos); wire the existing **non-prod** Supabase into the staging build (build-args + backend env) and add the staging origin to the non-prod Supabase Auth URLs. No new Supabase project; production untouched.
> 2. **Verify on staging** — cloud-epic is live at `staging.geojsonstudio.com`; `?ff=cloud` reveals **and exercises** the account flow end-to-end on a real domain (Google OAuth + email confirmation).
> 3. **UI/UX revamp** — polish every new cloud surface (LoginDialog, AccountMenu, AccountView, the `privacy.html`/`terms.html` pages, CloudMigrationPrompt, MyFilesDialog) to production quality; testable on staging. **Pulls the landing (ADR-024 Stage 1 — the dark client-rendered preview) forward** here, since it needs no infra. ***Complete (2026-07-06).*** *All chunks + both polish rounds done: landing, `/login` (now a split two-column page with a 4-provider OAuth grid), in-app chrome, `/files`, the account page (sectioned panels + section sidebar + Security/Billing panels), CloudMigrationPrompt (polished + re-hosted in MapView — a latent never-fires-on-login bug), NotFound wordmark, dark/responsive audit. LoginDialog + MyFilesDialog are dedicated pages ([ADR-029](02-decisions.md#adr-029--cloud-account-surfaces-are-routes-not-dialogs)). Code-verified only via the fake-session harness — the **user's real-account verification pass is the outstanding gate** (list consolidated in [`05-worklog.md`](05-worklog.md)).*
> 4. **Bugs & loose ends** — the user's real-account verification backlog (incl. the migration-prompt retest + re-apply `0002`), OAuth provider config in Supabase (GitHub/Microsoft/Facebook), per-file size limit + large-file testing, legal-page content, storage-quota constraints, and the smaller backlog items.
> 5. **Final polish**, then the production gate — **kept deferred** until the experience is polished and the user signs off. *Re-sequenced (2026-07-06, ADR-030): steps 4–5 now live in **Phase 7**, after the **Phase 6** monetisation build; production provisioning gates **Phase 8** (beta).*

## Phase 6 — Monetise: Stripe + entitlements (build, test mode)

> Moved ahead of beta by [ADR-030](02-decisions.md#adr-030--monetisation-built-before-beta-charging-still-goes-live-last) (was Phase 8): the entitlements layer changes the core write path, so beta should exercise it rather than have it retrofitted afterwards. *Charging* real users still comes last (the Phase 9 cutover).

- **Goal:** build the full paid-plans layer ([ADR-022](02-decisions.md#adr-022--monetisation-mechanics-user_plans-storage-quota-via-postgres-trigger-stripe); ADR-007 as amended by ADR-030) — entirely in **Stripe test mode** against **non-prod**. No live keys, no production project, no real charges.
- **Work:**
  - `public.user_plans` (+ optional `plans`); the **storage-quota Postgres trigger**. Tier limits/prices are **provisional** — final numbers wait for beta usage data (Phase 9).
  - Node routes: **Checkout**, **webhook** (raw-body signature → writes `user_plans`), **billing-portal**.
  - Client: upgrade CTA, usage bar (replacing the placeholder `QUOTA_BYTES`), plan state read from `user_plans`; the account page's Billing panel wired to the Customer Portal.
  - Create the **Stripe account** (activation/KYC deferred to Phase 8 — only needed for live keys).
- **Development flow:** Stripe test keys + the Stripe CLI forwarding webhooks to the local Node (writing to non-prod `user_plans`); Stripe **test clocks** simulate renewals, payment failures, and cancellations without waiting a billing cycle.
- **Validation:** full subscription lifecycle (subscribe, cancel, fail-to-pay, downgrade-over-limit) reflected correctly in `user_plans` + quota enforcement (test mode), exercised on staging as well as locally.
- **Risk:** medium (money + lifecycle edge cases), but isolated — no live money and no production footprint yet.

> **Code-complete (2026-07-22), fully verified in test mode (2026-07-24) — see [`05-worklog.md`](05-worklog.md) and [ADR-031](02-decisions.md#adr-031--phase-6-schema-plans-as-a-lookup-table-every-user-gets-a-server-written-user_plans-row).** All three slices built and green (API Jest + app build): **6a** `0005_plans_and_quota.sql` (`plans` lookup + read-only `user_plans` + `handle_new_user` default-plan trigger/backfill + `enforce_storage_quota`); **6b** Node `/api/v1/billing` checkout/portal/webhook (`BILLING_API_ENABLED`, `stripe` dep, service_role `user_plans` writes); **6c** `account-billing.js` + AccountView real plan/usage + Upgrade CTA + live Customer Portal + quota-exceeded toast. Two forks settled with the user (ADR-031): `plans` as a lookup table; every user gets a server-written default `early_access` row. **Verified (2026-07-24):** the user created the Stripe account + test Products/Prices, applied `0005`, filled the API env, `npm install`ed `stripe`, and ran the full test-mode lifecycle green (checkout→webhook grant, portal, quota gate, cancel, test-clock renewal + dunning). Two follow-ups surfaced during that pass — the over-limit **dialog** and the webhook **terminal-status revert** — fold into Phase 7 slice **7a** (below).

## Phase 7 — Pre-beta: entitlement build → large-file fix → loose ends → polish → sign-off

> **Re-sliced (2026-07-25).** Phase 7 had accreted three different kinds of work under a single "final polish & debugging" label — genuine entitlement *build* (from [ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)), discrete known-issue fixes, open-ended polish, and the real-account verification pass. Split into slices **with verification last**, because the real-account backlog re-tests surfaces that the fix/polish slices change — verifying earlier would only go stale before beta. Each build/fix slice carries its own tight "confirm it works" check; the standalone verification slice is the **beta-readiness sign-off**, the gate into Phase 8. *Charging real users is still Phase 9.*
>
> **Re-sliced again (2026-07-27) — a new 7b, and the tail renumbered.** Large-file testing (a 7b loose end at the time) found that a **43 MB file crashes the whole Supabase project**, twice, on two projects. That is not a loose end: it is an architectural defect in the core write path, and the fix — moving the blob to Supabase Storage ([ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row)) — is the largest single change left before beta. It becomes **Slice 7b**, and everything after shifts: old 7b (loose ends) → **7c**, old 7c (polish + quick wins) → **7d**, old 7d (verification & sign-off) → **7e**. Placed **before** the loose ends and polish because it changes the storage layer those slices sit on, and before verification for the same reason 7a was.

- **Goal:** everything a real external user will touch works, verified with **real accounts** — the consolidated gate before production provisioning. (Absorbs steps 4–5 of the near-term note above.)
- **Risk:** **medium**, up from low–medium, entirely because of 7b. 7a touched the schema + core write path; **7b replaces the blob storage layer outright and adds a second RLS surface** (`storage.objects`) — the security-critical part of the phase. 7c/7e are fixes and verification with no new architecture; 7d's remaining architectural addition is the public-serving path for share-as-URL ([ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)), which 7b makes considerably smaller (Storage serves the bytes; the planned Node public-read endpoint is largely obsolete).

### Slice 7a — entitlement-completion build ✅ *built 2026-07-26; `0005` applied + schema-verified 2026-07-27 (behavioural confirm-as-you-go checks still outstanding)*

Finish the entitlement surface so beta exercises quotas that are production-like on **both** axes (storage *and* file-count), and so the whole billing/entitlement surface is complete **before** 7e verifies it once (rather than verify → change the webhook → re-verify). Every schema edit below rides **one `0005` re-apply** (amend-in-place, pre-prod — ADR-023); the user re-runs it a single time.

- **File-count lever** ([ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)). Storage is enforced by the `0005` trigger; **file-count is not**. Add a `max_files` column on `plans` + a `user_files` BEFORE-INSERT count check (block a *new* file over the cap; deletes/updates always allowed, matching the humane-downgrade rule) + client UX (count vs limit; block "New file" at the cap → upgrade CTA).
- **Rename `early_access` → `free`** ([ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)). Slug + label, across `0005` (seed / default / `handle_new_user` / backfill / quota fallback), the webhook revert literal in `billingService.js`, any client reference/label, and tests.
- **Fix the inverted storage seed** ([ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)) — the seed must be monotonic (`free < basic < pro`); today `basic` 250 MB sits below `free` 1 GB. Reorder in the same `0005` edit. (Final numbers still wait for beta data — ADR-030.)
- **`plans` admin fields — `description` column + hidden plans** ([ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)). Add a private **`description`** column to `plans` (a maintainer's memo of what each row is for — **never rendered to users**), and seed two hidden plans: **`discount`** (special discounted) and **`god_mode`** (effectively-unlimited, for the maintainer's own account). Both ride the same `0005` re-apply; assignment and the hidden-*paid*-plan variant are documented in [`RUNBOOK.md`](RUNBOOK.md).
- **Over-limit save UX → dialog, not a toast** (decided 2026-07-24, from the Phase 6 quota test). The `GS_QUOTA_EXCEEDED` rejection currently surfaces as a transient toast (`auto-save-service.notifySaveFailed` → the "Storage limit reached … upgrade" branch). Promote it to a **modal/attention dialog** with a clear upgrade CTA — a rejected save is a serious, action-required state a toast can let the user miss. (While there, consider treating the quota error as **non-retryable** so autosave doesn't keep re-firing the same blocked write.)
- **Webhook: revert on terminal non-granting subscription statuses** (found 2026-07-24, dunning test). `billingService.handleWebhookEvent` reverts to `early_access` only on `customer.subscription.deleted` (canceled). A dunning failure that Stripe resolves as **`unpaid`** (a configurable alternative to "cancel") arrives via `customer.subscription.updated` with a non-granting status — which currently updates `status` but **leaves the paid plan in place**, so the entitlement wrongly persists. Handle terminal non-granting statuses (`unpaid`, `incomplete_expired`, `canceled`) in the `updated` branch by reverting the plan, so entitlement doesn't depend on the Stripe "manage failed payments" dashboard setting. (Interim: set that dashboard setting to "Cancel subscription.") `past_due` stays granting by design (grace window — verified 2026-07-24).
- **Confirm-as-you-go:** re-run the affected Phase 6 test-mode checks — an `unpaid` transition reverts the plan; the over-limit save raises the dialog; a new file over the cap is blocked while delete/update still succeed.

> **Built 2026-07-26** — see [`05-worklog.md`](05-worklog.md). All six items landed across the three repos; API Jest **18 suites / 264 tests** pass, app `npm run build` clean (`PlanLimitDialog` a 2.3 kB async chunk; the Supabase SDK still out of the main bundle). Provisional limits chosen by the user: **`free` 30 MiB / 3 files · `basic` 500 MiB / 50 files · `pro` 20 GiB / 1000 files** (monotonic on both axes; final numbers still wait for beta data — ADR-030), plus the hidden `discount` (Pro limits at a private price) and `god_mode` (sentinel) rows. Two implementation choices are recorded as an [ADR-032 addendum](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features): "unlimited" is a **sentinel, never `NULL`** (`max_files` is `NOT NULL`, so a plan row that omits it is rejected rather than silently ungated), and file-count is enforced **`BEFORE INSERT` only** (the humane-downgrade rule). The webhook fix is an [ADR-031 addendum](02-decisions.md#adr-031--phase-6-schema-plans-as-a-lookup-table-every-user-gets-a-server-written-user_plans-row). **Applied 2026-07-27:** the user re-ran `0005` and all verification queries return as expected — seeded rows + monotonicity, the rename landed, the file-count gate present, and `service_role` grants correct (`plans` → `REFERENCES,SELECT,TRIGGER,TRUNCATE`; `user_plans` → the same plus `INSERT,UPDATE`). The first run had aborted mid-script, leaving `user_plans` without its `INSERT` grant — worth remembering that a partial apply fails *silently downstream*, which is exactly what the verify blocks are for. **Still outstanding for the user:** the *behavioural* confirm-as-you-go checks above (an `unpaid` transition reverts the plan; an over-limit save raises the dialog; a new file over the cap is blocked while edit/delete still succeed).

### Slice 7b — large-file fix: the blob moves to Supabase Storage

> **New (2026-07-27).** Design and reasoning: [ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row). A 43 MB import kills the Supabase project (PostgREST OOMs materialising the `jsonb` payload — `520` on the write, `521` on the read-back, manual restart required); the same file is fine on the anonymous IndexedDB path, so the **paid** cloud product is currently worse than the **free** local one. No trigger, `CHECK`, or RLS policy can help — the blow-up is upstream of Postgres — and a client-side cap is UX rather than a control ([ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)). Doing this now costs a code change plus a bucket; doing it after beta costs a data migration.

Ordered in three parts. **7b-1 ships on its own, immediately** — it is independent of the rest and stops the bleeding while 7b-2 is built.

**7b-1 — stop the bleeding (no schema, independently shippable)** ✅ *built 2026-07-27; e2e green; **autosave coalescing reworked 2026-07-28** after manual verification found it losing edits on refresh — see [`05-worklog.md`](05-worklog.md). Re-run of e2e outstanding.*

- **Per-file ceiling: `50000000` (decimal 50 MB), uniform across tiers and environments** (the user's call, 2026-07-27; [ADR-032 addendum](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)). Align `MAX_FILE_SIZE_FOR_FILE_IMPORT` in `constants/file-constants.js` from `50 * 1024 * 1024` down to this value so the client cap and the future bucket limit are **one number**. Decimal, not binary, because Supabase's free plan caps uploads at 50 MB and a bucket's limit must be ≤ the project's global limit — 52428800 would sit above it.
  > **No interim lower cap** (decided 2026-07-27). The existing 50 MiB cap is what the 43 MB file passed on its way to crashing the project, so the ceiling is the right *destination* but provides no protection before 7b-2 lands. A temporary ~25 MiB cloud-path cap was proposed and **declined by the user**: they are the only user of the non-prod project and will not upload large files until the Storage path exists. Accepted risk, recorded rather than mitigated. One caveat worth remembering: staging is publicly reachable ([ADR-028](02-decisions.md#adr-028--deploy-the-cloud-epic-branch-to-staging-option-2), `--allow-unauthenticated`) and real signups there write to non-prod — the exposure is small only because the cloud UI is dark behind `?ff=cloud`, not because the surface is closed.
- **Honest failure messages.** `file-service.importFile` currently funnels *every* non-`GsUserFriendlyError` into **"The GeoJSON data is not valid."** — so a save or network failure is reported to the user as a corrupt file. It also swallows the failure of `restoreCurrentFileAfterFailedImport()` silently. Both were surfaced by this investigation.
- **Quota rejections during import must reach `PlanLimitDialog`.** A 7a gap, owned: the import path calls `fileStorage.setItem()` directly, bypassing `AutoSaveService`, so `GS_QUOTA_EXCEEDED` / `GS_FILE_LIMIT_REACHED` raised during an import never raises the dialog — it falls through to the "not valid" message above.
- **Debounced / coalesced autosave.** There is **none** today: eleven call sites in `draw-manager.js` each trigger a full whole-document write. Independent of where the bytes live, and the strongest argument is the user's own upload bandwidth — re-uploading 20 MB every few seconds on a phone is a real harm no warning dialog excuses. Required alongside 7b whether or not Storage lands first.
  > **Built 2026-07-27, on *both* paths** (the user's call — a cloud-only debounce was offered and declined). Two consequences that were not anticipated in the plan and are worth not losing: **(1)** coalescing invalidates ADR-018's free "nothing needs flushing here" — an owed save carries no file id, and the editor's draw manager survives navigation to `/files`, so six boundaries (file switch, delete, File→New, import ×2, sign-out) now flush explicitly via a new `active-auto-save.js` registry; the *delete* case is the sharp one, since an owed write after the store detaches the active file **lazily creates a replacement row**. **(2)** the e2e suite proves persistence by reloading immediately after an edit, so 16 reloads across 8 specs gained a `waitForSaveIdle(page)` helper.
  >
  > **Reworked 2026-07-28, and this is the durable lesson of the slice: price the window by what a save COSTS, not by which path it takes.** A uniform 1.2 s window lost edits — five points drawn quickly then refreshed persisted three. Two findings behind the fix. **(a)** The `pagehide`/`visibilitychange` flush meant to cover this **does not work**: the browser abandons the write during teardown and it is six async hops deep before a byte lands, so it loses reliably, not occasionally. Treat page-hide flushes as a bonus, never as the reason a window is safe to widen. **(b)** A first fix split the window local-vs-cloud; the cloud path then failed the same test, because *path is the wrong axis*. The debounce is justified by whole-document **upload bandwidth**, and that scales with the **document**, not the backend — coalescing a five-point file protects bandwidth nobody is using while charging full price in lost edits.
  >
  > The window is therefore chosen by **how long the last save took** (`SAVE_IS_CHEAP_BELOW_MS = 500`): cheap → **200 ms + a leading-edge write**, costly → **1.2 s**, unmeasured counts as cheap. Self-tuning across both paths, and it needs no serialising of a large document to estimate size. **ADR-025's `beforeunload` guard was pulled forward from 7c** as the only cover for a costly save owed at unload — and note *how* it protects: it warns, but more usefully the dialog is synchronous, so it **buys the in-flight write the time the user spends reading it**. No flush mechanism survives page death at our sizes (`fetch keepalive` caps at 64 KB, `sendBeacon` cannot set auth headers). **7b-2 re-prices this automatically** — moving the blob to Storage changes what a save costs, so re-run the manual check but expect no tuning.

**7b-2 — the move (the substance of the slice)**

- **Two prototypes first — both gate the design** (ADR-035): (1) does a `BEFORE INSERT OR UPDATE` trigger on `storage.objects` fire and reject cleanly, without leaving orphaned bytes? (2) may a `storage.objects` RLS policy contain a cross-table subquery (needed by 7d's publish)? Documented fallbacks: Node-issued **signed upload URLs** gated on a server-side quota check for (1); a separate public bucket for (2). *Prototype before committing to the slice, not during it.*
- **`0006_file_blobs_to_storage.sql`** — create the private **`user-files`** bucket in SQL (`storage.buckets` upsert) with an explicit `file_size_limit` of **`50000000` (decimal 50 MB)** — **this is where the per-file guardrail finally lives**, server-side at the edge ([ADR-032 addendum](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)); confirmed to sit exactly at the Supabase free plan's global upload ceiling, which a bucket limit may not exceed — and an allowed-MIME list; owner-only RLS on `storage.objects` keyed on the path prefix (`(storage.foldername(name))[1] = auth.uid()::text`), mirroring the `user_files` policies, with `anon` revoked.
- **Byte-quota enforcement re-based on `storage.objects.metadata->>'size'`** — the only place that knows the real size. A client-written `size_bytes` column is **rejected as the source of truth** (spoofable by the same replay ADR-033 describes). **File-count enforcement is untouched** — `enforce_file_count` still counts metadata rows.
- **New storage backend behind the existing file seam** — `{user_id}/{file_id}.geojson`, plain bytes, `application/json`. Implements the ADR-035 failure ordering: save = object then row; create = row then object (and "row without object" reads as an **empty file**); delete = object then row.
- **Account-deletion sweep** — `on delete cascade` does **not** remove storage objects. Add a `{user_id}/` prefix sweep to the existing `POST /api/v1/account/delete` (Phase 4, already `service_role`) **before** `admin.deleteUser`, plus an orphan-reconciliation query as a backstop. **A compliance obligation, not housekeeping.**
- **`user_storage_usage` rework** (amend `0003`) — `bytes` from `storage.objects`, `file_count` still from `user_files` so a file with no object yet still counts.
- **Export bundle rework** — no longer one `select`; becomes N object downloads, which is the natural shape of the backlogged **export-as-zip of individual `.geojson` files** (so a backlog item gets *cheaper*, not harder).
- **Cache-control decided deliberately** — short/no cache on owner reads (a just-saved file served stale reads as "my edit disappeared"), long cache reserved for published files.

**7b-3 — cleanup (after the new path is proven)**

- Delete the Postgres blob path and drop `user_files.geojson`. Per the user's call (2026-07-27) the old code stays in the repo as **clearly-commented dead code, with no feature flag** — the seam makes the cutover a one-line change and git is the real fallback. **Its value expires in days-to-weeks, not months:** it is a *code* fallback, not a *data* one, since the `geojson` column goes stale the moment files are saved to Storage. `enforce_storage_quota` (`0005`) stays until this point, so both paths keep an enforced quota during the overlap.

- **Confirm-as-you-go:** the 43 MB file imports, saves, reloads, and exports **without taking the project down**; a file over the bucket limit is refused by Storage with a clean message; two-account isolation holds on `storage.objects` (the new RLS surface) as well as on the tables; account deletion leaves **no objects behind**; the usage figure on `/account` still matches reality.

### Slice 7c — loose ends (known issues)

> Was 7b; renumbered 2026-07-27.

Discrete, enumerable tasks, each with a clear definition-of-done.

- **Crash-recovery journal — local storage buffers cloud writes** ([ADR-036](02-decisions.md#adr-036--local-storage-buffers-cloud-writes-the-recovery-journal-is-promoted-indexeddb-as-a-staging-area-is-rejected), 2026-07-28; promoted from the backlog, where it sat behind "only if users report lost work"). The active document's un-acknowledged state is written to a small IndexedDB buffer **keyed by file id**, cleared on successful upload and on sign-out; on next load an orphaned entry offers *"Recover unsaved changes?"* — offered, never applied silently. **Why it earned a slot:** 7b-1's autosave tuning showed durability was coupled to upload frequency, so the debounce window traded lost edits against saved bandwidth with a single number; the buffer decouples them and lets the adaptive window built in 7b-1 be deleted. **Two constraints found the hard way:** the journal write must be **immediate** (a debounced journal inherits the very teardown failure it exists to solve) and **keyed by file id** (or file A's journal restores into file B — the 7b-1 flush-boundary bug class). **Deliberately after 7b-2:** the retry logic must classify failures of the *final* storage backend, and 7b-2 changes every one of them. No new package — Dexie is already a dependency. Carries ADR-025 Level 1's unbuilt remainder with it (retry/backoff, reconnect flush); the `beforeunload` guard already shipped early in 7b-1.
- **OAuth provider config** in Supabase — GitHub / Microsoft (azure) / Facebook. The `/login` buttons render (`constants/auth-constants.js`) but only Google is configured on non-prod; each needs its OAuth app + the Supabase callback URL + dashboard enablement, then a clean round-trip. (Re-done on the prod project at Phase 8.)
- ~~**Per-file size limit**~~ **— moved to 7b (2026-07-27).** The large-file testing this was waiting on is what found the crash, and the ceiling now has a real server-side home: the Storage bucket's `file_size_limit` ([ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row)). It remains a **uniform guardrail, not a plan lever** ([ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)), and **the number is now chosen: `50000000` (decimal 50 MB) for all tiers** (2026-07-27), with `MAX_FILE_SIZE_FOR_FILE_IMPORT` aligned to the same value. What stays here is **reviewing the remaining ceilings** now that the storage one is fixed: URL import 3 MiB, geometry-add 1 MiB, conversion dataset import/export 10 MB, export output + shapefile-uncompressed 50 MB. These are **not** all the same concern — the conversion caps bound Node body size and compute, not stored bytes — so the goal is a *deliberate* set, not a single number forced across unrelated subsystems.
- **Landing-page pricing table is wrong on two counts** (found 2026-07-26; [ADR-032 addendum](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features)). `LandingView.vue` advertises **"Files up to 10 MB each"** (Basic) and **"Files up to 50 MB each"** (Pro) — a per-file *lever* that ADR-032 explicitly rejected and that **nothing in the product enforces** — plus stale storage figures (250 MB / 5 GB vs the seeded 500 MiB / 20 GiB). Remove the per-file bullets, correct the storage numbers, add the file counts (the lever that *is* real), and review the "early access" badges against [ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability) (that phrase now names the `free` plan, not a perk). Note the *final* numbers still wait for beta data and pricing isn't published until Phase 9 (ADR-030) — this is about not making false claims in the meantime.
- **Legal-page content** — finalise the drafted `privacy.html` / `terms.html` text (the user's to author), **including a ToS acceptable-use clause** prohibiting use of cloud storage as a general-purpose JSON backend (misuse → suspension) — the intent control for the client-direct non-GeoJSON-write concern ([ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)).
- **Checkout-return "activating…" notice** (agreed 2026-07-23). The plan is granted by the **webhook**, which can lag the browser's return from Checkout, so `/account` may briefly show the old plan. Add a small "your subscription is activating…" notice on `?billing=success` (optionally a short `getPlan()` refetch/poll) instead of the current silent stale display.
- **Graceful read-back of non-GeoJSON** ([ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)) — the app must handle reading a `user_files` row whose content isn't valid GeoJSON without crashing (a clear "couldn't load as GeoJSON" state + a raw-view/export escape hatch). Covers corruption from **any** cause — a replayed client-direct write, a bug, a partial save, format drift — not just the abuse scenario. Client-side only; the integrity half of ADR-033's package (quota + ToS being the other two).

> **"Storage-quota constraints"** (a prior loose-end line) is now decomposed: the monotonic-seed fix moved to **7a**; the final limit **values** stay provisional until beta data (Phase 9, ADR-030).

### Slice 7d — polish (production-quality pass) + quick-win features

> Was 7c; renumbered 2026-07-27.

Open-ended refinement toward production quality: the user's own polish list, plus a final cross-cutting UI/UX pass. **Deliberately left unbounded for now** — the stop point is a judgement call made when we get there, not a fixed checklist. Working bar: *no rough edge a beta user would trip on*; genuinely discretionary refinement can wait for real-usage signal from beta rather than guessed priorities (ADR-030's "beta tests the real system" rationale).

Two low-effort features ride here as **quick wins** ([ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)):

- **`save-as`** — clone the active file into a new named row (reuses the Phase 3 multi-file create path). A **core editor convenience, left ungated**; gives users a manual checkpoint without the machinery of version history (the future paid counterpart — backlog).
- **share-as-URL / publish read-only** — publish a file at an **unguessable URL** (+ an unpublish/revoke action), served as **raw `application/json`** (safe headers: `nosniff`, non-HTML content-type, CORS-friendly) so the existing **import-from-URL** feature can consume it. Publish + import is also the **v1 collaboration story** (ADR-034). Raw-serve keeps [ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)'s sanitisation tail **off** (only a *rendered* viewer would trip it). A browsable directory + a rendered viewer are deferred to Phase 10.
  > **Re-scoped by 7b (2026-07-27).** The planned **small Node public-read endpoint is largely obsolete** — with the file in Storage, Supabase serves the bytes directly, correctly typed, from CDN ([ADR-034 addendum](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)). Intended design: **one private bucket** + an RLS policy granting `anon` read where the owning `user_files` row is published — single copy, no expiry, publish/unpublish is a boolean flip (7b-2 prototypes the cross-table subquery this needs). Two caveats: **CDN caching undermines revocation** (an unpublished file may serve until its TTL expires — a correctness bug for a revoke action, so cache TTL on published objects is a deliberate choice), and the public path must **force** the content type + `nosniff` rather than trust the upload-supplied MIME, which is attacker-influenced ([ADR-033 addendum](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)). Fallbacks: signed URLs (expiring) or a separate public bucket (two copies).

### Slice 7e — real-account verification & beta sign-off (the gate)

> Was 7d; renumbered 2026-07-27.

The consolidated real-account pass, run **after** 7a–7d so it certifies the app exactly as it will reach beta users. This is the gate into Phase 8.

- The **real-account verification backlog** (consolidated list in [`05-worklog.md`](05-worklog.md)): migration-prompt retest + `0002` re-apply, `/login` flows + OAuth round-trips, `/account`, `/files`, landing/routing, in-app chrome.
- The **Phase 6 + 7a entitlement/payment surfaces** end-to-end in test mode: upgrade CTA, usage bar, Checkout → webhook → plan + quota, Customer Portal round-trip, cancel/dunning, plus 7a's file-count cap and the two billing fixes.
- The **7b storage surfaces**, which are new since this slice was written: large-file round-trip (import → edit → reload → export) at the real ceiling; two-account isolation on **`storage.objects`** as well as the tables; account deletion leaving no orphaned objects; the usage figure matching actual stored bytes; and a file over the bucket limit refused cleanly.
- **Validation:** the user signs off that staging (non-prod, test mode) is beta-ready.

## Phase 8 — Free beta / early access

> Was Phase 6; renumbered by ADR-030. **This is the production gate** — the first point real external users arrive, and the user's explicit "non-prod is good enough" sign-off ([ADR-014](02-decisions.md#adr-014--separate-supabase-projects-per-environment-non-prod-set-up-first)).

- **Goal:** real-world validation at zero monetary risk — now of the production-like system, quotas included.
- **Work:**
  - **Provision the production stack** (the deferred ADR-014 unblock): create the **production Supabase project**; apply the migrations; wire `VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY` per environment (mirror the Mapbox token); per-provider OAuth callbacks + the Auth redirect allow-list. First production cloud footprint — secrets/isolation must be right. *(Done only once the user is happy with non-prod.)*
  - **Cohort = plan rows:** beta users get a free **`beta` plan** in `user_plans` (the allowlist and the plan mechanism are the same thing — supersedes the earlier separate-allowlist idea). Quotas are **live**, so behaviour is production-like.
  - **No real charges.** Optionally let beta users exercise the real (live-mode) Checkout via a **100%-off "founders" coupon**.
  - **Start Stripe account activation** (business details / KYC / bank — days, country-dependent) so live keys never block the Phase 9 cutover.
  - Gather usage (informs the final tier limits/prices), fix issues, harden RLS.
- **Validation:** beta users complete the full account journey against the **prod** project without data or security problems; quota behaviour is correct on real usage.
- **Risk:** medium — first production footprint (secrets/isolation) on top of whatever beta surfaces.

## Phase 9 — Go-live

> Absorbs the old Phase 7 "Landing & go-public" **Stage 2** ([ADR-021](02-decisions.md#adr-021--app-entry-topology-static-landing-at--app-at-app)/[ADR-024](02-decisions.md#adr-024--entry-topology-in-two-stages-client-rendered-preview-then-static-seo-landing) — Stage 1, the client-rendered preview landing, was delivered in the UI/UX revamp) plus the payments cutover (ADR-030).

- **Goal:** the public front door + real payments + the first premium surface, on the stack beta proved.
- **Work:**
  - **Premium v1 — before go-public** ([ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)). Ship the first finished premium surface so the paid tiers aren't naked at launch: **bulk export** (a whole thin slice — export many files as a zip), decided and built **alongside the final pricing** (what Pro *is* and what it *costs* settled together on beta data). "Partial at launch" = *fewer features, each finished* — bulk **import** and the rest of the premium long tail follow post-launch (Phase 10), not a half-built wide surface now.
  - Hand-written **static SEO landing** at `/` (features, **pricing**, free-tier entry, sign-up); app relocated to **`/app`** (Vite base + router base + nginx + Supabase redirect config); **delete the temporary `Landing` component**.
  - **Retire the `?ff=cloud` flag** — cloud becomes unconditional; delete the scaffolding. Plus ADR-028's launch cleanup: merge `cloud-epic` → `main`, re-point the staging deploy.
  - **Payments cutover:** wire **live Stripe keys** (account activated during Phase 8); set the **final tiers/prices** from beta usage data; decide tax handling (e.g. Stripe Tax) before the first live charge.
  - **Beta users:** keep the free `beta` plan or convert (e.g. the founders coupon) — the grandfather decision, now just a plan-row update.
  - Reconcile `about.html`'s privacy section (backlog item).
- **Validation:** bare domain serves the **crawlable static** landing; free-tier entry → anonymous `/app`; sign-up → cloud; one real subscription end-to-end (subscribe → webhook → plan + quota updated); no dark-flag paths remain.
- **Risk:** medium — entry-topology + auth-redirect changes and the first live money, but every piece was proven in earlier phases.

## Phase 10 — Post-launch premium iteration

> Added 2026-07-26 ([ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)). The premium long tail, built **after** go-live bit by bit on the validated core. None of it gates core capability — every item is *scale / automation / distribution / collaboration*. Priorities are set by real launch signal, not guessed up front; items promote individually.

- **Goal:** grow paid-plan value beyond the Phase-9 Premium-v1 surface.
- **Candidate work** (unordered):
  - **Bulk operations — the rest:** bulk import (many files → many named rows), bulk delete, bulk conversion (reusing `/convert` + `/dataset`), bulk feature-level edits (gate the *many-at-once automation*, never the single action).
  - **Version history / restore** — automatic snapshots + restore (the paid "scale" counterpart to 7c's manual `save-as`).
  - **Publish, richer:** a discovery/browsable directory, a **rendered** public viewer — the point at which [ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos)'s output-sanitisation finally gets built — plus embed/iframe and branding controls.
  - **Shared editing** (only if it earns its place): a `file_shares` ACL + the owner-only RLS rewrite + an email-invite/claim flow + optimistic-concurrency conflict handling. [ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability) records why this is a phase of its own, not a ride-along.
  - **Developer surface:** a personal API token / hosted read endpoint (needs the "unify the two JWTs" backlog item as a prerequisite).
- **Risk:** varies per item — the publish viewer and shared editing carry real security surface (output safety, an RLS rewrite); the bulk/version items are additive and low-risk.

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
- **Account deletion** — define the flow (hard-delete from `user_files` + `user_settings`; Supabase deletes the auth user).
- **Connection-loss resilience** — `supabase-js` has no offline queue; logged-in users keep no local copy (ADR-004). v1 ships **Level 1** ([ADR-025](02-decisions.md#adr-025--connection-loss-resilience-for-cloud-edits-level-1-retry--reconnect-flush--save-status)): autosave **retry-with-backoff + reconnect flush**, a **save-status indicator**, and a **`beforeunload` guard**. A crash-recovery journal (Level 2) is backlogged.
- **Backups** — Supabase managed Postgres provides automated backups; confirm the tier when ready.
- **Monitoring** — basic uptime + error reporting; Supabase dashboard for DB metrics.
- **Kill-switch** — the always-present local path means flipping the flag off (or routing logged-in users to local fallback) is an instant rollback without a deploy.
