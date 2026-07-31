-- p2_storage_policy_cross_table.sql
-- Cloud epic — Phase 7b-2 PROTOTYPE 2 (ADR-035).
--
-- *** THIS IS NOT A MIGRATION. *** Throwaway objects only, all prefixed
-- `zz_p2_` / `zz-p2-`, all removed again in section 9. NON-PROD only.
--
-- THE QUESTION
--   ADR-035 §Consequences sketches publish (ADR-034) as: ONE private bucket,
--   owner-only for everything, plus one extra RLS policy granting `anon` read
--   where the corresponding public.user_files row is published. Publishing then
--   becomes flipping a boolean — one copy of the file, no expiry, instant
--   unpublish.
--
--   That requires a policy on storage.objects to reach OUT into another table.
--   ADR-035 flags it as needing prototyping. Two things could stop it, and they
--   are different failures with different fixes:
--     * `anon` has no grant on the metadata table at all → the subquery errors.
--     * the metadata table's own owner-only RLS hides the row from an anon
--       caller → the subquery returns nothing and everything is denied.
--   Both are plausible; the second is the quieter one, because it fails as
--   "correctly denied" rather than as an error.
--
-- WHAT IT ANSWERS
--   Q1  May a storage.objects policy contain a cross-table subquery at all?
--   Q2  Does the naive version work for `anon`, or does it hit one of the two
--       failures above? (Which one — the distinction decides the fix.)
--   Q3  Does a `security definer` lookup function fix it, and at what blast
--       radius? (It reads past RLS by design — it must expose the published
--       flag and NOTHING else.)
--   Q4  Is deriving file_id from the object path safe? The path is
--       {user_id}/{file_id}.geojson, so the policy must parse the name. A
--       malformed name must not raise — an error inside a policy would break
--       reads for everyone, not just for that object.
--   Q5  What does it cost per read? The policy runs on every object access.
--   Q6  Does unpublishing take effect immediately over HTTP, or does CDN
--       caching keep serving it? ADR-035 calls this "a correctness problem, not
--       a performance one" for a revoke action — this is where it gets measured.
--
-- HOW TO RUN — sections 0–4 and 9 are pure SQL. Sections 5–6 need real HTTP
--   requests (an anonymous GET of the object URL), which is the only thing that
--   proves the policy works through the Storage API rather than merely in
--   Postgres. See ./README.md.
--
-- A scratch table (public.zz_p2_files) stands in for public.user_files rather
-- than adding an is_published column to the real one — same shape, same
-- owner-only RLS, no migration to undo afterwards.

-- ============================================================================
-- 0. Preflight + scratch scaffolding.
-- ============================================================================

create table if not exists public.zz_p2_results (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  step     text,
  question text,
  observed text
);
truncate public.zz_p2_results restart identity;

insert into public.zz_p2_results (step, question, observed)
values ('0.1', 'Role, and may we create policies on storage.objects?',
        format('current_user=%s | owner=%s | rls enabled=%s',
               current_user,
               (select r.rolname from pg_class c join pg_roles r on r.oid = c.relowner
                 where c.oid = 'storage.objects'::regclass),
               (select relrowsecurity from pg_class where oid = 'storage.objects'::regclass)));

insert into public.zz_p2_results (step, question, observed)
select '0.2', 'Policies already on storage.objects',
       coalesce(string_agg(policyname || ' (' || cmd || ' → ' ||
                  array_to_string(roles, '/') || ')', ', ' order by policyname),
                '(none)')
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects';

-- Stand-in for public.user_files: same owner-only posture (0001), plus the
-- is_published flag publish would add.
create table if not exists public.zz_p2_files (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  name         text,
  is_published boolean not null default false
);
alter table public.zz_p2_files enable row level security;

revoke all on public.zz_p2_files from anon;
revoke all on public.zz_p2_files from authenticated;
grant select on public.zz_p2_files to authenticated;

drop policy if exists "zz_p2_files_select_own" on public.zz_p2_files;
create policy "zz_p2_files_select_own" on public.zz_p2_files
  for select to authenticated using (auth.uid() = user_id);

