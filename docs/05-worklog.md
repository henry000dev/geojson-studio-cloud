# 05 — Worklog

> **Stability:** volatile. A dated, append-at-top log of what's been done and where things were left. **Read this first on resuming.** Newest entry at the top.

---

## 2026-06-23 — Planning complete; planning repo set up

- Agreed the full architecture and rollout for the Cloud epic (see [`00-overview.md`](00-overview.md) through [`04-backlog.md`](04-backlog.md)).
- Named the effort the **Cloud epic**; brand is **"Cloud"**; this planning repo is **`geojson-studio-cloud`**, a sibling to app/api/resources.
- Wrote the doc set: overview, architecture, decisions (ADR-001…009), rollout, backlog, this worklog.
- **Status:** parked, pre-implementation. No code written in either code repo yet.

### Where to resume
- **Next action:** Phase 0 — introduce the document-storage and settings-KV provider seams as a behaviour-preserving no-op; validate by the existing Playwright suite passing unchanged. See [`03-rollout.md`](03-rollout.md#phase-0--branch-by-abstraction-no-flag-no-user-visible-change).

### Outstanding setup tasks (manual, not yet done)
- `git init` this repo and make the first commit.
- Add a one-line pointer in `geojson-studio-app/CLAUDE.md` and the api equivalent back to this repo.
- Decide whether to relocate `geojson-studio-app/docs/cloud-accounts-plan.md` content here and replace it with a pointer (recommended, to avoid two diverging copies).
