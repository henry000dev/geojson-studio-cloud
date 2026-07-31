# Prototypes

Throwaway experiments that answer a question the design depends on. **Not migrations** — nothing here is ever applied to production, and every script removes what it created.

The rule that puts a script in this directory rather than in [`../migrations`](../migrations): *we are about to write a migration whose shape depends on an assumption about a third party's behaviour that we cannot check by reading docs.* Both scripts here gate **Phase 7b-2** (the GeoJSON blob moving into Supabase Storage — [ADR-035](../../docs/02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row)), which says both must be prototyped before the slice is committed to. `0006_file_blobs_to_storage.sql` cannot be written honestly until they come back.

| File | Question it settles | What it decides |
|---|---|---|
| `p1_storage_objects_quota.sql` | Can the storage-bytes quota be enforced on `storage.objects`? | Whether `0006` carries a trigger, an RLS `WITH CHECK`, or a Node signed-URL gate |
| `p2_storage_policy_cross_table.sql` | Can a `storage.objects` policy consult another table? | Whether publish uses **one** bucket or **two** — a bucket-topology decision that is expensive to reverse later |
| **P3 — on hold, not written** | Is a signed upload URL **reusable**, or consumed after one upload? | Whether the client mints **once per session** or **once per save**. Single-use adds a Node round-trip ahead of every autosave, widening 7b-1's cost-priced window and making the 7c journal a prerequisite rather than a companion. Not SQL — a mint-then-upload-twice script against the Storage API |

> **⏸ 7b-2 paused 2026-07-31.** The user is reconsidering the remedy (other providers, edge functions, NoSQL documents), so **P3 is deliberately not being written**. P1 and P2 are complete and their results stand — see *Results* below. If the review returns to Supabase Storage, P3 is the only outstanding gate. Reasoning: [ADR-035, third addendum](../../docs/02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row).

## Safety

