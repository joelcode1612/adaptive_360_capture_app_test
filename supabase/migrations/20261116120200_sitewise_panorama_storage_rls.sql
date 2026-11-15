-- =============================================================================
-- SiteWise · private panorama bucket, row-level security and role protection
-- =============================================================================
--
-- WHAT THIS CREATES
--   1. A PRIVATE Storage bucket, `property-panoramas`.
--   2. `public.sitewise_can_manage_property(bigint)` — the single place that
--      answers "may this account write to this property?".
--   3. `public.sitewise_panorama_property_id(text)` — the path → property id
--      parser the Storage policies use.
--   4. Storage policies on `storage.objects` for that bucket.
--   5. Policies on `public.pano_jobs`.
--   6. A guard trigger that stops anyone who is not an administrator from
--      changing a role.
--
-- WHY ONE FUNCTION
--   Ownership, agent assignment and administration are three different facts in
--   three different tables. Writing them out inside each of the eight policies
--   below would mean eight places to get wrong, and one of them would be. They
--   are expressed once, and every policy calls it.
--
-- ⚠ COLUMN NAMES TO CONFIRM BEFORE RUNNING
--   The function reads three associations whose exact column names must be
--   confirmed against the live schema:
--
--     public.users.user_id            the auth user id
--     public.property.property_id     bigint primary key
--     public.property.owner_id        uuid → auth.users(id)
--     public.agent.property_id        the assignment
--     public.agent.user_id            the assigned account
--
--   Run the REVIEW queries at the bottom. If a name differs, change it in
--   `sitewise_can_manage_property` **only** — nothing else references these
--   columns.
--
-- WHAT THIS DOES NOT DO
--   * It does not insert, update or delete rows in Storage's internal metadata
--     tables. The bucket is created through `storage.buckets`, which is the
--     supported API, and files are written by the Storage API.
--   * It does not modify `public.property` or `public.agent`. No policy is added
--     to them, and no column is changed.
--   * It does not change `public.users` RLS. The role guard is a trigger, added
--     beside whatever protection already exists.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. The private bucket.
-- -----------------------------------------------------------------------------
-- `public = false` is the whole point: a panorama of a commercial interior is
-- not public until SiteWise publishes it, and publishing is a property decision,
-- not a storage one. 50 MiB is generous for a 12 MP × 38 equirectangular render
-- and small enough to refuse an accidental video upload.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'property-panoramas',
  'property-panoramas',
  false,
  52428800,
  array['image/jpeg']
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- -----------------------------------------------------------------------------
-- 2. May this account manage this property?
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER on purpose: the policy has to read `property` and `agent`
-- even when the caller's own RLS would hide them. `set search_path` is mandatory
-- on a definer function, or a caller could shadow `public` with their own schema.
--
-- Returns false for NULL, which is what a legacy `pano_jobs` row with no
-- property association produces — a panorama with no verified property is
-- readable only by its own owner.
create or replace function public.sitewise_can_manage_property(p_property_id bigint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    p_property_id is not null
    and (
      -- Administrators act administratively, which is the relationship the
      -- authorisation matrix calls "Authorized".
      exists (
        select 1 from public.users u
         where u.user_id = auth.uid()
           and u.role = 'admin'
      )
      -- A Property Owner manages the properties recorded against them. The role
      -- alone is not enough: this row is the proof.
      or exists (
        select 1 from public.property p
         where p.property_id = p_property_id
           and p.owner_id = auth.uid()
      )
      -- An Agent manages only properties with a verified assignment row.
      or exists (
        select 1 from public.agent a
         where a.property_id = p_property_id
           and a.user_id = auth.uid()
      )
      -- Entrepreneurs are intentionally absent: the ERD has no explicit
      -- per-property grant table, so there is nothing to verify against, and an
      -- entrepreneur therefore cannot write to a property. If such a table is
      -- added later, it belongs here and nowhere else.
    );
$$;

revoke all on function public.sitewise_can_manage_property(bigint) from public;
grant execute on function public.sitewise_can_manage_property(bigint) to authenticated;

-- -----------------------------------------------------------------------------
-- 3. The path parser.
-- -----------------------------------------------------------------------------
-- `properties/{property_id}/sessions/{session_id}/panorama.jpg`
-- foldername() splits on '/', so element 2 is the property id. The regex guard
-- matters: casting a non-numeric segment raises, and an exception inside a policy
-- surfaces to the client as a 500 rather than a 403.
create or replace function public.sitewise_panorama_property_id(object_name text)
returns bigint
language sql
immutable
as $$
  select case
    when (storage.foldername(object_name))[1] = 'properties'
     and (storage.foldername(object_name))[2] ~ '^[0-9]{1,18}$'
    then ((storage.foldername(object_name))[2])::bigint
    else null
  end;
$$;

revoke all on function public.sitewise_panorama_property_id(text) from public;
grant execute on function public.sitewise_panorama_property_id(text) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Storage policies.
-- -----------------------------------------------------------------------------
-- Every policy is `to authenticated`, so an anonymous caller matches none of
-- them. That is the "anonymous users cannot upload panoramas" guarantee: it is
-- the absence of a policy, not a role check inside one.
drop policy if exists "sitewise panoramas: authorised read" on storage.objects;
create policy "sitewise panoramas: authorised read"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'property-panoramas'
    and public.sitewise_can_manage_property(
      public.sitewise_panorama_property_id(name)
    )
  );

