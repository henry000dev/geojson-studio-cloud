# 00 — Overview

> **Status:** Phases 0–5 complete (seams + auth + remote file/settings round-trip + multi-file "My Files" + the Node server layer with account deletion + the account area & compliance pages), the **UI/UX revamp of every cloud surface is complete (2026-07-06)**, and **Phase 6 — monetisation — is built and fully verified in Stripe test mode against non-prod (2026-07-24, ADR-031):** `plans` + `user_plans` + the storage-quota trigger (`0005`), the Node `/api/v1/billing` Stripe checkout/portal/webhook layer, and the client billing UI (real plan/usage + Upgrade CTA + live Customer Portal) — the full subscription lifecycle (checkout→webhook grant, portal, quota gate, cancel, test-clock renewal + dunning) confirmed green. The plan-tier product shape is settled (**ADR-032, 2026-07-25:** four tiers — Guest / Free / Basic / Pro — differentiated by storage + file-count only). **Now — Phase 7, re-sliced again 2026-07-27 into five slices with verification last:** **7a** entitlement-completion build — **built + applied 2026-07-26** (the file-count lever now enforced, the `early_access → free` rename, monotonic seeds, hidden plans, and the two Phase 6 billing follow-ups) → **7b** the **large-file fix** — a 43 MB import crashes the whole Supabase project, so the GeoJSON blob moves out of `jsonb` into **Supabase Storage** ([ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row)); the biggest single change left before beta — **⏸ PAUSED 2026-07-31 — the *remedy* is under review (other providers, edge functions, NoSQL documents); nothing was built, and the *diagnosis* still binds** → **7c** loose ends → **7d** polish → **7e** real-account verification & beta sign-off. **Then Phase 8 — free beta / early access, the production-provisioning gate (ADR-014); Phase 9 — go-live** — everything so far has been on non-prod. See [`05-worklog.md`](05-worklog.md).
> **Epic:** Cloud. **Brand:** "Cloud" (user-facing); "Paid Plans" is a sub-stream.
> **This doc:** the read-me-first. Problem, goals, glossary, and the two-paths summary. For the technical design see [`01-architecture.md`](01-architecture.md); for *why* each choice was made see [`02-decisions.md`](02-decisions.md); for the plan see [`03-rollout.md`](03-rollout.md).

---

## Problem statement

GeoJSON Studio is a Vue 3 SPA for viewing and editing GeoJSON, currently in active beta. All user data lives in the browser — the GeoJSON document in **IndexedDB** (via Dexie), and settings/templates/bookmarks in **`localStorage`**. There is no way to keep work across devices or browsers, and no basis for charging for a hosted service.

The Cloud epic adds **optional user accounts** with **cloud-saved work**, while leaving the existing browser-only experience untouched for users who don't sign in. The end state is a **freemium SaaS** (ADR-019): the browser-only app is a permanent **free tier**, and **cloud accounts are the paid tier** — with **paid plans** (Stripe, storage-based) built **before beta in Stripe test mode**, and live charging switched on only at go-live (ADR-030).

## Goals

- Add optional **user accounts** with **cloud-saved work** for logged-in users.
- Keep the **anonymous free-tier experience unchanged** — IndexedDB + `localStorage` continue exactly as today for users without accounts.
- **Least-effort** implementation throughout (the consistently stated priority).
- **Incremental rollout** that does not disrupt the live beta or require a big-bang cutover.
- Ship a **freemium SaaS** (ADR-019): the free tier is the browser-only app; **cloud accounts are the paid tier** (storage-based plans via Stripe) — **built before beta in test mode; charging goes live last** (ADR-007 as amended by ADR-030).

## Non-goals

