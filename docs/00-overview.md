# 00 — Overview

> **Status:** implementation underway — Phase 0 (provider seams). See [`05-worklog.md`](05-worklog.md) for current state.
> **Epic:** Cloud. **Brand:** "Cloud" (user-facing); "Paid Plans" is a sub-stream.
> **This doc:** the read-me-first. Problem, goals, glossary, and the two-paths summary. For the technical design see [`01-architecture.md`](01-architecture.md); for *why* each choice was made see [`02-decisions.md`](02-decisions.md); for the plan see [`03-rollout.md`](03-rollout.md).

---

## Problem statement

GeoJSON Studio is a Vue 3 SPA for viewing and editing GeoJSON, currently in active beta. All user data lives in the browser — the GeoJSON document in **IndexedDB** (via Dexie), and settings/templates/bookmarks in **`localStorage`**. There is no way to keep work across devices or browsers, and no basis for charging for a hosted service.

The Cloud epic adds **optional user accounts** with **cloud-saved work**, while leaving the existing browser-only experience untouched for users who don't sign in. It also lays the foundation for **paid plans** (deferred to last).

## Goals

- Add optional **user accounts** with **cloud-saved work** for logged-in users.
- Keep the **anonymous/trial experience unchanged** — IndexedDB + `localStorage` continue exactly as today for users without accounts.
- **Least-effort** implementation throughout (the consistently stated priority).
- **Incremental rollout** that does not disrupt the live beta or require a big-bang cutover.
- Lay the groundwork for **paid plans**, deferred to the final phase.

## Non-goals

- **No sync.** Logged-in users use the cloud only; anonymous users use the local browser only. The paths are independent. No CRDTs/OT/conflict resolution.
- **No server-side spatial processing.** The server treats GeoJSON as opaque blobs.
- **No replacement of the anonymous experience.** Anonymous trial stays a first-class entry point.
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
- **Epic** — the umbrella body of work; decomposes into **phases** (0–5).
- **File** — the unit of saved work (one DB record per file). The plural UI is "My Files".
- **Project** — *not adopted.* Reserved for a possible future per-file-context model.
- **The flag** — a runtime URL-param feature flag that reveals the login UI; ships the account code "dark" until enabled.
- **Anonymous path / local path** — the existing IndexedDB + `localStorage` experience.
- **The seam(s)** — the storage-provider abstraction that lets the app swap local vs remote backends without knowing which is in use. Two of them: the **File seam** (the active GeoJSON blob) and the **Settings seam** (templates/bookmarks/prefs). See [`01-architecture.md`](01-architecture.md#4-the-storage-provider-seam).

## Current status

Planning complete and agreed; the `geojson-studio-app` code has been surveyed and the docs reconciled to it (2026-06-25). **Phase 0 is in progress** — introducing the File and Settings provider seams as a behaviour-preserving no-op, validated by the existing Playwright suite passing unchanged. See [`05-worklog.md`](05-worklog.md) for the running status.