drop policy if exists "sitewise panoramas: authorised upload" on storage.objects;
create policy "sitewise panoramas: authorised upload"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'property-panoramas'
    and public.sitewise_can_manage_property(
      public.sitewise_panorama_property_id(name)
    )
  );

-- `using` and `with check` together: the first decides which existing object may
-- be replaced, the second stops a replace from moving it to another property.
drop policy if exists "sitewise panoramas: authorised replace" on storage.objects;
create policy "sitewise panoramas: authorised replace"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'property-panoramas'
    and public.sitewise_can_manage_property(
      public.sitewise_panorama_property_id(name)
    )
  )
  with check (
    bucket_id = 'property-panoramas'
    and public.sitewise_can_manage_property(
      public.sitewise_panorama_property_id(name)
    )
  );

drop policy if exists "sitewise panoramas: authorised delete" on storage.objects;
create policy "sitewise panoramas: authorised delete"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'property-panoramas'
    and public.sitewise_can_manage_property(
      public.sitewise_panorama_property_id(name)
    )
  );

-- -----------------------------------------------------------------------------
-- 5. `pano_jobs` policies.
-- -----------------------------------------------------------------------------
alter table public.pano_jobs enable row level security;

-- Read: your own jobs, any job for a property you may manage, or any job at all
-- if you are an administrator. An unauthorised account sees nothing — there is
-- no "public panorama" policy here, because publication is a property-level
-- decision made elsewhere.
--
-- The administrator branch is not decoration. Without it, a legacy job whose
-- `property_id` is still NULL falls through `sitewise_can_manage_property(NULL)`
-- — which is false by design — and becomes invisible to the one account that is
-- allowed to delete it (see the delete policy below). That asymmetry was found
-- by executing this policy: an admin could delete a row it could not read. The
-- branch restores "you can see what you are trusted to remove" without widening
-- anything for owners, agents or entrepreneurs.
drop policy if exists "pano_jobs: owner or property manager read" on public.pano_jobs;
create policy "pano_jobs: owner or property manager read"
  on public.pano_jobs for select
  to authenticated
  using (
    owner = auth.uid()
    or public.sitewise_can_manage_property(property_id)
    or exists (
      select 1 from public.users u
       where u.user_id = auth.uid()
         and u.role = 'admin'
    )
  );

-- Write: the owner column must be the caller — this is what makes forging
-- another user's uuid impossible — and the property must be one they may manage.
-- `property_id is not null` is deliberate: an unassociated panorama has no
-- folder it is legitimately allowed to occupy.
drop policy if exists "pano_jobs: owner insert" on public.pano_jobs;
create policy "pano_jobs: owner insert"
  on public.pano_jobs for insert
  to authenticated
  with check (
    owner = auth.uid()
    and property_id is not null
    and public.sitewise_can_manage_property(property_id)
  );

drop policy if exists "pano_jobs: owner update" on public.pano_jobs;
create policy "pano_jobs: owner update"
  on public.pano_jobs for update
  to authenticated
  using (
    owner = auth.uid()
    and property_id is not null
    and public.sitewise_can_manage_property(property_id)
  )
  with check (
    owner = auth.uid()
    and property_id is not null
    and public.sitewise_can_manage_property(property_id)
  );

-- Only an administrator removes a job; an owner who no longer wants the
-- panorama can replace it, but the audit trail of the upload stays.
drop policy if exists "pano_jobs: admin delete" on public.pano_jobs;
create policy "pano_jobs: admin delete"
  on public.pano_jobs for delete
  to authenticated
  using (
    exists (
      select 1 from public.users u
       where u.user_id = auth.uid()
         and u.role = 'admin'
    )
  );

