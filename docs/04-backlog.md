# 04 — Backlog (deferred / TBD)

> **Stability:** volatile. Items parked deliberately, kept visible so they aren't lost. Promote to a phase in [`03-rollout.md`](03-rollout.md) when picked up; record any resulting decision in [`02-decisions.md`](02-decisions.md).

---

## Payments (mechanics settled in ADR-007/020/022; the *commercial* shape is the user's)
- **Plan model and pricing** — the concrete **tiers, prices, and per-plan storage limits**. Settled: **free = local, paid = cloud** (ADR-019); pricing is **storage-based** (ADR-022). The actual numbers are the user's to design.
- **Entitlement enforcement is decided** (ADR-022): a **Postgres trigger** on `user_files` enforces the per-plan storage quota; `public.user_plans` (+ optional `plans` lookup) holds plan state, written only by the Node webhook. TBD is the limit values and any non-storage entitlements (e.g. premium tools).
- **Lifecycle edge cases** — failed payments, cancellation (what happens to a paid user's cloud files), and **downgrade-over-limit** (decided rule: block growth, allow shrink — implementation TBD).

## Storage
- **Per-file size limit (likely for v1)** — GeoJSON Studio is an **editor**; by nature it isn't meant to handle very large files. A max-file-size restriction is probably warranted regardless of the storage backend. **Pending the user's own large-file testing** to pick the ceiling. This also bounds the whole-document write cost (below) and the storage-quota math (ADR-022).
- **Large-file ceiling** — current plan stores GeoJSON inline in a Postgres `jsonb`/`text` column (fine for normal files). If files routinely reach tens of MB, move the blob to **Supabase Storage** and keep a metadata row. Reassess when concrete file-size data exists. Note: since pricing is **storage-based** (ADR-022), "storage used" is measured on this inline data (Postgres DB size); moving to Supabase Storage later is a cost lever, not a change to quota enforcement.
- **Write granularity — whole-document vs deltas** — v1 sends the **entire FeatureCollection** on save (matches the inline-`jsonb` model; simplest; client-direct + RLS intact). Deltas only pay off *at scale* and — crucially — a delta *transport* over blob *storage* saves upload bytes but **not** DB write cost (Postgres rewrites the whole TOAST'd value anyway). Real delta benefit requires a different data model: **one row per feature** (`file_features`), where add/delete/modify become INSERT/UPDATE/DELETE. If ever needed, prefer **client-direct RPC / per-row `supabase-js`** over dedicated Node endpoints (ADR-002 — endpoints reintroduce a hop + re-implement RLS). Two divergent large-file strategies to keep distinct: **blob externalization** (Supabase Storage — keeps whole-doc writes) vs **per-feature rows** (enables deltas). Deferred pending real file-size data; a per-file size limit (above) may make this moot.

## Data model
- **Per-file "project" model** — bundling bookmarks, basemap, map view, and styling per file instead of user-global. Adopt only if per-file context becomes the desired UX (ADR-003). Extends the file row; no restructuring.
- **Per-key settings split** — the move-to-cloud vs stay-local table (architecture §6) is a default; revisit each key during Phases 2–3 as keys are migrated.

## Resilience
- **Crash-recovery journal (Level 2)** — beyond v1's Level 1 (retry + reconnect flush + save-status + `beforeunload`; ADR-025), persist the pending unsaved cloud state to a small IndexedDB buffer keyed by file id, cleared on each successful save; on the next load, detect an orphaned buffer and offer "Recover unsaved changes?" Covers the "tab closed while offline" case. This is a **deliberate, scoped exception to ADR-004** (one-way, self-clearing recovery journal — *not* a sync path). Build only if users actually report lost work.

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
- **Last-opened-file pointer** — persist the active file so a cold browser refresh reopens the exact file being viewed (v1 reopens the most-recently-updated row).
- **My Files at scale** — search/filter + pagination for users with many files (v1 is a simple most-recent-first list).
- **Migration dismissed-flag** — let a user permanently dismiss the first-login "save local work" prompt (v1 re-offers while cloud files == 0).
- **Open-on-read-only option** — open a file read-only rather than writable (v1 opens writable, like New/Import).
