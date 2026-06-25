# 05 — Worklog

> **Stability:** volatile. A dated, append-at-top log of what's been done and where things were left. **Read this first on resuming.** Newest entry at the top.

---

## 2026-06-25 — Pre-Phase-0 code survey; docs reconciled; starting the seams

Surveyed the actual `geojson-studio-app` `staging` branch before writing any code, and reconciled the design docs with what's really there:

- **File seam (was "Document seam" — renamed for consistency with the "file" glossary term):** 4 direct `dexieStorage` importers — `file-service`, `map-utils`, `MapView`, `draw-manager`. `auto-save-service` is **already decoupled** via constructor injection, so it rides along when `draw-manager` injects the provider. (The doc previously said "~5 sites", lumping auto-save in as a direct importer.)
- **Settings seam:** 45 direct `localStorage` calls across 12 files (doc said 43/11). `undo-new-file-toast.js` is new since the original survey; `features-list.js` only mentions `localStorage` in comments (not a call site). `session.js` (6 calls) stays on raw `localStorage`, outside the seam.
- **Key finding:** the settings seam must be **synchronous** — Pinia stores read `localStorage` in their sync `state()` factories, so an async seam would change store semantics and break the no-op. Recorded as **ADR-010**; the session-stays-local refinement is **ADR-011**.

Updated `00-overview.md` (status + glossary), `01-architecture.md` (§4 + appendix; "Document seam" → "File seam"), `03-rollout.md` (Phase 0), and appended ADR-010/011 to `02-decisions.md`.

### Where to resume
- **Next action:** Phase 0, Step 1 — add `src/services/storage/file-storage.js` wrapping `dexieStorage`, repoint the 4 importers (+ `draw-manager`'s injection into `AutoSaveService`). Branch `feat/cloud-step0-seam` off `staging`. Then the settings seam in per-store batches. Validate with the Playwright e2e suite (`npm run test:e2e`).

---

## 2026-06-23 — Planning complete; planning repo set up

- Agreed the full architecture and rollout for the Cloud epic (see [`00-overview.md`](00-overview.md) through [`04-backlog.md`](04-backlog.md)).
- Named the effort the **Cloud epic**; brand is **"Cloud"**; this planning repo is **`geojson-studio-cloud`**, a sibling to app/api/resources.
- Wrote the doc set: overview, architecture, decisions (ADR-001…009), rollout, backlog, this worklog.
- **Status:** parked, pre-implementation. No code written in either code repo yet.

### Setup tasks — all done
- ✅ `git init`, first commit, pushed to remote.
- ✅ Back-pointers added: `geojson-studio-app/CLAUDE.md` and `geojson-studio-api/CLAUDE.md` each reference `../geojson-studio-cloud` (with a "read before working on accounts/auth/cloud-storage" trigger). The pre-existing app↔api sibling pointers were kept.
- ✅ `geojson-studio-app/docs/cloud-accounts-plan.md` reduced to a one-line redirect to this repo (superseded by this doc set).

### Where to resume
- **Next action:** Phase 0 — introduce the document-storage and settings-KV provider seams as a behaviour-preserving no-op; validate by the existing Playwright suite passing unchanged. See [`03-rollout.md`](03-rollout.md#phase-0--branch-by-abstraction-no-flag-no-user-visible-change).
