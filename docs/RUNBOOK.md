# GeoJSON Studio — Operations Runbook

Living operational procedures for the Cloud epic — privileged/manual tasks run against the **Supabase** project via the SQL Editor. This is distinct in genre from the design/decision docs alongside it (`00`–`05`, which record *why*); this records *how to do* recurring ops tasks.

> **Not here:** running the billing stack locally (`.env.local`, Stripe CLI, `npm run local`) and the `STRIPE_PRICE_*` env wiring live in the **API repo**'s `README.md` → *Development → Local Billing & Webhooks*. Applying and verifying migrations lives in [`../supabase/migrations/README.md`](../supabase/migrations/README.md). **Wiping non-prod back to zero** for a clean test run lives in [`RESET.md`](RESET.md) — a development procedure, not an operational one, and it deletes every account.

The SQL Editor executes as a privileged role that **bypasses RLS**, so these writes succeed even though `user_plans` is read-only to clients (ADR-022). Before running anything, confirm which project you are on — **non-prod vs prod**.

---

## Plan administration

Plans are **data**: `public.plans` is a lookup of tier → **storage limit + file limit**, and every user has one row in `public.user_plans` naming their plan (ADR-031, `0005_plans_and_quota.sql`). Because tiers are rows, **comps and free hidden plans need no code change** — insert a plan row, then point a user at it. A hidden *paid* plan additionally needs a Stripe price + a price→plan mapping (see [Add a hidden *paid* plan](#add-a-hidden-paid-plan-private-stripe-price)).

The seeded tiers (provisional until go-live — ADR-030):

| plan | `limit_bytes` | `max_files` | listed? |
|---|---|---|---|
| `free` | 31457280 (30 MiB) | 3 | yes — the default for every account |
| `basic` | 524288000 (500 MiB) | 50 | yes |
| `pro` | 21474836480 (20 GiB) | 1000 | yes |
| `discount` | 21474836480 (20 GiB) | 1000 | **hidden** — Pro limits at a private price |
| `god_mode` | 1 PiB sentinel | 1000000 | **hidden** — the maintainer's own row |

### Add a hidden / comp plan

A *hidden* plan exists in the DB and is enforced by both quota triggers, but is never offered in the app's upgrade UI and has no Stripe price to buy. `discount` and `god_mode` are seeded by `0005` already ([ADR-034](02-decisions.md#adr-034--premium-features-gate-scale-automation-and-distribution-not-capability)) — this is how to add *another*. Add the plan row **first**: `user_plans.plan` is a foreign key to `plans.plan`, so the plan must exist before it can be assigned.

```sql
insert into public.plans (plan, limit_bytes, label, rank, max_files, description) values
  ('enterprise', 53687091200, 'Enterprise', 90, 5000,
   'HIDDEN. Comped 50 GiB tier for <who / why>.')
on conflict (plan) do update
  set limit_bytes = excluded.limit_bytes, label = excluded.label, rank = excluded.rank,
      max_files   = excluded.max_files,   description = excluded.description;
```

> **`max_files` is `NOT NULL`** — an insert that omits it is rejected, deliberately: a missing value must never read as "unlimited". "Unlimited" is expressed as a sentinel (`god_mode`'s 1000000), the same way `limit_bytes` uses the 1 PiB sentinel.
>
> **`description`** is a private maintainer's memo of what the row is for — never rendered to users, and (per caveat 3) not secret either, since any authenticated client can read `plans`. Use it to record *why* a hidden row exists; the next person to inspect the table will thank you.

### Add a hidden *paid* plan (private Stripe price)

When a hidden plan should be **paid** (e.g. a custom $7/mo rate for a colleague) rather than comped, it is bought through Stripe like any other plan — it is simply never listed in the app's upgrade UI. The subscriber pays via a private link; the existing webhook then grants the plan automatically, exactly like a normal tier. Steps (keep the Stripe mode — test vs live — matching the target project):

1. **Stripe:** create a Product and a recurring **Price** at the custom amount; copy the Price id (`price_…`).
2. **Payment Link:** create a Stripe **Payment Link** for that Price and send it privately to the person. (A generated Checkout Session works too; the Payment Link is the no-code path.)
3. **Plan row:** insert the matching `public.plans` row with the limits you want (same SQL as the comp section above).
4. **Price → plan mapping:** register the new Price id in the API's price→plan map (`buildPriceToPlan`, driven by the `STRIPE_PRICE_*` env vars — API repo README). Without this the webhook can't tell which plan the price grants. A brand-new plan slug may need a corresponding env entry.
5. The subscriber pays via the link → `customer.subscription.created` → webhook writes their `user_plans` row → plan active. **No public-UI change** — the price just isn't shown on `/account`.

Unlike a comp, a hidden *paid* plan **is** a real subscription, so the cancel/dunning revert (to `free`) and the webhook-overwrite behaviour in the caveats below all apply normally — which is correct; it's a paying user.

### Put a user on a plan (manual grant)

For a **comp / free** hidden plan, assign it by hand (a paid hidden plan is assigned by the webhook instead — see above). Look up the user id, then set the plan (and a `status` so the app treats them as active):

```sql
-- find the user
select id, email from auth.users where email = 'someone@example.com';

-- grant
update public.user_plans
set plan = 'god_mode', status = 'active'
where user_id = '<auth-user-uuid>';
```

### Inspect / reset a user's plan

```sql
-- current plan + limits for a user
select up.user_id, up.plan, p.limit_bytes, p.max_files, up.status,
       up.stripe_customer_id, up.stripe_subscription_id, up.current_period_end
from public.user_plans up
join public.plans p on p.plan = up.plan
where up.user_id = '<auth-user-uuid>';

-- what they are actually using, against those limits
select * from public.user_storage_usage where user_id = '<auth-user-uuid>';

-- reset to the free cloud allowance
update public.user_plans
set plan = 'free', status = null
where user_id = '<auth-user-uuid>';
```

### Caveats — read before relying on manual grants

1. **The Stripe webhook can overwrite a manual plan.** If a manually-granted user later goes through Checkout (or has any live subscription), `customer.subscription.created/updated` sets their `plan` from the subscription while the status is granting — clobbering the manual value (`services/billingService.js` in the API repo). For your own admin account: never run checkout on it. For comps: ensure they have no paying subscription. (A hidden *paid* plan is granted by the webhook by design, so this "clobber" is the intended path there.) A future `manual_override boolean` on `user_plans` (respected by the webhook) would make comp plans sticky — parked for Phase 7+.
2. **Insert the `plans` row before assigning it.** `user_plans.plan` is a FK to `plans.plan`; assigning a non-existent plan is rejected.
3. **"Hidden" ≠ secret at the API level.** `plans` is readable by any authenticated client (`grant select … to authenticated`, policy `using (true)`), so a curious user querying the table sees every row, including hidden ones and their `description`. "Hidden" means *not offered in the upgrade UI*, not *invisible*. Fine for self/comp use; filter the `plans` select only if a plan must be truly private.
4. **"Unlimited" is a sentinel, not infinity.** Both triggers compare against a real number (`used + new > limit_bytes`; `count(*) >= max_files`), so `god_mode`'s huge values are *effectively* ungated — the real ceiling is Supabase disk. There is no null-means-unlimited path: `max_files` is `NOT NULL`, and a user whose plan row is somehow missing falls back to the **`free`** limits rather than to no gate.
5. **Revert targets `free`.** If a manually-granted user also has Stripe activity, ending that subscription reverts them to `free`, not back to their manual plan — via `customer.subscription.deleted` on a cancel, or via `customer.subscription.updated` carrying a terminal status (`unpaid` / `incomplete_expired` / `canceled`) when dunning ends that way instead.
6. **Both levers are enforced, and both are humane on downgrade.** Moving a user to a smaller plan never deletes or locks anything: they keep every file, can still edit and delete them, and can still save anything that doesn't grow their usage. What's blocked is *growth* — a bigger save, or a new file past `max_files`.

---

## File storage — where a user's bytes actually live

> Added 2026-08-01 with [ADR-037](02-decisions.md#adr-037--a-file-is-a-snapshot-plus-deltas-whole-document-writes-are-retired) / migration `0006`. **Read this before touching anyone's file data by hand.**

**A FILE IS A SNAPSHOT PLUS DELTAS. Neither half is the file on its own.**

| Half | Where | Written |
|---|---|---|
| **Snapshot** — the whole `FeatureCollection` | Storage object, private bucket `user-files`, at `{user_id}/{file_id}.geojson` | rarely, at checkpoints |
| **Deltas** — one row per feature touched since | `public.file_edits`, deduped on `(file_id, feature_id)` | every edit |
| **Watermark** — which deltas the snapshot contains | `public.user_files.snapshot_seq` | after each checkpoint's upload lands |

Three consequences for anyone poking at this in the dashboard:

1. **Downloading the object does not give you the user's file.** It gives you the file as of the last checkpoint. Anything in `file_edits` above `snapshot_seq` is missing from it. To reconstruct: take the object, then apply each delta above the watermark by `feature_id` — `upsert` replaces (or appends), `delete` removes.
2. **Never delete `file_edits` rows to "tidy up".** A row above the watermark is the only copy of that edit. The buffer is emptied by checkpoints, which happen on their own; a buffer that looks large just means the file has not been opened or idled recently.
3. **Deleting a user does NOT delete their objects.** `on delete cascade` cannot reach Storage, and `storage.protect_delete()` rejects a direct SQL `DELETE` on `storage.objects` with `42501`. The `{user_id}/` prefix sweep on `POST /api/v1/account/delete`, via the Storage API, is the only mechanism — **a compliance obligation, not a cleanup nicety.** `file_edits` cascades normally.

**Usage figures lag.** `public.user_storage_usage` measures the **snapshot**, so it under-reports between checkpoints and jumps when one lands. That is by design (ADR-037's growth rule means nothing is refused mid-edit) and it is why the account page's usage bar is UX rather than a gate. A user reporting "my usage doesn't match my files" is almost always seeing this.

**The per-file ceiling is `50000000` bytes (decimal 50 MB), uniform across all tiers** — a guardrail, not a plan lever. It is enforced by the bucket's `file_size_limit`, at the edge. Do not raise it above the project's global upload limit; on the free plan those are the same number.

---

_See also: [`02-decisions.md`](02-decisions.md) ADR-022 / ADR-031 (plan model) · ADR-034 (hidden/comp/paid plans + the premium axis) · ADR-035 / ADR-037 (file storage), and [`../supabase/migrations/README.md`](../supabase/migrations/README.md) (applying + verifying `0005` and `0006`)._
