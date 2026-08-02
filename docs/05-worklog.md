# 05 — Worklog

> **Stability:** volatile. A dated, append-at-top log of what's been done and where things were left. **Read this first on resuming.** Newest entry at the top.

---

## 2026-08-02 — first smoke tests pass; non-prod reset to zero

**The slice does the thing it was built to do.** User-run smoke tests on the cloud path:

- **The 43 MB file edits without crashing and without server errors** — the failure that ADR-035 exists to remove, and the reason the whole snapshot+delta model was designed. This is the slice's headline claim and it now has evidence behind it.
- **Two tabs behave** — the lock, the dialog and the takeover all work against a real second tab.
- **Rapid point creation is fine**, where it previously was not.

Two rough edges left open by agreement, both to be picked up later: an **occasional "invalid feature" error on refresh** after rapidly creating points (the likeliest suspect is a delta written for a feature gl-draw had not finished assigning an id to — worth checking `deltaFeatureId` returning null against a half-built feature before assuming anything harder), and the pre-existing files that read blank.

The change buffer is `public.file_edits`, named for what a row is to the person who made it rather than for its role in the model, where it is a **delta**. The two words mean the same thing throughout — the model's vocabulary (`delta-model.js`, `delta-session.js`, ADR-037) is unchanged. The local Dexie store matches it (`fileEdits`, schema version 3).

### Non-prod reset to zero

**Everything was nuked and the migration chain replayed from an empty database** — all Storage objects, all `public` tables and functions, and all accounts. Prototype state had accumulated through 7b's two redesigns and there is only one developer, so the cost was zero and it clears out several half-answered questions at once, including the two pre-existing files that read blank (they were the last content in `user_files.geojson`; the question of a read-fallback bridge is now moot and **withdrawn**).

Because a lot of manual testing is coming, the procedure was extracted rather than left inline: **[`docs/RESET.md`](RESET.md)** (the steps, most of which are not SQL) and **[`supabase/scripts/reset-non-prod.sql`](../supabase/scripts/reset-non-prod.sql)** (the SQL, in two selectable sections — *data only* for the everyday loop, *full teardown* when a migration changes).

**The script is deliberately NOT in `supabase/migrations/`.** That directory is applied in filename order and is documented as `supabase db push`-compatible, so a nuke script numbered into it — `9999_`, `0007_`, anything — would eventually run as the last step of a deploy. It lives in `supabase/scripts/`, which nothing applies automatically.

It also carries a **forward-dated guard**: section 0 aborts if `public.production_marker` exists. That table does not exist yet and the check passes silently, so it costs nothing today — the point is that the protection is already in place on the day it starts to matter, rather than being remembered at the moment it is most needed. **Phase 9 provisioning must create that marker before applying any migration**; it is noted in `RESET.md`.

Two things worth knowing before the next reset:

- **Storage objects cannot be deleted in SQL** — `storage.protect_delete()` rejects a direct `DELETE` on `storage.objects` with `42501`, so the dashboard (or the Storage API) is the only route. This is the same constraint that makes the account-deletion sweep mandatory, met here in person rather than in a prototype.
- **The `auth.users` trigger must be dropped before `public.user_plans`.** `on_auth_user_created` references that table, and dropping it out from under the trigger breaks every future signup rather than failing loudly at drop time.

**The replay is worth more than the cleanup.** These migrations have been amended in place throughout, so the chain had never actually been run end to end against an empty database — and Phase 9 provisioning depends on precisely that. A clean replay is the first evidence it works.

App builds clean; chunking unchanged.

### Where to resume

Everything below still stands except the two-tab test and the 43 MB check (both done) and the blank pre-existing files (gone with the reset). So: **sign up fresh** and re-run the end-to-end path on an empty account, then the account-deletion Storage sweep (unbuilt, a compliance obligation), the kilobytes-not-megabytes measurement, two-account isolation, and the "invalid feature" refresh error.

---

## 2026-08-01 (fourth entry) — `0006` applied and verified; the Web Lock wired

**`0006` is applied to non-prod and all SQL-runnable checks pass**, including the **`seq`-bump stop-work check** (`PASS — the trigger bumped the seq`), the `anon` lockout, and the reworked usage view (a user with 2 files and **0 bytes** — correct, because bytes measure the *snapshot* and none has been uploaded yet).

**One snag in the README's own check, worth keeping.** The first version of the seq probe ran the seed and the upsert as two data-modifying CTEs in one statement and failed with `21000: ON CONFLICT DO UPDATE command cannot affect row a second time`. All CTEs in a statement share one snapshot, so the second write cannot see the row the first inserted — **the seed has to commit before the upsert can conflict with it**. Rewritten as two statements: a plain `INSERT`, then the real upsert with a `before` CTE reading the pre-update snapshot so both seqs are comparable in one result row. Cleanup was moved to a separate run so a trailing `DELETE` cannot swallow the verdict.

### Flagged: existing cloud files read blank

The account's two pre-existing files hold their content in `user_files.geojson`, and the new read path does not look there — it downloads from Storage, finds nothing, finds no deltas, and returns null. **Those files open blank.** Nothing is destroyed (the column is untouched), but the editor will not show them and editing one writes a fresh snapshot over the top.

**A read-fallback to the old column was deliberately NOT added.** It would be about ten lines and would die in 7b-3 anyway, but during the exact phase where the Storage path is being proven, a silent fallback would make a **broken upload look like a working read**. The recommendation instead is to `select geojson from user_files`, keep the text, and re-import through the app — which writes it properly to Storage and doubles as the first real end-to-end test. Offer stands if the user would rather have the bridge.

### The Web Lock, wired

Both UX calls settled by the user, both the recommended option:

- **Second tab → blocked with a dialog.** The file is **not loaded**: the editor stays empty behind `FileLockedDialog`, so nobody is ever drawing on a document that was never theirs to save. Buttons: **My Files** / **Take over**.
- **After takeover, the old tab → read-only with a banner**, document still on screen. Nothing vanishing while the user looks at it.

New: `constants/file-lock-constants.js`, `stores/file-lock.js`, `components/file/FileLockedDialog.vue`. Wired in `MapView.vue` (acquire before `initialiseFile`, a watch that turns the superseded tab read-only, reload-after-takeover), `AppStatusbar.vue` (the banner + Reload, extending the existing Read-Only indicator rather than inventing a new surface), and `stores/auth.js` (release on sign-out, beside the delta-session clear).

**Three decisions inside it worth not re-litigating:**

- **"Go to the other tab" is not offered**, though it was the obvious third button. There is no reliable way to focus another tab from script — `window.focus()` on a tab the user has not just interacted with is ignored by every current browser. **A button that silently does nothing is worse than no button**, so the message names the situation and lets the user switch tabs themselves.
- **The lock is acquired BEFORE the file loads**, which meant resolving the active file earlier than the seam would have. `ensureResolved()` is idempotent and runs its query once, so this costs nothing — and it is the only ordering where "blocked" can mean *never loaded* rather than *loaded then taken away*.
- **`close-on-escape` is set explicitly to false.** The dialog has no close button and its `v-model` setter is a no-op, so an Escape that got through would hide it **without changing the state that renders it** — leaving a blank editor with no way back. Cheap belt-and-braces rather than trusting PrimeVue's closable/escape coupling.

**The takeover handshake, and why it is clean here in a way a server lease never is:** both tabs are alive and can talk. The departing tab **checkpoints, then releases, then goes read-only** — so nothing is stranded in its buffer — where a lease takeover can only assume the previous holder is gone and hope it left nothing behind. The checkpoint is best-effort: if it fails the deltas are still durable and the arriving tab reconstructs from them, and refusing to hand over because a tidy-up failed would strand the user in the other tab. The 15 s takeover timeout is generous on purpose, because the departing tab may be uploading a large snapshot on its way out.

**Note the boundary-checkpoint finding from the previous entry does *not* apply here.** That one was about a file switch racing a *different* document into the draw manager. A yielding tab keeps its document and goes read-only, so there is no incoming load to race — the checkpoint is safe and genuinely useful.

### Where to resume

1. **Rescue the two existing files** (or accept losing them), then the **first real end-to-end run**: import → edit → reload → export on the cloud path. Nothing in the app has yet executed against a live `file_edits` row or a real Storage object.
2. **Two-tab test:** second tab refused; take over; old tab goes read-only; crashed tab (kill it) leaves no stale lock.
3. **Still unbuilt and a compliance obligation:** the `{user_id}/` Storage sweep on `POST /api/v1/account/delete`.
4. Then the rest of 7b-2's confirm-as-you-go list — the 43 MB file, the kilobytes-not-megabytes check, two-account isolation on `storage.objects` **and** `file_edits`.

---


## 2026-08-01 (third entry) — 7b-2 BUILD BEGINS: `0006` written, the delta model and both backends built, edit sites emitting deltas

**First code of the slice.** The migration is written but **not yet applied** — that is the user's next action. App builds clean; the Supabase SDK is still out of the main bundle (`supabase-client` remains its own chunk).

### What landed

