-- p1_storage_objects_quota.sql
-- Cloud epic — Phase 7b-2 PROTOTYPE 1 (ADR-035).
--
-- *** THIS IS NOT A MIGRATION. *** It lives outside ../migrations deliberately.
-- It creates throwaway objects (all prefixed `zz_p1_` / `zz-p1-`) and deletes
-- them again in section 9. Run it against the NON-PROD project only. Nothing
-- here is intended to survive; the deliverable is the report in section 10.
--
-- THE QUESTION
--   Today the storage-bytes quota is `enforce_storage_quota()`, a BEFORE
--   INSERT OR UPDATE trigger on public.user_files (0005 §4). Once the GeoJSON
--   moves into Supabase Storage (ADR-035), user_files no longer holds the bytes
--   and that trigger has nothing to weigh. The only place that knows a file's
--   real size is `storage.objects.metadata->>'size'` — a Supabase-managed table.
--
--   ADR-035 proposes the direct analogue: the same trigger, on storage.objects.
--   That is an assumption, and ADR-035 §Consequences says it must be prototyped
--   before the slice is committed to. This script tests it, in the order that
--   extracts the most information for the least setup.
--
-- WHAT IT ANSWERS
--   Q1  May we create a trigger on storage.objects at all? (permission)
--   Q2  Does it fire on a REAL upload — i.e. on the Storage API's write path,
--       not just on a hand-written SQL insert?
--   Q3  Is metadata->>'size' populated at BEFORE INSERT time, or filled in
--       afterwards by a second statement? If it is NULL at insert, quota-on-
--       insert is impossible as designed and the whole mechanism changes.
--   Q4  Does `raise exception` actually reject the upload, and what does the
--       HTTP client see? (needs a usable error, per 0005's GS_QUOTA_EXCEEDED)
--   Q5  When it rejects, are the bytes already in S3 — i.e. do we orphan
--       storage we can neither see nor count? This is the abuse-channel
--       question and the one most likely to sink the approach.
--   Q6  FALLBACK-IN-PLACE: can an RLS `WITH CHECK` policy carrying an aggregate
--       subquery do the same job without a trigger? (See the note at §6 — this
--       reopens a rejection recorded in ADR-022.)
--
-- HOW TO RUN — this script is NOT a single paste-and-go. Sections 2 and 4
--   require a real upload through the Storage API, which cannot be done from
--   the SQL editor. Run 0–1, then do the section-2 upload, then 3, then the
--   section-4 upload, then 5–6, then 9. See ./README.md for the exact steps
--   and the curl/dashboard recipes.
--
-- Every check writes a row into public.zz_p1_results instead of relying on
-- `raise notice`, which the Supabase SQL editor does not surface reliably.
-- Section 10 selects that table — paste its output back as the result.

-- ============================================================================
-- 0. Preflight — scratch scaffolding, then what the project will even allow.
-- ============================================================================

create table if not exists public.zz_p1_results (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  step     text,
  question text,
  observed text
);
truncate public.zz_p1_results restart identity;

-- The observer's log. Separate from the results table because the trigger
-- writes it from inside the Storage API's transaction, and we want the raw
-- firing record kept apart from our own commentary.
create table if not exists public.zz_p1_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  tg_op       text,
  bucket_id   text,
  object_name text,
  -- The load-bearing column (Q3): what the trigger could see at BEFORE-time.
  size_seen   bigint,
  metadata    jsonb
);
truncate public.zz_p1_log restart identity;

insert into public.zz_p1_results (step, question, observed)
values ('0.1', 'Which role does the SQL editor run as?',
        format('current_user=%s  session_user=%s', current_user, session_user));

insert into public.zz_p1_results (step, question, observed)
values ('0.2', 'Who owns storage.objects, and may we touch it?',
        format('owner=%s | TRIGGER priv=%s | CREATE on schema storage=%s',
               (select r.rolname
                  from pg_class c
                  join pg_roles r on r.oid = c.relowner
                 where c.oid = 'storage.objects'::regclass),
               has_table_privilege('storage.objects', 'TRIGGER'),
               has_schema_privilege('storage', 'CREATE')));