- **No sync.** Logged-in users use the cloud only; anonymous users use the local browser only. The paths are independent. No CRDTs/OT/conflict resolution.
- **No server-side spatial processing.** The server treats GeoJSON as opaque blobs.
- **No replacement of the anonymous experience.** The anonymous **free tier** stays a first-class entry point (it's the free product, not a trial — ADR-019).
- **No big-bang migration.** Existing users keep their local data; any migration is opt-in per-user on first signup.
- **No separate "v2" app.** Everything ships in the existing codebases behind a flag.

## The two paths (the core idea)

The whole design follows from one decision: **two fully isolated storage paths, chosen by auth state, that never sync.**

```
                          ┌─────────────────────────────┐
                          │           Vue SPA           │
                          └──────────────┬──────────────┘
                                         │
                       auth state decides ↓
                ┌────────────────────────┴────────────────────────┐
                │                                                 │
        anonymous (default)                                logged-in
                │                                                 │
   ┌────────────┴────────────┐                    ┌───────────────┴───────────────┐
   │ IndexedDB (Dexie)       │                    │ Supabase                      │
   │   geojson_data,         │                    │   Storage — the GeoJSON blob  │
   │   backup_geojson_data   │                    │   Postgres — metadata,        │
   │ localStorage            │                    │     settings, plans           │
   │   templates, bookmarks, │                    │   Auth (JWT)                  │
   │   settings, etc.        │                    │                               │
   └─────────────────────────┘                    └───────────────────────────────┘

   Existing Node API (format conversions, Turnstile session) — unchanged for both.
```

Because the paths are isolated, a cloud bug **cannot corrupt** the anonymous path, and the anonymous path doubles as a **kill-switch / instant rollback**.

## Glossary

- **Cloud** — the user-facing name for the whole capability (accounts + cloud storage + paid plans).
- **Epic** — the umbrella body of work; decomposes into **phases** (0–9).
- **File** — the unit of saved work (one DB record per file). The plural UI is "My Files".
- **Project** — *not adopted.* Reserved for a possible future per-file-context model.
- **The flag** — a runtime URL-param feature flag (`?ff=cloud`) that reveals the login UI; ships the account code "dark" until enabled. Temporary scaffolding — retired at go-public (ADR-021).
- **Anonymous path / local path** — the existing IndexedDB + `localStorage` experience.
- **The seam(s)** — the storage-provider abstraction that lets the app swap local vs remote backends without knowing which is in use. Two of them: the **File seam** (the active GeoJSON blob) and the **Settings seam** (templates/bookmarks/prefs). See [`01-architecture.md`](01-architecture.md#4-the-storage-provider-seam).
- **Free tier / paid tier** — the freemium split (ADR-019): the **free tier** is the local/anonymous app (browser-only, permanent, no account); the **paid tier** is cloud accounts (subscription, storage-based plans). "Free trial" is a misnomer — the free tier has no time limit.
- **Landing** — the static marketing page at `/`; the editor moves to `/app` (ADR-021).
- **Account area** — the user-facing self-service page (usage, data export, delete account, manage billing). *Not* an internal admin panel — the Supabase + Stripe dashboards serve that.
- **Server layer** — cloud/payment endpoints on the existing Node API (Stripe webhook, checkout, account deletion); the "selective Node layer" of ADR-002, made concrete in ADR-020.

## Current status

Planning complete and agreed; both code repos surveyed and the docs kept reconciled. **Phases 0–5 are complete** — the File and Settings provider seams (Phase 0), Supabase Auth + login UI dark behind the flag (Phase 1), the remote file/settings round-trip with owner-only RLS (Phase 2), the multi-file "My Files" UI (Phase 3), the Node server layer — JWT-verify middleware + `service_role` admin client + account deletion — against non-prod (Phase 4), and the account area & compliance (Phase 5): client-direct storage usage + data export, a dedicated `/account` route, static privacy/terms pages, and a `user_profiles` table for terms acceptance. The anonymous/local path is unchanged throughout.

The **UI/UX revamp (rollout near-term step 3) is complete (2026-07-06)**: cloud account surfaces are dedicated routes (ADR-029) — the landing (ADR-024 Stage 1 pulled forward), a split-layout `/login` with an OAuth provider grid (Google/GitHub/Microsoft/Facebook — only Google configured in Supabase so far), `/files`, and an `/account` page with a section sidebar plus Security and Billing panels; in-app chrome (avatar menu + active-file chip); everything audited dark + responsive. **Now:** **Phase 6 — monetise** is **built and fully verified in test mode (2026-07-24)** (`plans` + `user_plans` + quota trigger; Stripe Checkout/webhook/portal; upgrade CTA + real usage bar + Customer Portal), and the tier shape is settled ([ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features): Guest / Free / Basic / Pro, storage + file-count only). **Phase 7 (re-sliced 2026-07-25, and again 2026-07-27)** runs **7a** entitlement-completion build — **built 2026-07-26, `0005` applied and verified**: the **file-count lever** (`plans.max_files` + a BEFORE-INSERT trigger + client UX), the `early_access → free` rename, monotonic seeds (`free` 30 MiB/3 files · `basic` 500 MiB/50 · `pro` 20 GiB/1000), the hidden `discount`/`god_mode` plans, and the two Phase 6 billing follow-ups (over-limit **dialog** + webhook **terminal-status revert**) → **7b** the **large-file fix**, new and the phase's biggest item: a **43 MB** import OOMs PostgREST and takes the whole project down (twice, manual restart both times) while the anonymous IndexedDB path handles the same file fine, so the blob moves from `jsonb` into **Supabase Storage** ([ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row)) — with **7b-1** (client pre-flight cap, honest error messages, the import-path quota gap, debounced autosave) shipping immediately and on its own — **built 2026-07-27, e2e green; autosave coalescing reworked 2026-07-28 after it was found losing edits on refresh — the window is now priced by save cost, and ADR-025's `beforeunload` guard came forward from 7c**; **7b-2's two gating prototypes run 2026-07-30 ([ADR-035 addendum](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row)) — publish keeps a single private bucket, and quota enforcement was decided as **Node-issued signed upload URLs** over a `storage.objects` trigger — **then 7b-2 was PAUSED on 2026-07-31 for a rethink of the whole remedy** (whole-document 50 MB writes per edit burst are not acceptable for a paid product; the quota mechanism is thinly supported), with other providers / edge functions / NoSQL documents on the table. **Nothing was built — `0006` never existed.** ADR-035's *diagnosis* is unaffected and still binds: the blob cannot stay in Postgres. **The sharpest point for the rethink: the 50 MB-per-burst objection is a write-granularity problem (`file_features`), not a provider problem** → **7c** loose ends (OAuth provider config, legal content, checkout-return notice, the landing-page pricing corrections, and the **crash-recovery journal** — [ADR-036](02-decisions.md#adr-036--local-storage-buffers-cloud-writes-the-recovery-journal-is-promoted-indexeddb-as-a-staging-area-is-rejected), local storage buffering cloud writes, promoted from the backlog 2026-07-28) → **7d** polish + the save-as/publish quick wins → **7e** the real-account verification pass + beta sign-off, kept **last** so it certifies the app as it will ship. **Phase 8 — free beta / early access** — the production-provisioning gate ([ADR-014](02-decisions.md#adr-014--separate-supabase-projects-per-environment-non-prod-set-up-first)): the point where the epic leaves non-prod for a real production Supabase project, with beta users on free `beta` plan rows; then **Phase 9 — go-live** (static landing, flag retirement, live Stripe keys). See [`05-worklog.md`](05-worklog.md) for the running status.