-- -----------------------------------------------------------------------------
-- 6. A user cannot change their own role.
-- -----------------------------------------------------------------------------
-- RLS decides *which rows* an account may update. This trigger decides *which
-- columns*: even an account that may update its own profile row cannot promote
-- itself to owner, agent or admin.
--
-- `auth.uid() is null` means the statement is not running as an end user — the
-- service role, a migration, or a dashboard query. Role provisioning happens
-- there and only there, so that path is allowed through. It is not a bypass a
-- client can reach: the service-role key never ships in the app.
create or replace function public.sitewise_guard_role_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role is not distinct from old.role then
    return new;
  end if;

  if auth.uid() is null then
    return new;
  end if;

  if exists (
    select 1 from public.users u
     where u.user_id = auth.uid()
       and u.role = 'admin'
  ) then
    return new;
  end if;

  raise exception
    'Only an administrator may change a role (attempted % -> %)',
    old.role, new.role
    using errcode = '42501';
end;
$$;

drop trigger if exists sitewise_users_role_guard on public.users;
create trigger sitewise_users_role_guard
  before update of role on public.users
  for each row
  execute function public.sitewise_guard_role_change();

-- -----------------------------------------------------------------------------
-- 7. Verify.
-- -----------------------------------------------------------------------------
do $$
declare
  bucket_is_public boolean;
  storage_policies integer;
  job_policies integer;
begin
  select public into bucket_is_public
    from storage.buckets where id = 'property-panoramas';
  if bucket_is_public is null then
    raise exception 'bucket property-panoramas was not created';
  end if;
  if bucket_is_public then
    raise exception 'bucket property-panoramas is public; panoramas must be private';
  end if;

  select count(*) into storage_policies
    from pg_policies
   where schemaname = 'storage'
     and tablename = 'objects'
     and policyname like 'sitewise panoramas:%';
  if storage_policies < 4 then
    raise exception 'expected 4 storage policies, found %', storage_policies;
  end if;

  select count(*) into job_policies
    from pg_policies
   where schemaname = 'public'
     and tablename = 'pano_jobs'
     and policyname like 'pano_jobs:%';
  if job_policies < 4 then
    raise exception 'expected 4 pano_jobs policies, found %', job_policies;
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgname = 'sitewise_users_role_guard'
  ) then
    raise exception 'role guard trigger was not created';
  end if;

  raise notice
    'Panorama storage secured: private bucket, % storage policies, % job '
    'policies, role guard installed.', storage_policies, job_policies;
end
$$;

commit;

-- =============================================================================
-- REVIEW QUERIES (read-only)
-- =============================================================================
-- The three associations the policy function depends on:
--
-- SELECT table_name, column_name, data_type
--   FROM information_schema.columns
--  WHERE table_schema = 'public'
--    AND table_name IN ('users', 'property', 'agent')
--  ORDER BY table_name, ordinal_position;
--
-- Confirm the bucket is private:
--
-- SELECT id, name, public, file_size_limit, allowed_mime_types
--   FROM storage.buckets WHERE id = 'property-panoramas';
--
-- Confirm the policies:
--
-- SELECT policyname, cmd, roles FROM pg_policies
--  WHERE (schemaname = 'storage' AND tablename = 'objects')
--     OR (schemaname = 'public' AND tablename = 'pano_jobs')
--  ORDER BY schemaname, policyname;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- DROP TRIGGER IF EXISTS sitewise_users_role_guard ON public.users;
-- DROP FUNCTION IF EXISTS public.sitewise_guard_role_change();
--
-- DROP POLICY IF EXISTS "pano_jobs: admin delete" ON public.pano_jobs;
-- DROP POLICY IF EXISTS "pano_jobs: owner update" ON public.pano_jobs;
-- DROP POLICY IF EXISTS "pano_jobs: owner insert" ON public.pano_jobs;
-- DROP POLICY IF EXISTS "pano_jobs: owner or property manager read" ON public.pano_jobs;
--
-- DROP POLICY IF EXISTS "sitewise panoramas: authorised delete" ON storage.objects;
-- DROP POLICY IF EXISTS "sitewise panoramas: authorised replace" ON storage.objects;
-- DROP POLICY IF EXISTS "sitewise panoramas: authorised upload" ON storage.objects;
-- DROP POLICY IF EXISTS "sitewise panoramas: authorised read" ON storage.objects;
--
-- DROP FUNCTION IF EXISTS public.sitewise_panorama_property_id(text);
-- DROP FUNCTION IF EXISTS public.sitewise_can_manage_property(bigint);
--
-- The bucket is left in place: deleting it destroys every stored panorama. If it
-- really must go, empty it through the Storage API first, then
-- `DELETE FROM storage.buckets WHERE id = 'property-panoramas';`.