truncate public.zz_p2_files;

-- Two files for one fictional owner: one published, one not. The object path
-- is {user_id}/{file_id}.geojson exactly as ADR-035 specifies.
insert into public.zz_p2_files (id, user_id, name, is_published) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '11111111-1111-4111-8111-111111111111', 'published.geojson',   true),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
   '11111111-1111-4111-8111-111111111111', 'unpublished.geojson', false);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('zz-p2-proto', 'zz-p2-proto', false, 52428800, array['application/json'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Three objects, written by SQL so no bytes exist behind them — fine for
-- everything except sections 5–6, which need a real upload. Guarded: the
-- storage.objects column set and its own internal triggers are version-
-- dependent, and a bare failure here would abort the script before teardown
-- ever runs. If 0.3 reports a failure, create the three objects by upload
-- instead (paths matter exactly) — see ./README.md.
do $$
begin
  -- Idempotency only, and it must not abort the run: Supabase's
  -- storage.protect_delete() raises 42501 on any SQL delete of an object row
  -- (found running P1, 2026-07-30). On a first run there is nothing to delete
  -- anyway; on a re-run, clear the bucket from the dashboard first.
  begin
    delete from storage.objects where bucket_id = 'zz-p2-proto';
  exception when others then
    null;
  end;

  begin
    insert into storage.objects (bucket_id, name, metadata) values
      ('zz-p2-proto',
       '11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.geojson',
       jsonb_build_object('size', 100, 'mimetype', 'application/json')),
      ('zz-p2-proto',
       '11111111-1111-4111-8111-111111111111/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.geojson',
       jsonb_build_object('size', 100, 'mimetype', 'application/json')),
      -- Q4's hostile case: a name that does not parse as {uuid}/{uuid}.geojson.
      -- If the policy raises on this row, EVERY anon read breaks, including the
      -- legitimately published one — a self-inflicted outage from one bad name.
      ('zz-p2-proto', 'not-a-uuid/garbage.txt',
       jsonb_build_object('size', 100, 'mimetype', 'text/plain'));

    insert into public.zz_p2_results (step, question, observed)
    values ('0.3', 'Scratch objects created by SQL?', 'YES — 3 objects.');
  exception when others then
    insert into public.zz_p2_results (step, question, observed)
    values ('0.3', 'Scratch objects created by SQL?',
            format('NO — sqlstate=%s %s  (upload them instead; see README)',
                   sqlstate, sqlerrm));
  end;
end;
$$;

-- ============================================================================
-- 1. Q4 — path parsing, tested on its own before it goes anywhere near a
--    policy. Guarded with a regex so a non-uuid name yields NULL rather than
--    raising 22P02 (invalid input syntax for type uuid).
-- ============================================================================

create or replace function public.zz_p2_file_id_from_path(p_name text)
returns uuid
language sql
immutable
as $$
  -- Case-insensitive (~*): a name carrying an uppercase uuid must still resolve,
  -- otherwise it would silently read as "not published" rather than as an error —
  -- the worst kind of failure, since it looks like a deliberate denial.
  select case
           when storage.filename(p_name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.geojson$'
           then split_part(storage.filename(p_name), '.', 1)::uuid
         end;
$$;

do $$
declare
  v_ok    uuid;
  v_junk  uuid;
begin
  begin
    select public.zz_p2_file_id_from_path(
      '11111111-1111-4111-8111-111111111111/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.geojson')
      into v_ok;
    select public.zz_p2_file_id_from_path('not-a-uuid/garbage.txt') into v_junk;

    insert into public.zz_p2_results (step, question, observed)
    values ('1.1', 'Q4 — does path parsing survive a malformed object name?',
            format('good name → %s | junk name → %s (NULL expected, not an error)',
                   coalesce(v_ok::text, 'NULL'), coalesce(v_junk::text, 'NULL')));
  exception when others then
    insert into public.zz_p2_results (step, question, observed)
    values ('1.1', 'Q4 — does path parsing survive a malformed object name?',
            format('RAISED — sqlstate=%s %s  (unsafe for use in a policy)',
                   sqlstate, sqlerrm));
  end;
end;
$$;

-- ============================================================================
-- 2. Q1 + Q2 — the naive policy: subquery straight into the metadata table,
--    no elevated privilege. This is the version ADR-035 sketches. Expect it to
--    fail; the point is to learn WHICH way it fails.
-- ============================================================================

do $$
begin
  begin
    execute 'drop policy if exists "zz_p2_anon_read_naive" on storage.objects';
    execute $pol$
      create policy "zz_p2_anon_read_naive" on storage.objects
        for select to anon
        using (
          bucket_id = 'zz-p2-proto'
          and exists (
            select 1 from public.zz_p2_files f
             where f.id = public.zz_p2_file_id_from_path(storage.objects.name)
               and f.is_published
          )
        )
    $pol$;
    insert into public.zz_p2_results (step, question, observed)
    values ('2.1', 'Q1 — may a storage.objects policy contain a cross-table subquery?',
            'YES — policy created (creation is not the same as working; see 2.2).');
  exception when others then
    insert into public.zz_p2_results (step, question, observed)
    values ('2.1', 'Q1 — may a storage.objects policy contain a cross-table subquery?',
            format('NO — sqlstate=%s %s', sqlstate, sqlerrm));
  end;
end;
$$;

-- Role is switched with set_config(...) rather than `begin; set local role anon;
-- rollback;`. The rollback would discard the results rows this script exists to
-- produce — and worse, an explicit BEGIN inside the SQL editor's own implicit
-- transaction is a no-op, so the ROLLBACK would discard the ENTIRE script.
-- Switching back before the insert matters too: anon has no grant on
-- zz_p2_results.
do $$
declare
  v_prev text := current_setting('role', true);
  v_rows int;
  v_obs  text;
begin
  perform set_config('role', 'anon', true);

  begin
    select count(*) into v_rows from storage.objects where bucket_id = 'zz-p2-proto';
    v_obs := format('%s row(s) visible. Expected 1 (the published one). '
                    '0 = the grant or zz_p2_files'' own RLS hid the row from the subquery.',
                    v_rows);
  exception when others then
    v_obs := format('ERRORED — sqlstate=%s %s', sqlstate, sqlerrm);
  end;

  perform set_config('role', coalesce(v_prev, 'none'), true);

  insert into public.zz_p2_results (step, question, observed)
  values ('2.2', 'Q2 — what does anon see through the naive policy?', v_obs);
end;
$$;

-- ============================================================================
-- 3. Q3 — the security definer fix. The function reads past zz_p2_files' RLS
--    and needs no grant for the caller, so the policy can consult it as anon.
--
--    Blast radius is the thing to watch: this function is callable by anon, so
--    it must answer exactly one question — "is this file published?" — and
--    return a boolean, never a row. It leaks the existence of an id and nothing
--    else. `stable` (not `volatile`) so the planner may cache it per statement.
-- ============================================================================

create or replace function public.zz_p2_is_published(p_file_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_published from public.zz_p2_files where id = p_file_id), false);
$$;

revoke all on function public.zz_p2_is_published(uuid) from public;
grant execute on function public.zz_p2_is_published(uuid) to anon, authenticated;

do $$
begin
  begin
    execute 'drop policy if exists "zz_p2_anon_read_naive" on storage.objects';
    execute 'drop policy if exists "zz_p2_anon_read_definer" on storage.objects';
    execute $pol$
      create policy "zz_p2_anon_read_definer" on storage.objects
        for select to anon
        using (
          bucket_id = 'zz-p2-proto'
          and public.zz_p2_is_published(
                public.zz_p2_file_id_from_path(storage.objects.name))
        )
    $pol$;
    insert into public.zz_p2_results (step, question, observed)
    values ('3.1', 'Q3a — security definer policy created?', 'YES');
  exception when others then
    insert into public.zz_p2_results (step, question, observed)
    values ('3.1', 'Q3a — security definer policy created?',
            format('NO — sqlstate=%s %s', sqlstate, sqlerrm));
  end;
end;
$$;

do $$
declare
  v_prev  text := current_setting('role', true);
  v_names text;
  v_rows  int;
  v_obs   text;
begin
  perform set_config('role', 'anon', true);

  begin
    select count(*), coalesce(string_agg(storage.filename(name), ', '), '(none)')
      into v_rows, v_names
      from storage.objects where bucket_id = 'zz-p2-proto';
    v_obs := format('%s row(s): %s  [want: 1 row, aaaaaaaa-….geojson]', v_rows, v_names);
  exception when others then
    v_obs := format('ERRORED — sqlstate=%s %s', sqlstate, sqlerrm);
  end;

  perform set_config('role', coalesce(v_prev, 'none'), true);

  insert into public.zz_p2_results (step, question, observed)
  values ('3.2', 'Q3b — does anon now see exactly the published file?', v_obs);
end;
$$;

-- The revoke half: unpublish, confirm it disappears, publish again. In Postgres,
-- at least — section 6 is where the same question gets asked of the CDN.
do $$
declare
  v_prev text := current_setting('role', true);
  v_rows int;
  v_obs  text;
begin
  update public.zz_p2_files set is_published = false
   where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

  perform set_config('role', 'anon', true);
  begin
    select count(*) into v_rows from storage.objects where bucket_id = 'zz-p2-proto';
    v_obs := format('%s row(s) visible to anon while unpublished [want: 0]', v_rows);
  exception when others then
    v_obs := format('ERRORED — sqlstate=%s %s', sqlstate, sqlerrm);
  end;
  perform set_config('role', coalesce(v_prev, 'none'), true);

  -- Restore, so section 5's HTTP checks find the file published again.
  update public.zz_p2_files set is_published = true
   where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

  insert into public.zz_p2_results (step, question, observed)
  values ('3.3', 'Q3c — does unpublishing revoke access in Postgres?', v_obs);
end;
$$;

-- Owner isolation must survive all of this: a second user's view of the world is
-- unchanged by anything published. Cheap to check, and this policy joins the
-- two-account isolation test in ADR-035 §Consequences.
do $$
declare
  v_prev text := current_setting('role', true);
  v_rows int;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}', true);

  select count(*) into v_rows from public.zz_p2_files;

  perform set_config('role', coalesce(v_prev, 'none'), true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.zz_p2_results (step, question, observed)
  values ('3.4', 'Sanity — can a DIFFERENT authenticated user read the owner''s metadata?',
          format('%s row(s) [want: 0]', v_rows));
end;
$$;

-- ============================================================================
-- 4. Q5 — cost per read. The policy runs on every object access, so a plan
--    that re-executes the lookup per row is a different proposition from one
--    the planner caches. Read the output for the function call's actual time
--    and loop count, not the total.
-- ============================================================================

-- Plain `set role` / `reset role` (not `set local` in an explicit transaction) —
-- EXPLAIN has to return its output as a result set, so it can't live inside a
-- DO block, and an explicit rollback here would take the whole script with it.
set role anon;
explain (analyze, buffers, costs off)
  select name from storage.objects where bucket_id = 'zz-p2-proto';
reset role;

insert into public.zz_p2_results (step, question, observed)
values ('4.1', 'Q5 — per-read cost of the policy',
        '>>> FILL IN BY HAND from the EXPLAIN output above <<<');

-- ============================================================================
-- 5. THE REAL PROOF — anonymous HTTP. Everything above shows the policy works
--    in Postgres. It does not show that the Storage API honours it, because
--    the API decides for itself which role it connects as and what it checks
--    before it ever reaches a query.
--
--    >>> MANUAL STEP <<< (recipes in ./README.md §"Fetching as a stranger")
--      a. GET the published object's URL with NO auth header  → expect 200.
--      b. GET the unpublished object's URL with NO auth header → expect 4xx.
--    Note the exact status codes and any `cf-cache-status` header.
--
--    Caveat worth knowing before you read the result: the rows in section 0
--    were inserted by SQL, so no bytes exist in S3 behind them. A 200 is
--    therefore unlikely even when the policy is right — what you are looking
--    for is the DIFFERENCE between (a) and (b): a 404/400 "object not found"
--    for the published one versus a 403-shaped denial for the unpublished one
--    means the policy is being consulted and is discriminating correctly.
--    To get a true 200, upload a real file to the published path first
--    (README.md covers it) — worth doing, since 200-vs-403 is unambiguous and
--    404-vs-400 requires interpretation.
-- ============================================================================

insert into public.zz_p2_results (step, question, observed)
values ('5.1', 'Anonymous GET of the PUBLISHED object',
        '>>> FILL IN BY HAND: status + body <<<');
insert into public.zz_p2_results (step, question, observed)
values ('5.2', 'Anonymous GET of the UNPUBLISHED object',
        '>>> FILL IN BY HAND: status + body <<<');

-- ============================================================================
-- 6. Q6 — revocation vs the CDN. Only meaningful if 5.1 returned 200.
--
--    >>> MANUAL STEP <<<
--      a. Fetch the published object anonymously (warms the cache).
--      b. In SQL:  update public.zz_p2_files set is_published = false
--                   where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
--      c. Immediately fetch it again, anonymously.
--
--    Still 200 → the CDN is serving a file the owner has revoked. Record how
--    long it keeps doing so. ADR-035 already calls this a correctness problem
--    rather than a performance one; a non-zero answer here is what turns that
--    from a caveat into a design constraint on publish.
-- ============================================================================

insert into public.zz_p2_results (step, question, observed)
values ('6.1', 'Q6 — does unpublish take effect immediately over HTTP?',
        '>>> FILL IN BY HAND: status after unpublish + cf-cache-status + time to expiry <<<');

-- ============================================================================
-- 9. Teardown. Run it even on failure — a stray anon-read policy on
--    storage.objects is a live data-exposure path, and the security definer
--    function is executable by anon.
-- ============================================================================

drop policy if exists "zz_p2_anon_read_naive"   on storage.objects;
drop policy if exists "zz_p2_anon_read_definer" on storage.objects;

drop function if exists public.zz_p2_is_published(uuid);
drop function if exists public.zz_p2_file_id_from_path(text);

drop table if exists public.zz_p2_files;

-- See the note in P1 §9: storage.protect_delete() rejects SQL deletes of object
-- rows, and an unguarded failure here would roll back the policy and function
-- drops above — leaving anon read access live. Guarded so the drops survive.
--
-- >>> DELETE THE BUCKET FROM THE DASHBOARD <<< Storage → zz-p2-proto → Delete
-- bucket, then re-run this section.
do $$
begin
  begin
    delete from storage.objects where bucket_id = 'zz-p2-proto';
    delete from storage.buckets where id = 'zz-p2-proto';
    insert into public.zz_p2_results (step, question, observed)
    values ('9.0', 'Scratch bucket removed by SQL?', 'YES');
  exception when others then
    insert into public.zz_p2_results (step, question, observed)
    values ('9.0', 'Scratch bucket removed by SQL?',
            format('NO — sqlstate=%s %s  (delete the bucket from the dashboard)',
                   sqlstate, sqlerrm));
  end;
end;
$$;

insert into public.zz_p2_results (step, question, observed)
select '9.1', 'Teardown — anything of ours left behind?',
       format('policies=%s | functions=%s | scratch bucket rows=%s | scratch table=%s',
              (select count(*) from pg_policies
                where schemaname = 'storage' and tablename = 'objects'
                  and policyname like 'zz\_p2\_%'),
              (select count(*) from pg_proc
                where proname like 'zz\_p2\_%'),
              (select count(*) from storage.objects where bucket_id = 'zz-p2-proto'),
              (select count(*) from information_schema.tables
                where table_schema = 'public' and table_name = 'zz_p2_files'));

-- ============================================================================
-- 10. The report. Paste this output back.
--     (drop table public.zz_p2_results; once the result is recorded.)
-- ============================================================================

select step, question, observed from public.zz_p2_results order by id;
