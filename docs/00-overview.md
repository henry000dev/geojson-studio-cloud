# 00 — Overview

> **Status:** Phases 0–2 complete (seams + auth + remote file/settings round-trip). Phase 3 (multiple files — "My Files") in progress; design agreed (ADR-018). See [`05-worklog.md`](05-worklog.md).
> **Epic:** Cloud. **Brand:** "Cloud" (user-facing); "Paid Plans" is a sub-stream.
> **This doc:** the read-me-first. Problem, goals, glossary, and the two-paths summary. For the technical design see [`01-architecture.md`](01-architecture.md); for *why* each choice was made see [`02-decisions.md`](02-decisions.md); for the plan see [`03-rollout.md`](03-rollout.md).

---

## Problem statement

GeoJSON Studio is a Vue 3 SPA for viewing and editing GeoJSON, currently in active beta. All user data lives in the browser — the GeoJSON document in **IndexedDB** (via Dexie), and settings/templates/bookmarks in **`localStorage`**. There is no way to keep work across devices or browsers, and no basis for charging for a hosted service.

The Cloud epic adds **optional user accounts** with **cloud-saved work**, while leaving the existing browser-only experience untouched for users who don't sign in. The end state is a **freemium SaaS** (ADR-019): the browser-only app is a permanent **free tier**, and **cloud accounts are the paid tier** — with **paid plans** (Stripe, storage-based) deferred to the final phase.

## Goals

- Add optional **user accounts** with **cloud-saved work** for logged-in users.
- Keep the **anonymous free-tier experience unchanged** — IndexedDB + `localStorage` continue exactly as today for users without accounts.
- **Least-effort** implementation throughout (the consistently stated priority).
- **Incremental rollout** that does not disrupt the live beta or require a big-bang cutover.
- Ship a **freemium SaaS** (ADR-019): the free tier is the browser-only app; **cloud accounts are the paid tier** (storage-based plans via Stripe), **deferred to the final phase**.

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
   │   geojson_data,         │                    │   Postgres tables             │
   │   backup_geojson_data   │                    │   Auth (JWT)                  │
   │ localStorage            │                    │   (Storage only if needed)    │
   │   templates, bookmarks, │                    │                               │
   │   settings, etc.        │                    │                               │
   └─────────────────────────┘                    └───────────────────────────────┘

   Existing Node API (format conversions, Turnstile session) — unchanged for both.
```

Because the paths are isolated, a cloud bug **cannot corrupt** the anonymous path, and the anonymous path doubles as a **kill-switch / instant rollback**.

## Glossary

- **Cloud** — the user-facing name for the whole capability (accounts + cloud storage + paid plans).
- **Epic** — the umbrella body of work; decomposes into **phases** (0–8).
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

Planning complete and agreed; the `geojson-studio-app` code surveyed and docs reconciled (2026-06-25). **Phases 0–2 are complete** — the File and Settings provider seams (Phase 0), Supabase Auth + login UI dark behind the flag (Phase 1), and the remote file/settings round-trip with owner-only RLS (Phase 2) are all in place; the anonymous/local path is unchanged. **Phase 3 (multiple files — "My Files") is in progress** — design agreed and recorded as [ADR-018](02-decisions.md#adr-018--phase-3-multi-file-model-and-file-lifecycle). See [`05-worklog.md`](05-worklog.md) for the running status.
