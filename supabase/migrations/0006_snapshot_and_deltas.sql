-- 0006_snapshot_and_deltas.sql
-- Cloud epic — Phase 7b-2: a file becomes a SNAPSHOT plus DELTAS (ADR-037).
--   * the private `user-files` Storage bucket — where the SNAPSHOT lives.
--   * owner-only RLS on storage.objects, keyed on the {user_id}/ path prefix.
--   * public.file_edits — the bounded per-feature change buffer (the DELTAS).
--   * user_files.snapshot_seq — the watermark reads and checkpoints pivot on.
--   * public.user_storage_usage reworked to measure Storage bytes, not jsonb.
--
-- Apply to the NON-PROD Supabase project via the SQL Editor (see ./README.md),
-- AFTER 0001-0005. Idempotent: safe to re-run.
--
-- Design: docs/02-decisions.md ADR-037 (a file is a snapshot plus every delta
-- recorded after it — neither half is the file on its own) and ADR-035 (the
-- diagnosis that put the blob in Storage: a 43 MB jsonb payload OOMs PostgREST
-- and takes the whole project down). ADR-002 is RESTORED in full — writes are
-- client-direct under RLS again; the signed-upload-URL mint designed under
-- ADR-035 is withdrawn, because nothing needs checking before a write any more.
--
-- THE MODEL, in one paragraph, because every object below only makes sense
-- against it: the whole FeatureCollection is one Storage object, written RARELY
-- at checkpoints. Every edit writes a small row to file_edits instead — one row
-- per feature TOUCHED, deduplicated by (file_id, feature_id). Reading a file is
-- snapshot -> deltas above user_files.snapshot_seq -> apply by feature id. A
-- checkpoint is not a merge: the client already holds the finished document, so
-- it uploads what it is holding, advances the watermark, and deletes the deltas
-- that snapshot incorporated. NOTHING SERVER-SIDE EVER MATERIALISES THE
-- DOCUMENT — that is what stops ADR-035's crash returning by another route.
--
-- Two things are deliberately NOT here, and their absence is the design:
--   * No quota trigger on storage.objects. ADR-037's rule is "the save that
--     crosses the limit is allowed; subsequent GROWTH is blocked; shrinking is
--     always allowed", so quota is never evaluated before a write. What remains
--     is the bucket's file_size_limit (edge-enforced, below), enforce_file_count
--     on user_files (0005, untouched), and a client-side gate on the next
--     growth-causing action. Prototype P1 showed a trigger here is *possible*
--     but wins on none of its three risks (opaque 500s, an overwrite arriving as
--     INSERT-then-UPDATE, undetermined orphaned bytes) — see ../prototypes.
--   * No server-side folding of deltas into the snapshot. That would need some
--     process to download, parse and re-upload 50 MB, which is exactly the
--     failure ADR-035 exists to remove.
--
-- 0005's enforce_storage_quota on user_files.geojson is left in place on
-- purpose: the Postgres blob path survives as commented dead code until 7b-3, so
-- both paths keep an enforced quota during the overlap. It becomes a no-op the
-- moment nothing writes that column, and is dropped with it.

-- ============================================================================
-- 1. The `user-files` bucket — where the snapshot object lives.
--    Created in SQL rather than the dashboard so this file stays the source of
--    truth for the schema (ADR-009) and the production project can be brought up
--    by replaying these migrations in order.
--
--    PRIVATE (public = false). Owner access comes from the RLS policies in
--    section 2; there is no unauthenticated read path. Publish / share-as-URL
--    (7d, ADR-034) is designed as a `security definer` cross-table lookup
--    granting `anon` read on published rows only — ONE bucket, not two, which is
--    what prototype P2 settled. It is not built here.
--
--    file_size_limit is the per-file guardrail's SERVER-SIDE home: 50000000,
--    DECIMAL 50 MB, uniform across tiers and environments (ADR-032 addendum).
--    Decimal, not 52428800: Supabase's free plan caps uploads at 50 MB globally
--    and a bucket's limit must sit at or below the project's. The client's
--    MAX_FILE_SIZE_FOR_FILE_IMPORT is aligned to the same number, so the cap the
--    user is warned about and the cap the edge enforces are ONE number.
-- ============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'user-files',
  'user-files',
  false,
  50000000,
  -- The uploader supplies the content type, so this list is a sanity filter, not
  -- a security control — an attacker-influenced MIME must never be trusted on
  -- the way back out (ADR-033 addendum). The public serving path, when it is
  -- built, FORCES the content type and `nosniff` rather than echoing this.
  array['application/geo+json', 'application/json', 'text/plain']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ============================================================================