- **Non-prod only.** There is no production project yet ([ADR-014](../../docs/02-decisions.md#adr-014--separate-supabase-projects-per-environment-non-prod-set-up-first)); when there is, nothing in this directory goes near it.
- Everything created is prefixed `zz_p1_` / `zz_p2_` / `zz-p1-` / `zz-p2-`. If you see that prefix anywhere afterwards, teardown didn't finish.
- **Both scripts arm things that would break the project if left behind** — P1 arms a trigger that rejects *every* upload; P2 arms a policy that lets *anonymous* users read objects. Section 9 of each removes them. **Run section 9 even if the prototype fails**, and confirm its `9.1` row reads all zeros.
- **Object rows cannot be deleted by SQL.** Supabase guards `storage.objects` with `storage.protect_delete()`, which raises `42501 — Direct deletion from storage tables is not allowed. Use the Storage API instead.` Because the SQL editor runs a whole paste as one transaction, an unguarded delete doesn't merely fail — it **rolls back the trigger and policy drops in the same section**, leaving the dangerous objects armed. Both teardowns now guard the delete so the drops always survive; **remove the scratch bucket from the dashboard** (Storage → bucket → Delete bucket), then re-run section 9.
- Both touch `storage.objects`, which is Supabase-managed. Nothing here alters existing rows or Supabase's own triggers and policies — but the preflight records what was already there, so a mistake is at least detectable.

## Setup

From the non-prod project (**Settings → API**, and **Storage → Settings → S3 connection** for the optional orphan probe):

```powershell
$SUPABASE_URL  = "https://<project-ref>.supabase.co"
$ANON_KEY      = "<publishable / anon key>"    # VITE_SUPABASE_PUBLISHABLE_KEY
$SERVICE_KEY   = "<service_role key>"          # server-side only, never in the app
```

`curl` below is real curl. In PowerShell, `curl` is an alias for `Invoke-WebRequest` — use `curl.exe` explicitly.

---

## P1 — the quota

Run **in order**, stopping where marked. It is not a single paste-and-go: the two informative steps need a real upload, which the SQL editor cannot do.

1. **Sections 0–1** in the SQL Editor. Stop.
2. **Upload for real** (below) — any small file. This is what proves the trigger fires on the Storage API's path rather than only on hand-written SQL.
3. **Section 2.** Read `2.2` closely — see *The one number that matters*.
4. **Section 3** (arms the rejecting trigger). Stop.
5. **Empty the bucket from the dashboard** — Storage → `zz-p1-proto` → select all → delete. **Not** by SQL: `delete from storage.objects` drops the metadata row and leaves the bytes in S3, which is exactly the debris the orphan probe is looking for. Re-run section 3's last query; `3.3` should read `(none — good)`.
6. **Upload for real again**, this time the 7,777,777-byte file. **Record the HTTP status and response body verbatim** — that is the answer to "what would the user's browser see?", and no query can produce it.
7. **Section 4**, then the orphan probe, then **section 5** (hand-filled).
8. **Section 6** — the no-trigger alternative.
9. **Section 9** (teardown), then **10** (the report).

> **Why section 4 reads a sequence and not the log.** The rejecting trigger raises, and that exception rolls back the statement — including any log row the trigger itself wrote. A log table would therefore be empty whether the trigger fired or never ran at all, and those are opposite conclusions. Sequences are the one thing rollback doesn't undo, so the firing count is kept in `zz_p1_reject_seq`.

### The one number that matters

Result row `2.2` reports what `metadata->>'size'` contained at `BEFORE INSERT` time.

- **A number** → the trigger can weigh a write before it lands. ADR-035's design holds; continue.
- **NULL** → the Storage API inserts the row first and fills the size in afterwards. Quota-on-insert is then impossible *as designed*, and moving the gate to `BEFORE UPDATE` doesn't rescue it — by then the bytes are already committed, which is Q5's failure by construction. If you see NULL, the rest of P1 is confirmatory and the real answer is the signed-URL fallback.

### Uploading for real

Make the distinctive file (step 5 above):

```powershell
$path   = "$env:TEMP\zz-p1-7777777.json"
$prefix = '{"pad":"'
$suffix = '"}'
$body   = $prefix + ('x' * (7777777 - $prefix.Length - $suffix.Length)) + $suffix
[System.IO.File]::WriteAllText($path, $body, (New-Object System.Text.UTF8Encoding($false)))
(Get-Item $path).Length     # must print 7777777
```

Then either route — both go through the Storage API, which is the path under test:

**Dashboard** — Storage → `zz-p1-proto` → Upload file. Uses the service-role key, which bypasses RLS *policies* but **not triggers**, so it exercises P1 correctly. Doesn't give you a clean response body, so prefer curl for step 5.

**curl** — gives you the status and body:

```powershell
curl.exe -i -X POST "$SUPABASE_URL/storage/v1/object/zz-p1-proto/probe-7777777.json" `
  -H "apikey: $SERVICE_KEY" `
  -H "Authorization: Bearer $SERVICE_KEY" `
  -H "Content-Type: application/json" `
  --data-binary "@$env:TEMP\zz-p1-7777777.json"
```

> Using the service-role key keeps the test about the **trigger**, not about RLS. If you'd rather see exactly what a real browser session gets, swap the `Authorization` bearer for a signed-in user's access token (DevTools → Application → Local Storage → the `sb-…-auth-token` entry → `access_token`). Worth doing once for step 5, since the error string is the deliverable.

### Probing for orphans

The honest caveat: **S3 is not visible from SQL.** `storage.objects` showing no row proves the *metadata* was kept out; it says nothing about whether the *bytes* were written first.

**Direct probe** (needs S3 access keys — Storage → Settings → S3 connection → generate, plus the AWS CLI). Anything listed here but absent from result `4.2` is an orphan:

```powershell
$env:AWS_ACCESS_KEY_ID     = "<s3 access key>"
$env:AWS_SECRET_ACCESS_KEY = "<s3 secret>"
aws s3 ls s3://zz-p1-proto/ --recursive --region us-east-1 `
  --endpoint-url "$SUPABASE_URL/storage/v1/s3"
```

**If you can't settle it, record `UNDETERMINED`** — and note that this argues *for* the signed-URL fallback, not against it. An orphan channel that can't even be measured is precisely the unbounded-cost surface ADR-035 moved to Storage to close.

---

## P2 — publish, one bucket or two

Sections 0–4 and 9 are pure SQL. Sections 5–6 need real HTTP, because everything before them only proves the policy works *in Postgres* — not that the Storage API honours it.

1. **Sections 0–4** in the SQL Editor. Section 4 prints an `EXPLAIN`; paste its timing into `4.1`.
2. **Fetch as a stranger** (below) → fill in `5.1` / `5.2`.
3. **The revocation check** → fill in `6.1`.
4. **Section 9** (teardown), then **10** (the report).

### Fetching as a stranger

The scratch rows in section 0 are SQL-inserted, so **no bytes exist behind them** and a `200` is unlikely even when the policy is right. What you're reading is the *difference* between the two requests. For an unambiguous result, put real bytes behind the published path first — `PUT`, not `POST`, because section 0 already created the row and `POST` would come back `409 Duplicate`:

```powershell
$pubPath = "11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.geojson"
'{"type":"FeatureCollection","features":[]}' | Set-Content -Encoding utf8 "$env:TEMP\zz-p2.geojson"

curl.exe -i -X PUT "$SUPABASE_URL/storage/v1/object/zz-p2-proto/$pubPath" `
  -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" `
  -H "Content-Type: application/json" --data-binary "@$env:TEMP\zz-p2.geojson"
```

Worth doing for the unpublished path too (`bbbbbbbb-…`), so that request also has real bytes behind it and its denial can't be confused with a plain "not found".

Then, **with no `Authorization` header at all** — this is the anonymous visitor:

```powershell
# (a) the PUBLISHED file — want 200
curl.exe -i "$SUPABASE_URL/storage/v1/object/zz-p2-proto/$pubPath" -H "apikey: $ANON_KEY"

# (b) the UNPUBLISHED file — want a denial
$privPath = "11111111-1111-4111-8111-111111111111/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.geojson"
curl.exe -i "$SUPABASE_URL/storage/v1/object/zz-p2-proto/$privPath" -H "apikey: $ANON_KEY"
```

Record both statuses and any `cf-cache-status` header. `200` vs `403` is unambiguous; `404` vs `400` needs interpreting, which is why uploading the real file first is worth the extra step.

### The revocation check (Q6)

Only meaningful if (a) returned `200`:

```powershell
curl.exe -sI "$SUPABASE_URL/storage/v1/object/zz-p2-proto/$pubPath" -H "apikey: $ANON_KEY"   # warm the cache
```
```sql
update public.zz_p2_files set is_published = false
 where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
```
```powershell
curl.exe -sI "$SUPABASE_URL/storage/v1/object/zz-p2-proto/$pubPath" -H "apikey: $ANON_KEY"   # immediately
```

Still `200`? The CDN is serving a file the owner has revoked. Note how long it keeps doing so. ADR-035 already calls this a correctness problem rather than a performance one — a non-zero answer turns that caveat into a hard constraint on how publish is built.

---

## What the answers decide

**P1 — quota enforcement in `0006`:**

| Result | Consequence |
|---|---|
| Trigger creatable, fires on the API path, size present at BEFORE INSERT, rejects cleanly, no orphans | ADR-035's primary proposal holds. `0006` ships `enforce_storage_quota` re-based onto `storage.objects`; the client's `GS_QUOTA_EXCEEDED` handling is unchanged. |
| Fires and rejects, but **orphans bytes** | Rejection is not a gate — it's a free-storage channel. Fall back to Node signed upload URLs (quota checked *before* any bytes move). |
| Size is **NULL** at BEFORE INSERT | Same fallback, for a different reason: there is nothing to weigh at the only moment that would help. |
| Trigger refused or never fires, but P1 §6 shows a `WITH CHECK` policy works | Use the policy, and reopen ADR-022's rejection of RLS-only quota with the evidence. Accept the generic error string, or catch the 403 client-side and translate it. |
| Nothing works in-database | Node signed upload URLs. Costs a server hop on the write path ([ADR-002](../../docs/02-decisions.md#adr-002--client-direct-access-with-rls-not-a-node-wrapper)) — but only for a small control message, never the blob. |

**P2 — bucket topology:**

| Result | Consequence |
|---|---|
| Cross-table policy works (naive or via `security definer`) | **One private bucket.** Publish is a boolean flip; one copy of every file; quota accounting stays simple. Build the `security definer` lookup deliberately narrow — boolean in, boolean out. |
| Policy works but the CDN keeps serving after unpublish | One bucket still, but unpublish needs a real revocation story (cache-control on owner reads, or a purge). Don't ship publish until it's designed. |
| Cross-table subquery impossible | **Two buckets.** Publishing copies the file into a public one; unpublishing deletes the copy. Two copies of every published file, doubled quota accounting, and a staleness problem when a published file is edited. Cheaper to know now than after `0006`. |

## Results — run 2026-07-30 against non-prod

Both run, both torn down clean. Recorded here so the directory stands on its own; the reasoning and consequences are in the [ADR-035 addendum](../../docs/02-decisions.md#adr-035--the-geojson-blob-moves-to-supabase-storage-user_files-becomes-a-metadata-row).

**P1 — quota**

| Question | Answer |
|---|---|
| Q1 trigger creatable on `storage.objects` | **Yes** (owner is `supabase_storage_admin`; `postgres` may still add triggers) |
| Q2 fires on the real Storage API path | **Yes** |
| Q3 `metadata->>'size'` at `BEFORE INSERT` | **Yes** — 206826, single `INSERT`, no follow-up `UPDATE` |
| Q4 rejects the upload | **Yes** — but `HTTP 500`, `{"error":"DatabaseError","message":"database error, code: 23514"}`; the raised message is stripped |
| Q5 orphaned bytes | **UNDETERMINED**, evidence favouring yes (S3 `eTag` + `httpStatusCode: 200` already in metadata at `BEFORE INSERT`; `100 Continue` before refusal) |
| Q6 `WITH CHECK` alternative | **Not run** — moot once the trigger worked, since a policy rejects at the same moment and carries the identical orphan exposure |

Two things the script wasn't looking for and found anyway:

- **An overwrite is an upsert** — `BEFORE INSERT` then `BEFORE UPDATE` for one `PUT`, on a row that keeps its `id` and `created_at`. A naive quota trigger double-counts on every autosave and inverts humane-downgrade.
- **`storage.protect_delete()`** rejects direct SQL `DELETE` on `storage.objects` (`42501`) while permitting `INSERT`. Asymmetric, and it makes the Storage-API deletion sweep mandatory.

**P2 — publish**

| Question | Answer |
|---|---|
| Q1 cross-table subquery in a policy | **Yes**, creatable |
| Q2 naive version | **Fails** — `42501 permission denied`, a *grant* failure, not RLS. Errors loudly rather than denying quietly |
| Q3 `security definer` lookup | **Works** — exactly 1 row visible to `anon`; unpublish revokes; cross-user isolation held |
| Q4 malformed object name | **Filtered, not raised** — the regex guard is load-bearing; an exception in a policy would break reads for the whole bucket |
| Q5 cost | **0.285 ms**, index scan on `idx_objects_bucket_id_name_lower`, one function call per fetch |
| HTTP, published / unpublished | **200** / non-disclosing `{"statusCode":"404","code":"NoSuchKey"}` |
| Q6 revocation vs CDN | **Immediate** — caveat: on a `no-cache` object. `cacheControl` is set by the *uploader*, so this is a per-upload lever |

**Verdicts against the matrix below:** P2 → **one private bucket**. P1 → the trigger works but wins on none of its three risks, so the **signed-URL fallback is recommended**; that decision is open and recorded in the ADR addendum and [`03-rollout.md`](../../docs/03-rollout.md) 7b-2.

## Sending the results back

Both scripts end with a `select` over their results table. Paste those, plus the hand-filled rows (`4.3`, `5.1` in P1; `4.1`, `5.1`, `5.2`, `6.1` in P2). Then drop the leftovers:

```sql
drop table    if exists public.zz_p1_results;
drop table    if exists public.zz_p1_log;
drop sequence if exists public.zz_p1_reject_seq;
drop table    if exists public.zz_p2_results;
```

The findings belong in [`../../docs/05-worklog.md`](../../docs/05-worklog.md), and any that contradict ADR-035's assumptions belong in an addendum to it — the ADR states the trigger as a *proposal with a documented fallback*, so a negative result confirms the ADR was written correctly rather than invalidating it.