**Cloud repo — `supabase/migrations/0006_snapshot_and_deltas.sql`** (new): the private `user-files` bucket (`public = false`, `file_size_limit` **50000000**, MIME sanity list), four owner-only `storage.objects` policies keyed on the `{user_id}/` path prefix, **`public.file_edits`** (`seq bigserial`, `feature_id` **text**, unique on `(file_id, feature_id)`, owner-only RLS), **`user_files.snapshot_seq`**, and `user_storage_usage` reworked to read Storage bytes via a full outer join with a **regex guard** on the path segment (prototype P2's finding — an exception inside the view would break the usage read for everyone). The migrations README gains a verification block, including a **stop-work check on the `seq` bump**.

> **The `seq` bump lives in a `BEFORE UPDATE` trigger, not in the statement.** PostgREST builds its own `on conflict do update set …` from the columns it is given and cannot be made to call `nextval()`. A trigger gets the same result from any writer, which is the safer home for an invariant this load-bearing anyway.

**App repo** — the model, both backends, the seam, and the edit sites:

- **`delta-model.js`** (new, pure — no I/O): `applyDeltas` (the read half), `dedupeDeltas`, `deltaFeatureId`, and **`reconcileDeltas`**.
- **`delta-session.js`** (new): the incorporated-seq bookkeeping, the contiguous watermark, and the presence signal.
- **`remote-file-storage.js`**: rewritten around Storage + `file_edits`. `getDocument` / `applyChanges` / `checkpoint` / `writeDocument` / `clearDocument`. The old Postgres blob path is retained as commented dead code, no flag, per the 2026-07-27 call.
- **`browser-file-storage.js`**: the same model in Dexie (schema **v3**, `fileEdits: "++seq, &[fileId+featureId], fileId"`). No upgrade callback needed — an existing record is a complete snapshot with no deltas outstanding, which *is* watermark 0 and an empty buffer.
- **`file-storage.js`**: the seam, now the enforcement point for the invariant.
- **`auto-save-service.js`**: rewritten to emit deltas and schedule checkpoints.
- **`undo-redo-service.js`**: `undo()`/`redo()` now return `{ operationType, affectedIds }`.
- **`draw-manager.js`**: all eight `scheduleSave()` call sites now report the features they touched; `loadGeoJsonFile` re-baselines the reconciler.
- **`file-lock.js`** (new): the Web Locks + `BroadcastChannel` mechanism. **Not yet wired to any UI** — see *Where to resume*.

### The four findings worth keeping

**1. The watermark has the same trap as the delete predicate, and nobody had noticed.** The addendum written yesterday establishes that a checkpoint's delete must be a **set**, never `seq <= max`. But `snapshot_seq` **is a scalar**, and it advertises the same information to readers — so writing `max(incorporated)` reintroduces the identical bug at the other end: a session holding `{11,12,13,15}` claiming 15 makes every future reader **skip 14**. The fix is to advance only to the top of the unbroken run (**13**), after which readers re-fetch 15 and apply it twice — **harmless precisely because deltas are assignments.** *This is the second place that rule has paid for itself, and neither payoff was anticipated when it was chosen.* Recorded as [ADR-037 addendum 2](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired).

**2. The delete rule protects the deltas but not the snapshot — a checkpoint needs a compare-and-set too.** The incorporated-set delete stops A destroying B's *delta rows*. It says nothing about the *object*: B, holding a base A has already replaced, would upload its document over A's snapshot wholesale. So the watermark update carries `where snapshot_seq = <the base I read>`, and **a checkpoint that loses the CAS must not delete any deltas.** Nothing is lost when it loses — the deltas keep flowing, the buffer just is not tidied by that session.

**3. Checkpointing on file switch / sign-out is wrong, not merely expensive — withdrawn.** It was on the planned trigger list. A checkpoint reads the current document *out of the draw manager*, and a file switch is about to load a **different** document into that same draw manager: un-awaited, it uploads the incoming file's contents as the **outgoing file's snapshot**. Awaiting it instead blocks the switch on a whole-document upload and buys nothing, because the deltas are already durable. **Idle + buffer-width are the triggers**, plus the mandatory checkpoint before anything reads the object directly. The flush at those boundaries is untouched and still load-bearing.

**4. A safety net was added that the plan did not have, because the failure it prevents is silent.** Edit sites report what they touched — the precise signal, and ADR-037 was right that the app already knows it. But there are twenty-odd draw modes, and *auditing every one once is not the same as keeping every one correct forever*; a site that forgets to report would have its edit vanish at the next checkpoint with nothing to notice at the time. So `reconcileDeltas` also compares the document's feature-id set against the last persisted one: **an id that appeared is an upsert, an id that vanished is a delete**, regardless of what anyone reported. Costs `O(features)` in Set operations — no serialising, no deep compare. **The one gap it cannot close** is a *modification* to a still-present feature that nobody reported, since catching that needs the whole-document compare this design exists to remove. That gap is why **undo/redo now return their affected ids**: undoing a geometry move is exactly that shape, and it was the one real hole.

### Deviations from the plan, all deliberate

- **7b-1's adaptive coalescing window was deleted now rather than in 7b-3.** `lastSaveDurationMs`, `lastSaveIsCheap()`, `SAVE_IS_CHEAP_BELOW_MS` and the leading-edge branch all priced a trade — data loss against bandwidth — that stops existing once an edit is durable for a few hundred bytes. Leaving it would have meant shipping a mechanism whose entire documented rationale is void. A plain 250 ms rate limit remains. **The two durable lessons are kept verbatim in the file**: price a window by what a save costs, not by which path it takes; and never treat a page-hide flush as the reason a window is safe to widen.
- **Page-hide now flushes deltas and deliberately does *not* checkpoint.** For the first time the teardown write is small enough to have a realistic chance of landing. It is still not a guarantee.
- **The Web Lock service is built but not wired.** The mechanism is the hard part and is done; the dialog ("already open in another tab" + go-to-it / take-over) and read-only mode are UI with product decisions in them. Left inert rather than half-wired — nothing calls it, so there is no broken state.

### Verification so far

- `npm run build` clean; `supabase-client` still a separate chunk.
- The two pure modules were exercised directly against **13 assertions**, including the two-device race end to end: A opens at 10, writes 13 and 15, B writes 14 — A's captured set is `{13,15}`, **14 is never deleted**, the watermark advances to **10** (not 15), and an edit written during the upload stays owed to the next checkpoint. Replaying the same deltas twice is proven to be a no-op.
- **Not run:** the e2e suite (the user runs it), and nothing at all against a live Supabase project — `0006` has not been applied.

### Where to resume

1. **Apply `0006` to non-prod** and work through the migrations README verification block. **The `seq`-bump check is a stop-work**: if an updated row comes back with the same seq, the trigger did not fire and a checkpoint would delete a row another session had re-edited.
2. **Wire the Web Lock** — the dialog, take-over, and read-only mode.
3. **Then the confirm-as-you-go list** in rollout 7b-2: a 43 MB file imports/edits/reloads/exports without taking the project down; an edit burst on a 40 MB file uploads **kilobytes**; two-account isolation on `storage.objects` **and** `file_edits`; account deletion leaves no objects (the sweep on `POST /api/v1/account/delete` is **still unbuilt** and is a compliance obligation).
4. **Still open from before:** whether the usage figure shows snapshot bytes or snapshot + pending deltas (built as **snapshot bytes**, the simpler call — it is UX, not a gate); the 7a behavioural confirm-as-you-go checks.

**Two verifications from the previous entry are now closed, both by code trace.** Duplicate feature ids **block** rather than warn — `file-service.js:146` throws on import, `GeometryAddDialog.vue:219` blocks the add path — which is what the delta model needs, since two features sharing an id make a delta ambiguous. And ids are **not user-editable**: the root `id` is never surfaced in the UI, and the preserved copy at `properties[geojsonstudio-user-supplied-id]` is hidden from the properties editor by `filterOutSystemProperties`. Noted while there: `getFeatureId()` accepts `ID`/`Id`/`iD` while GL Draw keys on lowercase `id`, so the delta path uses `feature.id` alone, as ADR-037 requires.

---


## 2026-08-01 (second entry) — multi-session settled: a Web Lock for tabs, no server lease, safe delete retained

**Discussion only — no code.** The one item ADR-037 left open is closed. Recorded as the [ADR-037 addendum](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired).

**The user's framing was a product one and it's the right call:** *editing the same file from multiple tabs or devices is not supported*, said plainly in the UI, with support as a possible later feature. The question I was asked was whether locking would let us delete the concurrency machinery and get back to autosave faster.

**The answer was "mostly yes, but not the bit you'd expect."**

**The safe delete does not cost anything, so locking it away saves nothing.** A checkpoint has to know which deltas to remove regardless — so the safe and unsafe forms are the same code with a different `WHERE`. Dropping it would save zero lines while shipping a known data-loss path, and it is forward-compatible: add a lease later and the defensive branch just stops firing. The reverse — unsafe now, lease later — means relying on a lock being perfect to cover a bug we chose to keep. **This is the one thing I pushed back on and the user accepted it.**

**A server lease is not airtight, and its leak is a flow we already committed to.** Any lease needs an expiry or a crashed tab locks a user out of their own file. Any expiry opens a window where a lapsed session returns and writes — which is **exactly the offline-outbox drain**. So lease and outbox interact badly by construction, and a lease would not even let the divergence guard be deleted, because take-over recreates the same divergence. Deferred to the backlog.

**Where the real simplification was: split by *where* the second session is.**
- **Same browser** — the **Web Locks API** is a genuine lock and genuinely cheap. Per-origin, and the browser **auto-releases on tab close or crash**: no lease column, no heartbeat, no TTL, and no stale-lock problem, which is the thing that makes server leases tiresome. Take-over coordinates over `BroadcastChannel`. **This is the case users actually hit** — one person, forgotten second tab.
- **Cross-device** — warned, not blocked. Nothing is destroyed (the safe delete), and the blast radius is a single feature rather than a whole document.

**Presence turned out to be free.** No heartbeat, no lease table: **deltas newer than the snapshot that this session did not write** already mean someone else has been editing. That drives both warnings — on open and on write/checkpoint.

**Then the mechanics question — "how does a tab know which edits it wrote?" — which was sharper than it looked.** The identity is the delta's `seq`, returned by Postgres on write. Three details, each wrong in its obvious form:

1. **Capture the set when the document is *serialised*,** not when the upload completes — otherwise edits made during the upload get deleted.
2. **A set, not a high-water mark.** A opens at 10 and writes 13, B writes 14, A writes 15 → A's set is `{11,12,13,15}` and never included 14, which `seq <= 15` would delete.
3. **Not a writer/session id.** It would delete the session's own post-serialise writes, *and* never clean up deltas inherited at open — so the buffer would accumulate orphans forever. This one looks like the obvious simplification and is the worst of the three.

**And a schema consequence that makes the whole thing work:** the dedup upsert must **bump `seq`**, never preserve it. That is what makes delete-by-exact-seq safe with no special case — a row another session has since re-edited carries a new `seq`, doesn't match, and survives. **The conservative behaviour falls out of the design rather than being coded for**, which is the sign the seq-set choice is the right one.

**The honest gap, accepted deliberately:** on a second device a user can watch an edit to a shared feature revert after a reload. Bounded to features both people touched, explained by the warnings, and closed properly only by the deferred lease.

**Docs updated:** ADR-037 addendum (product position, Web Lock, deferred lease, the three delete mechanics, the `seq`-bump); architecture §4a gains a *Multi-session* subsection with the behaviour table and the incorporated-set rule, plus a schema note on the upsert; rollout 7b-2 gains the Web Lock and the expanded delete rule, 7c's multi-session item re-scoped to the cross-device warnings, confirm-as-you-go extended (second tab refused, crashed tab leaves no stale lock, cross-device loses nothing); backlog gains a **Multi-session / concurrent editing** section holding the deferred lease.

### Where to resume
- **Unchanged and still next: `0006_snapshot_and_deltas.sql`.** Nothing is blocked. Add the `seq`-bumping upsert to the shape already recorded.
- **Multi-session is no longer an open design question** — it is now build work split across 7b-2 (lock + safe delete) and 7c (warnings).
- **Still outstanding:** checkpoint policy numbers; whether the usage figure shows snapshot bytes or snapshot + pending deltas; the two feature-id verifications (does duplicate detection block or warn; confirm ids are not user-editable); and the 7a behavioural confirm-as-you-go checks.

---


## 2026-08-01 — the 7b-2 rethink returns: ADR-037, a file is a snapshot plus deltas. No vendor change.

**Discussion only — no code, no SQL.** The pause called on 2026-07-31 came back with a **new remedy and the same provider**. Recorded as [ADR-037](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired); 7b-2 rewritten around it.

**The reframe that unlocked it.** Three questions had been fused into one: *what is the unit of storage*, *what is the unit of transfer*, and *what is the unit of durability*. Because they were fused, the design space looked binary — whole-document blob **or** the `file_features` rewrite. Separating them exposed a middle nobody had written down: **keep the blob as a snapshot, and send only what changed in between.**

**The model.** A file is a **snapshot plus every delta recorded after it — neither half is the file on its own.** The snapshot is the whole `FeatureCollection`, one Storage object, written rarely at checkpoints. Deltas are small Postgres rows, one per feature touched, written on every edit. Reading is snapshot → deltas above the watermark → apply by feature id. A checkpoint is **not a merge** — the client already holds the finished document, so it is just *"upload what you're holding, mark it as the new base."*

**Four things had to be true, and all four are:**

1. **The app already knows what changed.** `undo-redo-service.js` records every edit as create/delete/update with the affected features — and the current code **throws that away** to re-serialise the whole collection. The expensive half of a delta model was already built.
2. **Feature ids are already stable and already persisted.** Traced end to end: gl-draw preserves an incoming id and only generates when absent (`feature_types/feature.js:8`), `toGeoJSON()` emits it, `draw-manager.js:184` **throws** if a new feature has none, and `getPersistableGeoJson()` carries them into what autosave writes. **No data migration, no id-assignment pass** — the invariant already holds in the stored bytes. This was the single assumption that could have killed the design.
3. **Deltas must be assignments, not instructions.** *"Feature X is now this"*, never *"move X three metres north."* That makes replay idempotent, ordering per-feature, and lets the buffer **deduplicate by feature id** — so it grows with features *touched*, not edits *made*. Twenty vertex drags on one boundary is one row. This is what keeps the buffer bounded and the failure handling simple; it is not a style choice.
4. **Collection-level state needs no special case.** `collectionProperties` is written in exactly two places (`draw-manager.js:207` load/import, `:292` File→New) — top-level metadata is **carried, not edited**, so it only changes during whole-document operations, which write a snapshot anyway.

**What this fixes that ADR-035 explicitly did not.** The cost of an edit stops depending on the size of the file. A 50 MB file and a 5 KB file cost the same to keep saved. That was the objection that paused the slice, and ADR-035 says under *Consequences* that it does not address it.

**The quota problem largely dissolved, and it dissolved for a product reason.** The user's rule: *the save that crosses the limit is allowed; subsequent **growth** is blocked; shrinking is always allowed* — stated explicitly as a UX call, not a technical concession. Because nothing is ever refused mid-edit, **quota never needs checking before a write** — which was the *sole* reason Node had to mint signed upload URLs. The whole mechanism is dropped and **[ADR-002](02-decisions.md#adr-002--client-direct-access-with-rls-not-a-node-wrapper)'s client-direct writes are restored**. The lesson is worth keeping: the pressure to add a server hop came from a product rule nobody had stated deliberately, and it evaporated the moment the rule was examined on its own terms. Deltas also make the rule *cheap* — under whole-document writes, "did this edit grow the file?" meant serialising 50 MB to find out; a delta **is** the answer.

**NoSQL was the most serious alternative and it lost on hard numbers.** The intuition — *the store should accept a patch, not a whole file* — is right; no mainstream document store will do it at our sizes. Ceilings: DynamoDB **400 KB**, Firestore **1 MiB**, CosmosDB **2 MB**, MongoDB **16 MB**, against a 50 MB requirement. And the **addressing** problem is worse than the size one: GeoJSON's `features` is an array, Firestore cannot address array elements at all, and the fix in every case is to store features as a map keyed by id — **at which point the document design *is* `file_features` with the pieces in a different container.** Two extras worth keeping: the delta write is largely a *network* win (Mongo and Firestore both rewrite the document internally), and **Firestore bills per document read**, so one-doc-per-feature costs a 200k-feature file 200k reads *per open* — dollars per user per month on a $5 plan.

**Two findings that changed my own recommendation mid-conversation.** I had scoped deltas to the cloud path on the grounds that IndexedDB is fast; **that was wrong** — the local cost is serialising 40 MB on the main thread on every save, which is exactly the delay reported on large files, and deltas remove it regardless of where bytes go. Both paths now use one model. And I had flagged unbounded buffer growth as a risk before working out that **assignment-semantics let the buffer dedupe**, which mostly removes it.

**The multi-session race, found while writing this up.** Devices A and B open at watermark 10; B writes deltas 11–12; A writes 13; A checkpoints with a document that never contained B's edits and deletes everything up to 13 — **B's work destroyed in both places, silently.** Fix: **a checkpoint may only delete deltas it actually incorporated.** Roughly ten lines, non-negotiable, and it must be built *with* the checkpoint rather than after it. Worth noting the model makes concurrency **better** than today overall: two sessions now collide only on features both touched, where today one whole document overwrites the other entirely.

**Rejected, and why it is worth recording:** patching ADR-036's journal with UI ("last saved N minutes ago", staleness indicators). Factually it does not hold — **Safari evicts IndexedDB after 7 days of no interaction**, Chrome evicts under pressure, and for a product whose paid proposition *is* cloud storage, "your work was on your laptop" is not the promise being sold. And on the product's own terms: the stated requirement is that saving be seamless, and a staleness indicator exists precisely to make the user think about saving. **Client-side compression** (measured 6.6× on `taiwan.json`) was **declined by the user** on latency, complexity, and a commercial argument that is the strongest of the three — uncompressed storage fills quotas faster, and quota pressure drives upgrades.

**Docs updated:** ADR-037 added; ADR-035 status (remedy superseded, signed-URL addendum withdrawn, P3 moot), ADR-036 status (journal → delta outbox), ADR-002 (bent then restored — addendum added), ADR-025 (retry classifier's job gets easier; indicator stops tracking staleness); architecture §2, a new §4a, §4 seam note, §5 data model (`file_edits`, `user_files.snapshot_seq`); rollout 7b-2 rewritten, 7b-1 note superseded, 7b-3 gains the adaptive-window deletion, 7c re-scoped (outbox, network status, multi-session UI); backlog write-granularity **resolved**; overview status + diagram + glossary.

### Where to resume
- **Next unit of work: `0006_snapshot_and_deltas.sql`** — the private bucket + `file_edits` + `snapshot_seq` + the `user_storage_usage` rework. The shape is settled; nothing is blocked on a prototype.
- **The largest client piece is the seam's interface change** (`applyChange` / `getDocument` / `checkpoint`). First time the seam's *shape* changes rather than its backend, so Phase 0's one-line-swap payoff does **not** apply here.
- **Open decisions, none blocking:** checkpoint policy numbers (idle timeout, buffer-width threshold); whether the displayed usage figure is snapshot bytes or snapshot + pending deltas.
- **Two verifications outstanding** (both cheap, neither blocking the migration): does the existing duplicate-feature-id detection **block** an import or merely warn — duplicates go from annoyance to corruption under deltas; and confirm feature ids are not user-editable (the user's assessment is that they are not).
- **Still true and still outstanding:** the 7a behavioural confirm-as-you-go checks.

---


## 2026-07-31 — 7b-2 PAUSED: the user is rethinking the whole remedy; nothing built, nothing to unwind

**Stop point.** Immediately after the signed-URL design was recorded, the user called a halt to reconsider the approach — possibly a different provider (Firebase named, with its size limits acknowledged), edge functions, or NoSQL documents. **No code and no SQL had been written**, so there is nothing to revert; `0006` never existed. Recorded in full as the [ADR-035 third addendum](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row), with a factual note against each reason so a later reconsideration starts from the evidence rather than the summary. The three reasons, and what I'd want the reader to know about each:

**"Writing the entire 50 MB file for every burst of edits isn't optimal for a paid product."** Correct — and ADR-035 says so itself under *Consequences*: "What this does **not** fix: editing cost." Worth being blunt that **this is a data-model problem, not a vendor problem.** Object storage makes each whole-document write far cheaper without making it smaller. The fix is the parked per-feature row model (`file_features`), and switching provider doesn't reach it: Firestore's ~1 MiB document ceiling means a 50 MB `FeatureCollection` can't be a document at all — it goes to Cloud Storage (structurally what we just designed) or gets split per feature, which *is* `file_features` under another name. The write-granularity backlog item is annotated accordingly; it has gone from parked to the live question.

**"The quota mechanism is fiddly and not well supported by Supabase."** Fair, but it lands on a narrower target than it looks. Signed upload URLs and bucket `file_size_limit` are documented mainstream patterns; what needed prototyping was **our own** idea of a quota trigger on a vendor-managed table, and the prototypes killed it before it reached a migration — which is what they were for. What stays genuinely awkward with *any* provider: an aggregate byte quota has no first-class home in object storage, so it is application-level everywhere. Bounded-overshoot was the honest admission of that.

**"Needing prototypes suggests this isn't a well-known path."** Half true, and the halves matter. P2 was novel and came back clean. P1 probed something we invented. Blob-in-object-store with metadata-in-SQL is the ordinary shape for this problem — but the *volume of bespoke machinery to make the quota exact* is a real smell, and that part of the instinct is sound.

**What survives any provider decision** (so it isn't re-derived): the per-file ceiling as a uniform guardrail; tiers as data rows; two isolated paths with no sync; the recovery journal; cost-priced coalesced autosave (shipped); and the finding that whole-document writes are the real cost driver. **What is Supabase-specific and would be discarded:** `0006`, the `storage.objects` RLS work, the `security definer` publish lookup, the `protect_delete()` constraint, signed-URL mechanics.

**ADR-035's diagnosis is unaffected and still binding** — a 43 MB `jsonb` write takes the whole project down, and the blob cannot stay in Postgres. Its *remedy* is what is under review; the ADR's Status line now says so.

### Where to resume
- **The user is rethinking the solution.** Nothing to do until that returns.
- **P3 deliberately not written.** If the review comes back to Supabase Storage, the P1/P2 results stand and P3 is the only outstanding gate.
- **Still true regardless of the outcome:** the 7a behavioural confirm-as-you-go checks are outstanding, and the whole-document write cost is a live problem that no provider choice resolves on its own.

---

## 2026-07-31 — Signed upload URLs adopted for 7b-2; the design recorded, and one assumption sent back for prototyping

Discussion only — **no code**. The open decision from yesterday is settled in direction: **signed upload URLs**, not a `storage.objects` trigger. Design captured in the [ADR-035 addendum](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row) (2026-07-31). Three things came out of working the design that were not visible when the recommendation was made:

**Supabase has no per-user storage API**, so the quota check has no new machinery: Node reads the reworked `user_storage_usage` view with the `service_role` client it already has, joined to the plan. Same shape as `getUserPlan`.

**The quota becomes bounded-overshoot rather than exact, and that is a real loss.** A signed URL authorizes a *path*, not a *byte count* — the client declares a size, Node checks and mints, and nothing stops the client uploading more. Bounded by the bucket's 50 MB `file_size_limit`, by `max_files`, and by the next check refusing the following write: worst case 3 × 50 MB against a `free` user's 30 MiB, visible in the usage figure, self-correcting on the next save. Accepted because the trigger's compensating defect — an apparently unbounded, *invisible* orphan channel — is worse. **Bounded-and-visible beats unbounded-and-invisible**, but this is a trade and is now on the record so it isn't rediscovered as a bug.

**Write authorization moves from RLS to Node**, which is an amendment in spirit to ADR-002. The token is a capability, not a session. What keeps it safe is the path format: Node builds `{user_id}/{file_id}.geojson` from the *verified* `sub` claim, never from client input, so a leaked URL structurally cannot address another user's prefix. Reads stay client-direct under owner-only RLS, so ADR-002 bends only for the write-authorization step and only for the blob.

**A new failure class arrives with it:** the mint can return `401` while the user has unsaved work on screen — a state that doesn't exist today. ADR-036's journal is the mitigation, and it's already in 7c. Worth noting the sequencing is now mutual: 7b-2 went first because retry logic must classify the *final* backend's failures, and 7b-2's chosen design adds a failure the journal answers.

**One assumption deliberately not made.** Is a signed upload URL reusable, or consumed after one upload? Reusable → mint once per file per session and autosave costs nothing extra. Single-use → every autosave pays a Node round-trip before the write starts, which (because 7b-1 prices the coalescing window on *measured save duration*) would widen the window to 1200 ms and re-create the exact durability-versus-cost coupling ADR-036 exists to break; the journal would become a prerequisite rather than a companion. Given yesterday's round found three undocumented behaviours in this same API, this one gets a prototype rather than a guess.

### Where to resume
- **Next unit of work: write P3** — a ~20-line prototype that mints one signed upload URL, uploads twice, and reports whether the second is refused. Offered; not yet written.
- **`0006_file_blobs_to_storage.sql` still cannot be written** — P3 decides whether the client mints per save or per session, which changes the client design though not the SQL. The SQL parts are otherwise settled: one private bucket, owner-only RLS for reads, the `user_storage_usage` rework, `security definer` publish lookup.
- **Unchanged:** the 7a behavioural confirm-as-you-go checks are still outstanding.

---

## 2026-07-30 — ADR-035's two prototypes run: the quota trigger works and still loses; publish gets its one bucket

**The 7b-2 gate is discharged.** Both prototypes written, run against non-prod by the user, and torn down clean. Scripts and method live in a new [`../supabase/prototypes/`](../supabase/prototypes/) directory — deliberately *outside* `migrations/`, on the rule that a script belongs there when we are about to write a migration whose shape depends on a third party's behaviour we cannot check by reading docs. Full findings in the [ADR-035 addendum](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row); the short version:

**The trigger mechanism is viable — the assumption this ADR rested on is confirmed.** It is creatable on `storage.objects`, it fires on the Storage API's *real* write path (not just on hand-written SQL), `metadata->>'size'` is populated at `BEFORE INSERT`, and `raise exception` genuinely refuses the write. Everything that follows is about what it costs, not whether it works.

**Three findings turn the primary proposal into the fallback:**

1. **An overwrite is an upsert.** One `PUT` fires `BEFORE INSERT` *then* `BEFORE UPDATE`, on a row that keeps its id and `created_at`. A trigger written as the direct analogue of `enforce_storage_quota` double-counts on every autosave (the `INSERT` branch sees no `OLD`, and `id <> new.id` misses the surviving row because the proposed row's id differs) **and** inverts humane-downgrade — a user already over quota would be blocked from deleting features to get back under. Autosave is the dominant write path, so this is the common case. The fix is known: defer in the `INSERT` branch when `(bucket_id, name)` already exists, and exclude by name rather than by id.
2. **The rejection degrades to an opaque `500`.** PostgREST passes a raised message through — that is where today's over-limit dialog gets its text. The Storage API strips it: `HTTP 500`, `{"error":"DatabaseError","message":"database error, code: 23514"}`. Only the SQLSTATE survives. And `5xx` is what ADR-025's retry classifier treats as **transient**, so an over-quota user retries the whole upload forever and is never told to upgrade.
3. **Orphans: `UNDETERMINED`, evidence favouring yes.** The metadata visible at `BEFORE INSERT` already carries S3's `eTag` and `httpStatusCode: 200` — the object write completed and was acknowledged *before* the row insert was attempted. The rejected 7.7 MB upload transferred in full (`100 Continue`) before refusal. Proof needs an S3-endpoint listing, not run; recorded as undetermined deliberately, since an orphan channel we cannot measure argues against the design as strongly as one we can.

**Recommendation: promote the documented fallback — Node-issued signed upload URLs.** The only option that refuses *before the bytes move*, returns a clean `4xx` with our own message, and sidesteps the upsert arithmetic. **This is the one open decision and it is the user's** — the alternative (keep the trigger, fix the upsert, add a client pre-flight, let the reconciliation sweep bound the debris) preserves client-direct writes and is recorded in the addendum.

**Found incidentally, and it is a hard constraint: `storage.protect_delete()`.** Direct SQL `DELETE` on `storage.objects` raises `42501`; inserts are permitted, so the guard is asymmetric. This makes ADR-035's account-deletion gap **worse than it states** — not merely that the cascade leaves objects behind, but that **no SQL mechanism can clean the rows either**. The `service_role` sweep via the Storage API is the only home for it. Compliance obligation, now mandatory rather than natural.

**P2 came back clean, and publish keeps its one bucket.** A cross-table subquery in a `storage.objects` policy works — via a `security definer` lookup, since the naive form fails on a *grant* (`42501`), not on RLS. Preferred over granting `anon` read on `user_files`, which would let strangers enumerate every published file and its owner. Malformed object names must be regex-guarded before the `::uuid` cast, or one bad name breaks reads for the whole bucket. Cost negligible (0.285 ms, index scan). Anonymous `GET`: **200** published, non-disclosing `NoSuchKey` unpublished — so a revoked link reads as "not found", which is both safer and friendlier. **Revocation is immediate**, with one caveat: `cacheControl` is set by the *uploader* (`curl PUT` defaults to `no-cache`; the dashboard's multipart upload sets `max-age=3600`), so what is proven is that a `no-cache` object revokes instantly. That makes CDN-versus-revocation a deliberate per-upload choice rather than an inherited constraint.

**Three lessons about the harness itself**, all of which cost a re-run and are now fixed in the scripts:

- **A rejecting trigger cannot log its own firing** — the `raise exception` rolls back the trigger's own `INSERT`, so the log is empty whether it fired or never ran, and those are opposite conclusions. Sequences are the exception to transactionality; the firing count moved to one.
- **`storage.protect_delete()` in a teardown is a trap.** The SQL editor runs a paste as one transaction, so the failing `delete` rolled back the `drop trigger` statements above it and left the rejecting trigger armed — on `storage.objects`, i.e. blocking uploads to *every* bucket on the project. Both teardowns now guard the delete so the drops always survive.
- **A results table that `truncate`s on re-run is destroyable**, and duly got destroyed. Durable state (the sequence, `pg_trigger`, `pg_policies`) was what actually settled things.

### Where to resume
- **The open decision is the user's:** signed upload URLs (recommended) versus the fixed trigger. `0006_file_blobs_to_storage.sql` cannot be written until it is made — the quota mechanism is most of the migration.
- **Everything else in 7b-2 is now unblocked** and its shape is known: one private bucket, `security definer` publish lookup, the mandatory Storage-API deletion sweep, the upsert-aware quota arithmetic (if the trigger route wins), and a deliberate `cacheControl` per upload.
- **Not carried forward:** the orphan probe. Re-runnable in ~10 minutes (enable S3 keys, install the AWS CLI, redo P1 steps 4–6) if the decision turns on it.

---

## 2026-07-28 — ADR-036: local storage will buffer cloud writes (journal promoted to 7c); IndexedDB-as-staging-area rejected

Discussion only — **no code**. Manual verification of the reworked autosave came back clean (rapid points and rapid deletes both persist; the "Leave site?" dialog appears only when you beat the window, which is the guard working). That closed the acute bug and opened the structural question behind it.

**The proposal:** use IndexedDB as a staging area for cloud users — edit against local storage exactly as the anonymous path does, and schedule pushes to Supabase on top. Claimed: unified code across both paths, offline support, possibly no more seam, "like mobile apps do it".

**The distinction that decided it:** a *staging area* makes local the source of truth (replication — conflicts, reconciliation, a state machine); a *journal* keeps the cloud authoritative and holds only un-acknowledged writes (no conflict resolution at all). The user's intent turned out to be the journal, so **[ADR-036](02-decisions.md#adr-036--local-storage-buffers-cloud-writes-the-recovery-journal-is-promoted-indexeddb-as-a-staging-area-is-rejected) adopts the journal and records the staging version as rejected**, with the reasoning, so it isn't re-derived later.

Why staging fails, briefly: it needs conflict resolution over whole-document blobs, where a merge doesn't exist and sync can only pick a winner; **the Pro tier refutes it outright** (20 GiB can't be mirrored in browser quota → eviction → the cloud is authoritative again → it's a cache plus a seam, i.e. what we already have, with more parts); quota rejection detaches from the action that caused it; cloud bytes in the browser store become a sign-out privacy problem that is currently structural; and it doesn't fix the 43 MB crash. The simplification claim inverts — the seam is ~50 lines and is what makes the ADR-035 cutover one line, while the local store would need a **multi-file schema** it doesn't have today. The mobile-app comparison holds only for frameworks syncing small *records*; the real prerequisite for local-first here is the parked **per-feature row model** (`file_features`).

**What was promoted, and why now.** The journal is ADR-025's Level 2, which sat behind "build only if users actually report lost work" — that trigger is **retired**. The three rounds of debounce tuning showed the deficiency is structural: durability was coupled to upload frequency, so one number was trading lost edits against saved bandwidth. A local buffer decouples them and lets 7b-1's adaptive window be deleted. Also recorded against ADR-025: `beforeunload` **warns without writing**, so Level 1 never covered the horizon that ADR assumed it did.

Two design constraints, both learned from 7b-1 rather than reasoned in advance: the journal write must be **immediate** (a debounced journal inherits the same teardown failure it exists to solve), and it must be **keyed by file id** (or file A's journal restores into file B — the flush-boundary bug class). No new dependency: Dexie is already there. `workbox-background-sync` noted as the one genuinely interesting future addition — a Service Worker queue is the only thing that can finish an upload *after* the tab closes — but the app has no Service Worker and that's 7d at the earliest.

**Sequenced after 7b-2**, on the user's agreement. The deciding reason is that the journal's retry logic must classify which failures are retryable, and 7b-2 changes every one of those answers.

### Where to resume
- **Unchanged:** 7b-2 is next and still gated by the two ADR-035 prototypes. I offered to write both scripts.

---

## 2026-07-28 — 7b-1 follow-up: the debounce lost edits on refresh; the coalescing window is now priced by save cost, plus `beforeunload`

**e2e suite green** on the 7b-1 build. But manual verification found the regression the previous entry flagged as a "best effort" caveat, and it is worse than described: **drawing five points quickly and refreshing persisted only three.**

**The `pagehide` flush does not work — it was never a mitigation, only a hope.** Count the hops a flush must survive before a byte lands: `runPendingSave` → `performSaveWithStatus` → `await handleSaveStart` → `performSave` → `fileStorage.setItem` → `resolveBackend` (async) → Dexie → and only then an IndexedDB transaction that still has to commit. The browser aborts in-flight IndexedDB transactions during teardown, so on reload the write reliably loses. Nothing about "3 of 5" is special: points 1–3 fell inside one window that expired normally and wrote; 4–5 were still owed at refresh and went.

**A second defect, found reading the code rather than from the report:** on page-hide, `runPendingSave` chained the flush *behind* any in-flight write with `.then()`, so the flush did not even **start** until the earlier write resolved. During teardown that is a guaranteed loss — strictly worse than racing. Chaining is correct for timer-driven saves (it stops two whole-document writes landing out of order) and wrong for a flush; it is now `runPendingSave({ immediate: true })` from the page-hide listeners only.

**First attempt — a path-aware window — was the wrong axis, and manual verification on the *cloud* path found it still losing edits (1, 2, 3 at random; same on rapid deletes).** Cloud kept 1200 ms plus a network round-trip, so the real exposure after the last click was ~1.5 s. Not a new defect — the window left in place deliberately — but the reasoning that left it there does not survive contact.

**The design error underneath: the debounce was never about *path*, it was about *cost*.** The justification was upload bandwidth — re-sending 20 MB on a phone connection. That argument scales with the **document**, not the backend. A five-point file is a few hundred bytes; coalescing it protected bandwidth nobody was using while still charging full price in lost edits. Splitting local-vs-cloud made exactly that mistake, and `isRemoteWriteTarget()` — added that morning for the split — was removed again.

**The window is now priced by how long the last save actually took.** That measures the cost directly, needs no serialising a 40 MB document to estimate its size, and is self-tuning across both paths: a small cloud file (fast round-trip) gets the short window, a large one gets the long one, local is almost always cheap. Documents get expensive gradually, so the previous save predicts the next.

- `SAVE_IS_CHEAP_BELOW_MS = 500` — comfortably above a small-file Supabase round-trip, well below a large upload.
- **cheap → `AUTO_SAVE_DEBOUNCE_CHEAP_MS = 200`** plus a **leading-edge write** (first edit of a burst goes straight through). Self-limiting: the fast path needs nothing in flight, so when writes finish between clicks it degrades to write-every-edit, and when they don't the burst coalesces.
- **costly → `AUTO_SAVE_DEBOUNCE_COSTLY_MS = 1200`**, no leading edge. The bandwidth saving lives here and only here.
- Unmeasured counts as **cheap**, so one edit then reload keeps the edit. Guessing wrong moves a write earlier; it does not add one. Duration is recorded on success only — a failed save times the failure, not the document.

**ADR-025's `beforeunload` guard pulled forward from 7c**, because nothing else covers a costly save still owed at unload. It protects by two mechanisms and the second is the one that saves the file: it *warns* (browser wording, not ours), and it **buys time** — the dialog is synchronous and blocks navigation, so the write kicked off in the handler gets the whole time the user spends reading it, which is far more than it needs. Staying finishes the save outright. Gated on `hasPendingSave() || saveHasFailed` and silent otherwise: a guard that fires on every close trains people to click through it.

Also dropped the `await`s on `SaveStatusHelper` in `performSaveWithStatus` — the helper is synchronous, so awaiting it only inserted microtask hops ahead of the write: dead weight normally, material during teardown.

App build clean; `supabase-client` still its own 203 kB chunk.

### Where to resume
- **User:** re-run e2e — **`beforeunload` is new and interacts with the suite's ~20 reloads.** It should stay silent (`waitForSaveIdle` already precedes every reload that follows an edit, and Playwright auto-handles dialogs), but that is a prediction, not a result. Then repeat the rapid-points and rapid-deletes checks on **both** paths, and commit.
- **Then 7b-2**, unchanged and still gated by the two ADR-035 prototypes below.
- **Note for 7b-2:** moving the blob to Storage changes what a save costs, so it re-prices this window automatically — no tuning needed, but worth re-running the same manual check once the new backend is in.

---

## 2026-07-27 — Phase 7b-1 built: import cap aligned, honest import errors, import-path quota → dialog, coalesced autosave

> **Superseded in part (2026-07-28):** the e2e suite ran green, and the "best effort" page-hide caveat below proved to be a real data-loss bug. The debounce is now path-aware — see the entry above.

All four items of slice **7b-1** built in the app repo (`cloud-epic`). No schema, no API change — 7b-1 was always meant to ship on its own, and does. App `npm run build` clean; the Supabase SDK is still its own chunk (main bundle +1.6 kB). **The e2e suite has not been run — that's the user's, and this slice touches it (see the caveat below).**

**The ceiling is one number now.** `MAX_FILE_SIZE_FOR_FILE_IMPORT` drops from `50 * 1024 * 1024` to **`50000000`** (decimal), the value the `user-files` bucket's `file_size_limit` will carry in 7b-2. Both the file picker and drag-drop route through `validateDroppedFile`, so there was a single cap site to change. As recorded in the ADR-032 addendum, this fixes nothing by itself — the 43 MB file passed the old cap too.

**Import failures now say what actually failed.** `file-service.importFile` funnelled *every* unrecognised error into "The GeoJSON data is not valid." — so a dropped connection or a refused cloud write sent the user off to debug data that was fine. The persistence step is now its own method (`persistImportedFile`) whose failures are classified as storage failures, leaving the generic fallback to cover only the parse/load step it was always meant to describe. `restoreCurrentFileAfterFailedImport()` no longer swallows its own failure silently: it returns whether the previous file made it back and the message says so when it didn't, instead of leaving a blank canvas explained only by an error about the import. Its old comment ("the file remains intact in IndexedDB") was also an assumption ADR-035 disproves — a cloud read carries the same ceiling as a write.

**The 7a import-path gap is closed.** Because the import path writes through the seam directly rather than through `AutoSaveService`, `GS_QUOTA_EXCEEDED` / `GS_FILE_LIMIT_REACHED` never reached `PlanLimitDialog`. They do now. The dialog gained a **`context`** on its event payload (`save` | `import`), because the two cases leave the editor in opposite states and the existing advice text — *"Your edits are still on screen but unsaved. Export this file to keep a copy…"* — is actively wrong after an import, which is rolled back to the previous file. This is the case ADR-032 called out: the 50 MB per-file ceiling sits *above* the free tier's 30 MiB quota, so a free user importing a large file must get the upgrade prompt, not "file too large".

**Autosave coalesces** (`AUTO_SAVE_DEBOUNCE_MS = 1200`, `AUTO_SAVE_MAX_WAIT_MS = 8000` — the max-wait exists so continuous drawing still checkpoints instead of pushing the debounce out indefinitely). All eleven call sites moved from `save()` to `scheduleSave()`; `save()` was left orphaned by that and removed rather than kept as dead code. Writes chain rather than overlap, so two whole-document saves can't land out of order. Timer-driven failures report to Sentry explicitly, replacing the rethrow-at-the-call-site that used to carry them.

**The part that wasn't in the plan: coalescing breaks an invariant the code relied on.** `FilesView.openFile` carried the comment *"Autosaves are per-op and by-id (ADR-018), so nothing needs flushing here."* That was true only because saves were immediate. An owed save carries no file id of its own, so it lands on whatever file is active when it fires — and the editor's draw manager **survives navigation to `/files`** (MapView's unmount doesn't destroy it), so the timer really can fire while the user is picking another file. ADR-018's "pending autosave flushed first" stopped being free. A small `active-auto-save.js` registry publishes the live service so callers with no draw-manager reference can flush; **six boundaries** now do:
- **file switch** (`FilesView.openFile`) — the owed snapshot would be written into the newly adopted row;
- **file delete** (`FilesView.confirmDelete`) — worse than a no-op: once the store detaches the active file, the same write *lazily creates a replacement row*, so deleting a file would silently spawn a new one holding its contents;
- **File→New** — same lazy-create problem on the cloud path; and on the **local** path `createNewFile()` *reads* storage to build the undo backup, so a stale read would back up a file missing the user's last edits;
- **Import** (both the `hasSavedFile()` replace-warning check and the import itself) — a pending snapshot of the outgoing file could otherwise land *after* the import's own write and overwrite what was just imported;
- **sign-out** — write while the session is still valid; afterwards the seam routes to local and the cloud write would simply fail.

### Caveats — both are the user's to close

- **The e2e suite must be run.** It exercises **only** the anonymous/local path (no spec uses `?ff=cloud`), and ~20 `page.reload()` assertions prove persistence by reloading immediately after an edit — which now races the debounce. Scoping the debounce to the cloud path only would have avoided this entirely and was offered; **the user chose both paths**, so the suite was brought along: a new `waitForSaveIdle(page)` helper (`e2e/helpers/app-helpers.js`, polling `window.__gsDrawManager.autoSaveService.hasPendingSave()`) is now called before the **16** reloads that follow an edit, across 8 specs. The four reloads that are purely about `localStorage` settings (`colour-mode`, `welcome-splash`, `narrow-screen-warning`, `widgets`' session-token seed) were left alone. All 8 specs parse (esbuild); **none have been executed.**
- **Closing a tab inside the debounce window can still lose the last edit.** `pagehide` + `visibilitychange`→hidden listeners flush, but the write is async and the page may die first — **best effort, not a guarantee**. Before this slice every edit was written immediately, so this is a real regression traded for the bandwidth fix, and it is only fully closed by ADR-025's `beforeunload` guard, still unbuilt (7c/7d). Worth deciding deliberately rather than discovering later.

**Also fixed in passing:** `FileService.reloadFromStorage` was **defined twice** in the class — the second definition silently overwrote the first, making lines 37–43 dead code. Harmless today (no caller used the discarded return value), but it sat inside the exact method this slice rewires, so it went. Unrelated and untouched: `npm run lint` is broken repo-wide (ESLint 10 against a legacy `.eslintrc` + a removed `--ext` flag).

### Where to resume
- **User:** run the **e2e suite** (the real gate on this slice), then commit the app repo + these docs.
- **Then 7b-2** — still gated by the **two prototypes** ADR-035 requires *before* committing to the migration shape: (1) does a `BEFORE INSERT OR UPDATE` trigger on `storage.objects` fire and reject cleanly without orphaning bytes? (2) may a `storage.objects` RLS policy contain a cross-table subquery? Both are SQL against the non-prod project. `0006_file_blobs_to_storage.sql` doesn't exist yet.
- **Unchanged:** the 7a behavioural confirm-as-you-go checks are still outstanding (`unpaid` reverts the plan; over-limit save raises the dialog; new file over the cap blocked while edit/delete succeed).

---

## 2026-07-27 — Large files crash the project: the blob moves to Supabase Storage (ADR-035); Phase 7 re-sliced with a new 7b

Planning session (no app code). 7a's outstanding items were confirmed done by the user — `0005` re-applied, `service_role` grants correct (`user_plans` → `INSERT,REFERENCES,SELECT,TRIGGER,TRUNCATE,UPDATE`), all verification queries green — and staging OAuth was fixed (the recreated Supabase project had kept its default **Site URL**, so `redirectTo` wasn't allow-listed and Supabase silently fell back to `localhost:3000`; dashboard-only fix). Then large-file testing found the real problem.

**A 43 MB import takes the entire Supabase project down.** Twice, on two different projects, each needing a manual restart. Trace: `520` on `PUT /rest/v1/user_files` (invalid origin response) immediately followed by `521` on the read-back `GET` (origin unreachable) — PostgREST OOMs materialising the `jsonb` payload. 26 MB works. **The same file is fine on the anonymous IndexedDB path**, so the *paid* cloud product is currently worse than the *free* local one at exactly the point a user pays for it. The user's word: "a deal breaker." Correct.

**Why it was unfixable in place** — four properties, and each kills a different candidate fix:
1. **The blow-up is upstream of Postgres.** No `CHECK`, trigger, or RLS policy ever runs — `enforce_storage_quota` is downstream of the crash. There was **no server-side seam** to put a per-file guard in.
2. **A client cap is UX, not a control** ([ADR-033](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos) — a user can replay their own write with any body). So one user, accidentally or not, can halt the service **for everyone**.
3. **Reads have the same ceiling as writes** (the `521` *is* the read-back), so no write-side mitigation is sufficient.
4. **`jsonb` write amplification is per-edit** — a TOASTed value can't be partially updated, so every autosave re-writes the whole document plus comparable WAL, and autosave has **no debounce** (eleven whole-document call sites in `draw-manager.js`).

**Decision → [ADR-035](02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row): the blob moves to Supabase Storage; `user_files` becomes a metadata row.** Private `user-files` bucket, objects at `{user_id}/{file_id}.geojson`, plain untransformed bytes, owner-only RLS on `storage.objects` keyed on the path prefix. Supersedes the inline-blob half of ADR-001 and ADR-016; **corrects ADR-022**, which had claimed a Storage move would be "a cost lever, not a change to quota enforcement" — it is neither optional nor enforcement-neutral. Scaling compute was rejected on its merits: the memory cost is **per concurrent request**, so the cliff is *size × concurrency* — it moves rather than disappears, and fixes neither (3) nor (4).

**What it buys beyond not crashing:** the per-file guardrail finally gets a real server-side home (the bucket's `file_size_limit`, enforced at the edge — [ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features) asked for this and the architecture had nowhere to put it); TOAST/WAL amplification goes away entirely; **publish gets cheaper** ([ADR-034 addendum](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability) — the planned Node public-read endpoint is largely obsolete, Storage serves the bytes from CDN); and the unit economics improve, since DB disk is the cost driver and the dominant direction (repeated autosave uploads) is **ingress**, the un-metered one. **Egress is not a new cost** — a 43 MB `jsonb` read already pays the same bytes; the move only relabels the line item.

**What it costs — the honest list:** quota enforcement must be re-based on `storage.objects.metadata->>'size'` (a client-written size column is **rejected as source of truth** — spoofable by the same replay ADR-033 describes); **no transaction spans Postgres and Storage**, so failure ordering becomes a design artefact (save = object then row; create = row then object, with "row without object" reading as an *empty file*; delete = object then row); **`on delete cascade` cannot reach Storage**, so account deletion needs an explicit prefix sweep in the existing `POST /api/v1/account/delete` — a **compliance obligation, not housekeeping**; the usage view and export bundle both need rework (export becomes N downloads, which is exactly the shape of the backlogged export-as-zip, so that item gets *cheaper*); and `storage.objects` RLS is a **second security surface** for the two-account isolation test.

**Two prototypes gate the slice** rather than being assumed: can a `BEFORE INSERT OR UPDATE` trigger on `storage.objects` reject cleanly without orphaning bytes (fallback: Node-issued signed upload URLs gated on a server-side quota check), and may a `storage.objects` policy contain a cross-table subquery (needed by publish; fallback: a separate public bucket).

**Two second-order effects worth not losing:** [ADR-033's addendum](02-decisions.md#adr-033--no-server-side-geojson-content-validation-integrity-via-quota-and-tos) — `jsonb` at least rejected *malformed* JSON, an object store accepts **arbitrary bytes**, so reader-robustness moves from prudent to **required**, and upload-supplied MIME types are served back, so any public path must **force** content type + `nosniff` (the sharing revisit-trigger, arriving via the storage layer rather than a rendered viewer). And [ADR-032's addendum](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features) — `LandingView.vue` advertises **"Files up to 10 MB / 50 MB each"**, a per-file lever ADR-032 explicitly rejected and that **nothing enforces**, at storage figures (250 MB / 5 GB) already superseded by the seeded 500 MiB / 20 GiB.

**Phase 7 re-sliced:** the storage move becomes **7b**, and the tail shifts — old 7b (loose ends) → **7c**, old 7c (polish + quick wins) → **7d**, old 7d (verification) → **7e**. 7b is ordered **7b-1 stop the bleeding** (client pre-flight cap, honest error messages, the 7a import-path gap where quota rejections bypass `PlanLimitDialog`, and **debounced autosave**) → **7b-2 the move** → **7b-3 cleanup**. **7b-1 ships on its own, immediately.** Phase risk raised low–medium → **medium**, entirely on 7b.

**Cutover style — the user's call:** no feature flag. The seam makes the switch a one-line change and git is the real fallback, so the Postgres blob path stays as clearly-commented dead code and is deleted with the `geojson` column once proven. Flagged and accepted: it is a **code** fallback, not a **data** one — the column goes stale the moment files are written to Storage, so its value expires in days-to-weeks. `enforce_storage_quota` stays until deletion so both paths keep an enforced quota during the overlap.

**Per-file ceiling chosen by the user: 50 MB, uniform across all tiers** — no per-tier variation, so ADR-032's "optionally higher for Pro" is declined and the guardrail stays a pure guardrail. It matches the cap the app **already** enforces (`MAX_FILE_SIZE_FOR_FILE_IMPORT`, `constants/file-constants.js`), which is the point: one ceiling instead of two that drift. Four consequences worth not losing:
- **`50000000` (decimal), not `52428800` (binary).** The user confirmed Supabase's **free plan caps uploads at 50 MB**, paid plans much higher — so the ceiling lands exactly on the platform boundary, where the binary/decimal distinction stops being pedantry: a bucket's `file_size_limit` may not exceed the project's global limit, and the binary value would also open a ~2.4 MB band where the client accepts what Storage refuses. **`MAX_FILE_SIZE_FOR_FILE_IMPORT` is aligned down** from `50 * 1024 * 1024` to the same number — a 2.4 MB tightening of the anonymous path that nobody will notice, in exchange for client and bucket being a single value. Uniform across environments too; prod may allow more, but raising it later is bucket config, not code.
- **It fixes nothing by itself.** The 43 MB file that crashed the project **passed the pre-existing 50 MiB cap already**. 50 MB is the right *destination*; only the Storage move makes it safe.
- **No interim lower cap — the user's call.** A temporary ~25 MiB cloud-path cap was proposed (testing: 26 MB works, 43 MB kills it) and **declined**: sole user of non-prod, will avoid large uploads until Storage lands. Accepted risk, recorded rather than mitigated. Worth remembering that staging is publicly reachable (ADR-028, `--allow-unauthenticated`) — the exposure is small because the cloud UI is dark behind `?ff=cloud`, not because the surface is closed.
- **It sits above the free tier's 30 MiB total quota**, deliberately — the quota stops free users first (ADR-032: at free tiers a per-file cap is redundant with total storage). The UX consequence is that such a user must get the **upgrade prompt, not "file too large"** — the same import-path gap already logged in 7b-1.

**Docs touched:** new **ADR-035**; addenda on **ADR-032** (guardrail home + the chosen 50 MiB ceiling + the false landing claims), **ADR-033** (residual widens to arbitrary bytes; content-type), **ADR-034** (publish re-scoped); supersession notes on **ADR-001** and **ADR-022**; `03-rollout.md` (new 7b, tail renumbered, risk raised, landing-pricing fix added to 7c); `01-architecture.md` §2 §4 §5 + a storage-RLS policy shape; `04-backlog.md` (large-file ceiling + per-file limit promoted; write-granularity corrected; debounce and orphan-reconciliation added); this entry.

### Where to resume
- **Build 7b-1 first** — it is independent, needs no schema, and stops staging from being crashable while 7b-2 is designed.
- **Then the two 7b-2 prototypes**, before committing to the migration shape. `0006_file_blobs_to_storage.sql` doesn't exist yet; `migrations/README.md` and `RUNBOOK.md` get their bucket-config + orphan-sweep sections when it's written.
- ~~**Open decision:** the per-file ceiling~~ — **closed 2026-07-27: `50000000` (decimal 50 MB), uniform, no Pro variation, no interim cap.** Platform limit confirmed (free plan = 50 MB). Nothing outstanding on this.
- **Unchanged and still outstanding:** ADR-025 Level 1 is only part-built (save-status indicator exists; **no retry/backoff, no reconnect flush, no `beforeunload`**) — 7c/7d. The 7a confirm-as-you-go checks (`unpaid` reverts the plan; over-limit save raises the dialog; new file over the cap blocked while edit/delete succeed) are still the user's to run. Commit the three repos.

---

## 2026-07-26 — Phase 7a built: file-count lever, `early_access → free`, monotonic seeds, hidden plans, over-limit dialog, webhook terminal-status revert

All six items of slice **7a** built across the three repos. Build green: API Jest **18 suites / 264 tests** (was 260 — four new terminal-status cases); app `npm run build` clean, `PlanLimitDialog` a 2.3 kB async chunk with the Supabase SDK still out of the main bundle. **Pending the user:** one `0005` re-apply, then the confirm-as-you-go checks.

**Tier limits — the user's call, now seeded** (provisional until go-live, ADR-030): **`free` 30 MiB / 3 files · `basic` 500 MiB / 50 files · `pro` 20 GiB / 1000 files**, monotonic on both axes (the old seed had `basic` 250 MiB sitting *below* free 1 GiB). Hidden rows: **`discount`** (Pro limits at a private Stripe price) and **`god_mode`** (1 PiB / 1e6 sentinels).

**Schema — one `0005` amend-in-place (ADR-023):**
- **`early_access` → `free`** throughout: seed, `user_plans.plan` default, `handle_new_user`, backfill, quota fallback. The FK dictates the order — move the `user_plans` rows across, then re-default the column, then delete the old `plans` row; all three are no-ops on a fresh project.
- **`plans.max_files`** (added nullable → seeded → backfilled → `set not null`, which is what keeps the script re-runnable) + **`plans.description`** (private maintainer memo).
- **`enforce_file_count`** — a `BEFORE INSERT` trigger on `user_files` raising **`GS_FILE_LIMIT_REACHED`**. `security invoker` like the quota trigger, so its `count(*)` is RLS-scoped to the writer. INSERT-only by design: the humane-downgrade rule means edits and deletes always stay open.

**API:** `handleWebhookEvent` now reverts on the **terminal** statuses (`unpaid`/`incomplete_expired`/`canceled`) arriving via `customer.subscription.updated`, not just on `deleted` — so entitlement no longer depends on how the Stripe dashboard is configured to resolve dunning (the interim "set it to Cancel subscription" mitigation can be dropped). The subscription id is *kept* on that path (the object still exists in Stripe), unlike the deleted branch which nulls it. `past_due` stays granting — that's the grace window.

**App:**
- **New `stores/entitlements.js`** — plan + usage in one place, dynamic-imported so the SDK stays out of the main bundle. The editor's file-cap check and the account page's usage panel now read the same numbers instead of fetching separately; `AccountView` was moved onto it (its local `plan`/`usage` refs and its private `formatBytes` are gone — the latter to `ui-utils`).
- **Over-limit save → modal.** `auto-save-service.notifySaveFailed` raises **`APP_EVENT_PLAN_LIMIT_REACHED`** for either plan gate; new code-split **`PlanLimitDialog.vue`** (hosted by MapView, beside CloudMigrationPrompt) shows usage-vs-limit and an upgrade CTA. The CTA opens `/account` in a **new tab** — the storage case fires *because a save failed*, so routing away would discard the very work the dialog is about.
- **Retry stance:** saves keep being attempted after a rejection, deliberately — the quota trigger accepts any write that shrinks or holds flat, so the next autosave succeeds on its own once the user frees space; a circuit breaker would drop a save that would now be accepted. The existing `saveHasFailed` guard is what stops the alert repeating.
- **File-count UX:** File→New in cloud mode checks the cap first (fails open) and raises the dialog instead of blanking the editor; `/files` shows "N of M files" plus an at-limit notice; `/account` shows the file count against the cap. New `constants/plan-constants.js` holds the free-plan slug, upgrade ordering, and the provisional display copy.

**Docs:** `0005` + `migrations/README.md` (new verify blocks: seeded rows/monotonicity, rename landed, file-count gate); **ADR-032 addendum** (chosen limits; sentinel-not-`NULL`; INSERT-only enforcement) and **ADR-031 addendum** (why the terminal-status revert exists); `01-architecture.md` schema sketch; `RUNBOOK.md` (seeded tier table, `max_files` is `NOT NULL` so the old example inserts would now fail, revert target, humane-downgrade caveat); `03-rollout.md` 7a marked built; api `README.md`; this entry.

### Where to resume
- **User:** re-apply **`0005`** (idempotent) on non-prod, then the confirm-as-you-go checks — an `unpaid` transition reverts the plan; an over-limit save raises the dialog; a new file over the cap is blocked while editing/deleting existing files still work. Commit the three repos.
- Then **7b** (OAuth providers, per-file size ceiling, legal content + the ADR-033 acceptable-use clause, checkout-return notice, graceful non-GeoJSON read-back) → **7c** polish + the save-as/publish quick wins → **7d** the real-account verification pass.
- **Noticed while working in the autosave path — ADR-025's Level 1 is only part-built.** The **save-status indicator** exists (`save-status-helper.js`), but there is **no retry-with-backoff, no reconnect flush, and no `beforeunload` guard** anywhere in `src` (grepped: zero hits for `beforeunload`, no retry path in `auto-save-service.js`). So a cloud save lost to a dropped connection is reported and then simply left — and logged-in users keep no local copy (ADR-004). Not a 7a item and not touched here; logged so it's a deliberate call for **7b/7c** rather than an oversight discovered by a beta user.

---

## 2026-07-26 — Premium-feature axis settled (ADR-034); RUNBOOK moved into docs/

Planning session (no app code). Explored adding paid-plan features beyond storage — share/collaborate, publish publicly, batch operations — and settled the *axis* + *sequencing* (which ride go-live, which become a post-launch phase).

**Decision → [ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability): premium = scale / automation / distribution / collaboration, never core capability** (extends ADR-032's "gate scale, not capability" from the tier levers to the feature axis). The slate, placed by *architectural risk*:
- **Phase 7a:** `plans.description` (private admin memo) + seeded hidden plans **`discount`** + **`god_mode`** — rides the existing `0005` re-apply.
- **Phase 7c (quick wins):** **`save-as`** (ungated core convenience) and **share-as-URL / publish read-only** (unguessable token URL + unpublish; a small Node public-read endpoint serves **raw** geojson so **import-from-URL** can consume it — raw-serve keeps ADR-033's sanitisation tail off; the read endpoint doesn't violate ADR-002's write-path guard). Publish + the existing import-from-URL is the **v1 collaboration story**.
- **Phase 9 (Premium-v1 slice):** **bulk export** as the first finished premium surface, paired with pricing finalisation. "Partial at launch" = *fewer features, each finished* — not half-built-wide.
- **New Phase 10 — post-launch premium iteration:** bulk import + the rest of bulk ops, version history, richer publish (discovery + a **rendered** viewer → where ADR-033's output-sanitisation finally lands), shared editing, a developer API token.

**Deferred / declined:** collaborative editing (email-invite ACL / teams / "same-organisation") **deferred**, real-time collab **declined** — cost dominated by the invite-by-email + claim-on-signup flow, the owner-only-RLS → `file_shares` ACL rewrite, and the whole-document-write clobber (pulls in the parked per-feature model); publish + import substitutes. Priority-support SLA + an "early preview" perk **not built** (soft label; AI-drafted replies over one inbox suits a solo maintainer). Clarified the **"early access" collision** — it names the `free` plan (the ADR-032 rename), *not* a perk.

**Hidden plans + Stripe:** comp/free plans = pure SQL (no Stripe); a hidden **paid** plan = a real Stripe Price + Payment Link never listed in the upgrade UI, granted by the existing webhook once the price→plan mapping exists.

**Docs touched:** new **ADR-034**; `03-rollout.md` (7a plans-admin fields, 7c quick wins + a risk-line note on the public-read endpoint, Phase 9 Premium-v1, new Phase 10); `04-backlog.md` premium-feature menu; **`RUNBOOK.md` moved `→ docs/`** and given a *hidden paid plan* section (+ `god_mode`/`discount` examples); this entry.

### Where to resume
- No new blocker for **7a** — the `description` column + `discount`/`god_mode` seeds fold into its existing `0005` re-apply. **save-as** + **publish** are the 7c quick wins; **bulk export** is the Phase 9 Premium-v1 slice. Everything with "another human sees this file" (shared editing, a rendered public viewer) is Phase 10, by design.

---

## 2026-07-25 — Content-integrity decision (ADR-033): no server-side GeoJSON validation; quota + ToS + reader-robustness

Follow-on from a user question. Because GeoJSON is written **client-direct** to `user_files` (owner-RLS, opaque `jsonb`), a user can replay their own auto-save request (devtools → curl/Postman, own valid token) and store any valid JSON in their **own** row — potentially turning the table into a general-purpose JSON store.

**Analysis:** blast radius is **self-only** (RLS), and `jsonb` already rejects malformed JSON, so the residual is *valid JSON that isn't GeoJSON*. The decisive point: **a GeoJSON validator doesn't stop this** — arbitrary data wraps trivially inside a valid `FeatureCollection` (`geometry: null`, payload under `properties`), passing any structural check. So validation is a speed bump against casual junk, not an anti-abuse control; the real cost bound is the (content-agnostic) **quota**, already built.

**Decision (ADR-033):** no server- or DB-side content validation. Integrity/abuse handled by three controls — **quota** (`0005` trigger + per-file cap + file-count lever = the cost bound), a **ToS acceptable-use clause** (intent; misuse → suspension), and **reader robustness** (the app reads back non-GeoJSON gracefully = integrity). Client-side validation stays a UX guardrail. A shallow DB CHECK was considered and declined (bypassable; only buys a uniform-shape invariant we don't need); the Node-validation path was rejected (reverses ADR-002, fixes nothing the wrapper doesn't defeat). **Revisit trigger:** file sharing / public files / server-side rendering — then *safe rendering / output sanitisation* (not validation) becomes the real control.

**Docs touched:** new **ADR-033**; `03-rollout.md` 7b gains the ToS acceptable-use clause + a graceful-read-back task; `04-backlog.md` compliance note (+ decided-against pointer); this entry. **No phase/scope change** — both land in the existing Phase 7b.

### Where to resume
- 7b picks up the ToS clause (with the legal content) and the graceful-read-back task; quota is already built. Nothing here blocks 7a.

---

## 2026-07-25 — Phase 7 re-sliced into 7a–7d (verify last); Phase 6 marked done+verified in the plans

Planning session (no app code). Two things: reconciled the plan docs with Phase 6 being **done + verified** (the 2026-07-24 test-mode pass), and **re-sliced Phase 7** — which had grown from "final polish & debugging" into a mix of real build work, discrete fixes, open-ended polish, and the real-account verification pass.

**Phase 7 → four slices, verification last:**
- **7a — entitlement-completion build:** the unbuilt **file-count lever** (`plans.max_files` + a `user_files` insert-count check + client UX), the **`early_access → free` rename**, the **inverted storage-seed fix** (`free < basic < pro`), and the two Phase 6 billing follow-ups pulled in here (over-limit save → **dialog**; webhook **revert on terminal non-granting statuses**). All schema edits ride **one `0005` re-apply**. Rationale for folding the billing follow-ups in: the whole billing/entitlement surface is then complete before 7d verifies it once, rather than verify → change the webhook → re-verify.
- **7b — loose ends (known issues):** OAuth provider config (GitHub/MS/Facebook), per-file size ceiling, legal-page content, the checkout-return "activating…" notice. ("Storage-quota constraints" decomposed — seed fix → 7a, final values → Phase 9.)
- **7c — polish:** the user's own list + a final UI/UX pass. **Left unbounded by choice** — stop point is a judgement call at the time; working bar is "no rough edge a beta user would trip on," with discretionary refinement deferred to real beta signal.
- **7d — real-account verification & beta sign-off:** the consolidated real-account backlog + all Phase 6/7a payment surfaces → the user's beta-ready sign-off, the gate into Phase 8.

**Why verify last:** 7d's backlog re-tests surfaces that 7b/7c change, so verifying earlier only goes stale before beta; instead each build/fix slice self-checks, and 7d certifies the app as it will actually ship. (Phase boundaries 7/8/9 unchanged — this is internal slicing, not a re-sequence, so no new ADR.)

**Docs touched:** `03-rollout.md` Phase 7 rewritten into 7a–7d; `00-overview.md` status + current-status updated (Phase 6 built+verified, tier shape per ADR-032, the Phase 7 re-slice); `04-backlog.md` file-count-lever + checkout-return items pointed at their slices; this entry.

### Where to resume
- Dev work starts **7a** — the `0005` revision (`max_files` + rename + seed reorder) and its enforcement/UX, plus the two billing fixes in the api/app repos. User re-applies `0005` once and re-runs the affected Phase 6 test-mode checks.
- **7c** polish list is the user's; **7d** is the user's real-account pass.

---

## 2026-07-25 — Plan-tier product shape settled (ADR-032) + ops docs

A planning session (no app code shipped) settling the commercial *shape* on top of the built Phase 6 mechanism, plus two operational docs.

**Decisions → [ADR-032](02-decisions.md#adr-032--plan-tiers-differentiated-by-storage-and-file-count-not-features):**
- **Four tiers** — Guest (anon/local, 1 file) · Free (cloud) · Basic · Pro — differentiated by **storage + file-count only**. Core editing/format-conversion is **never gated** (it's the acquisition funnel — gate scale/persistence, not capability). The differentiator table lives in ADR-032.
- **Permanent free *cloud* tier** — refines ADR-019's "free = local, paid = cloud": a free sign-in buys durability + multi-device + more files, not the ability to work.
- **Rename `early_access` → `free`** (slug + label; "freemium" rejected as a tier name — it names the business model).
- **Per-file size = guardrail, not a lever** (redundant with the total cap; protects editor perf + write cost). Already a Phase 7 loose end.
- **API usage limits stay a uniform compute guard; per-user metering deferred** — the existing IP rate limiter suffices; a per-plan rate perk needs the two-JWT unification first.

**Biggest catch — new build work:** the **file-count lever is chosen but unbuilt** (the `0005` trigger enforces storage only). Needs `plans.max_files` + a `user_files` insert-count check + client UX → Phase 7. Also queued: fix the inverted storage seed (`basic` 250 MB < free 1 GB), and reconcile `00-overview.md` / ADR-019's "cloud = paid" wording with the permanent free-cloud tier.

**Ops docs created:** the API repo `README.md` gained a *Local Billing & Webhooks (Stripe test mode)* section (env + Stripe CLI + `npm run local` + lifecycle recipe); new cloud-repo **`RUNBOOK.md`** documents plan administration (comp / hidden / unlimited plans via SQL, with caveats).

**Next:** user decides when to implement the file-count lever and the `early_access → free` rename (both Phase 7 / doable pre-prod; user re-runs `0005`). Phase 6 itself stays done + verified (2026-07-24).

---

## 2026-07-24 — Phase 6 monetisation FULLY VERIFIED in test mode (whole lifecycle green)

After the two 2026-07-23 blockers were fixed (service_role grants re-applied via `0005`; API restarted for the `managed_payments` opt-out), the user ran the **entire** Phase 6 test-mode verification against non-prod — **all green**. Phase 6 is now build-complete **and** verified; what remains is the user's git commit across the three repos, then Phase 7. Two follow-ups surfaced during verification are logged in Phase 7 (below).

**Verified this session (test mode / non-prod):**
- **Checkout → webhook grant:** Upgrade → Stripe test Checkout (`4242…`) → `customer.subscription.created` webhook → `user_plans` written → account page shows the paid plan. (First proof of the **webhook** leg — checkout URL gen was already provable; the entitlement grant only became testable once a real payment landed.)
- **Customer Portal:** Manage billing opens the Stripe-hosted portal; the `return_url` round-trips back to `/account?ff=cloud`.
- **Storage-quota gate (the core-write-path change that justified building Phase 6 pre-beta):** with the plan limit temporarily lowered below usage, a **growing** save is rejected with the `GS_QUOTA_EXCEEDED` → "Storage limit reached … upgrade" message, while a **shrinking/flat** save still succeeds (humane downgrade).
- **Immediate cancel:** dashboard "cancel immediately" → `customer.subscription.deleted` → row reverts to `early_access` (`status = canceled`, subscription id + period end nulled, customer id retained).
- **Forged webhook signature:** a bogus `Stripe-Signature` POST to the live local webhook returns **400 `{"error":"Invalid signature"}`** before any handler logic (verified via `curl`).
- **Test-clock renewal:** subscription created on a Stripe test clock (with `supabase_user_id`/`plan` metadata so `resolveUserId` maps it); advancing past `current_period_end` fired `customer.subscription.updated` and **advanced the stored period end**, plan/`active` intact.
- **Test-clock dunning:** failing card (`4000…0341`) → repeated `charge.failed` → `status = past_due` with the **paid plan retained** (the `past_due ∈ GRANTING_STATUSES` grace window, working as designed) → retries exhausted → `customer.subscription.deleted` → back to `early_access` (`canceled`).

**Follow-ups found → logged in Phase 7 (`03-rollout.md`):** (1) over-limit save UX should be a **modal dialog, not a toast** (+ consider making the quota error non-retryable); (2) the webhook should **revert on terminal non-granting statuses** (`unpaid`/`incomplete_expired`/`canceled` via `subscription.updated`), so entitlement doesn't depend on the Stripe "manage failed payments" dashboard setting — interim mitigation is setting that to "Cancel subscription."

**Next:** user commits `cloud-epic` on the api + app repos and the `0005`/docs changes here, then Phase 7 (the two follow-ups above + the standing real-account backlog + loose ends).

---

## 2026-07-23 — Phase 6 first live-in-test-mode run: two checkout blockers found + fixed

The user began the test-mode checkout run (Stripe account + test Products/Prices created, `0005` applied, API env filled, `stripe listen` + local API + app all up). Early access + usage bar rendered correctly (6c `getPlan` works). The **Upgrade → checkout** call 500'd. Diagnosed with two throwaway scripts (since removed) reproducing the exact service calls; found **two independent blockers**, both now fixed:

1. **`42501 permission denied for table user_plans`** (hit first, before Stripe). Root cause: on this Supabase project `service_role` did **not** inherit the default `public`-schema table grants, and `BYPASSRLS` does not cover **table-level** privileges — so the Node service_role client's PostgREST reads/writes are denied. This never surfaced before because Phase 4 account deletion uses the **GoTrue Admin API** (no table grant needed), so `getUserPlan`/`upsertUserPlan` are the first service_role **PostgREST** calls in the epic. Confirmed project-wide (every public table 42501 for service_role) while `auth.admin.listUsers` succeeded (key *is* service_role; it just lacks table grants). **Fix:** `0005` now `grant`s `service_role` explicitly — `select` on `plans`, `select,insert,update` on `user_plans`. The Phase 1–5 tables share the latent gap but need no fix (never touched by service_role over PostgREST). → **user must re-run `0005`** (idempotent).

2. **Stripe `Managed Payments … tax code is missing`** (would hit next). New Stripe accounts default **Managed Payments** (merchant-of-record + auto tax) ON, which requires a `tax_code` on every product. **Fix:** `createCheckoutSession` now passes `managed_payments: { enabled: false }` — classic Checkout, no tax code needed; the adopt-or-not decision is deferred to Phase 8/9 (backlog + ADR-031).

After both fixes: a real Stripe **test Checkout URL** is returned end-to-end; API Jest **18 suites / 260 tests** still pass. Also bumped `stripe` **17 → 22.3.2** (latest; `new Stripe()`/methods unchanged, no code impact) and `npm install`ed it. **Docs:** backlog (Managed Payments decision + service_role-grant learning), `migrations/README.md` (service_role grant verify block), this entry.

### Where to resume
- **User:** re-run `0005` (adds the service_role grants); **restart the API** with `npm run local` (picks up the `managed_payments` change); retry Upgrade → Checkout with test card `4242 4242 4242 4242`; watch `stripe listen` for `[200]`s and confirm `user_plans` flips to the paid tier. Then the rest of the lifecycle (portal, cancel) per the 2026-07-22 resume list.

---

## 2026-07-22 — Phase 6 (monetise) code-complete: plans + quota trigger, Stripe Node routes, client billing UI

Built all three Phase 6 slices in one session; the two design forks were settled with the user and recorded as **ADR-031**. Everything is **Stripe test mode / non-prod**, shipped dark behind flags — charging real users is still Phase 9 (ADR-030). Build green: API Jest **18 suites / 260 tests pass**; app `npm run build` clean (`AccountView` a 20 kB async chunk; Supabase SDK still out of the main bundle). **Pending the user** (see "Where to resume").

**Design decisions (ADR-031, refines ADR-022):**
- `public.plans` is a real **lookup table** (tier → `limit_bytes` + `label`/`rank`) — limits are data, changed with a row UPDATE.
- **Every cloud user has a `user_plans` row**, defaulted to a new **`early_access`** plan, created **server-side** by a `handle_new_user` trigger on `auth.users` (+ a one-time backfill) — *not* a client write — so `user_plans` stays strictly server-authoritative (client reads its own row, never writes it).

**Slice 6a — schema + quota (cloud repo).** `supabase/migrations/0005_plans_and_quota.sql`: `plans` (seeded `early_access` 1 GiB / `basic` 250 MiB / `pro` 5 GiB — **provisional**), `user_plans` (owner-read-only RLS — no client write grant/policy), the default-plan trigger + backfill, and `enforce_storage_quota` (BEFORE INSERT/UPDATE on `user_files`: blocks a write that grows the user's total bytes past the plan limit; always allows flat/shrinking writes — humane downgrade; raises a `GS_QUOTA_EXCEEDED` message the client detects). `migrations/README.md` verifying block + **ADR-031** + architecture §5 sketch all updated.

**Slice 6b — Stripe Node routes (api repo, `cloud-epic`).** New `services/stripeClient.js` (lazy `require("stripe")`, injectable for tests), `services/billingService.js` (checkout/portal orchestration + **idempotent** webhook reconciliation + `buildPriceToPlan`), `controllers/billingController.js`, `routes/billingRoute.js`. Extended `services/supabaseClients.js` with service_role `getUserPlan` / `upsertUserPlan` / `findUserIdByCustomerId`. Endpoints under `/api/v1/billing`, gated by `BILLING_API_ENABLED`: **checkout** + **portal** (behind `createSupabaseAuth` + a tight rate limiter), **webhook** (public, Stripe-signed, **raw body**, mounted **before** the `/api` Cloudflare guard — Stripe carries no guard header and the signature is its auth). New config/secrets (`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, the `STRIPE_PRICE_{BASIC,PRO}_{MONTHLY,ANNUAL}` map) with fail-fast on the two secrets; `.env.template` + `package.json` (`stripe` dep — **user runs `npm install`**). New suites `billing.test.js`, `stripeClient.test.js`, plus supabaseClients plan-op tests. **Entitlements are granted on the webhook, never on the browser's return.**

**Slice 6c — client billing UI (app repo, `cloud-epic`).** New `services/account/account-billing.js` (`getPlan` = client-direct read of `user_plans ⋈ plans`; `startCheckout` / `openBillingPortal` → the Node endpoints with the Supabase bearer, mirroring `deleteAccount`); `config.api.billingCheckout` / `billingPortal`. `AccountView.vue`: the Plan & usage panel shows the **real plan + real limit** (placeholder `QUOTA_BYTES` removed), with an **Upgrade** block (monthly/annual `SelectButton` + per-tier Checkout; provisional display prices); the Billing panel's **Manage billing** opens the live Customer Portal. Quota UX: a new SDK-free `services/storage/quota-error.js` + `auto-save-service.notifySaveFailed(error)` now shows "Storage limit reached … upgrade" for an over-limit save instead of the generic "browser storage may be full".

### Where to resume — user tasks, then Phase 7 verification
1. **Stripe (user):** create the account (test mode; KYC/activation is Phase 8), create test-mode Products/Prices (Basic + Pro, monthly + annual), hand the price ids to the API env.
2. **Non-prod wiring (user):** apply `0005`; set `BILLING_API_ENABLED=true` + the Stripe keys/prices in the API env; `npm install` (adds `stripe`); run `stripe listen --forward-to localhost:8080/api/v1/billing/webhook` for local webhooks; `npm install` + git on both code repos (`cloud-epic`).
3. **Verify (test mode, real account) — lands in Phase 7:** full lifecycle via Stripe **test clocks** — subscribe → webhook writes `user_plans` → account page reflects plan + usage; upgrade Checkout round-trip; Manage billing → portal; an over-limit save shows the quota toast and shrinking recovers; cancel → reverts to `early_access`. Runs alongside the standing real-account verification backlog.
4. Then the remaining Phase 7 loose ends (OAuth provider config, per-file size limit, legal content) → **Phase 8** production provisioning + beta.

---

## 2026-07-06 — Phases re-sequenced (ADR-030): monetisation build moved before beta; tail is now Phases 6–9

Planning session on the remaining phases. The user proposed bringing Stripe forward so beta tests an almost production-like system; analysis agreed: the entitlements/quota layer (ADR-022) changes the core write path, so retrofitting it *after* beta would invalidate part of what beta proved and need its own testing round; Stripe **test mode + test clocks** make the full subscription lifecycle testable pre-beta; grandfathering reduces to a plan row. Key reframing: what moves forward is the **build** (test mode) — **charging real users still comes last**, so ADR-007's rationale ("no one pays while the foundation is unproven") is intact.

**New sequence** (recorded as **ADR-030**; rollout Phases 6–9 rewritten):
- **Phase 6 — Monetise (build, test mode):** `user_plans` + storage-quota trigger, Node Checkout/webhook/portal routes, upgrade CTA + usage bar (replaces the placeholder `QUOTA_BYTES`), Billing panel wired to the Customer Portal — all non-prod, provisional tiers; Stripe account created (activation deferred).
- **Phase 7 — Final polish & debugging:** the consolidated pre-beta gate — the real-account verification backlog (see the handoff entry below) + loose ends (OAuth provider config, per-file size limit, legal content, storage-quota constraints) + the new payment surfaces.
- **Phase 8 — Free beta / early access** (was Phase 6): still the **production-provisioning gate** (ADR-014). Beta users = free `beta` plan rows (the allowlist *is* the plan mechanism); quotas live; no charges (optional live-mode 100%-off founders coupon); Stripe **activation (KYC/bank)** runs here.
- **Phase 9 — Go-live:** absorbs old Phase 7 **Stage 2** (static SEO landing, `/app` move, `?ff=cloud` retirement, ADR-028 launch cleanup) + the payments cutover: live Stripe keys, final tiers/prices from beta usage data, tax-handling decision.

**Docs touched:** new **ADR-030**; ADR-007 status annotated (sequencing amended, rationale intact); rollout Phases 6–9 rewritten + both re-sequencing notes updated; stale phase numbers fixed in ADRs 014/022/024/026/027/028/029, the overview (status, goals, glossary 0–9), architecture §5 comment, and the backlog.

### Where to resume
- Dev work starts **Phase 6**: design the `user_plans`/`plans` migration + quota trigger (ADR-022 shapes), then the Node Stripe routes (test keys, Stripe CLI webhook forwarding).
- The user's **real-account verification backlog** (handoff entry below) is unchanged and can proceed in parallel — it now lands in **Phase 7** rather than blocking Phase 6.

---

## 2026-07-06 — Session paused for handoff: UI/UX revamp COMPLETE; next is the user's real-account verification pass

**The revamp (rollout near-term step 3) is finished and the user approved the final /login split layout ("I like this version much better").** This entry is the fresh-session resume point; the dated entries below (2026-07-04 → 2026-07-06 evening) hold the per-chunk detail. Build clean throughout; everything below was verified **only** via the session-local fake-session Playwright harness (mocked REST, light+dark+mobile) — **nothing new has been checked against real Supabase.**

**What the revamp delivered (all in the app repo's `cloud-epic` working tree; git is the user's):**
- Landing page + `/` `/app` routes; landing mobile-nav overflow fixed.
- **`/login`** — split two-column page (brand/heading/benefits left, card right; stacks <900px); email form first, then an "or continue with" **2×2 OAuth grid: Google / GitHub / Microsoft (azure) / Facebook** (`constants/auth-constants.js`; `auth.signInWithOAuth`); sign-up leads with the terms checkbox gating submit + all providers; forgot/reset flows; no scrollbar at 1366×720 (page scrolls itself, auto-margin centring).
- **`/account`** — sectioned panels on the export-dialog idiom + **section sidebar** (sticky, scroll-to, active tracking) + **Security panel** (inline password change + reset-link fallback; provider-aware note for OAuth accounts) + **Billing placeholder panel** (thin entry point to the future Stripe Customer Portal — ADR-022) + top back link.
- **`/files`** — table page; New File button removed (File toolbar owns New); top back link.
- **Chrome** — avatar menu + active-file chip (standard 6px/neutral hover); File toolbar order **New | Open | Import | Export** ("Open" = the old My Files button).
- **`CloudMigrationPrompt`** — copy polish + **bug fix: it could never fire on login** (was hosted in FileToolbar, which unmounts when the default Draw tab takes over; now hosted in MapView, gated on cloud-mode + app-ready). **Re-opens the Phase 3c verification.**
- **File name length limit** — `MAX_FILE_NAME_LENGTH = 100`: input `maxlength`s + store clamp + a CHECK constraint amended into `0002` (cloud repo, ADR-023 policy).
- **Cross-cutting fix** — `#app` boxes routed pages at exactly 100vh; long pages (`/account`, `/files`, `/login`) now scroll internally with `background-attachment: local` so the grid paints the full height.
- NotFound wordmark fixed (last holdout); privacy/terms checked — no changes needed.

**Consolidated user-verification backlog (staging/local, real accounts) — the outstanding gate before the pre-Phase-6 loose ends:**
1. **Re-apply `0002`** to non-prod (idempotent; adds the name-length CHECK), then a >100-char rename attempt.
2. **Migration prompt (Phase 3c retest):** appears on login **without touching the File tab**; Save→first cloud file; Not now; no prompt when cloud files exist / local empty; flag-off never loads it.
3. **/login:** email sign-in; signup→confirm→sign-in (checkbox gates submit + all four providers); **Google OAuth round-trip from the new grid** (regression); forgot→email→reset→lands in editor (redirect allow-list covers `/login?ff=cloud&mode=reset`); signed-in visits bounce; **on a real smallish laptop: no scrollbar, proportions feel right**.
4. **/account:** password change (incl. mismatch/short errors) + the "send a reset link" path; Google-account variant shows the provider note (no password fields); sidebar scroll/highlight feel; real usage figures; avatar photo; export + delete round-trips.
5. **/files:** open/switch; delete (incl. open file → blank editor); rename persistence (chip + list agree); "Open" badge on cold load; two-account isolation.
6. **Landing/routing:** `/?ff=cloud` → landing (incl. mobile nav ≤480px: icon-only brand); bare `/` → editor unchanged; `/app`; flag-off e2e suite.
7. **Chrome:** chip rename persists; Google avatar renders; unsaved-blank chip after File→New; "Open" toolbar button placement feels right.
8. **New setup task (user):** configure **GitHub / Microsoft (azure) / Facebook** in the Supabase dashboard (OAuth apps + callback URL) — buttons error cleanly ("provider is not enabled") until then; then round-trip each. (Backlogged in `04-backlog.md`.)

**Docs state:** overview + rollout step 3 marked revamp-complete; backlog has the provider-config task; `0002` carries the name CHECK. Harness scripts (`shoot-revamp.cjs`, `shoot-login2.cjs`; PROJECT_REF `eprkeuxtnnijaenqbrie`, fake session + route-mocked REST — note `user_files` mocks must honour `limit=1`) are **session-local scratchpad files, not in either repo**.

### Where to resume
1. The user runs the verification backlog above (and the Supabase provider config); fix whatever falls out.
2. Then the remaining pre-Phase-6 loose ends: per-file size limit (user's large-file testing → pick the ceiling), legal content finalisation, storage-quota constraints.
3. Then **Phase 6** — production provisioning (ADR-014 gate: prod Supabase project, apply `0001`–`0004`, per-env `VITE_SUPABASE_*`, Google + the new providers' callbacks on prod) + the beta allowlist.

---

## 2026-07-06 (evening) — /login pivoted to the split two-column layout; providers below email; laptop scrollbar fixed

The spacious single column (entry below) still read "busy" to the user once four providers were stacked on top, and short laptop screens showed a vertical scrollbar. Pivoted to the **split layout** (the other option offered): brand + heading + mode copy (and the sign-up benefits checklist) on the **left**, the form card on the **right**; stacks to one centred column below 900px. Per the user, **providers moved below the email form** ("or continue with" divider), and they're now a **2×2 named-button grid** (Google/GitHub/Microsoft/Facebook) — half the height of the stack. Sign-up's terms checkbox sits above the Create-account button and still gates it plus all four providers.

**Scrollbar fix:** same `#app`-boxes-the-page problem class as the account/files pages — the login root now scrolls itself (`height: 100vh; overflow-y: auto`, `background-attachment: local`) and the layout centres by **auto margins**, not flex centering (which clips the top when content overflows). Playwright-verified `scrollHeight <= clientHeight` at **1366×720** for both modes, light + dark; desktop + mobile shots clean (`shoot-login2.cjs`).

**Unchanged:** auth logic, modes, gating rules, `auth-constants.js`, `signInWithOAuth` — this was template/CSS only. The user-verification items from the entry below still stand.

---

## 2026-07-06 (later) — /login cosmetic notes captured & fixed: spacious redesign + multi-provider OAuth UI

The user's long-outstanding `/login` critiques finally landed: the sign-in and create-account modes looked too similar, and spacing was too compact. Offered two directions (split two-column vs. spacious single column) — **user chose the spacious single column**. Also new scope from the user: **more OAuth providers besides Google** — chose **GitHub, Microsoft (azure), Facebook**, *UI-only for now; the user configures each in the Supabase dashboard later.* Build clean (LoginView ~11.4 kB); verified signin+signup, light+dark, desktop+390px via the scratchpad harness (`shoot-login.cjs`).

**Built (app repo):**
- **`constants/auth-constants.js`** (new) — `OAUTH_PROVIDERS` (`google`/`github`/`azure`/`facebook` + labels + PrimeIcons) and `PROVIDER_LABELS`. One list drives the login buttons and the account page's wording. Listing a provider only renders its button — Supabase dashboard config still required per provider.
- **`stores/auth.js`** — `signInWithGoogle(redirectPath)` generalised to **`signInWithOAuth(provider, redirectPath)`** (same redirect/flag mechanics; an unconfigured provider errors cleanly in the page's message area).
- **`LoginView.vue` redesign** — card shape is now: **provider stack** (4 outlined "Continue with X" buttons) → "or continue with email" divider → email + password. Spacing opened up (card padding 2rem, field gaps 1.4rem, container gap 1.75rem, max-width 26→28rem). **Mode differentiation:** sign-up shows a **benefits checklist** under the heading (files everywhere / auto-saved / free in early access) and **leads with the terms checkbox**, which gates the provider stack right below it (the disabled state is self-explaining; same rule as before, now covering all providers). `providerLoading` locks the stack during a round-trip. Forgot/reset modes unchanged bar the roomier spacing.
- **`AccountView.vue`** — sign-in method + the Security panel's no-password note now name the actual provider via `PROVIDER_LABELS` (was hard-coded "Google").

**Not yet verified (needs the user):** Google round-trip regression from the new stack (only provider configured on non-prod); GitHub/Microsoft/Facebook buttons show a clean error until configured — **Supabase provider setup is a user task** (GitHub OAuth app, Azure app registration, Facebook app; each needs the Supabase callback URL). Signup: checkbox gating across all four + Create account.

### Where to resume
- The revamp's known punch-list is now **empty**. Remaining pre-Phase-6: the user's real-account verification backlog (incl. the 3c migration-prompt retest + `0002` re-apply), OAuth provider config in Supabase (new), per-file size limit, legal content. Then **Phase 6** (production gate, ADR-014).

---

## 2026-07-06 — Account sidebar + Round B (alignment pass) done; migration-prompt never-fired bug found & fixed

Two user-requested tweaks, then the whole Round B alignment pass (app repo, `cloud-epic` working tree). Build clean; everything verified light + dark (+ mobile 390px) via the scratchpad harness (`shoot-revamp.cjs`, extended with signed-out surfaces, mobile viewports, a sidebar-click check, and a seeded-IndexedDB migration-prompt scenario).

**User tweaks:**
- **Account page sidebar** (the "sidebar settings shell" previously deferred): a sticky left nav with the six section entries; click scrolls to the panel (smooth, inside the page's own scroll container), the active entry tracks scroll via IntersectionObserver (danger entry highlights error-tinted), hidden ≤900px where the single column stands alone. Layout: `account-shell` (62rem) → `account-body` = nav (13rem, sticky) + `account-main` (46rem).
- **"Back to editor" enlarged** (default Button size, was `small`) on `/account` + `/files`.

**Round B:**
- **`NotFound.vue`** — last wordmark holdout fixed (icon + HTML text). Also dropped its `prefers-color-scheme` duplicate block: the colour-mode store stamps `html.dark` pre-render on every route, and an OS fallback would override an explicit in-app light choice.
- **`CloudMigrationPrompt`** — copy polish (names the feature count; "nothing is moved or deleted"; upload icon on the CTA). **And a real bug found by the audit: the prompt could never fire on login.** It was hosted inside `FileToolbar`, but toolbars mount only while their menu tab is selected and the default tab is **Draw** (MapView briefly sets File, then AppMenu's app-ready watch switches to Draw, unmounting it). **Moved to `MapView`** (`v-if="isCloudMode && appReadyState.isAppReady"` — app-ready also guarantees `fileService` is assigned and passed on that re-render). Screenshot-proven firing from the Draw tab. *This re-opens Phase 3c's "prompt appears on login" verification — retest against real Supabase.*
- **`privacy.html` / `terms.html`** — checked, no changes: already the full design language (Funnel Sans/JetBrains Mono, grid, accent), correct icon+text brand, consistent footers; `prefers-color-scheme` is right for static pages outside the app toggle.
- **Dark + responsive audit** — swept landing/login/account/files/chrome/404 in dark + 390px. One fix: the **landing nav overflowed at 390px** ("Sign in" wrapped, CTA past the right edge) → tightened gaps + nowrap ≤640px, icon-only brand ≤480px. Everything else held (files table drops the date column, account sidebar hides, login card scales).

**Not yet verified (needs the user, real account):** the migration prompt end-to-end (Phase 3c retest — appears on login *without* touching the File tab, Save round-trip, Not now, no-prompt cases); sidebar feel on a real session; plus the standing real-account backlog and the `0002` re-apply from 2026-07-05.

### Where to resume
- **Gather the user's `/login` cosmetic notes** (still uncaptured — the last open Round B item), fix, then the pre-Phase-6 loose ends: user's real-account verification backlog, per-file size limit (user's large-file testing), legal content finalisation. Then **Phase 6** (production provisioning gate, ADR-014).

---

## 2026-07-05 — Round A done: account-page round-2 critiques captured & implemented, Security + Billing panels, toolbar Open button, name-length limit

The user supplied the previously-uncaptured round-2 critiques and they're all built (app repo, `cloud-epic` working tree). Build clean (~1s, code-split held — AccountView ~15.5 kB async chunk, SDK out of main). Verified light + dark via a **recreated fake-session Playwright harness** (`shoot-revamp.cjs`, scratchpad, session-local — same pattern as 2026-07-04: injected unexpired session + route-mocked REST; `user_files` mock honours `limit=1`).

**Account page (`AccountView.vue`):**
- **"Back to editor" moved to the top** (top-left, above the brand header; footer removed) — bottom placement was easily missed on a long page. Same on `/files`. (`/login` has no such link — it's short and pre-editor; left as is.)
- **Panels restyled to the export/style-dialog idiom:** compact headers (`0.5rem 1.25rem`), **secondary-coloured** 0.875rem header icons (was primary), 0.875rem titles, inter-panel gap 1.1 → 1.75rem. Danger zone keeps its error tint. Same treatment applied to the `/files` panel.
- **New Security panel** (after Profile; the deferred /login-chunk item): email-provider accounts get inline new/confirm password fields → `updatePassword` (no current password needed — the session authorises), plus a "send a reset link" alternative reusing the /login forgot→reset flow; Google-only accounts (detected via `app_metadata.providers`) get an explanatory note instead.
- **New Billing panel** (after Plan & usage): placeholder — disabled "Manage billing" button + "None on file / No invoices yet" details. **Confirmed relevant with Stripe** (user asked): ADR-022's Checkout + **Customer Portal** means Stripe hosts the billing-history/payment-method UI, so this panel stays a thin portal entry point even once live.

**Chrome:**
- **File toolbar: cloud files button moved between New and Import and renamed "My Files" → "Open"** (desktop-app convention). Tooltip now "Open a file from your cloud files". The AccountMenu overlay item keeps the "My Files" label (it names the page).
- **`/files`: "New File" button removed** from the panel header (New lives on the File toolbar; `startNewFile` handler dropped).
- **ActiveFileChip + AccountMenu avatar hover normalised:** pill radius (999px) → 6px, hover = neutral `--p-content-hover-background` wash (was primary-blue border + blue-tinted bg — flagged as non-standard). Avatar image itself stays circular.

**File name length limit — didn't exist; added.** DB column was unconstrained `text`; no input bounded it. Now: `MAX_FILE_NAME_LENGTH = 100` (`file-constants.js`) — `maxlength` on both rename inputs (chip + /files), clamp in the active-file store (`clampName` — the single choke point for create/rename), and an **idempotent CHECK constraint amended into `0002_multi_file.sql`** (cloud repo, per the ADR-023 pre-prod amendment policy). **User: re-apply `0002` to non-prod** (drop-then-add pair; safe to re-run).

**Pre-existing bug found & fixed:** `#app` is a fixed `100vh` flex column and `#main` gets `flex: 1`, so a routed page taller than the viewport **overflows its own root box — the grid background stopped at the first viewport** on the (now longer) account page. Scoped fix on `/account` + `/files` (global layout untouched): the page root becomes its own scroll container (`height: 100vh; overflow-y: auto`) with `background-attachment: local` so the grid paints the full scroll height. Note: page screenshots now need a tall viewport, not `fullPage` (the scroll is inside the page root).

**Not yet verified (needs the user, real account on staging/local):** password change round-trip (incl. wrong-length/mismatch errors) + the reset-link path from /account; Google-account variant shows the note (harness only faked an email account); the whole pre-existing real-account backlog from 2026-07-04 still stands; and **re-apply `0002`** before rename-length testing.

### Where to resume — Round B (final alignment pass)
- Gather the user's `/login` cosmetic notes (still uncaptured), then: `NotFound.vue` wordmark fix (last holdout), `CloudMigrationPrompt.vue` polish, `privacy.html`/`terms.html` styling check, cross-surface dark + responsive audit, docs sync.

---

## 2026-07-04 — Session paused for handoff: 4 of 6 revamp chunks done, two rounds remain

The UI/UX revamp (rollout near-term step 3) is being handed to a **fresh session**. This entry is the resume point; the four dated entries below have the per-chunk detail.

**Done (4 of 6 chunks), each verified visually light + dark via the scratchpad fake-session Playwright harness — real-account round-trips still owed (see the backlog list at the end):**
1. Landing page (Phase 7 Stage 1 pulled forward) + `/` `/app` routes.
2. `/login` page (LoginDialog deleted; forgot/reset flow added).
3. In-app chrome — avatar account menu + menubar active-file chip + AppMenu brand fix.
4. `/files` page (MyFilesDialog deleted).

**Round A — Account page polish, round 2 (task #6).** The account page was rebuilt as sectioned PrimeVue Panels and the user approved it but said *"better, but we'll come back and polish it up again"* — **the specific critiques were not captured, so round 2 starts by asking the user what they want changed.** One item is already scoped: wire a **Security panel** (change / reset password) into `AccountView.vue`, **reusing the `/login` reset flow** — `auth.js` already has `resetPasswordForEmail` + `updatePassword`; the Security panel was deliberately deferred out of the account chunk so the reset flow was built once, on `/login`. Fold in any layout refinements now that the account page-family (`/login`, `/account`, `/files`) shares one idiom.

**Round B — Final alignment pass across remaining cloud surfaces (task #5).**
- **`NotFound.vue`** — the **last wordmark holdout**: still uses `logo-rectangle-dist.svg`, which follows the OS `prefers-color-scheme` rather than the app's `html.dark` toggle. Apply the about.html brand pattern (`logo-icon-only.svg` + HTML "GeoJSON Studio" text styled by tokens), as already done on the landing nav, the account/login/files headers, and AppMenu.
- **`CloudMigrationPrompt.vue`** — polish to production quality (not reviewed this session).
- **`public/privacy.html` / `public/terms.html`** — styling check against the current design language (the *content* stays the user's).
- **Dark-mode + responsive audit** across every cloud surface — a deliberate cross-surface sweep, beyond the per-chunk harness shots.
- **Gather the user's `/login` cosmetic notes** — after the login chunk the user said *"I noticed some small cosmetic issues but we will come back and address these later"*; specifics not captured, so this round also **starts by asking**.
- **Docs sync** at the end.

**Consolidated user-verification backlog (real accounts, staging/local — pending; does not block the two rounds).** Nothing below is checked against real Supabase — the harness only proves layout/behaviour with mocked data:
- *Landing/routing:* `/?ff=cloud` → landing (light/dark/mobile); bare `/` → editor unchanged; `/app`; flag-off e2e.
- *`/login`:* email sign-in + signup→confirm→sign-in; Google OAuth returning to `/app?ff=cloud`; the full forgot→email→reset→lands-in-editor flow (first time it exists — confirm the staging redirect allow-list covers `/login?ff=cloud&mode=reset`).
- *Chrome:* chip rename persists + reflects in the list; Google avatar photo renders (harness shows only the initial badge); unsaved-blank chip after File→New.
- *`/files`:* open/switch round-trip; New File → blank editor → first edit creates a row; delete (incl. the open file → blank editor); rename persistence; the "Open" badge on a cold `/files` load; two-account isolation.
- *Account:* real usage figures; avatar/Google variant; export + delete round-trips.

**Working tree.** All four chunks live in the **app repo** (`geojson-studio-app`, `cloud-epic`) working tree; these doc edits are in the **cloud repo**. Git is the user's — the fresh session picks up the live working tree as-is (deleted: `LoginDialog.vue`, `MyFilesDialog.vue`; new: `LandingView`/`RootView`/`LoginView`/`FilesView`/`ActiveFileChip`; rewritten: `AccountView`/`AccountMenu`). The scratchpad harness scripts (`shoot-{landing,account,chrome,files}.cjs`, `capture-hero.cjs`; PROJECT_REF `eprkeuxtnnijaenqbrie`) are session-local and not in either repo.

### Where to resume
1. **Round A (task #6)** — ask the user for their account-page round-2 critiques; wire the Security panel via the existing reset flow; apply layout refinements.
2. **Round B (task #5)** — NotFound logo fix, CloudMigrationPrompt polish, privacy/terms styling, dark/responsive audit; gather the user's `/login` cosmetic notes; sync docs.

---

## 2026-07-04 — /files page built; MyFilesDialog deleted (ADR-029 completed)

Fifth revamp chunk. My Files is now a **dedicated route** — the second half of ADR-029 (ADR-018 status annotated: only the browsing *surface* moved; the file lifecycle rules are unchanged).

**Built (app repo):**
- **`src/views/FilesView.vue`** (new, ~9 kB async chunk) — the library page on the account area's idiom (grid background, brand header, a PrimeVue Panel): **table layout** (Name / Last edited columns; ellipsised names; relative dates), active row highlighted with an **"Open" tag**, per-row **inline rename** (Enter/Esc + check/cancel buttons) and **delete** (ConfirmDialog), **New File** in the panel header, empty + loading + error states, "Back to editor" footer. Responsive: the date column drops at 640px.
- **Behavioural shift from the dialog:** the editor is unmounted while the page shows, so **open = `adoptActiveFile` + navigate to `/app`** (the editor's startup load reads the adopted row through the seam — no in-place `reloadFromStorage`); **New File = `startNewBlank` + navigate**; deleting the open file detaches it, so the editor returns blank. On a **cold direct load** the view awaits `ensureResolved()` before listing so the "Open" badge is correct.
- **Router** — `/files` route (lazy); the guard's signed-in branch now covers `Account` + `Files` (logged-out → `/login`).
- **`AccountMenu`** — the overlay menu gains **My Files** (above Account). **`FileToolbar`** — the "My Files" button navigates to `/files` (dialog import/state removed). **`MyFilesDialog.vue` deleted.**

**Build:** clean; FilesView is its own async chunk; flag-off untouched. Verified visually light + dark via the fake-session harness (`shoot-files.cjs` — note: the `user_files` mock must honour `limit=1`, since `resolveMostRecentFile`'s `maybeSingle()` errors on multiple rows).

**Not yet verified (needs the user, real accounts):** open/switch round-trip (file list → open → editor shows that file), New File → blank editor → first edit creates a row, delete (incl. the open file → blank editor on return), rename persistence, the "Open" badge on a cold `/files` load, two-account isolation on the list, flag-off e2e.

### Where to resume — account round-2 polish, then the alignment pass
- Task #6: gather the user's account-page round-2 critiques + the noted /login cosmetic issues; hook up the Security panel using the /login reset flow. Then task #5 (CloudMigrationPrompt, NotFound logo, compliance styling, dark/responsive audit). ADR-029 is now fully realised; remaining known wordmark holdout: `NotFound.vue`.

---

## 2026-07-04 — In-app chrome: avatar account entry, menubar file chip, brand fix

Fourth revamp chunk (task: in-app chrome). The user flagged the signed-in account entry's look (raw email as a text button) and the active file's name sitting as a button on the File toolbar "next to Export, which is weird".

**Built (app repo):**
- **`src/components/nav/ActiveFileChip.vue`** (new, ~1.6 kB async chunk, flag-gated like AccountMenu) — a pill chip in the menubar's end cluster showing the active cloud file (`pi-cloud` icon + name, ellipsised): **click to rename inline** (Enter/blur saves, Esc cancels; store `rename()`); a blank unsaved file (no row yet — ADR-018 lazy creation) shows an italic "Untitled", non-clickable, with an explanatory tooltip. **Designated future home of the ADR-025 save-status indicator.** Self-gates on `isLoggedIn`.
- **`AccountMenu.vue`** — signed-in entry is now an **avatar chip** (Google `avatar_url` photo or initial badge + caret; tooltip "Account") instead of the email text button; the overlay menu gains a **header** (name/email via the Menu `#start` slot) above Account / Sign out. Signed-out "Sign in" button unchanged (→ `/login`).
- **`FileToolbar.vue`** — the cloud button's label is a fixed **"My Files"** (was: the active file's name); it remains only the library entry point.
- **`AppMenu.vue`** — branding switched to the about.html pattern (**`logo-icon-only.svg` + HTML "GeoJSON Studio" text** + Beta tag), fixing the wordmark's OS-vs-`html.dark` mismatch in the editor itself; `min-height: 42px` preserves the previous menubar height. *(NotFound.vue is now the last wordmark holdout — alignment pass.)*

**Build:** clean; ActiveFileChip + AccountMenu are separate async chunks; flag-off fetches neither (branding change is the only flag-off-visible diff, deliberate bug fix). Verified visually light + dark via the fake-session harness (`shoot-chrome.cjs`): chip + avatar + brand render correctly; menubar brand now legible in dark mode.

**Not yet verified (needs the user):** chip rename round-trip against real Supabase (persists + My Files list reflects it); Google-account avatar photo renders (harness only covers the initial badge); unsaved-blank chip state after File→New; menu header contents; flag-off menubar unchanged bar the new brand rendering; e2e.

### Where to resume — /files page
- Next: task #4 — replace MyFilesDialog with a `/files` page (ADR-029 pre-authorises the shape), wiring open/switch via `reloadFromStorage` after navigation back to `/app`; add a "My Files" item to the account overlay menu; then account round-2 polish (task #6), then the alignment pass (task #5).

---

## 2026-07-04 — /login page built; LoginDialog deleted (ADR-029)

Third revamp chunk. Login is now a **dedicated route**, recorded as **ADR-029** ("cloud account surfaces are routes, not dialogs" — covers `/login` now and `/files` next; extends ADR-027, supersedes the Phase 1 dialog).

**Built (app repo):**
- **`src/views/LoginView.vue`** (new, ~11 kB async chunk) — centred-card auth page on the account page's visual idiom (grid background, icon+text brand, gs tokens). **Four modes** seeded from `?mode=`: `signin` (default; "Forgot password?" link), `signup` (terms checkbox gating both Create account **and** Google — unchanged rule), `forgot` (new), `reset` (new). Success → full navigation to `/app?ff=cloud` (ADR-004 re-bootstrap).
- **Forgot/reset password flow** (previously missing entirely): `auth.js` gains `resetPasswordForEmail(email)` (recovery link targets `/login?ff=cloud&mode=reset`) and `updatePassword(newPassword)`; the recovery email signs the user in and lands on the reset form. `signInWithGoogle(redirectPath)` parametrised — the login page passes `/app` so the OAuth round-trip lands in the editor.
- **Router** — `/login` route (lazy); guard extended: `/login` needs the flag and bounces signed-in users to `/app` **except** `mode=reset`; `/account`'s logged-out redirect now goes to **`/login`** (was: landing).
- **`AccountMenu.vue`** — "Sign in" navigates to `/login` (dialog import/markup removed; chunk shrank ~6 kB → ~1.1 kB). **`LoginDialog.vue` deleted.**
- **Landing** — nav "Sign in" → `/login`; cloud + Basic/Pro "Get early access" CTAs → `/login?mode=signup`.

**Build:** clean; LoginView is its own async chunk; flag-off untouched. Visually verified signin/signup/forgot in light + dark (dev server screenshots; signup correctly disables both buttons until terms ticked).

**Not yet verified (needs the user, real accounts on staging/local):** email+password sign-in and signup→confirm→sign-in round-trips from `/login`; Google OAuth now returning to **`/app?ff=cloud`**; the full **forgot→email→reset→lands in editor** flow (first time this exists — also confirm the staging `/**` redirect allow-list matches `/login?ff=cloud&mode=reset`); signed-in visits to `/login` bounce to the editor; flag-off e2e.

### Where to resume — in-app chrome
- Next chunk (task #3): avatar-chip account entry + the active-file name chip in the menubar (moving it off the File toolbar), plus the AppMenu wordmark dark-mode fix. Then `/files` (task #4), account round-2 polish (task #6), final alignment pass (task #5).

---

## 2026-07-04 — Account page redesigned (sectioned PrimeVue Panels)

Second revamp chunk, same session as the landing. The user judged the Phase 5 account page "plain — looks like a dialog"; options were assessed (sectioned cards à la Stripe/Supabase; sidebar settings shell — premature until Phase 8; two-column dashboard; enrich-in-place) and **sectioned single-column** chosen, with the user's tweak: **PrimeVue `Panel`s, not custom cards** (matching FileExportDialog's panel usage). Sidebar shell noted as the post-Phase-8 evolution.

**Rebuilt `AccountView.vue`** as four Panels (46rem column, grid background + brand header retained):
- **Profile** — avatar (Google `user_metadata.avatar_url`, initial-badge fallback) + email + **Sign out** (new; lands on the landing with the flag, full navigation re-bootstrap per ADR-004); Member since (`created_at`), Sign-in method (`app_metadata.provider`).
- **Plan & usage** — "Early access" Tag + note; **usage meter** (`ProgressBar`) against a **placeholder 1 GB allowance** (`QUOTA_BYTES` — real quotas are Phase 8/ADR-022) with bytes/file-count caption. Makes the storage-based-pricing story visible.
- **Data & privacy** — export (unchanged mechanics) + **terms-acceptance record** (new client-direct read `getTermsAcceptance()` in `account-data.js`, owner-scoped by user_profiles RLS) + policy links.
- **Danger zone** — delete (unchanged mechanics), error-tinted panel border/header via the unscoped-block override pattern (no `:deep()`).
- Deferred into the /login chunk: a **Security panel** (password change/reset) — so the reset flow is built once.

**Brand/logo dark-mode bug found & fixed:** `logo-rectangle-dist.svg` adapts via its internal `prefers-color-scheme` media query, i.e. it follows the **OS**, not the app's `html.dark` toggle — OS-light + app-dark rendered a black wordmark on a dark page. Fixed on the landing nav + account header with the **about.html brand pattern** (colour-stable `logo-icon-only.svg` + HTML "GeoJSON Studio" text styled by tokens). **Still affected (pre-existing, fix with their own chunks): `AppMenu.vue` menubar branding (chrome chunk) and `NotFound.vue` (alignment pass).**

**Verification:** build clean (AccountView ~12 kB / LandingView ~17 kB async chunks; SDK still out of main). Visually verified light+dark via Playwright against the dev server using an **injected fake unexpired Supabase session + route-mocked REST reads** (scratchpad `shoot-account.cjs` — no real auth touched; note: with a signed-in session the colour mode comes from cloud settings (ADR-017), so dark is emulated via the OS `colorScheme`, not `localStorage`). **User still to verify on staging** (real account: avatar/Google variant, real usage figures, export/delete round-trip).

### Where to resume — auth page (/login)
- Unchanged: `/login` next (sign-in/up + Google + terms + forgot-password + Security panel hookup), then chrome (avatar chip + file-name chip + AppMenu logo fix), then `/files`, then the alignment pass (CloudMigrationPrompt, NotFound logo, compliance-page styling, dark/responsive audit).

---

## 2026-07-04 — UI/UX revamp begins: landing page built (Phase 7 Stage 1 pulled forward)

First chunk of the UI/UX revamp (rollout near-term step 3). **Session decisions** (user): design order is **landing first** (sets the end-to-end look), then the other surfaces; the Stage 1 landing is built as the **real product design** (ported to static HTML at Stage 2, not redesigned); pricing shows **three placeholder tiers** — Free / Basic **$5/mo** / Pro **$15/mo** with placeholder feature bullets (real plans still the user's, per backlog); the visual direction **extends the existing identity** (PrimeVue blue + the `about.html` design language: Funnel Sans / JetBrains Mono, grid-paper background, `#2e5fa3` accent, JSON-syntax motifs). Also agreed for later chunks: **login becomes a dedicated page** (replacing LoginDialog, adding the missing forgot-password flow), **My Files becomes a page** (replacing the dialog), the **account entry** gets an avatar-chip treatment, and the **active-file name moves out of the File toolbar** into a menubar document chip (future home of the ADR-025 save-status indicator). The dialogs→pages change gets its own ADR when built.

**Built (app repo, per ADR-024 Stage 1):**
- **`src/views/LandingView.vue`** (new, async chunk ~13 kB js + 11 kB css) — the full marketing page: sticky nav, hero (tagline *"The modern, intuitive GeoJSON editor"* + CTAs), a real editor screenshot in a browser-frame mock (light/dark variants swap with the resolved colour mode; only one downloads), 6-card feature grid, free-vs-cloud "duality" split (JSON-snippet motif), 3-tier pricing, FAQ (`<details>`), closing CTA, footer. Plain HTML/CSS in one self-contained component for the Stage 2 static port; fonts injected on mount only; dark mode keys off `html.dark` (stamped pre-render by the colour-mode store — AccountView precedent); responsive at 900/640 px.
- **`src/views/RootView.vue`** (new) — `/` branches by the flag: on → async LandingView, off → MapView (vanilla, byte-identical).
- **Router** — `/` → RootView (name `Root`), **`/app` → MapView** (name `Editor`; route names were unreferenced). Account guard unchanged: logged-out flag-on visitors to `/account` now land on the landing.
- **`AccountView.backToApp`** → `/app?ff=cloud` (the flag-on root is now the landing).
- **`NarrowScreenWarningDialog` moved App.vue → MapView.vue** — editor-only; no longer covers the landing or `/account` on small screens.
- **Hero screenshots** — captured off **staging** by a Playwright script (scratchpad; not the e2e suite) that seeds `welcomed` + IndexedDB (`GeoJSONStudio` v20, `geoJson` store) with `Data/taiwan.geojson` on the `about.html` origin page, then shoots 1440×900@2x; light (streets) + dark (`dark-v11` basemap) → `src/assets/img/landing/editor-{light,dark}.jpg` (jpeg q85, ~410/335 kB).
- **Interim links:** all landing CTAs (incl. nav "Sign in" and the paid-tier "Get early access") → `/app?ff=cloud`; rewired to `/login` when the auth page lands.

**Build:** clean (vite 8 / rolldown, ~2s). LandingView is its own async chunk — never fetched flag-off; no SDK in main; flag-off `/` structurally unchanged. Landing verified by full-page screenshots (light/dark/mobile) against the dev server.

**Not yet verified (needs the user, on staging after push):** `/?ff=cloud` → landing (light + dark + mobile); bare `/` → editor unchanged; `/app` + `/app?ff=cloud` → editor; account page "Back to editor" → `/app?ff=cloud`; flag-off e2e suite.

### Where to resume — auth page (/login)
- Next chunk: dedicated `/login` route on the landing's design language (sign-in / create-account modes, Google, terms checkbox, confirm-email messaging, **new forgot-password flow** via `resetPasswordForEmail` + reset view); delete LoginDialog; rewire the landing/nav CTAs; record the dialogs→pages ADR. Then in-app chrome (avatar chip + file-name chip), then `/files`, then the alignment pass.

---

## 2026-07-03 — cloud-epic live on staging; deploy reconfiguration verified (ADR-028)

User verified the whole ADR-028 setup end-to-end: **`cloud-epic` → `staging.geojsonstudio.com`** (cloud live behind `?ff=cloud`, account flow working), **`main` → production** unchanged, and the **`staging` branch deploys nowhere** (trigger flipped to `[cloud-epic]` on both `cloud-epic` and `staging`, both repos; the staging branch reaches prod only via a PR into `main`). Staging reuses the **non-prod** Supabase (no new project); `ACCOUNT_API_ENABLED=true` on `backend-staging` so account deletion works there too.

**Debugging captured (will recur at the prod gate):**
- **Google OAuth returned to `localhost`** on staging → Supabase fell back to the **Site URL** because the staging `redirect_to` didn't match the **Redirect URLs** allow-list. Fixed by adding **both** `https://staging.geojsonstudio.com` **and** `https://staging.geojsonstudio.com/**` — the bare origin matters because the app redirects to the root `/?ff=cloud`, which `/**` alone didn't match. (Locally this was masked: a redirect to the same origin as the Site URL is auto-allowed.)
- **`emailRedirectTo`** added to `signUpWithPassword` (`auth.js`) so email-confirmation links follow the current origin (localhost / staging / prod) instead of the single Site URL.

**Next: the UI/UX revamp** — the largest remaining pre-production workstream (all the new cloud surfaces), iterated locally + verified on staging.

### Where to resume — UI/UX revamp
- Inventory + polish the new cloud surfaces: LoginDialog, AccountMenu, AccountView, CloudMigrationPrompt, MyFilesDialog (privacy/terms **content** is the user's). Then the loose ends (per-file size limit, storage constraints, legal content) → final polish → **Phase 6** production. Prod provisioning (separate Supabase project + Google callback + per-env `VITE_SUPABASE_*`) remains the ADR-014 gate.

---

## 2026-07-03 — Branch/deploy decision: cloud-epic → staging (Option 2, ADR-028); near-term plan = staging preview + UI/UX polish

Planning + CI wiring — **no app code.** Decided how to get the long-lived `cloud-epic` branch onto a real deployed environment for validation + polish **before** the production gate. Recorded as **ADR-028**.

**Decision (Option 2):** repoint the staging deploy from the `staging` branch to `cloud-epic` (both repos), so `cloud-epic` → `staging.geojsonstudio.com` while `main` → production stays untouched. The `staging` branch stays a normal integration branch (push + PR to `main`) but deploys nowhere. **Key gotcha:** GitHub Actions runs the workflow **from the pushed branch**, so the trigger change must land on **both** cloud-epic (to enable) **and** the `staging` branch (to stop it clobbering the cloud-epic build); `main` keeps its inert copy. Options 1 (keep staging branch deploying) and 3 (dedicated `cloud.` subdomain) considered — rejected / reserved.

**CI edits staged on cloud-epic (this session):**
- **app** `.github/workflows/deploy-staging.yml` — trigger `[staging]`→`[cloud-epic]` + `VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY` build-args; **`Dockerfile.staging`** — matching `ARG`/`ENV`.
- **api** `.github/workflows/deploy-staging.yml` — trigger `[staging]`→`[cloud-epic]` + `SUPABASE_URL,SUPABASE_PUBLISHABLE_KEY,SUPABASE_SERVICE_ROLE_KEY,ACCOUNT_API_ENABLED=true` on `--set-env-vars`.

**Cloud on staging reuses the existing non-prod Supabase (no new project).** Still needs the user to: create the `staging` GitHub Environment Variables/Secrets (non-prod Supabase values) in **both** repos; add the staging origin to the non-prod Supabase Auth **Redirect URLs / Site URL** (OAuth + email confirmation); apply the same trigger change on the **`staging` branch**; confirm `staging.geojsonstudio.com` is domain-mapped to `frontend-staging`. (Push cloud-epic *before* the GH vars exist = dark deploy to verify the pipeline; create them + re-push = cloud live.)

**Near-term plan (re-sequenced; see rollout note):** (1) reconfigure deploys, (2) verify cloud on staging incl. `?ff=cloud`, (3) UI/UX revamp of all new cloud surfaces (pulls the **landing / Phase 7 Stage 1** forward), (4) bugs & loose ends (per-file size limit, legal content, storage constraints), (5) final polish → then **Phase 6** production (**kept deferred**).

**Docs touched:** new **ADR-028**; rollout gains the near-term note before Phase 6.

### Where to resume — reconfigure + verify on staging
- User: create the staging GH env vars/secrets (both repos) + Supabase Auth URLs for the staging origin + the `staging`-branch trigger edit + confirm the domain mapping, then push cloud-epic → verify `staging.geojsonstudio.com` + `?ff=cloud`. Then the **UI/UX revamp** (biggest workstream) — best iterated locally, verified on staging. User handles git.

---

## 2026-07-03 — Phase 5 verified complete

User verified the account area against **non-prod**: the `/account` page shows email + storage used, and **account deletion succeeded** end-to-end (after starting the local backend API so the Phase 4 delete endpoint was reachable). Reports being happy with it. With 5a (compliance pages) + 5b (account page: usage / export / delete) + 5c (terms acceptance) all in, **Phase 5 is done.** The one open Phase-5 thread is the user finalising the **legal content** of the drafted `privacy.html` / `terms.html` before real users arrive.

**Next: Phase 6 — free beta / early access**, the **production-provisioning gate** (ADR-014) — the first time the epic leaves non-prod.

---

## 2026-07-02 — Phase 5 implemented (5a–5c: account area + compliance) — code-complete

Built all three Phase 5 slices per ADR-027. **Build clean** (vite 8 / rolldown, ~1.05s); the code-split held — `AccountView`, `terms-acceptance`, and the account UI stay out of main, and `supabase-client` remains a separate ~201 kB async chunk (no SDK in main). Ships behind `?ff=cloud`. **Pending the user: apply `0003` + `0004` to non-prod, plus the manual gate below.**

**Slice 5a — compliance pages (app repo):**
- `public/privacy.html` + `public/terms.html` — hand-written static pages mirroring `about.html` (shared theming, TOC, sections, footer), served by nginx's static fallback at `/privacy.html` / `/terms.html`. Draft content with `[placeholders]` for owner-specific legal bits (legal entity, governing law, minimum age); user finalises later.
- `public/about.html` — added a footer link row (App / About / Terms / Privacy).

**Slice 5b — My Account page (cloud + app repos):**
- `0003_storage_usage_view.sql` — `public.user_storage_usage` (`security_invoker`; `sum(octet_length(geojson::text))` + `count(*)`; owner-scoped via user_files RLS; grant select to authenticated).
- `src/views/AccountView.vue` — lazy / code-split `/account` route: email, storage used, **Export my data** (client-direct bundle → JSON download), **Delete account** (Phase 4 endpoint + confirm → sign out → anonymous `/`), a Phase 8 billing stub, and Privacy/Terms links.
- `src/services/account/account-data.js` — client-direct `getStorageUsage` / `buildExportBundle` / `deleteAccount`.
- `src/router/index.js` — `/account` route + `beforeEach` guard (cloud flag on + signed in, else redirect to `/`; flag-preserving nav; stays dark when the flag is off).
- `src/components/auth/AccountMenu.vue` — an "Account" item (→ `/account?ff=cloud`) above Sign out.
- `src/constants/api-constants.js` + `src/config/index.js` — `API_ENDPOINT_ACCOUNT_DELETE` / `config.api.accountDelete`.

**Slice 5c — terms acceptance (cloud + app repos):**
- `0004_user_profiles.sql` — generic per-user `public.user_profiles` (owner-only RLS: select/insert/update; **no delete** — cascade only); first columns `terms_accepted_at` + `terms_version`.
- `src/components/auth/LoginDialog.vue` — a **required** terms checkbox on the signup tab (links to the pages) gating both **Create account** and **Continue with Google** (Google gated only in signup mode).
- `src/services/account/terms-acceptance.js` — `recordTermsAcceptanceOnFirstLogin()` (idempotent upsert; `TERMS_VERSION = "2026-07-02"`), wired **fire-and-forget after mount** in `main.js` (flag-on only).

**Not yet verified — the Phase 5 gate (needs the user):**
1. Apply `0003` + `0004` to non-prod (SQL Editor); confirm the view + table + RLS per the migrations README.
2. Compliance: `/privacy.html` + `/terms.html` render and are styled like about.html; review/finalise the legal content + `[placeholders]`.
3. Account page: flag-on, signed in → AccountMenu → **Account**; email + storage figure correct; **Export** downloads a complete bundle; **Delete account** removes the account (cascade) → anonymous. (Needs `ACCOUNT_API_ENABLED=true` on the API + CORS for the app origin.)
4. Terms: signup blocked until the box is ticked (email + Google); after first login a `user_profiles` row exists with timestamp + version; a repeat login doesn't overwrite it; two-account RLS holds on the view + table; flag-off / anonymous never touches either.

### Where to resume — Phase 5 verification, then Phase 6
- Once the user applies the migrations + passes the gate, Phase 5 is done. Next is **Phase 6 — free beta / early access**, the **production-provisioning gate** (ADR-014): create the prod Supabase project, apply `0001`–`0004`, wire per-env `VITE_SUPABASE_*`, then the allowlist cohort. User handles git + e2e + migrations.

---

## 2026-07-02 — Phase 5 design agreed (ADR-027); ready to implement Slice 5a

Design session for **Phase 5 — account area + compliance** — **no code yet.** Grounded in the real repos first (app `vue-router` with base = `import.meta.env.BASE_URL`; the `public/about.html` static-page pattern served by nginx's `try_files … /index.html` fallback; api Phase 4 `createSupabaseAuth` + `POST /api/v1/account/delete`). Recorded as **ADR-027**; rollout Phase 5 fleshed into three slices.

**Decisions:**
- **Usage + export are client-direct (RLS); no new Node endpoints** — pure owner reads need no secret (ADR-002). Usage = a `public.user_storage_usage` view (`security_invoker`, `sum(octet_length(geojson::text))` + `count(*)`); export = the client packages its own `user_files` + `user_settings` into one JSON bundle. Deletion reuses the Phase 4 endpoint. **Supersedes-in-part** ADR-026's assumption that Phase 5 adds Node endpoints.
- **My Account is a dedicated `/account` route** (lazy / code-split `AccountView.vue`, flag+auth-guarded, `?ff=cloud`-preserving nav, `AccountMenu` entry), not a dialog — SaaS convention; rides `BASE_URL` → becomes `/app/account` after Phase 7.
- **Compliance = static HTML** (`public/privacy.html` + `public/terms.html`) mirroring `about.html`; no infra change. Content drafted by me, edited by the user later.
- **Terms acceptance in a generic `public.user_profiles` table** (user's call — not the narrow `terms_acceptances`, and not `user_settings`, which is preferences-only): one row per user, `terms_accepted_at` + `terms_version` first, room for future per-user fields. A **required** signup checkbox gates both password + Google; the row is written on **first login** (idempotent), since confirm-email / OAuth leave no authenticated session at the signup instant.

**Migrations (user applies to non-prod):** `0003_storage_usage_view.sql`, `0004_user_profiles.sql`.

**Docs touched:** new **ADR-027** (+ ADR-026 annotated with the supersede-in-part pointer); rollout Phase 5 rewritten as slices 5a–5c; backlog compliance/ops updated (deletion done; export + terms in Phase 5) with new deferrals (reconcile `about.html` privacy at launch, terms re-acceptance on version bump, export-as-zip, `user_profiles` future fields); `00-overview.md` status refreshed to Phases 0–4 done / Phase 5 starting.

### Where to resume — Phase 5 · Slice 5a
- Author `public/privacy.html` + `public/terms.html` in `geojson-studio-app`, mirroring `about.html` (draft content — the user finalises the legal text). Then 5b (`0003` usage view + the `/account` route/view with usage / export / delete) and 5c (`0004` `user_profiles` + signup checkbox + first-login recording). The user applies migrations to non-prod and handles git + e2e.

---

## 2026-07-02 — Phase 4 verified complete

User ran the full round-trip against **non-prod**: filled the API `.env.local` (URL + `sb_publishable_…` + `sb_secret_…` as `SUPABASE_SERVICE_ROLE_KEY`), enabled the API, and `POST /api/v1/account/delete` with a real access token returned **204** — the `auth.users` row and the user's `user_files`/`user_settings` cascaded away. **Phase 4 is done.** Next: **Phase 5 — account area + compliance** (reuses `createSupabaseAuth`). Production provisioning remains the Phase 6 beta gate.

---

## 2026-07-02 — Phase 4 implemented (Node server layer + account deletion) — code-complete

Built Phase 4 in `geojson-studio-api` per ADR-026. **Jest: 7 suites / 161 tests pass** (147 pre-existing untouched + 14 new). Ships **dark** (`ACCOUNT_API_ENABLED=false` by default); **pending the user's manual round-trip against non-prod.**

**New files:**
- **`services/supabaseClients.js`** — `createSupabaseClients(config, deps)` returns a two-function wrapper: `verifyUser(token)` (→ `auth.getUser`, null on failure) and `deleteUser(id)` (→ `service_role` `auth.admin.deleteUser`, **tolerant of an already-deleted user** — 404/"not found" swallowed so concurrent/repeat calls stay clean). `deps.createClient` is injectable for tests.
- **`middlewares/supabaseAuth.js`** — `createSupabaseAuth(clients)` mirrors `createSessionAuth`: `Bearer` token → `verifyUser` → attaches `req.supabaseUser = {id,email}`, else 401. **No debug-secret bypass** (identity endpoint), **no open "disabled" mode** (only mounted when enabled).
- **`routes/accountRoute.js` + `controllers/accountController.js` + `services/accountService.js`** — `POST /api/v1/account/delete`; deletes `req.supabaseUser.id` **only** (never a body id), 204 on success. No body parser.
- **`tests/account.test.js`** (7) + **`tests/supabaseClients.test.js`** (7).

**Wiring:**
- **`app.js`** — new block *only when `config.accountApiEnabled`*: mounts `/api/v1/account` with its own tight rate limiter (`maxRequests: 10`, like `/session`) + `createSupabaseAuth`, then the route. Inherits the existing Cloudflare guard + logger on `/api`. **Turnstile path untouched** (session auth still scoped to convert/dataset; only registration lines added).
- **`index.js`** — config gains `accountApiEnabled`, `supabaseUrl`, `supabasePublishableKey`, `supabaseServiceRoleKey`.
- **`.env.template` / `.env.local`** — the four new vars (local defaults to `ACCOUNT_API_ENABLED=false`, empty Supabase values). **`SUPABASE_SERVICE_ROLE_KEY` is secret/server-only** — not committed with a value.
- **`tests/helpers/createTestApp.js`** — now takes an `overrides` object (used to enable the account API + inject stub clients).
- Added dep **`@supabase/supabase-js`**.

**Not yet verified — the Phase 4 gate (needs the user):**
1. Fill `.env.local` from the **non-prod** Supabase project (URL + publishable + `service_role`), set `ACCOUNT_API_ENABLED=true`, `npm run local`.
2. With a real non-prod dev-login access token: `POST /api/v1/account/delete` with `Authorization: Bearer <token>` → **204**; confirm the `auth.users` row is gone and `user_files`/`user_settings` cascaded away in the Supabase Table Editor.
3. No/invalid token → **401**; body-supplied id is ignored (only the token's user is deleted).
4. Confirm `admin.deleteUser`'s already-gone error shape matches `isUserNotFound` (adjust if Supabase returns a different status/message).

### Where to resume — Phase 5 (account area + compliance)
- Reuse `createSupabaseAuth` for the account-area endpoints (storage usage, data export). Deletion is already done. Prod provisioning is still the Phase 6 beta gate. User handles git + runs any manual/e2e checks.

---

## 2026-07-02 — Phase 4 design agreed (ADR-026); ready to implement

Design session for **Phase 4 — Node server layer (on non-prod)** — **no code yet.** Read the actual `geojson-studio-api` repo first (layered `routes→controllers→services`, `createApp(config)` DI, middleware factories with `enabled` flags, all endpoints `POST`/RPC-style, secrets read in `index.js` + documented in `.env.template`). Recorded as **ADR-026**; Phase 4 in [`03-rollout.md`](03-rollout.md) fleshed out.

**Decisions:**
- **Verify the Supabase JWT via `supabase.auth.getUser`** (delegate to Supabase) rather than local signature check — simplest correct option, catches revoked/deleted users, no crypto surface to own. Local JWKS/HS256 verify revisited only if a high-frequency authed endpoint ever needs it.
- **New `createSupabaseAuth` middleware** (mirrors `createSessionAuth`) → attaches `req.supabaseUser`; **two injected clients** (verify + `service_role` admin) so Jest can stub them.
- **Endpoint is `POST /api/v1/account/delete`, not `DELETE`** — the whole API is already all-`POST`/RPC-style (verified: zero DELETE/PUT anywhere), so an action-verb path is *more* consistent and reads as an action namespace (`/account/delete`, later `/account/export`). User raised this; agreed on the merits.
- **Self-only deletion**: targets `req.supabaseUser.id` from the verified token, never a body id (IDOR guard); no debug-secret bypass on an identity endpoint; handler tolerant of repeat calls. `admin.deleteUser` cascades to `user_files`/`user_settings`.
- **Scope**: deletion only this phase; usage/export deferred to Phase 5 (reusing the same middleware). New dep `@supabase/supabase-js`; new non-prod env `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` / `SUPABASE_SERVICE_ROLE_KEY` (secret) / `ACCOUNT_API_ENABLED` (ships dark).

**Q&A resolved:** (1) **No impact to the Turnstile code** — session auth stays scoped to convert/dataset; account routes get their own gate; `app.js` only gains registration lines; account endpoint inherits the Cloudflare guard + logger. Only shared touchpoint is the existing in-memory rate-limiter block Map (a block on one path applies to the others — pre-existing behaviour). (2) HTTP-method discussion → `POST /account/delete` (above).

**Docs touched:** new **ADR-026**; ADR-020 annotated (its first concrete build); rollout Phase 4 fleshed out with the file-by-file plan + validation.

### Where to resume — implement Phase 4 (on non-prod)
- In `geojson-studio-api`: add `@supabase/supabase-js`; `services/supabaseClients.js` (verify + admin, injected via `createApp` config); `middlewares/supabaseAuth.js` (`createSupabaseAuth` → `getUser` → `req.supabaseUser`); `routes/accountRoute.js` + `controllers/accountController.js` + `services/accountService.js` for `POST /api/v1/account/delete` (self-only, cascade, repeat-tolerant); wire config in `index.js` + `.env.template`; mount in `app.js` (new `/api/v1/account` group + tight limiter, no Turnstile changes); Jest tests with stubbed clients. The user handles git + runs tests.

---

## 2026-07-02 — Phase 3 verified complete

User confirmed **Slice 3c** (first-login opt-in migration) passes manual verification. With 3a/3b already verified, **Phase 3 is done** — logged-in users can create, switch, rename, and delete multiple named cloud files, and first-login local→cloud migration works. Large-file testing (→ per-file size limit) is deliberately deferred; it doesn't block Phase 4. **Next: Phase 4 — Node server layer (on non-prod).**

---

## 2026-07-02 — Defer production Supabase to the beta gate; Phase 4 is now non-prod-only

Planning tweak — **no code.** The user questioned why Phase 4 provisions the **production** Supabase project when we're nowhere near production-ready. Confirmed it doesn't need to, and it's more consistent with **ADR-014** ("non-prod only for now; defer prod until core is proven") to move it.

**Decision:** split the old Phase 4. Nothing between here and beta requires the prod project — the Node server layer + account deletion need only *a* `service_role` key (non-prod has one), the account area is non-prod, and even **Stripe develops in test mode** against non-prod. So:
- **Phase 4 → "Node server layer (on non-prod)"** — JWT-verify middleware + `service_role` client + account deletion, all against the existing non-prod project. Prod bullet removed.
- **Production provisioning moved to the front of Phase 6 (beta)** — the first point real users arrive and the user's explicit "non-prod is good enough" sign-off. Pins ADR-014's vague "until proven" to a concrete gate.
- **Phase 8** annotated: Stripe Checkout/webhook/portal built in **test mode** (Stripe CLI → local Node → non-prod `user_plans`); live keys + prod are the launch cutover only.

**Docs touched:** ADR-014 Consequences (added "when proven happens" → Phase 6 gate); rollout Phase 4 rewritten (non-prod, risk down to low–medium), Phase 6 gains the prod-provisioning task + gate framing, Phase 8 gains the test-mode note.

### Where to resume — Phase 4 (Node server layer, on non-prod)
- Add the server layer to `geojson-studio-api`: Supabase-JWT-verify middleware + a `service_role` client pointed at **non-prod**; first endpoint = **account deletion** (cascade via the `on delete cascade` FKs). Still open on the user's side: verify Phase 3 Slice 3c, and large-file testing → per-file size limit.

---

## 2026-07-02 — Design Q&A: staged entry topology, connection-loss resilience, delta framing (ADRs 024–025)

Planning session — **no code.** Pressure-tested four concerns for Phases 7–8 and captured the outcomes.

**Decisions (new ADRs):**
- **ADR-024 — Entry topology in two stages.** A query-string flag only affects client-side behaviour after load, so the landing can't be *both* flag-gated *and* statically SEO-served. **Stage 1:** dark preview — one SPA at root, a flag-gated `/` renders a **temporary client-rendered `Landing` component**, `/app` = editor, no infra change, no SEO (fine while dark). **Stage 2 (launch):** the ADR-021 restructure — **static SEO landing** at `/`, app → `/app`, flag deleted, temporary component removed. Resolves the earlier bare-domain contradiction: Stage 1 bare = editor, Stage 2 bare = landing.
- **ADR-025 — Connection-loss resilience (Level 1).** `supabase-js` has **no offline queue** (unlike Firestore); logged-in users keep no local copy (ADR-004). v1 = **retry-with-backoff + reconnect flush + a save-status indicator + a `beforeunload` guard** (autosave-service + a small Pinia store; no new storage). A crash-recovery journal (Level 2, a scoped ADR-004 exception) and full offline-first (Level 3) are rejected/backlogged.

**Other Q&A (no ADR):**
- **Deltas / large files (#4)** — right smell, wrong time/mechanism. v1 keeps **whole-document writes** (matches inline-`jsonb`; deltas save upload bytes but not DB write cost until you move to **per-feature rows**). If ever needed, prefer **client-direct RPC / per-row** over Node endpoints (ADR-002). The user will **test large files** and likely impose a **per-file size limit** (Studio is an editor, not built for huge files) — which may make deltas moot.
- **RLS vs RPC vs Node endpoints** — clarified: both RLS (DB-enforced per-user `WHERE`) and RPC (a Postgres function called via `supabase.rpc`) are client-direct; Node endpoints are for **secrets, trusted callbacks, and privileged ops only** (ADR-002/020), not CRUD.

**Docs touched:** new ADR-024/025; ADR-021 status annotated (this is its Stage 2 form); rollout Phase 7 rewritten as two stages + connection-loss added to cross-cutting concerns; backlog — Storage expanded (per-file size limit, whole-doc-vs-delta), new **Resilience** section (Level 2 journal).

### Where to resume — Phase 4 (production + Node server layer)
- Unchanged: Phase 3 is complete; Phase 4 is next. ADRs 024–025 are forward-looking design capture (Phases 7 / cross-cutting) — nothing to build now.

---

## 2026-07-01 — Schema cleanup: `files` → `user_files`, drop `backup_geojson` (ADR-023)

Two schema refinements, done by **amending the creation scripts** — we're pre-production and the user dropped the non-prod tables, so no ALTER/cleanup migration (ADR-023). App build clean.

- **`0001` / `0002`** — the active-document table is now **`public.user_files`** (consistency with `user_settings` / `user_plans`), with its index (`user_files_one_per_user_uq`), policies (`user_files_*`), and trigger (`user_files_set_updated_at`) renamed to match. The **`backup_geojson` column is gone** (cloud File→New is non-destructive — ADR-018). The user re-applies `0001`+`0002` fresh.
- **`remote-file-storage.js`** — targets `user_files`; `KEY_TO_COLUMN` now maps only `geojson_data → geojson` (the local-only `backup_geojson_data` key never reaches the cloud). Build clean; chunking unchanged.
- **Docs** — new **ADR-023**; ADR-016 annotated as superseded-in-part; ADR-022 + architecture §5 (sketch, note, RLS example) + rollout + backlog references updated to `user_files`; the "drop backup_geojson" backlog item removed (done); migrations README records the pre-prod in-place-amendment policy.

### Where to resume — Phase 4 (production + Node server layer)
- Unchanged: Phase 3 is complete; Phase 4 is next. Note for prod: because these were creation-script amendments (not ALTER migrations), the **production** project just applies the current `0001`+`0002` once — there's no rename/drop to replay.

---

## 2026-07-01 — SaaS scope expansion: roadmap revamped (Phases 4–8), ADRs 019–022

Planning session — **no code.** The user set the goal explicitly: **monetise Studio as a freemium SaaS.** Discussed the shape and captured it across the docs.

**Decisions (new ADRs):**
- **ADR-019 — Freemium: free = local, paid = cloud.** The anonymous/local app is a *permanent free tier* (not a trial); cloud accounts are the paid tier; pricing is **storage-based**.
- **ADR-020 — Server layer = the existing Node API** (not Edge Functions) for the Stripe webhook, account deletion, and privileged Supabase ops (`service_role`). Makes ADR-002 concrete.
- **ADR-021 — Entry topology:** static hand-written landing at `/`, editor at `/app`; landing placed via the Dockerfile (SEO-friendly, no framework, no SSR); retires `?ff=cloud` at go-public.
- **ADR-022 — Monetisation mechanics:** `public.user_plans` (server-authoritative — webhook writes, client reads own row), **storage quota via a Postgres trigger** on `files`, Stripe Checkout + Customer Portal + webhook.

**Roadmap revamp (`03-rollout.md`); Phases 0–3 unchanged (done):**
- **P4** Production + Node server layer (prod Supabase / ADR-014 unblock; JWT-verify middleware + `service_role`; first use = account deletion).
- **P5** Account area (usage / data export / delete account / Manage-billing link) + compliance (privacy + ToS).
- **P6** Free beta / early access (allowlist) — the old Phase 4.
- **P7** Landing & go-public (static landing, app→`/app`, retire the flag).
- **P8** Monetise: Stripe + entitlements (`user_plans`, quota trigger, Checkout/webhook/portal) — the old Phase 5; payments still **last** (ADR-007).

Also: renamed the planned table `user_plan` → **`user_plans`** (plural, matching `files`/`user_settings`) across the docs; refreshed `00-overview.md` (freemium framing + glossary: free/paid tier, landing, account area, server layer), `01-architecture.md` §5 sketch, and `04-backlog.md` (plan/pricing = storage-based & user-designed; entitlement mechanics now decided).

**Q&A captured (mental models):** webhooks are one-way inbound (Stripe→Node→`user_plans`); the `public` schema is just Postgres' default namespace (not "public access" — RLS is the gate; it's the API-exposed schema); the landing is build-time static HTML served by the existing nginx (not SSR); storage quota is enforced by a DB trigger, not the client.

### Where to resume — Phase 4 (production + Node server layer)
- Create the **production Supabase project** + wire per-environment `VITE_SUPABASE_*` build args (ADR-014). Add the **server layer to `geojson-studio-api`**: a Supabase-JWT-verify middleware + a `service_role` client; first endpoint = **account deletion**. Then Phase 5. No app-repo cloud code is blocked on this — the Phase 3 follow-ups in `04-backlog.md` can be picked up any time too.

---

## 2026-07-01 — Phase 3 · Slice 3c authored (first-login opt-in migration) — Phase 3 code-complete

Built the last piece of Phase 3: the one-time, opt-in offer to copy a user's LOCAL work into their new cloud account. Build clean; **pending the user's manual check.** Phase 3 (3a–3c) is now **code-complete, awaiting verification.**

- **`CloudMigrationPrompt.vue`** (new, code-split, cloud-only) — on mount it self-gates: shows the prompt only when the cloud account is **empty** (`activeFileStore.activeFileId === null` after `ensureResolved` ⟺ zero files) **and** there's **non-empty local work** (reads `dexieStorage.getItem(geojson_data)` directly — the one deliberate cross-path read, ADR-004). "Save to cloud" → `createNew("Untitled")` + `fileStorage.setItem(geojson_data, localWork)` + `reloadFromStorage()` (loads it into the editor). "Not now" → nothing. **The local copy is never moved or deleted.**
- **`FileToolbar.vue`** — renders it `v-if="isCloudMode"` (self-gates further from there), passing `:fileService`. Same code-split pattern as `MyFilesDialog`.

**Self-extinguishing (no dismissed-flag).** After a "Save" — or after the user creates any cloud file — the account is no longer empty, so it never prompts again. Declining and creating nothing re-offers next login; acceptable for v1 (a dismissed-flag is backlogged).

**Build:** clean (vite 8 / rolldown, ~1.4s). `CloudMigrationPrompt-*.js` (~1.8 kB) is its **own async chunk**; no SDK in main; flag-off path unchanged.

**Not yet verified — to test (closes Phase 3):**
1. Fresh account (zero cloud files) with local work → on login, prompt appears; **Save to cloud** → the local work becomes the first cloud file (shows in My Files + editor); log out → local copy still intact.
2. **Not now** → nothing migrated, local intact; prompt re-offers next login (until a cloud file exists).
3. Account that already has cloud files → **no** prompt.
4. Empty local (no features) → **no** prompt.
5. Flag-off / anonymous → component never loads.

### Where to resume — Phase 4 (free beta / early access)
- Once 3c is verified, Phase 3 is done. Phase 4: pick the cohort mechanism (allowlist is the conventional step once auth exists), keep the flag as the public visibility toggle, gather usage, harden RLS. **No payments yet** (that's Phase 5 — Stripe + entitlements). Also still open: the deferred Phase 3 follow-ups in `04-backlog.md` (import-as-named-file, File Info metadata, drop `backup_geojson`, etc.) can be picked up any time.

---

## 2026-06-29 — Phase 3 · Slice 3b authored (My Files dialog + toolbar wiring)

Built the My Files UI on top of 3a. Build clean; **pending the user's manual round-trip + flag-off e2e.**

- **`MyFilesDialog.vue`** (new) — `GsDialog` list (name + last-edited, most-recent first; active file badged "Current"); per-row **open / rename (inline) / delete (confirm)**; footer **New File** (primary) + Close. Opened from the toolbar; refreshes its list on show. Code-split into its own async chunk.
- **`FileToolbar.vue`** — adds a **My Files button labelled with the active file's name** (cloud only) + the dialog. **File→New is now branched by auth state:** cloud → non-destructive (`startNewBlank` + `reloadFromStorage`, no confirm/backup); local → the existing destructive-New + backup/undo-toast flow, untouched.
- **`file-service.reloadFromStorage()`** (new) — storage-agnostic editor reload (clear → load the active doc from the seam → reset undo/redo, or blank if none). Drives in-place switch, cloud New, and delete-active→blank. file-service stays **decoupled** from the active-file store (the caller sets which row is active first).
- **`active-file.js`** — added `activeFileName` state (toolbar label) + `adoptActiveFile`/`startNewBlank`; `rename`/`remove` keep the label in step; `_resolve` seeds id+name.
- **`remote-file-storage.js`** — `resolveMostRecentFileId` → `resolveMostRecentFile` (returns `{id, name}`); lazy-insert + `clear()` use `adoptActiveFile`.

**Autosave flush — not needed (revises the 3b design note).** Autosave has no debounce (it runs per draw op) and the remote `setItem` captures the target `id` **before** its network call, so an in-flight save always commits to the file that was active when the draw happened; `clearAll()` is silent (no autosave). So an explicit "flush before switch" is unnecessary — the by-id capture is the race guard.

**Build:** clean (vite 8 / rolldown, ~1.2s). `MyFilesDialog-*.js` (~4.7 kB) is its **own async chunk**; `remote-file-storage-*.js` (~1.9 kB) + `supabase-client-*.js` (~202 kB) still separate; **no SDK in main**. The light active-file store rides in main. Flag-off path structurally unchanged.

**Not yet verified — to test before 3c:**
1. Open / switch / rename / delete files from the dialog; the toolbar name label tracks the active file.
2. Cloud File→New starts a blank file with **no confirm**; drawing creates a fresh row; the old file is still in My Files.
3. Delete the **active** file → editor resets to blank.
4. Two-account isolation still holds (B never sees A's files in the list).
5. **Flag-off e2e unchanged** (anonymous path untouched).

### Where to resume — Phase 3 · Slice 3c
- First-login opt-in migration: on login with **zero cloud files** AND **non-empty local work**, prompt *"Save your current local work as your first file?"* → yes seeds a new file from the local GeoJSON (`activeFileStore.createNew` + write the local doc); no leaves local untouched. Mirror `cloud-settings-bootstrap.js`'s flag-on hook; it's a post-mount prompt (interactive), not a pre-mount await.

---

## 2026-06-29 — Phase 3 · Slice 3a authored (multi-file storage + active-file state)

Slice 3a built — the multi-file storage round-trip, **no UI yet** (that's 3b). Build clean; **pending the user applying `0002` + the verification gate below.**

- **`supabase/migrations/0002_multi_file.sql`** (cloud repo) — drops `files_one_per_user_uq`, adds `files.name`. Owner-only RLS / triggers / columns from `0001` already cover multiple rows. (migrations README updated.)
- **`src/stores/active-file.js`** (new) — holds `activeFileId` + the `files` list; actions `ensureResolved` (cold load → most-recently-updated row, once, idempotent like `auth.ensureInitialised`), `refreshList`, `createNew`, `rename`, `remove`. Main-bundle-safe: every Supabase action dynamically imports the remote module, so no SDK in main.
- **`remote-file-storage.js`** — rewritten from single-row upsert to **active-row-by-`id`**: getItem/setItem/removeItem target `activeFileId`; **UPDATE-by-id, not upsert**; first write with no active file does a **serialised lazy-insert** (one in-flight promise → no duplicate rows) and adopts the id; `clear()` is now **active-row-only** (can't wipe the library). Adds lifecycle exports (`resolveMostRecentFileId` / `listFiles` / `createFile` / `renameFile` / `deleteFile`).
- **`file-storage.js`** — the logged-in branch now `await useActiveFileStore().ensureResolved()` before returning the remote backend, so the startup read loads the user's most-recent file.

**Build:** clean (vite 8 / rolldown, ~1.2s). Chunks confirm the split held: `remote-file-storage-*.js` (~1.9 kB) and `supabase-client-*.js` (~202 kB) stay **separate async chunks**; the light active-file store rides in main, **no SDK in main**. Flag-off = unchanged → anonymous e2e unaffected.

**Not yet verified — the Phase 3 gate (do before 3b):**
1. Apply `0002` to the **non-prod** project; confirm the `name` column exists and `files_one_per_user_uq` is gone.
2. **Round-trip:** flag on, sign in, draw → a row is lazily created (one row, named "Untitled"); reload → it reopens. In devtools, `useActiveFileStore().createNew("B")` etc. to make a second file, switch `activeFileId`, reload → the most-recently-updated opens.
3. **Two-account RLS with multiple rows:** A creates files; B sees only their own; the `set local role anon` check still denies.

### Where to resume — Phase 3 · Slice 3b
- My Files dialog (`GsDialog`) + FileToolbar wiring (active-file name label, My Files button); cloud File→New non-destructive (gate the local backup / undo-toast path by auth state); in-place file switch (clear + reset undo/redo + load, **flush pending autosave first**); delete-active → blank editor.

---

## 2026-06-29 — Phase 3 design agreed (ADR-018); ready to implement Slice 3a

Design session for Phase 3 (multi-file "My Files") — **no code yet.** Walked the real app flows (`FileToolbar` New/Import, `file-service`, `auto-save-service`, `FileInfo`, `FileImportDialog`) and agreed the multi-file model. Recorded as **ADR-018**; Phase 3 re-sliced in [`03-rollout.md`](03-rollout.md); deferrals parked in [`04-backlog.md`](04-backlog.md).

**Decisions:**
- **Lazy, non-destructive File→New (cloud):** New starts a blank file; the row is inserted on the first edit. The previous file persists as its own row → the destructive "replace" confirm is dropped in cloud mode.
- **`backup_geojson` vestigial in cloud:** revert = reopen the previous file from My Files; the backup/undo-new-file machinery stays **local-only** (gated at the orchestration layer, not the seam). Column left in place, dropped later.
- **Provider rewrite (ships with `0002`):** active-row-**by-id** get/set/remove; serialised lazy-insert on first write; **UPDATE-by-id not upsert** (closes the switch/delete races); `clear()` made safe. `0002` drops `files_one_per_user_uq`, adds `name`.
- **Active file:** cold load opens the most-recently-updated row (none → blank); switching is in-place (clear + reset undo/redo + load, pending autosave flushed first); delete-active → blank editor; **open/import stay writable**.
- **First-login migration:** opt-in prompt when **cloud files == 0 AND local non-empty** → yes copies local into the first cloud file; self-extinguishing (no flag).
- **Unchanged:** bookmarks/templates user-global; multi-tab last-write-wins (no sync).

**Does NOT complicate the storage seam:** the active-document I/O (autosave/load) stays uniform across both paths; the one branch is at the New-file orchestration (a genuinely different feature), and the cloud branch is the simpler one. Confirmed `fileStorage.clear()` has no app caller today (so the "delete all files" footgun isn't currently reachable — still being made safe).

### Where to resume — Phase 3 · Slice 3a
- Author `supabase/migrations/0002_multi_file.sql` (drop `files_one_per_user_uq`, add `name`); user applies to non-prod. Rewrite `remote-file-storage.js` → by-id + serialised lazy-insert + UPDATE-by-id + safe `clear()`. Add `src/stores/active-file.js` (active id + list + lifecycle + `ensureResolved()` most-recent-on-load) and wire `file-storage.js` routing. Prove the multi-file round-trip before any UI (3b).

---

## 2026-06-28 — Phase 2 · Slice 2b: settings remote provider (hydrate-on-login cache)

File round-trip + two-account RLS verified by the user. Built the cloud **settings** backend, keeping the seam synchronous (ADR-010) with **per-key routing** (architecture §6).

- **`settings-cache.js`** (new, light / main bundle) — in-memory `Map` + a synchronous `localStorage`-shaped backend; writes schedule a fire-and-forget background flush via an installed flusher. **No SDK import**, so it's main-bundle-safe.
- **`cloud-settings-bootstrap.js`** (new, dynamic / flag-on) — awaits auth; if logged in, hydrates all `user_settings` rows into the cache and installs the flusher (`upsert` on `(user_id,key)`; delete on remove/clear). Fails safe to local on error.
- **`settings-storage.js`** — per-key routing via a `CLOUD_SETTINGS_KEYS` allowlist: cloud only when the cache is active **and** the key is allowlisted; otherwise `localStorage`. Still fully synchronous.
- **`main.js`** — when the flag is on, dynamically import + `await initCloudSettings()` **before `app.mount()`**, so the cache is populated when stores read it in their `state()` factories. Flag off mounts synchronously (unchanged).

**Classification (architecture §6).** CLOUD (follows the user): `map_style`, `bookmarks`, `unit_system`, the four side-panel keys (`feature_label_property`, `feature_sort_option`, `feature_filter_property`, `filter_sync_map`), `stylingTemplates`. LOCAL (device-level): `colour_mode`, `welcomed`, `app_hint_visible`, narrow-screen flag, plus two **judgment calls** — `measurements_while_drawing` and `undo_new_file_toast_enabled` (treated as device/workflow toggles, not in §6's move list). *Flagged for user confirmation.*

> **Revised same-day (ADR-017):** user decided **all** settings should follow the account. Dropped the `CLOUD_SETTINGS_KEYS` allowlist — the settings seam now routes **every** key to the cloud cache when logged in (`resolveBackend()` again, no key check). The session credential stays local automatically (it's outside the seam — ADR-008/011). Also noted: there is no distinct "narrow-screen" key in code (the dialog reuses `welcomed`). Rebuilt clean.

> **Housekeeping:** moved the file seam's local backend from `services/file/dexie-storage-manager.js` → `services/storage/browser-file-storage.js` (file rename only — code identifiers `dexieStorage`/`DexieStorageManager` unchanged), so it sits beside its remote sibling (`remote-file-storage.js`). `services/storage/` is now the whole persistence layer; `services/file/` stays file domain logic. One import path updated (`file-storage.js`); build clean.

> **Housekeeping:** organised `services/storage/` into two subfolders — `file/` (`file-storage.js`, `browser-file-storage.js`, `remote-file-storage.js`) and `settings/` (`settings-storage.js`, `settings-cache.js`, `cloud-settings-bootstrap.js`). File moves + import-path updates only (all `@/` alias paths; ~15 importers across `src/`); no other code changes. Build clean.

**Isolation:** a fresh cloud account starts with empty cloud settings; local settings are untouched and reappear on logout (ADR-004). Opt-in local→cloud migration is Phase 3.

**Build:** clean. `cloud-settings-bootstrap-*.js` + `remote-file-storage-*.js` + `supabase-client-*.js` are separate async chunks, none in main. e2e (flag off) unaffected.

### Where to resume — Phase 3
- Multi-file "My Files" UI; **drop `files_one_per_user_uq`**, add `name`; the opt-in "save your current local work as your first file?" migration on first login. (Phase 2 is functionally complete once settings are verified.)

---

## 2026-06-28 — Phase 2 · Slice 2: remote file provider + auth-state routing

Schema applied to non-prod by the user and verified. Built the remote **file seam** and wired routing by auth state — **no call-site changes** (the Phase 0 seam paying off).

- **`src/services/storage/remote-file-storage.js`** (new) — Supabase backend implementing `getItem/setItem/removeItem/clear` against `public.files`. The two seam keys map to columns (`geojson_data`→`geojson`, `backup_geojson_data`→`backup_geojson`) on the user's single row; writes are `upsert` on `user_id` (preserving the other column); `removeItem` nulls a column; `clear` deletes the row. RLS scopes everything to the owner. Statically imports the SDK, so it's only reached via dynamic import → its own async chunk.
- **`src/services/storage/file-storage.js`** — `resolveBackend()` is now async: flag OFF → `dexieStorage` immediately (never touches auth/Supabase, still dark); flag ON → `await auth.ensureInitialised()` then route (logged-in → dynamically-imported `remoteFileStorage`, else local). Awaiting auth on the first read fixes the **startup race** so a logged-in user loads their cloud file, not stale local data.
- **`src/stores/auth.js`** — `init()` → **`ensureInitialised()`**: idempotent, awaitable, shares one module-level init promise between the account UI and the file seam.
- **`AccountMenu.vue` / `LoginDialog.vue`** — reload on sign-in success and after sign-out, so the app re-bootstraps cleanly on the correct storage path (the two paths never mix in-memory; also discards any pending local autosave timer so anonymous data can't leak to cloud). Google OAuth already reloads via redirect, and the startup await handles its return.

**Build:** clean. Chunks: `remote-file-storage-*.js` (~0.9 kB) + `supabase-client-*.js` (~202 kB) are separate async chunks; main bundle +~2 kB (light auth/flags stores), **no SDK in main**. Flag-off = unchanged, so the existing e2e (anonymous) is unaffected.

**Not yet verified — the security gate (do before trusting this):**
1. **Round-trip:** flag on, sign in, draw something (autosaves to cloud), reload → it persists; sign out → local data returns.
2. **Two-account RLS isolation:** sign in as A, save; sign in as B → B sees empty/their own, never A's; confirm in the Supabase Table Editor that each row's `user_id` matches, and that the SQL `set local role anon` check still denies.

### Where to resume — Phase 2 · Slice 2b
- Settings remote provider against `public.user_settings` + the **hydrate-on-login in-memory sync cache** (ADR-010), keeping the settings seam synchronous. Then Phase 3 (multi-file UI; drop `files_one_per_user_uq`; add `name`).

---

## 2026-06-27 — Phase 2 · Slice 1: cloud schema + RLS authored (not yet applied)

First Phase 2 slice — **schema + Row-Level Security only**, no app code. Authored `supabase/migrations/0001_files_and_user_settings.sql` (+ `supabase/migrations/README.md`) as the source of truth (ADR-009):

- **`public.files`** — the active GeoJSON doc. Phase 2 keeps **one row per user** (`files_one_per_user_uq`, dropped in Phase 3). Columns `geojson` + `backup_geojson` (the file seam writes both `geojson_data` and `backup_geojson_data`; ADR-004 keeps no IndexedDB for logged-in users). `name` deferred to Phase 3.
- **`public.user_settings`** — per-user `(key, value)`; `value` is **`text`** (lossless mirror of the seam's opaque `localStorage` strings).
- **RLS** — owner-only per-command policies (`auth.uid() = user_id`) scoped to `authenticated`; `anon` revoked. `updated_at` trigger; `on delete cascade` to `auth.users`. Decisions recorded as **ADR-016**; architecture §5 annotated.

**State:** migration **authored, not applied.** Next: user applies it to the **non-prod** project (SQL Editor), confirms tables + RLS + the `anon` lockout check (see migrations README).

### Where to resume — Phase 2 · Slice 2 (after schema applied)
- `RemoteStorageManager` implementing the **file seam** against `public.files` (upsert on `user_id`), wired into `resolveBackend()` to switch by **auth state** (logged-in → remote, anonymous → local) — no call-site changes. Prove the single active-file round-trip, then the **two-account RLS isolation** test (the hard gate). Settings remote provider + hydrate-on-login cache (ADR-010) is Slice 2b.

---

## 2026-06-27 — Phase 1: Supabase Auth wired up, shipped dark behind the flag

Supabase project exists (user-created): URL + **publishable** key (`sb_publishable_…`, not the legacy anon key — **ADR-012**) supplied. **Email** and **Google** providers enabled; **"Confirm email" is ON**, so email signups must click a confirmation link before they can sign in (the login UI says so; Google has no such step). Supabase Site URL = `http://localhost:5173` for dev.

**Built (all gated behind `?ff=cloud`, account module code-split so it's absent from the main bundle):**
- **Config / env:** `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` added to `.env.local` (real values, gitignored) and `.env.template` (placeholders); surfaced via `src/config/index.js` (`config.supabase`).
- **Feature-flag store** `src/stores/feature-flags.js` (`cloudEnabled`) — **URL-presence-based, not persisted (ADR-015):** the store reads `?ff=cloud` from the URL at construction; no `localStorage`, no `:off` param, no URL-stripping, no pre-Pinia bootstrap. Default (no param) = vanilla app. *(Revised same-day from the original persist-to-localStorage design — see the addendum below; ADR-013 superseded.)*
- **Supabase client** `src/services/auth/supabase-client.js` — lazy singleton (`getSupabaseClient()`), the only static importer of `@supabase/supabase-js`; only ever reached via dynamic `import()`, so the SDK lands in its own async chunk and never loads when the flag is off.
- **Auth store** `src/stores/auth.js` — `user`/`session` state, `isLoggedIn`, and `init()` / `signInWithPassword` / `signUpWithPassword` / `signInWithGoogle` / `signOut`; each dynamically imports the client (no SDK at app start).
- **UI** — `src/components/auth/AccountMenu.vue` (entry point in the `AppMenu` `#end` slot, before branding) + `src/components/auth/LoginDialog.vue` (email+password sign-in/sign-up tabs + "Continue with Google", built on `GsDialog`). `AppMenu` loads `AccountMenu` via `defineAsyncComponent` only when `cloudEnabled`, so flag-off never fetches the account chunk.
- **Dependency:** `@supabase/supabase-js` added.

**Inertness check (the Phase 1 acceptance criterion):** flag off → `AccountMenu` async chunk is never requested, no Supabase client constructed, no auth network calls, no account UI; only the tiny inert flag-check rides in the main bundle. Flag on (`?ff=cloud`) → "Sign in" appears; dev can sign up / sign in (email+password or Google) / sign out. No data has moved — Phases 2+ do storage routing.

**Validation:** `npm run build` clean (vite 8 / rolldown). Chunking confirms the split: `AccountMenu-*.js` (~7 kB, the account module) and `supabase-client-*.js` (~202 kB, the SDK) are **both separate async chunks**, absent from the main `index-*.js`. `@supabase/supabase-js@^2.108`. e2e to be run by the user.

### Addendum (same day) — decisions from review

- **Flag semantics simplified (ADR-015).** Reworked the flag to be **URL-presence-based, not persisted**: `cloudEnabled` = `?ff=cloud` present in the URL, read once at load. Removed the `localStorage` persistence, the `ff_cloud` constant, the `:off` param, the URL-stripping, and the pre-Pinia bootstrap in `main.js`. Added an OAuth tweak: `signInWithGoogle` sets `redirectTo` to carry `ff=cloud` back so the account UI survives the Google round-trip. Rationale: simpler mental model, and the bare domain is always vanilla so the dark feature can't stick on a browser. Rebuilt clean.
- **Environments (ADR-014).** Decided on **separate Supabase projects per environment** (dedicated prod isolated from non-prod). **For now: non-prod only** — the current project is local/non-prod; the production project and all CI/Dockerfile env-var wiring are **deferred** until core cloud functionality is proven. The team is new to Supabase, so we keep focus on functionality first.
- **Pipeline wiring deferred (explicit).** Worked out the exact mechanism (mirror the Mapbox token: `--build-arg` → Dockerfile `ARG`/`ENV` → Vite; URL as a GitHub Variable, publishable key as a Secret; env-scoped per GitHub Environment) but **did not touch** `Dockerfile.staging/production` or `deploy-*.yml`. To be done with the prod setup later.

### Where to resume — Phase 2
- Remote provider implementations behind the existing seams (`RemoteStorageManager` over `public.files`; settings KV over `public.user_settings`), switched by **auth state** (logged-in → remote, anonymous → local). RLS first, manually verified. Prove the single-active-file round-trip before any multi-file UI.

---

## 2026-06-26 — Phase 0 complete (both seams in)

**Step 2 — Settings seam done.** Added `src/services/storage/settings-storage.js` (synchronous `localStorage` mirror, same `resolveBackend()` swap-point as the file seam). Migrated all settings consumers — **39 calls across 11 files** — onto `settingsStorage` in four batches (A: leaf stores; B: `side-panel`; C: `styling-template` + `Bookmarks`; D: map/dialog components). `session.js` (6 calls) deliberately left on raw `localStorage` (ADR-008 / ADR-011). Production build clean.

**Validation.** `npm run build` clean for both steps. The Playwright e2e suite is **flaky** in this environment — different tests fail across identical runs (PC07/PC08, the large-file `file-import-real-world` RW04/07/08, `feature-editing` G02). Traced PC07/PC08: the Web-Mercator path mounts the Cloudflare **Turnstile** widget in a cross-origin iframe, whose script is denied `localStorage` ("Access is denied for this document") under the test's partitioned storage — surfaced as an uncaught page error (shows as `<anonymous>`). Third-party/environmental, and **not** in the seam's code path (convert → `apiFetch` → session store; `session.js` untouched). A clean re-run confirmed the failures move around → flakiness, not regression. Treating these as known-flaky for now.

**Phase 0 is complete:** both provider seams (file + settings) are in place as a behaviour-preserving no-op; the anonymous/local path is unchanged. Going forward, e2e is run by the user; the build is the fast local check.

### Where to resume — Phase 1 (decisions made 2026-06-26)
- **Auth methods:** email + password **and** Google OAuth.
- **Supabase project:** user is creating it (guided walk-through provided); will share the project URL + anon (public) key. App is greenfield for Supabase.
- **Sequencing:** all Phase 1 code waits until the Supabase project + keys exist, then done together — feature-flag store (`?ff=cloud` → `localStorage` → reactive `cloudEnabled`; ADR-005), `supabase-js` lazy-init client (code-split, inert when flag off), then login/signup/logout UI (email+password + Google).
- **Blocked on:** Supabase project URL + publishable key; Email and Google providers enabled in Supabase. Env vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` (in gitignored `.env.local`; documented in `.env.template`). *(Now unblocked — see 2026-06-27 entry. Key naming: publishable, not legacy anon — ADR-012.)*

---

## 2026-06-25 — Pre-Phase-0 code survey; docs reconciled; starting the seams

Surveyed the actual `geojson-studio-app` `staging` branch before writing any code, and reconciled the design docs with what's really there:

- **File seam (was "Document seam" — renamed for consistency with the "file" glossary term):** 4 direct `dexieStorage` importers — `file-service`, `map-utils`, `MapView`, `draw-manager`. `auto-save-service` is **already decoupled** via constructor injection, so it rides along when `draw-manager` injects the provider. (The doc previously said "~5 sites", lumping auto-save in as a direct importer.)
- **Settings seam:** 45 direct `localStorage` calls across 12 files (doc said 43/11). `undo-new-file-toast.js` is new since the original survey; `features-list.js` only mentions `localStorage` in comments (not a call site). `session.js` (6 calls) stays on raw `localStorage`, outside the seam.
- **Key finding:** the settings seam must be **synchronous** — Pinia stores read `localStorage` in their sync `state()` factories, so an async seam would change store semantics and break the no-op. Recorded as **ADR-010**; the session-stays-local refinement is **ADR-011**.

Updated `00-overview.md` (status + glossary), `01-architecture.md` (§4 + appendix; "Document seam" → "File seam"), `03-rollout.md` (Phase 0), and appended ADR-010/011 to `02-decisions.md`.

### Progress
- ✅ **Step 1 — File seam done.** Added `src/services/storage/file-storage.js` (a facade delegating to `dexieStorage` via a `resolveBackend()` indirection — the single place Phase 2 swaps in remote-by-auth). Repointed all 4 importers (`file-service`, `map-utils`, `MapView`, `draw-manager`); `auto-save-service` rides along via DI (`draw-manager` injects the provider). `dexieStorage` is now referenced only by the singleton + the provider.
- **Validation:** production build clean; `npm run test:e2e` → **433 passed, 11 failed**. All 11 failures are environmental, not the seam: 10 are conversion/Web-Mercator/session tests that "require backend at localhost:8080" (Node API not running here); 1 is a context-menu flake (G02, whose twin G03 passed). The seam-exercising specs (autosave, file-management, new-file restore/undo, native `.geojson` import) all passed.

### Where to resume
- **Next action:** Phase 0, Step 2 — add `src/services/storage/settings-storage.js` (synchronous `localStorage` mirror), then migrate the settings consumers in per-store batches (A: leaf stores; B: `side-panel`; C: `styling-template` + `Bookmarks`; D: map/dialog components). `session.js` stays on raw `localStorage`. Re-run the e2e suite at batch boundaries.

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
