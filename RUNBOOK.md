# GeoJSON Studio — Operations Runbook

Living operational procedures for the Cloud epic — privileged/manual tasks run against the **Supabase** project via the SQL Editor. This is distinct in genre from the design/decision docs under [`docs/`](docs/) (which record *why*); this records *how to do* recurring ops tasks.

> **Not here:** running the billing stack locally (`.env.local`, Stripe CLI, `npm run local`) lives in the **API repo**'s `README.md` → *Development → Local Billing & Webhooks*. Applying and verifying migrations lives in [`supabase/migrations/README.md`](supabase/migrations/README.md).

The SQL Editor executes as a privileged role that **bypasses RLS**, so these writes succeed even though `user_plans` is read-only to clients (ADR-022). Before running anything, confirm which project you are on — **non-prod vs prod**.

---

## Plan administration

Plans are **data**: `public.plans` is a lookup of tier → storage limit, and every user has one row in `public.user_plans` naming their plan (ADR-031, `0005_plans_and_quota.sql`). Because tiers are rows, comps and hidden plans need **no code change** — insert a plan row, then point a user at it.

### Add a hidden / comp plan

A *hidden* plan exists in the DB and is enforced by the storage-quota trigger, but is never offered in the app's upgrade UI and has no Stripe price to buy. Add the plan row **first** — `user_plans.plan` is a foreign key to `plans.plan`, so the plan must exist before it can be assigned.

Example — an effectively-unlimited plan (for your own account):

```sql
insert into public.plans (plan, limit_bytes, label, rank) values
  ('unlimited', 1125899906842624, 'Unlimited', 100)   -- 1 PiB sentinel = effectively no gate
on conflict (plan) do update
  set limit_bytes = excluded.limit_bytes, label = excluded.label, rank = excluded.rank;
```

Student / enterprise comps are the same pattern with a real limit:

```sql
insert into public.plans (plan, limit_bytes, label, rank) values
  ('student',     2147483648, 'Student',    50),   -- 2 GiB
  ('enterprise', 53687091200, 'Enterprise', 90)    -- 50 GiB
on conflict (plan) do update
  set limit_bytes = excluded.limit_bytes, label = excluded.label, rank = excluded.rank;
```

### Put a user on a plan (manual grant)

Look up the user id, then set the plan (and a `status` so the app treats them as active):

```sql
-- find the user
select id, email from auth.users where email = 'someone@example.com';

-- grant
update public.user_plans
set plan = 'unlimited', status = 'active'
where user_id = '<auth-user-uuid>';
```

### Inspect / reset a user's plan

```sql
-- current plan + limit for a user
select up.user_id, up.plan, p.limit_bytes, up.status,
       up.stripe_customer_id, up.stripe_subscription_id, up.current_period_end
from public.user_plans up
join public.plans p on p.plan = up.plan
where up.user_id = '<auth-user-uuid>';

-- reset to the free cloud allowance
update public.user_plans
set plan = 'early_access', status = null
where user_id = '<auth-user-uuid>';
```

### Caveats — read before relying on manual grants

1. **The Stripe webhook can overwrite a manual plan.** If a manually-granted user later goes through Checkout (or has any live subscription), `customer.subscription.created/updated` sets their `plan` from the subscription while the status is granting — clobbering the manual value (`services/billingService.js` in the API repo). For your own admin account: never run checkout on it. For comps: ensure they have no paying subscription. A future `manual_override boolean` on `user_plans` (respected by the webhook) would make manual plans sticky — parked for Phase 7+.
2. **Insert the `plans` row before assigning it.** `user_plans.plan` is a FK to `plans.plan`; assigning a non-existent plan is rejected.
3. **"Hidden" ≠ secret at the API level.** `plans` is readable by any authenticated client (`grant select … to authenticated`, policy `using (true)`), so a curious user querying the table sees every row, including hidden ones. "Hidden" means *not offered in the upgrade UI*, not *invisible*. Fine for self/comp use; filter the `plans` select only if a plan must be truly private.
4. **"Unlimited" is a sentinel, not infinity.** The quota trigger compares `used + new > limit_bytes`, so a huge `limit_bytes` is *effectively* ungated — the real ceiling is Supabase disk. (If you ever want true no-gate semantics, a one-line trigger change to treat `null` as unlimited is possible; today a `null` limit falls back to the `early_access` limit.)
5. **Revert-on-cancel targets `early_access`.** If a manually-granted user also has Stripe activity, a cancellation reverts them to `early_access`, not back to their manual plan.

---

_See also: [`docs/02-decisions.md`](docs/02-decisions.md) ADR-022 / ADR-031 (plan model), and [`supabase/migrations/README.md`](supabase/migrations/README.md) (applying + verifying `0005`)._