-- 2. Owner-only RLS on storage.objects — THE SECOND SECURITY SURFACE.
--    Same shape as the table policies in 0001, but keyed on the object's PATH
--    PREFIX instead of a column: objects are named `{user_id}/{file_id}.geojson`,
--    so the first path segment IS the ownership claim. This belongs in the
--    two-account isolation test alongside the tables (ADR-035).
--
--    storage.objects has RLS enabled and its grants managed by Supabase; we add
--    policies only. `anon` gets no policy at all, which under deny-by-default is
--    how it is locked out — there is nothing to revoke.
--
--    The policies are scoped to this bucket by name, so no other bucket on the
--    project is affected by them.
-- ============================================================================
drop policy if exists "user_files_objects_select_own" on storage.objects;
create policy "user_files_objects_select_own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'user-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "user_files_objects_insert_own" on storage.objects;
create policy "user_files_objects_insert_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'user-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- A checkpoint overwrites the snapshot in place, and prototype P1 found the
-- Storage API serves an overwrite as INSERT-then-UPDATE on a row that keeps its
-- id — so the UPDATE policy is on the hot path, not an edge case.
drop policy if exists "user_files_objects_update_own" on storage.objects;
create policy "user_files_objects_update_own" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'user-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'user-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "user_files_objects_delete_own" on storage.objects;
create policy "user_files_objects_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'user-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- NOTE, and it is a compliance obligation rather than a nicety: `on delete
-- cascade` CANNOT reach Storage, and storage.protect_delete() rejects a direct
-- SQL DELETE on storage.objects with 42501 (prototype P1). So no SQL mechanism
-- can clean up a deleted user's objects. The `{user_id}/` prefix sweep on
-- POST /api/v1/account/delete, via the Storage API, is the ONLY home for it.

-- ============================================================================
-- 3. user_files.snapshot_seq — the watermark.
--    The highest file_edits.seq the CURRENT snapshot object already contains.
--    Reads fetch deltas above it. Checkpoints advance it, and only AFTER the
--    object upload has landed — that ordering is what stops a checkpoint
--    claiming edits it never uploaded.
--    0 means "the snapshot predates every delta", which is also the correct
--    reading for a brand-new file with no object yet (an empty document).
-- ============================================================================
alter table public.user_files add column if not exists snapshot_seq bigint not null default 0;

-- ============================================================================
-- 4. public.file_edits — THE CHANGE BUFFER.
--    Named for what a row IS to the user (an edit they made) rather than for its
--    role in the model, where it is a DELTA — the two words mean the same thing
--    throughout this file, the design docs and the client.
--
--    Bounded, and emptied at every checkpoint: it is NOT a mirror of the file
--    and never grows to the size of one. Deliberately not `file_features` (one
--    permanent row per feature) — that model fixes writes by creating a read
--    problem, pushing 200k rows through PostgREST on every open, which is the
--    same materialisation that crashed the project in the first place.
--
--    DELTAS ARE ASSIGNMENTS, NEVER INSTRUCTIONS. "Feature X is now this" /
--    "feature X is gone" — never "move feature X three metres north". Load-
--    bearing, not stylistic: it makes replay idempotent (a half-failed
--    checkpoint that leaves incorporated deltas behind is harmless), makes
--    ordering per-feature rather than global, and lets the buffer deduplicate by
--    feature id — so it grows with features TOUCHED, not edits MADE. Twenty
--    vertex drags on one boundary is one row.
-- ============================================================================
create table if not exists public.file_edits (
  seq         bigserial   primary key,   -- global, monotonic: the ordering + watermark key
  file_id     uuid        not null
                          references public.user_files (id) on delete cascade,
  user_id     uuid        not null default auth.uid()
                          references auth.users (id) on delete cascade,
  -- TEXT, not uuid, and this is a correctness requirement rather than laziness:
  -- app-created ids are uuidv4, gl-draw's fallback is a 32-char nanoid, and a
  -- user-supplied id from an imported file is preserved verbatim and can be
  -- anything at all (ADR-037). A uuid column would reject real documents.
  feature_id  text        not null,
  op          text        not null check (op in ('upsert', 'delete')),
  -- The whole new feature for 'upsert'; null for 'delete'.
  feature     jsonb,
  created_at  timestamptz not null default now()
);

-- The dedup key. Twenty edits to one feature collapse to one row.
create unique index if not exists file_edits_file_feature_uq
  on public.file_edits (file_id, feature_id);

-- The read path: "every delta for this file above the snapshot's watermark".
create index if not exists file_edits_file_seq_idx
  on public.file_edits (file_id, seq);

-- ---------------------------------------------------------------------------
-- 4a. The seq bump — the single most subtle object in this file.
--
-- The dedup upsert MUST BUMP seq, never preserve it. That is what makes a
-- checkpoint's delete-by-exact-seq safe with no special case: if another session
-- has re-edited a feature this one knew as seq 11, that row now carries a new
-- seq, the checkpoint's DELETE ... WHERE seq IN (its own set) does not match it,
-- and their work survives automatically. The conservative behaviour falls out of
-- the design rather than being coded for.
--
-- It lives in a trigger rather than in the statement because the client upserts
-- through PostgREST, which builds its own `on conflict do update set ...` from
-- the columns it was given and cannot be made to call nextval(). A BEFORE UPDATE
-- trigger gets the same result from any writer, which is the safer place for an
-- invariant this load-bearing anyway.
--
-- Why "deltas it actually incorporated" and not "everything up to now": two
-- devices open at watermark 10, B writes 11-12, A writes 13, A checkpoints with
-- a document that never contained B's edits — and `seq <= 13` would destroy B's
-- work in both places, silently. The delete predicate is a SET of seqs captured
-- when the client SERIALISES the document (not when the upload finishes, so
-- edits made during the upload survive). See ADR-037's addendum; the client half
-- of this rule lives in the seam, and the two halves only work together.
-- ---------------------------------------------------------------------------
create or replace function public.bump_file_edit_seq()
returns trigger
language plpgsql
security invoker
as $$
begin
  new.seq := nextval(pg_get_serial_sequence('public.file_edits', 'seq'));
  return new;
end;
$$;

drop trigger if exists file_edits_bump_seq on public.file_edits;
create trigger file_edits_bump_seq
  before update on public.file_edits
  for each row execute function public.bump_file_edit_seq();

-- ---------------------------------------------------------------------------
-- 4b. RLS — owner-only, mirroring user_files exactly (0001).
--     user_id is denormalised onto this table purely so the policy is a column
--     comparison rather than a join back to user_files on every delta write.
-- ---------------------------------------------------------------------------
alter table public.file_edits enable row level security;

revoke all on public.file_edits from anon;
grant select, insert, update, delete on public.file_edits to authenticated;
-- bigserial owns a sequence, and a PostgREST insert that omits `seq` needs usage
-- on it. Explicit rather than relying on inherited defaults — 0005 learned that
-- lesson the hard way with service_role (42501 "permission denied").
revoke all on sequence public.file_edits_seq_seq from anon;
grant usage, select on sequence public.file_edits_seq_seq to authenticated;

drop policy if exists "file_edits_select_own" on public.file_edits;
create policy "file_edits_select_own" on public.file_edits
  for select to authenticated using (auth.uid() = user_id);

drop policy if exists "file_edits_insert_own" on public.file_edits;
create policy "file_edits_insert_own" on public.file_edits
  for insert to authenticated with check (auth.uid() = user_id);

drop policy if exists "file_edits_update_own" on public.file_edits;
create policy "file_edits_update_own" on public.file_edits
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "file_edits_delete_own" on public.file_edits;
create policy "file_edits_delete_own" on public.file_edits
  for delete to authenticated using (auth.uid() = user_id);

-- ============================================================================
-- 5. public.user_storage_usage — reworked for Storage (replaces 0003's version).
--
--    Bytes now come from storage.objects.metadata->>'size', which is the ONLY
--    authoritative byte count: a client-written size column would be spoofable
--    by request replay (ADR-033). file_count still comes from user_files.
--
--    THE FIGURE LAGS. It measures the SNAPSHOT, so between checkpoints it
--    under-reports the live document and jumps when one lands. Acceptable under
--    ADR-037's growth rule — nothing is refused mid-edit — and it is the reason
--    the account page's usage bar is UX rather than a gate.
--
--    security_invoker again, so both halves are RLS-scoped to the caller: the
--    user_files policies from 0001 and the storage.objects policies from section
--    2 above. No policy on the view itself is needed or possible.
--
--    A full outer join, not an inner one, because the two halves legitimately
--    disagree in both directions: a file created but never checkpointed has a
--    row and no object, and an object whose row was deleted is an orphan worth
--    keeping visible rather than hiding.
-- ============================================================================
create or replace view public.user_storage_usage
with (security_invoker = on) as
with files as (
  select user_id, count(*)::int as file_count
  from public.user_files
  group by user_id
),
objects as (
  select
    ((storage.foldername(name))[1])::uuid                 as user_id,
    coalesce(sum((metadata->>'size')::bigint), 0)::bigint as bytes
  from storage.objects
  where bucket_id = 'user-files'
    -- The regex guard is LOAD-BEARING, not defensive noise: prototype P2 found a
    -- malformed object name is filtered rather than raised only if you filter
    -- it, and an exception raised while evaluating this view would break the
    -- usage read for everyone. A ::uuid cast on an arbitrary path segment is
    -- exactly the kind of thing that raises.
    and (storage.foldername(name))[1] ~
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  group by 1
)
select
  coalesce(f.user_id, o.user_id) as user_id,
  coalesce(f.file_count, 0)      as file_count,
  coalesce(o.bytes, 0)           as bytes
from files f
full outer join objects o on o.user_id = f.user_id;

revoke all on public.user_storage_usage from anon;
grant select on public.user_storage_usage to authenticated;
