# 04 — Backlog (deferred / TBD)

> **Stability:** volatile. Items parked deliberately, kept visible so they aren't lost. Promote to a phase in [`03-rollout.md`](03-rollout.md) when picked up; record any resulting decision in [`02-decisions.md`](02-decisions.md).

---

## Payments
- **Plan model and pricing** — tiers, what's free vs paid, trial behaviour. (Stripe mechanics are settled in ADR-007; the *commercial* shape is not.)
- **Entitlements** — concrete quotas (file count, file size, premium tools) and how each is enforced (RLS/Postgres function vs the selective Node layer).
- **Lifecycle edge cases** — failed payments, downgrades, what happens to a paid user's cloud files on cancellation.

## Storage
- **Large-file ceiling** — current plan stores GeoJSON inline in a Postgres `jsonb`/`text` column (fine for normal files). If files routinely reach tens of MB, move the blob to **Supabase Storage** and keep a metadata row. Reassess when concrete file-size data exists. Decide whether to set an explicit per-file size limit for v1.

## Data model
- **Per-file "project" model** — bundling bookmarks, basemap, map view, and styling per file instead of user-global. Adopt only if per-file context becomes the desired UX (ADR-003). Extends the file row; no restructuring.
- **Per-key settings split** — the move-to-cloud vs stay-local table (architecture §6) is a default; revisit each key during Phases 2–3 as keys are migrated.

## Auth / sessions
- **Unify the two JWTs** — the existing Turnstile session JWT (for the conversion API) and the Supabase user JWT are independent. Could be unified later so logged-in users skip the Turnstile gate on the conversion API. Not needed for v1.

## Compliance / ops
- **Privacy policy + terms of service** — required before opening accounts to real users.
- **Account deletion + data export** — GDPR-style flows; define and implement before/at the beta.
- **Backup tier** — confirm Supabase backup/retention settings when provisioning for real.

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
