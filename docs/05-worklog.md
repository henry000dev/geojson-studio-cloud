# 05 — Worklog

> **Stability:** volatile. A dated, append-at-top log of what's been done and where things were left. **Read this first on resuming.** Newest entry at the top.

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