-- Supabase ships its own triggers here. Worth recording: if one of them is a
-- BEFORE trigger that also touches metadata, ordering (alphabetical by name)
-- would matter to us.
insert into public.zz_p1_results (step, question, observed)
select '0.3', 'Triggers already on storage.objects (Supabase''s own)',
       coalesce(string_agg(tgname || ' [' ||
                  case when (t.tgtype::int & 2) = 2 then 'BEFORE' else 'AFTER' end || ']',
                  ', ' order by tgname), '(none)')
  from pg_trigger t
 where t.tgrelid = 'storage.objects'::regclass
   and not t.tgisinternal;

-- The column set is version-dependent (owner vs owner_id, level, path_tokens…).
-- Recording it makes the rest of the result reproducible against a known shape.
insert into public.zz_p1_results (step, question, observed)
select '0.4', 'storage.objects columns (version-dependent)',
       string_agg(column_name || ':' || data_type, ', ' order by ordinal_position)
  from information_schema.columns
 where table_schema = 'storage' and table_name = 'objects';

-- A scratch bucket, shaped like the real one ADR-035 specifies (private,
-- explicit size limit, JSON-only) so the test exercises the real configuration.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('zz-p1-proto', 'zz-p1-proto', false, 52428800, array['application/json'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ============================================================================
-- 1. Q1 — may we create a trigger on storage.objects, and does it fire on a
--    plain SQL insert? The `security definer` is load-bearing: the Storage API
--    connects as supabase_storage_admin, which has no rights on public.zz_p1_log,
--    so the function must run as its owner to be able to write the log at all.
--    (The real quota trigger will need the same treatment to read user_plans.)
-- ============================================================================

create or replace function public.zz_p1_observe()
returns trigger
language plpgsql
security definer
set search_path = public, storage
as $$
begin
  insert into public.zz_p1_log (tg_op, bucket_id, object_name, size_seen, metadata)
  values (tg_op, new.bucket_id, new.name,
          (new.metadata->>'size')::bigint, new.metadata);
  return new;
end;
$$;

-- CREATE TRIGGER has no IF NOT EXISTS, and the whole statement may be refused
-- on privilege grounds — which is itself the answer to Q1. Catch it so the
-- script reports rather than aborts.
do $$
begin
  begin
    execute 'drop trigger if exists zz_p1_observe_trg on storage.objects';
    execute 'create trigger zz_p1_observe_trg
               before insert or update on storage.objects
               for each row execute function public.zz_p1_observe()';
    insert into public.zz_p1_results (step, question, observed)
    values ('1.1', 'Q1 — may we CREATE a trigger on storage.objects?',
            'YES — created.');
  exception when others then
    insert into public.zz_p1_results (step, question, observed)
    values ('1.1', 'Q1 — may we CREATE a trigger on storage.objects?',
            format('NO — sqlstate=%s %s', sqlstate, sqlerrm));
  end;
end;
$$;

-- Does it fire on a hand-written insert? Necessary but NOT sufficient: the
-- Storage API is a separate service and may write by a path that differs.
-- Section 2 is the one that counts.
do $$
declare
  v_fired int;
begin
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('zz-p1-proto', 'direct-sql-insert.geojson',
            jsonb_build_object('size', 12345, 'mimetype', 'application/json'));

    select count(*) into v_fired from public.zz_p1_log
     where object_name = 'direct-sql-insert.geojson';

    insert into public.zz_p1_results (step, question, observed)
    values ('1.2', 'Does the trigger fire on a direct SQL insert?',
            case when v_fired > 0 then 'YES — logged.'
                 else 'NO — insert succeeded but nothing logged.' end);
  exception when others then
    insert into public.zz_p1_results (step, question, observed)
    values ('1.2', 'Does the trigger fire on a direct SQL insert?',
            format('INSERT ITSELF FAILED — sqlstate=%s %s', sqlstate, sqlerrm));
  end;
end;
$$;

-- ============================================================================
-- 2. Q2 + Q3 — THE INFORMATIVE ONE. Stop here and do a REAL upload.
--
--    >>> MANUAL STEP <<<
--    Upload any small .json file to the `zz-p1-proto` bucket, via either
--    route in ./README.md §"Uploading for real" (dashboard is fine — the
--    dashboard's service-role key bypasses RLS policies but does NOT bypass
--    triggers, which is exactly the path under test).
--
--    Then run section 2 below.
--
--    Read the output carefully. `size_seen` is the whole ballgame:
--      * a number  → metadata is present at BEFORE INSERT; a quota trigger can
--                    weigh the write before it lands, as ADR-035 assumes.
--      * NULL      → the API inserts the row first and fills the size in later.
--                    Quota-on-insert is then impossible; the gate would have to
--                    move to BEFORE UPDATE (which is after the bytes are already
--                    committed — i.e. it fails Q5 by construction) or to the
--                    signed-URL fallback.
--    Also note the tg_op sequence: a lone INSERT, or INSERT followed by UPDATE?
-- ============================================================================

insert into public.zz_p1_results (step, question, observed)
select '2.1', 'Q2 — does the trigger fire on a REAL Storage API upload?',
       case when count(*) filter (where object_name <> 'direct-sql-insert.geojson') > 0
            then 'YES — the API path fires it.'
            else 'NO — nothing logged from the upload (or no upload done yet).'
       end
  from public.zz_p1_log;

insert into public.zz_p1_results (step, question, observed)
select '2.2', 'Q3 — is metadata->>''size'' populated at BEFORE INSERT time?',
       coalesce(string_agg(
         format('%s size_seen=%s', tg_op, coalesce(size_seen::text, 'NULL')),
         ' then ' order by id), '(no upload recorded)')
  from public.zz_p1_log
 where object_name <> 'direct-sql-insert.geojson';

-- The full raw record, in case the summary above flattens something that matters.
insert into public.zz_p1_results (step, question, observed)
select '2.3', 'Raw metadata seen by the trigger (first API row)',
       coalesce((select metadata::text from public.zz_p1_log
                  where object_name <> 'direct-sql-insert.geojson'
                  order by id limit 1), '(none)');

-- ============================================================================
-- 3. Q4 (part 1) — swap the observer for a REJECTING trigger and confirm the
--    exception blocks a plain SQL insert. Mirrors 0005 §4's error contract so
--    the client-side handling would be unchanged.
-- ============================================================================

-- Section 4 has to tell "the trigger never fired" apart from "it fired and
-- rejected" — opposite conclusions that look identical from outside the
-- database. A log table CANNOT do that job here: the `raise exception` below
-- aborts the statement, and the trigger's own INSERT is rolled back with it, so
-- the log would be empty in both cases and 4.1 would always read "never fired".
--
-- Sequences are the exception to transactionality — a consumed nextval() is
-- never given back, even on rollback. So the firing count survives the very
-- exception that discards everything else.
create sequence if not exists public.zz_p1_reject_seq;
select setval('public.zz_p1_reject_seq', 1, false);   -- reset: 0 firings so far

create or replace function public.zz_p1_reject()
returns trigger
language plpgsql
security definer
set search_path = public, storage
as $$
begin
  perform nextval('public.zz_p1_reject_seq');

  raise exception
    'GS_QUOTA_EXCEEDED: prototype rejection (op=%, size=%)',
    tg_op, coalesce((new.metadata->>'size')::text, 'unknown')
    using errcode = 'check_violation';
end;
$$;

do $$
begin
  begin
    execute 'drop trigger if exists zz_p1_observe_trg on storage.objects';
    execute 'drop trigger if exists zz_p1_reject_trg on storage.objects';
    execute 'create trigger zz_p1_reject_trg
               before insert on storage.objects
               for each row execute function public.zz_p1_reject()';
    insert into public.zz_p1_results (step, question, observed)
    values ('3.1', 'Rejecting trigger armed?', 'YES');
  exception when others then
    insert into public.zz_p1_results (step, question, observed)
    values ('3.1', 'Rejecting trigger armed?',
            format('NO — sqlstate=%s %s', sqlstate, sqlerrm));
  end;
end;
$$;

do $$
begin
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('zz-p1-proto', 'should-be-blocked.geojson',
            jsonb_build_object('size', 999, 'mimetype', 'application/json'));
    insert into public.zz_p1_results (step, question, observed)
    values ('3.2', 'Q4a — does raise exception block a direct SQL insert?',
            'NO — the insert went through anyway. (Serious: the gate leaks.)');
  exception when others then
    insert into public.zz_p1_results (step, question, observed)
    values ('3.2', 'Q4a — does raise exception block a direct SQL insert?',
            format('YES — blocked. sqlstate=%s  message=%s', sqlstate, sqlerrm));
  end;
end;
$$;

-- Clear the bucket before the rejection test so section 4.2 reads unambiguously
-- (§1.2's SQL row and §2's upload would otherwise be counted as survivors).
--
-- >>> DO THIS FROM THE DASHBOARD, NOT HERE <<< Storage → zz-p1-proto → select
-- all → delete. Deleting via SQL removes only the metadata row and leaves §2's
-- bytes in S3 — which is the exact debris section 5 is trying to detect, so
-- clearing it by SQL would poison the orphan probe.
insert into public.zz_p1_results (step, question, observed)
select '3.3', 'Bucket emptied via the dashboard before the rejection test?',
       format('%s row(s) still present: %s',
              count(*), coalesce(string_agg(name, ', '), '(none — good)'))
  from storage.objects where bucket_id = 'zz-p1-proto';

-- ============================================================================
-- 4. Q4 (part 2) + Q5 — THE DECIDING ONE. Stop here and upload for real again,
--    with the rejecting trigger armed.
--
--    >>> MANUAL STEP <<<
--    Upload a file whose size is DISTINCTIVE and easy to spot — README.md §
--    "Uploading for real" generates one of exactly 7,777,777 bytes. Use that
--    one; section 5's orphan probe depends on being able to recognise it.
--    Record the HTTP status and the response body verbatim — that is the
--    answer to "what would the user's browser see?".
--
--    Then run section 4 below.
-- ============================================================================

-- Read from the sequence, not the log — see the note above zz_p1_reject().
insert into public.zz_p1_results (step, question, observed)
select '4.1', 'Q4b — did the rejecting trigger fire on the real upload?',
       case when is_called
            then format('YES — fired %s time(s) and raised each time.', last_value)
            else 'NO — never fired. The Storage API''s write path does not reach our trigger.'
       end
  from public.zz_p1_reject_seq;

insert into public.zz_p1_results (step, question, observed)
select '4.2', 'Q4c — was the row kept out of storage.objects?',
       format('%s row(s) present in zz-p1-proto: %s  [want: none]',
              count(*), coalesce(string_agg(name, ', '), '(none — good)'))
  from storage.objects
 where bucket_id = 'zz-p1-proto';

-- Fill this in by hand from the upload response — it is the UX answer, and no
-- query can produce it. A clean 4xx carrying GS_QUOTA_EXCEEDED means the client
-- can say "You're out of space"; an opaque 500 means it cannot.
insert into public.zz_p1_results (step, question, observed)
values ('4.3', 'Q4d — what did the HTTP client actually see?',
        '>>> FILL IN BY HAND: status code + response body from the upload <<<');

-- ============================================================================
-- 5. Q5 — the orphan probe. The weakest test here, and worth being honest
--    about why: S3 is not visible from SQL. storage.objects showing no row
--    (4.2) proves the METADATA was kept out; it says nothing about whether the
--    BYTES were written before the row insert was attempted.
--
--    Two probes, in order of strength:
--
--    (a) S3-compatible listing — the only direct evidence. If the project has
--        S3 access keys enabled (Storage → Settings → S3 connection), list the
--        bucket over the S3 endpoint; anything present there but absent from
--        4.2 is an orphan. Recipe in ./README.md §"Probing for orphans".
--
--    (b) Behavioural inference — disarm the trigger (section 9 does this),
--        re-upload the SAME path, then compare the stored size against the
--        7,777,777-byte original. Equal size proves nothing either way; a
--        multipart remnant or a failure to overwrite is evidence of debris.
--
--    If neither probe can settle it, record "UNDETERMINED" — and note that an
--    undetermined answer argues FOR the signed-URL fallback rather than against
--    it, because an unbounded orphan channel is exactly the abuse surface
--    ADR-035 moved to Storage to close.
-- ============================================================================

insert into public.zz_p1_results (step, question, observed)
values ('5.1', 'Q5 — orphaned bytes after a rejected upload?',
        '>>> FILL IN BY HAND: YES / NO / UNDETERMINED, with which probe was used <<<');

-- ============================================================================
-- 6. Q6 — the in-place fallback: enforce the quota with an RLS `WITH CHECK`
--    policy carrying an aggregate subquery, and no trigger at all.
--
--    NOTE, because this reopens a settled decision: ADR-022 §Alternatives
--    rejected "client- or RLS-`with check`-only quota" on the grounds that
--    aggregate-across-rows checks belong in a trigger. That rejection was made
--    when the trigger was uncontroversially available, on our own table. If Q1
--    or Q2 comes back NO, the premise is gone and this becomes the cheapest
--    surviving option — so it is tested here rather than assumed dead.
--
--    Its known cost is measured below: a policy violation cannot carry a custom
--    message, so the client gets a generic RLS denial instead of
--    GS_QUOTA_EXCEEDED. Whether that is tolerable is a product call, and 6.3
--    captures the exact string so the call can be made on evidence.
-- ============================================================================

do $$
begin
  begin
    execute 'drop trigger if exists zz_p1_reject_trg on storage.objects';

    execute $pol$
      drop policy if exists "zz_p1_quota_with_check" on storage.objects
    $pol$;
    -- Deliberately hard-coded to a 1 KB ceiling so any real upload trips it.
    execute $pol$
      create policy "zz_p1_quota_with_check" on storage.objects
        for insert to authenticated
        with check (
          bucket_id = 'zz-p1-proto'
          and coalesce((
                select sum((o.metadata->>'size')::bigint)
                  from storage.objects o
                 where o.bucket_id = 'zz-p1-proto'
              ), 0) + coalesce((metadata->>'size')::bigint, 0) <= 1024
        )
    $pol$;
    insert into public.zz_p1_results (step, question, observed)
    values ('6.1', 'Q6a — may a WITH CHECK policy on storage.objects carry an aggregate subquery?',
            'YES — policy created.');
  exception when others then
    insert into public.zz_p1_results (step, question, observed)
    values ('6.1', 'Q6a — may a WITH CHECK policy on storage.objects carry an aggregate subquery?',
            format('NO — sqlstate=%s %s', sqlstate, sqlerrm));
  end;
end;
$$;

-- Exercise it as a real client role. The SQL editor's role bypasses RLS, so
-- switching role is the only way to actually reach the policy (same technique
-- the migrations README uses for user_files).
--
-- Role is switched with set_config(...) inside the block rather than
-- `begin; set local role …; rollback;`. Two reasons, both learned the hard way:
-- the rollback would discard the results rows this script exists to produce,
-- and an explicit BEGIN inside the SQL editor's own implicit transaction is a
-- no-op — so the ROLLBACK would discard the ENTIRE script, not just this block.
-- Switching back before the insert also matters: `anon`/`authenticated` have no
-- grant on zz_p1_results.
do $$
declare
  v_prev  text := current_setting('role', true);
  v_verdict text;
  v_message text;
begin
  perform set_config('role', 'authenticated', true);
  -- Any well-formed uuid: the policy under test keys on bucket_id, not on the
  -- caller, so this only has to survive auth.uid()'s ::uuid cast.
  perform set_config('request.jwt.claims',
    '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}', true);

  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('zz-p1-proto', 'policy-over-quota.geojson',
            jsonb_build_object('size', 999999, 'mimetype', 'application/json'));
    v_verdict := 'NO — the over-quota insert succeeded.';
    v_message := '(not reached — nothing was denied)';
  exception when others then
    v_verdict := format('YES — blocked. sqlstate=%s', sqlstate);
    v_message := sqlerrm;
  end;

  perform set_config('role', coalesce(v_prev, 'none'), true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.zz_p1_results (step, question, observed)
  values ('6.2', 'Q6b — does the WITH CHECK policy block an over-quota insert?', v_verdict);
  insert into public.zz_p1_results (step, question, observed)
  values ('6.3', 'Q6c — what error message does a policy denial produce? (UX cost)', v_message);
end;
$$;

-- ============================================================================
-- 9. Teardown. Leaves the project exactly as found. Safe to run on its own if
--    a section above aborted midway — nothing here depends on earlier state.
--    Run it even if the prototype "failed": an armed rejecting trigger on
--    storage.objects would break every upload on the project.
-- ============================================================================

drop trigger if exists zz_p1_observe_trg on storage.objects;
drop trigger if exists zz_p1_reject_trg  on storage.objects;
drop policy  if exists "zz_p1_quota_with_check" on storage.objects;

drop function if exists public.zz_p1_observe();
drop function if exists public.zz_p1_reject();
-- (the sequence is dropped with the report tables in section 10, not here —
--  4.1 reads it, and teardown may be re-run on its own)

-- FINDING (2026-07-30): Supabase guards these tables with storage.protect_delete(),
-- which raises 42501 "Direct deletion from storage tables is not allowed. Use the
-- Storage API instead." on any SQL DELETE of an object row. Because the SQL editor
-- runs the whole script as ONE transaction, an unguarded delete here doesn't just
-- fail — it rolls back the trigger and policy drops above, leaving the rejecting
-- trigger armed. Hence the guard: the drops must survive regardless.
--
-- >>> DELETE THE BUCKET FROM THE DASHBOARD <<< Storage → zz-p1-proto → Delete
-- bucket. That routes through the Storage API, which is the only thing permitted
-- to remove these rows, and takes the objects with it. Then re-run this section;
-- the statements below become no-ops.
do $$
begin
  begin
    delete from storage.objects where bucket_id = 'zz-p1-proto';
    delete from storage.buckets where id = 'zz-p1-proto';
    insert into public.zz_p1_results (step, question, observed)
    values ('9.0', 'Scratch bucket removed by SQL?', 'YES');
  exception when others then
    insert into public.zz_p1_results (step, question, observed)
    values ('9.0', 'Scratch bucket removed by SQL?',
            format('NO — sqlstate=%s %s  (delete the bucket from the dashboard)',
                   sqlstate, sqlerrm));
  end;
end;
$$;

-- Confirm nothing of ours survives on the shared table.
insert into public.zz_p1_results (step, question, observed)
select '9.1', 'Teardown — anything of ours left on storage.objects?',
       format('triggers=%s | policies=%s | scratch bucket rows=%s',
              (select count(*) from pg_trigger
                where tgrelid = 'storage.objects'::regclass and tgname like 'zz\_p1\_%'),
              (select count(*) from pg_policies
                where schemaname = 'storage' and tablename = 'objects'
                  and policyname like 'zz\_p1\_%'),
              (select count(*) from storage.objects where bucket_id = 'zz-p1-proto'));

-- ============================================================================
-- 10. The report. Paste this output back.
--     The results table, the observer log and the counter are left in place on
--     purpose so the report survives teardown. Once the result is recorded:
--       drop table public.zz_p1_results;
--       drop table public.zz_p1_log;
--       drop sequence public.zz_p1_reject_seq;
-- ============================================================================

select step, question, observed from public.zz_p1_results order by id;
select id, tg_op, object_name, size_seen, metadata from public.zz_p1_log order by id;
