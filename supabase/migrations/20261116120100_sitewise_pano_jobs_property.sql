-- =============================================================================
-- SiteWise · link `public.pano_jobs` to `public.property`
-- =============================================================================
--
-- WHY
--   `pano_jobs` records a panorama job but not *which property* the panorama
--   belongs to. Without that link the app can upload a file but SiteWise cannot
--   answer "show me this building's panorama", and — worse — there is nothing
--   for a row-level policy to check, so any authenticated account could attach a
--   panorama to any job id.
--
-- WHAT
--   One additive column, one foreign key, one index. No new panorama table: the
--   ERD's `pano_jobs` already models the job, the status, the frames and the
--   object path. Adding a second table would mean two sources of truth for one
--   upload.
--
-- SAFETY
--   * `property_id` is NULLABLE. Legacy rows keep NULL and are **not** assigned
--     to an arbitrary property — a wrong association is worse than a missing
--     one, because it publishes one owner's room under another owner's building.
--   * `ON DELETE SET NULL`: deleting a property must not delete the record of a
--     panorama that was captured for it.
--   * `NOT VALID` on the path CHECK: it constrains every new row without
--     re-validating history that may predate the convention.
--
-- REVIEW BEFORE EXECUTION
--   Confirm `public.property`'s key really is `property_id bigint`, and confirm
--   the existing `pano_jobs` columns. Both queries are at the bottom.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. The column. `bigint`, matching `public.property.property_id` — not a uuid,
--    and not the FYP research-data identifier that happens to share the name.
-- -----------------------------------------------------------------------------
alter table public.pano_jobs
  add column if not exists property_id bigint;

-- -----------------------------------------------------------------------------
-- 2. The foreign key, added only if it is not already there.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'pano_jobs_property_id_fkey'
       and conrelid = 'public.pano_jobs'::regclass
  ) then
    alter table public.pano_jobs
      add constraint pano_jobs_property_id_fkey
      foreign key (property_id)
      references public.property (property_id)
      on delete set null;
  end if;
end
$$;

create index if not exists ix_pano_jobs_property_id
  on public.pano_jobs (property_id);

-- The job list for one session is the upload path's own lookup.
create index if not exists ix_pano_jobs_session_id
  on public.pano_jobs (session_id);

-- -----------------------------------------------------------------------------
-- 3. `panorama_path` must be a Storage object path, never a device path.
-- -----------------------------------------------------------------------------
-- A Storage path is relative: `properties/12/sessions/…/panorama.jpg`. An
-- absolute path (`/data/user/0/…`, `C:\…`) is a phone's private layout and is
-- meaningless — and misleading — in a cloud column. NOT VALID so that history is
-- not re-checked, but every new write is constrained.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'pano_jobs_panorama_path_not_device_path'
       and conrelid = 'public.pano_jobs'::regclass
  ) then
    alter table public.pano_jobs
      add constraint pano_jobs_panorama_path_not_device_path
      check (
        panorama_path is null
        or (
          panorama_path not like '/%'
          and panorama_path not like '%\\%'
          and panorama_path not like '%:%'
        )
      ) not valid;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 4. The status CHECK is preserved exactly as it was.
-- -----------------------------------------------------------------------------
-- The app's offline states (`pending`, `uploading`, `failed`, `blocked`) live in
-- local SQLite. They are deliberately **not** added here: `pano_jobs.status`
-- describes the job, not the device's network. This block only reports what the
-- live constraint is, so a reviewer can confirm it still allows the four values
-- and nothing else has crept in.
do $$
declare
  status_definition text;
begin
  select pg_get_constraintdef(con.oid) into status_definition
    from pg_constraint con
   where con.conrelid = 'public.pano_jobs'::regclass
     and con.contype = 'c'
     and pg_get_constraintdef(con.oid) ilike '%queued%'
   limit 1;

  if status_definition is null then
    raise notice
      'No status CHECK found on public.pano_jobs. The app only ever writes '
      'queued/processing/done/error; if the column is unconstrained, add the '
      'four-value CHECK rather than leaving it open.';
  elsif status_definition not ilike '%processing%'
     or status_definition not ilike '%done%'
     or status_definition not ilike '%error%' then
    raise exception
      'public.pano_jobs.status CHECK does not allow the documented four values: %',
      status_definition;
  else
    raise notice 'pano_jobs.status CHECK preserved: %', status_definition;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 5. Verify.
-- -----------------------------------------------------------------------------
do $$
declare
  column_type text;
  legacy_without_property bigint;
begin
  select data_type into column_type
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'pano_jobs'
     and column_name = 'property_id';

  if column_type is null then
    raise exception 'pano_jobs.property_id was not created';
  end if;
  if column_type <> 'bigint' then
    raise exception 'pano_jobs.property_id is %, expected bigint', column_type;
  end if;

  -- Legacy jobs must be left alone, not silently associated.
  select count(*) into legacy_without_property
    from public.pano_jobs
   where property_id is null;
  raise notice
    '% existing pano_jobs row(s) have no property association. They are '
    'intentionally untouched: backfill them from verified ownership records, '
    'never by guessing.', legacy_without_property;
end
$$;

commit;

-- =============================================================================
-- REVIEW QUERIES (read-only)
-- =============================================================================
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'pano_jobs'
--  ORDER BY ordinal_position;
--
-- SELECT column_name, data_type
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'property'
--  ORDER BY ordinal_position;
--
-- SELECT conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid = 'public.pano_jobs'::regclass;
--
-- SELECT count(*), status FROM public.pano_jobs GROUP BY status;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- ALTER TABLE public.pano_jobs DROP CONSTRAINT IF EXISTS pano_jobs_panorama_path_not_device_path;
-- DROP INDEX IF EXISTS public.ix_pano_jobs_session_id;
-- DROP INDEX IF EXISTS public.ix_pano_jobs_property_id;
-- ALTER TABLE public.pano_jobs DROP CONSTRAINT IF EXISTS pano_jobs_property_id_fkey;
-- ALTER TABLE public.pano_jobs DROP COLUMN IF EXISTS property_id;
--
-- Dropping the column discards which property each panorama belonged to. Export
-- `SELECT id, property_id FROM public.pano_jobs WHERE property_id IS NOT NULL`
-- first.
