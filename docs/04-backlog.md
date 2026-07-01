# 04 — Backlog (deferred / TBD)

> **Stability:** volatile. Items parked deliberately, kept visible so they aren't lost. Promote to a phase in [`03-rollout.md`](03-rollout.md) when picked up; record any resulting decision in [`02-decisions.md`](02-decisions.md).

---

## Payments (mechanics settled in ADR-007/020/022; the *commercial* shape is the user's)
- **Plan model and pricing** — the concrete **tiers, prices, and per-plan storage limits**. Settled: **free = local, paid = cloud** (ADR-019); pricing is **storage-based** (ADR-022). The actual numbers are the user's to design.
- **Entitlement enforcement is decided** (ADR-022): a **Postgres trigger** on `files` enforces the per-plan storage quota; `public.user_plans` (+ optional `plans` lookup) holds plan state, written only by the Node webhook. TBD is the limit values and any non-storage entitlements (e.g. premium tools).
- **Lifecycle edge cases** — failed payments, cancellation (what happens to a paid user's cloud files), and **downgrade-over-limit** (decided rule: block growth, allow shrink — implementation TBD).

## Storage
- **Large-file ceiling** — current plan stores GeoJSON inline in a Postgres `jsonb`/`text` column (fine for normal files). If files routinely reach tens of MB, move the blob to **Supabase Storage** and keep a metadata row. Reassess when concrete file-size data exists. Decide whether to set an explicit per-file size limit for v1. Note: since pricing is **storage-based** (ADR-022), "storage used" is measured on this inline data (Postgres DB size); moving to Supabase Storage later is a cost lever, not a change to quota enforcement.

## Data model
- **Per-file "project" model** — bundling bookmarks, basemap, map view, and styling per file instead of user-global. Adopt only if per-file context becomes the desired UX (ADR-003). Extends the file row; no restructuring.
- **Per-key settings split** — the move-to-cloud vs stay-local table (architecture §6) is a default; revisit each key during Phases 2–3 as keys are migrated.

## Auth / sessions
- **Unify the two JWTs** — the existing Turnstile session JWT (for the conversion API) and the Supabase user JWT are independent. Could be unified later so logged-in users skip the Turnstile gate on the conversion API. Not needed for v1.

## Compliance / ops
- **Privacy policy + terms of service** — required before opening accounts to real users (**now Phase 5**).
- **Account deletion + data export** — GDPR-style flows (**now Phase 5**); deletion needs the Node `service_role` (ADR-020), cascading via the `on delete cascade` FKs.
- **Backup tier** — confirm Supabase backup/retention settings when provisioning for real (Phase 4).

## Phase 3 follow-ups (deferred UI/UX & cleanup)

> Parked during the Phase 3 design ([ADR-018](02-decisions.md#adr-018--phase-3-multi-file-model-and-file-lifecycle)). None block the multi-file round-trip; pick up after 3a–3c land.

- **Import as a new named file** — import currently replaces the *active* file's content; instead create a *new* file named from the source filename (`roads.geojson` → "roads"), with an optional name-override field in the import dialog.
- **File Info metadata** — show name, created date, and last-edited date alongside the existing feature/size/bounds stats.
- **Export default filename** — default the export filename to `<file name>.geojson` rather than the generic name.
- **Drop the `backup_geojson` column** — a cleanup migration once cloud File→New is confirmed non-destructive (the column is vestigial in cloud — ADR-018).
- **Last-opened-file pointer** — persist the active file so a cold browser refresh reopens the exact file being viewed (v1 reopens the most-recently-updated row).
- **My Files at scale** — search/filter + pagination for users with many files (v1 is a simple most-recent-first list).
- **Migration dismissed-flag** — let a user permanently dismiss the first-login "save local work" prompt (v1 re-offers while cloud files == 0).
- **Open-on-read-only option** — open a file read-only rather than writable (v1 opens writable, like New/Import).
