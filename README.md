# geojson-studio-cloud

Planning, design, and shared substrate for the **Cloud epic** — adding user accounts, cloud storage, and (later) paid plans to GeoJSON Studio.

This repository sits alongside the two code repositories and belongs to neither:

```
geojson-studio/
  geojson-studio-app/        <- Vue SPA frontend (its own repo)
  geojson-studio-api/        <- Node.js backend (its own repo)
  geojson-studio-resources/  <- shared non-code assets (Bruno, Data)
  geojson-studio-cloud/      <- THIS repo: Cloud epic docs + (later) Supabase schema/migrations
```

It is the home for things that belong to neither app nor api: the design docs below, and — as the work progresses — the Supabase SQL schema, RLS policies, migrations, and entitlements config.

## Documents

Read in this order; the first three are the stable "truth", the last three change often.

| Doc | Stability | Purpose |
|---|---|---|
| [`docs/00-overview.md`](docs/00-overview.md) | stable-ish | Start here. Problem, goals/non-goals, glossary, the two-paths summary. |
| [`docs/01-architecture.md`](docs/01-architecture.md) | **stable** | The technical design: paths, Supabase, RLS, the storage seam, data model. |
| [`docs/02-decisions.md`](docs/02-decisions.md) | **stable** (append-only) | ADR log — every major decision with its rationale and rejected alternatives. |
| [`docs/03-rollout.md`](docs/03-rollout.md) | volatile | Branch strategy, the phased plan (0–5), feature-flag mechanics. |
| [`docs/04-backlog.md`](docs/04-backlog.md) | volatile | Deferred / TBD items kept visible. |
| [`docs/05-worklog.md`](docs/05-worklog.md) | volatile | Dated "what's done / where I left off" log. Read this first on resuming. |

## Conventions

- The user-facing brand for this capability is **"Cloud"**. "Paid Plans" is a sub-stream within it.
- The body of work is referred to as the **Cloud epic**; it decomposes into **phases** (see rollout).
- British English in prose (matching the app repo conventions).
