-- =============================================================================
-- SiteWise SQL harness · executed assertions for the three migrations
-- =============================================================================
--
-- Run AFTER 00_supabase_standins.sql, 10_legacy_state.sql and the three
-- migrations, against a throwaway database. Every case runs real SQL under the
-- real role (`set role authenticated`, `anon`, or `postgres`) so the policies
-- are evaluated, never bypassed.
--
-- Results land in `harness.results`; the runner prints them and fails the build
-- if any row has ok = false. A case that was expected to fail is only counted as
-- passing when it fails with the *specific* SQLSTATE being claimed:
--
--   42501  insufficient_privilege — an RLS policy refused the row, or the
--                                  role-change guard raised
--   23514  check_violation       — a CHECK constraint refused the value
--   23503  foreign_key_violation
--   23505  unique_violation
--
-- That distinction matters: "the insert failed" is not evidence of security.
-- =============================================================================

create schema if not exists harness;

create table if not exists harness.results (
  name   text not null,
  ok     boolean not null,
  detail text,
  at     timestamptz not null default now()
);

truncate harness.results;

-- -----------------------------------------------------------------------------
-- Assertion helpers. SECURITY INVOKER on purpose: they must execute the SQL as
-- the role under test, so the policies apply.
-- -----------------------------------------------------------------------------
create or replace function harness.check(p_name text, p_ok boolean, p_detail text default null)
returns void
language plpgsql
as $$
begin
  insert into harness.results (name, ok, detail) values (p_name, p_ok, p_detail);
end;
$$;

-- Did the statement succeed?
create or replace function harness.expect_ok(p_name text, p_sql text)
returns void
language plpgsql
as $$
declare
  st text;
  msg text;
begin
  begin
    execute p_sql;
    perform harness.check(p_name, true, null);
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform harness.check(p_name, false, format('unexpected %s: %s', st, msg));
  end;
end;
$$;

-- Did the statement fail with exactly this SQLSTATE?
create or replace function harness.expect_error(p_name text, p_sql text, p_state text)
returns void
language plpgsql
as $$
declare
  st text;
  msg text;
begin
  begin
    execute p_sql;
    perform harness.check(p_name, false,
      format('statement succeeded; expected SQLSTATE %s', p_state));
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform harness.check(p_name, st = p_state, format('SQLSTATE %s: %s', st, msg));
  end;
end;
$$;

-- Does the query return exactly this many rows?
create or replace function harness.expect_count(p_name text, p_sql text, p_expected bigint)
returns void
language plpgsql
as $$
declare
  n bigint;
  st text;
  msg text;
begin
  begin
    execute format('select count(*) from (%s) q', p_sql) into n;
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform harness.check(p_name, false, format('query failed %s: %s', st, msg));
    return;
  end;
  perform harness.check(p_name, n = p_expected,
    format('expected %s row(s), got %s', p_expected, n));
end;
$$;

-- Did the statement affect exactly this many rows? (RLS hides rows rather than
-- erroring on UPDATE/DELETE, so the row count is the evidence.)
create or replace function harness.expect_affected(p_name text, p_sql text, p_expected bigint)
returns void
language plpgsql
as $$
declare
  n bigint;
  st text;
  msg text;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform harness.check(p_name, false, format('statement failed %s: %s', st, msg));
    return;
  end;
  perform harness.check(p_name, n = p_expected,
    format('expected %s row(s) affected, got %s', p_expected, n));
end;
$$;

-- Does the query return this scalar value (compared as text)?
create or replace function harness.expect_value(p_name text, p_sql text, p_expected text)
returns void
language plpgsql
as $$
declare
  v text;
  st text;
  msg text;
begin
  begin
    execute format('select (%s)::text', p_sql) into v;
  exception when others then
    get stacked diagnostics st = returned_sqlstate, msg = message_text;
    perform harness.check(p_name, false, format('query failed %s: %s', st, msg));
    return;
  end;
  perform harness.check(p_name, v is not distinct from p_expected,
    format('expected %L, got %L', p_expected, v));
end;
$$;

grant usage on schema harness to anon, authenticated, service_role;
grant select, insert on harness.results to anon, authenticated, service_role;

-- =============================================================================
-- SETUP — needs a role the legacy CHECK could not have held
-- =============================================================================
-- An account with the `owner` role that owns no property. §7 of the brief says a
-- role alone never grants access; this account is how that is proven rather than
-- asserted.
insert into public.users (user_id, email, full_name, role)
values ('00000000-0000-0000-0000-000000000009',
        'owner_none@sitewise.test', 'Owner Without Property', 'owner')
on conflict (user_id) do nothing;

-- =============================================================================
-- 1. SCHEMA SHAPE — did the migrations produce what they claim?
-- =============================================================================
select harness.expect_value('migration1: role CHECK accepts owner',
  $$select exists (
      select 1 from pg_constraint
       where conname = 'users_role_check'
         and pg_get_constraintdef(oid) ilike '%owner%'
    )$$, 'true');

select harness.expect_value('migration1: role CHECK rejects property_owner',
  $$select exists (
      select 1 from pg_constraint
       where conname = 'users_role_check'
         and pg_get_constraintdef(oid) not ilike '%property_owner%'
    )$$, 'true');

select harness.expect_value('migration1: exactly one role CHECK remains',
  $$select count(*) from pg_constraint
     where conrelid = 'public.users'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%entrepreneur%'$$, '1');

select harness.expect_value('migration1: NULL role repaired to entrepreneur',
  $$select role from public.users
     where user_id = '00000000-0000-0000-0000-000000000008'$$, 'entrepreneur');

select harness.expect_value('migration1: role column is NOT NULL',
  $$select is_nullable = 'NO' from information_schema.columns
     where table_schema = 'public' and table_name = 'users' and column_name = 'role'$$,
  'true');

select harness.expect_value('migration1: default role is entrepreneur',
  $$select column_default like '%entrepreneur%' from information_schema.columns
     where table_schema = 'public' and table_name = 'users' and column_name = 'role'$$,
  'true');

-- The migration must not have promoted the mislabelled owners. They stay
-- entrepreneurs until a human reviews their ownership records.
select harness.expect_count('migration1: existing entrepreneurs were not promoted',
  $$select 1 from public.users
     where user_id in ('00000000-0000-0000-0000-000000000002',
                       '00000000-0000-0000-0000-000000000003')
       and role = 'entrepreneur'$$, 2);

select harness.expect_value('migration1: the pre-existing trigger survived',
  $$select count(*) from pg_trigger
     where tgrelid = 'public.users'::regclass
       and tgname = 'users_touch_updated_at'$$, '1');

select harness.expect_value('migration1: the inbound foreign key survived',
  $$select count(*) from pg_constraint
     where contype = 'f' and confrelid = 'public.users'::regclass$$, '4');

select harness.expect_value('migration1: the status CHECK was not disturbed',
  $$select exists (
      select 1 from pg_constraint
       where conname = 'users_status_check'
         and pg_get_constraintdef(oid) ilike '%suspended%'
    )$$, 'true');

select harness.expect_value('migration2: pano_jobs.property_id is bigint',
  $$select data_type from information_schema.columns
     where table_schema = 'public' and table_name = 'pano_jobs'
       and column_name = 'property_id'$$, 'bigint');

select harness.expect_value('migration2: property_id is nullable (legacy rows stay NULL)',
  $$select is_nullable from information_schema.columns
     where table_schema = 'public' and table_name = 'pano_jobs'
       and column_name = 'property_id'$$, 'YES');

select harness.expect_value('migration2: FK to property uses ON DELETE SET NULL',
  $$select pg_get_constraintdef(oid) from pg_constraint
     where conname = 'pano_jobs_property_id_fkey'$$,
  'FOREIGN KEY (property_id) REFERENCES property(property_id) ON DELETE SET NULL');

select harness.expect_value('migration2: legacy job kept a NULL property_id',
  $$select property_id is null from public.pano_jobs where id = 'pano_legacy_1'$$,
  'true');

select harness.expect_value('migration2: legacy device path was not re-validated',
  $$select panorama_path like '/%' from public.pano_jobs where id = 'pano_legacy_1'$$,
  'true');

-- The four documented job states are accepted...
select harness.expect_value('migration2: status CHECK allows the four job states',
  $$select (pg_get_constraintdef(oid) ilike '%queued%'
        and pg_get_constraintdef(oid) ilike '%processing%'
        and pg_get_constraintdef(oid) ilike '%done%'
        and pg_get_constraintdef(oid) ilike '%error%')
     from pg_constraint where conname = 'pano_jobs_status_check'$$, 'true');

-- ...and none of the device-only sync states were smuggled into the cloud column.
select harness.expect_value('migration2: device sync states were not added to pano_jobs',
  $$select (pg_get_constraintdef(oid) not ilike '%pending%'
        and pg_get_constraintdef(oid) not ilike '%uploading%'
        and pg_get_constraintdef(oid) not ilike '%blocked%')
     from pg_constraint where conname = 'pano_jobs_status_check'$$, 'true');

select harness.expect_value('migration2: session_id is indexed',
  $$select count(*) from pg_indexes
     where schemaname = 'public' and tablename = 'pano_jobs'
       and indexname = 'ix_pano_jobs_session_id'$$, '1');

select harness.expect_value('migration3: bucket exists and is private',
  $$select not public from storage.buckets where id = 'property-panoramas'$$, 'true');

select harness.expect_value('migration3: bucket limits mime types to image/jpeg',
  $$select allowed_mime_types::text from storage.buckets
     where id = 'property-panoramas'$$, '{image/jpeg}');

select harness.expect_value('migration3: bucket has a 50 MiB size limit',
  $$select file_size_limit from storage.buckets where id = 'property-panoramas'$$,
  '52428800');

select harness.expect_value('migration3: four storage policies installed',
  $$select count(*) from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'sitewise panoramas:%'$$, '4');

select harness.expect_value('migration3: no storage policy targets anon',
  $$select count(*) from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname like 'sitewise panoramas:%'
       and 'anon' = any (roles)$$, '0');

select harness.expect_value('migration3: four pano_jobs policies installed',
  $$select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'pano_jobs'$$, '4');

select harness.expect_value('migration3: pano_jobs has RLS enabled',
  $$select relrowsecurity from pg_class where oid = 'public.pano_jobs'::regclass$$,
  'true');

select harness.expect_value('migration3: the role guard trigger is installed',
  $$select count(*) from pg_trigger where tgname = 'sitewise_users_role_guard'$$,
  '1');

-- =============================================================================
-- 2. PATH PARSER — a policy must never raise on a hostile path
-- =============================================================================
select harness.expect_value('parser: standard path yields the property id',
  $$select public.sitewise_panorama_property_id(
      'properties/7/sessions/s1/panorama.jpg')$$, '7');

select harness.expect_value('parser: extra segments still yield the property id',
  $$select public.sitewise_panorama_property_id(
      'properties/12/sessions/s1/extra/panorama.jpg')$$, '12');

select harness.expect_value('parser: non-numeric segment yields NULL, not an exception',
  $$select public.sitewise_panorama_property_id(
      'properties/abc/sessions/s1/panorama.jpg')$$, null);

select harness.expect_value('parser: wrong prefix yields NULL',
  $$select public.sitewise_panorama_property_id(
      'not-properties/7/sessions/s1/panorama.jpg')$$, null);

select harness.expect_value('parser: a bare filename yields NULL',
  $$select public.sitewise_panorama_property_id('panorama.jpg')$$, null);

select harness.expect_value('parser: an empty path yields NULL',
  $$select public.sitewise_panorama_property_id('')$$, null);

select harness.expect_value('parser: an injection-shaped segment yields NULL',
  $$select public.sitewise_panorama_property_id(
      'properties/7; drop table public.users/sessions/s1/panorama.jpg')$$, null);

-- =============================================================================
-- 3. "MAY THIS ACCOUNT MANAGE THIS PROPERTY?"
-- =============================================================================
-- As the owner of property 7 (seeded as `entrepreneur`, owning property 7).
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
set role authenticated;

select harness.expect_value('manage: a recorded owner may manage their own property',
  $$select public.sitewise_can_manage_property(7)$$, 'true');
select harness.expect_value('manage: a recorded owner may not manage another property',
  $$select public.sitewise_can_manage_property(9)$$, 'false');
select harness.expect_value('manage: a nonexistent property is refused',
  $$select public.sitewise_can_manage_property(999)$$, 'false');
select harness.expect_value('manage: a NULL property is refused',
  $$select public.sitewise_can_manage_property(null)$$, 'false');

-- As the account holding the `owner` ROLE but no property row.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000009', false);

select harness.expect_value('manage: the owner role alone grants nothing (property 7)',
  $$select public.sitewise_can_manage_property(7)$$, 'false');
select harness.expect_value('manage: the owner role alone grants nothing (property 12)',
  $$select public.sitewise_can_manage_property(12)$$, 'false');

-- As the agent assigned to property 8.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);

select harness.expect_value('manage: an assigned agent may manage the assigned property',
  $$select public.sitewise_can_manage_property(8)$$, 'true');
select harness.expect_value('manage: an agent may not manage an unassigned property',
  $$select public.sitewise_can_manage_property(7)$$, 'false');

-- As an entrepreneur.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', false);

select harness.expect_value('manage: an entrepreneur may not manage any property',
  $$select public.sitewise_can_manage_property(7)$$, 'false');
select harness.expect_value('manage: an entrepreneur may not manage property 8 either',
  $$select public.sitewise_can_manage_property(8)$$, 'false');

-- As the administrator.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);

select harness.expect_value('manage: an administrator may manage any property',
  $$select public.sitewise_can_manage_property(9)$$, 'true');
select harness.expect_value('manage: an administrator may manage property 12',
  $$select public.sitewise_can_manage_property(12)$$, 'true');

reset role;

-- =============================================================================
-- 4. STORAGE POLICIES
-- =============================================================================
-- 4a. Anonymous. `anon` holds the same table GRANTs as `authenticated`, so the
--     only thing standing between it and the bucket is the policy set.
set role anon;
select set_config('request.jwt.claim.sub', '', false);

select harness.expect_error('storage: anonymous cannot upload a panorama',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/7/sessions/anon-try/panorama.jpg')$$,
  '42501');

select harness.expect_count('storage: anonymous reads nothing',
  $$select 1 from storage.objects where bucket_id = 'property-panoramas'$$, 0);

reset role;

-- 4b. The owner of property 7.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
set role authenticated;

select harness.expect_ok('storage: an owner uploads into their own property folder',
  $$insert into storage.objects (bucket_id, name, metadata)
    values ('property-panoramas', 'properties/7/sessions/t-owner-upload/panorama.jpg',
            '{"mimetype":"image/jpeg"}'::jsonb)$$);

-- A second object, so the owner's own delete is proven against a real row.
select harness.expect_ok('storage: an owner uploads a second panorama',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/7/sessions/t-owner-delete/panorama.jpg')$$);

select harness.expect_error('storage: an owner cannot upload into another owner''s folder',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/9/sessions/t-cross/panorama.jpg')$$,
  '42501');

select harness.expect_error('storage: an owner cannot upload into a different bucket',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas-private', 'properties/7/sessions/t-bucket/panorama.jpg')$$,
  '42501');

select harness.expect_error('storage: a non-numeric property folder is refused',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/abc/sessions/t-bad/panorama.jpg')$$,
  '42501');

select harness.expect_count('storage: an owner reads their own property folder',
  $$select 1 from storage.objects
     where bucket_id = 'property-panoramas'
       and name = 'properties/7/sessions/t-owner-upload/panorama.jpg'$$, 1);

select harness.expect_count('storage: an owner reads nothing in another owner''s folder',
  $$select 1 from storage.objects
     where bucket_id = 'property-panoramas'
       and name like 'properties/9/%'$$, 0);

select harness.expect_affected('storage: an owner may replace their own object',
  $$update storage.objects
       set metadata = '{"mimetype":"image/jpeg","replaced":true}'::jsonb
     where bucket_id = 'property-panoramas'
       and name = 'properties/7/sessions/t-owner-upload/panorama.jpg'$$, 1);

select harness.expect_affected('storage: an owner may delete their own object',
  $$delete from storage.objects
     where bucket_id = 'property-panoramas'
       and name = 'properties/7/sessions/t-owner-delete/panorama.jpg'$$, 1);

reset role;

-- 4c. Anonymous, against an object that really exists.
--     A DELETE policy filters rows instead of raising, so "anonymous cannot
--     delete" is proven by the row count, not by an error. Deleting a path that
--     never existed would pass this case while proving nothing — which is how
--     this assertion was caught being vacuous the first time it ran.
set role anon;
select set_config('request.jwt.claim.sub', '', false);

select harness.expect_affected('storage: anonymous cannot delete an existing panorama',
  $$delete from storage.objects
     where bucket_id = 'property-panoramas'
       and name = 'properties/7/sessions/t-owner-upload/panorama.jpg'$$, 0);

reset role;

-- 4d. The object survived that attempt.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
set role authenticated;

select harness.expect_count('storage: the panorama survived the anonymous delete',
  $$select 1 from storage.objects
     where bucket_id = 'property-panoramas'
       and name = 'properties/7/sessions/t-owner-upload/panorama.jpg'$$, 1);

reset role;

-- 4e. The agent assigned to property 8.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
set role authenticated;

select harness.expect_ok('storage: an assigned agent uploads to the assigned property',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/8/sessions/t-agent-upload/panorama.jpg')$$);

select harness.expect_error('storage: an agent cannot upload to an unassigned property',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/7/sessions/t-agent-cross/panorama.jpg')$$,
  '42501');

reset role;

-- 4f. The entrepreneur. Explicitly authorised is the only route, and no grant
--     table exists, so nothing is authorised.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', false);
set role authenticated;

select harness.expect_error('storage: an entrepreneur cannot upload anywhere',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/7/sessions/t-entrep/panorama.jpg')$$,
  '42501');

select harness.expect_count('storage: an entrepreneur reads no panoramas',
  $$select 1 from storage.objects where bucket_id = 'property-panoramas'$$, 0);

reset role;

-- 4g. The administrator.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;

select harness.expect_count('storage: an administrator reads any property folder',
  $$select 1 from storage.objects
     where bucket_id = 'property-panoramas'
       and name = 'properties/7/sessions/t-owner-upload/panorama.jpg'$$, 1);

select harness.expect_ok('storage: an administrator uploads to any property folder',
  $$insert into storage.objects (bucket_id, name)
    values ('property-panoramas', 'properties/12/sessions/t-admin/panorama.jpg')$$);

reset role;

-- =============================================================================
-- 5. pano_jobs POLICIES
-- =============================================================================
-- 5a. The owner of property 7 writes its own job.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', false);
set role authenticated;

select harness.expect_ok('jobs: an owner inserts a job for their own property',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id, panorama_path)
    values ('pano_owner_1', 't-owner-job',
            '00000000-0000-0000-0000-000000000002', 'queued', 7,
            'properties/7/sessions/t-owner-job/panorama.jpg')$$);

select harness.expect_error('jobs: an owner cannot forge another account''s uuid',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id)
    values ('pano_forged', 't-forged',
            '00000000-0000-0000-0000-000000000003', 'queued', 7)$$,
  '42501');

select harness.expect_error('jobs: an owner cannot attach a job to another property',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id)
    values ('pano_cross', 't-cross',
            '00000000-0000-0000-0000-000000000002', 'queued', 9)$$,
  '42501');

select harness.expect_error('jobs: an owner cannot insert a job with no property',
  $$insert into public.pano_jobs (id, session_id, owner, status)
    values ('pano_unlinked', 't-unlinked',
            '00000000-0000-0000-0000-000000000002', 'queued')$$,
  '42501');

select harness.expect_error('jobs: a device path is rejected by the path CHECK',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id, panorama_path)
    values ('pano_device_path', 't-device',
            '00000000-0000-0000-0000-000000000002', 'done', 7,
            '/data/user/0/com.example/files/ar_capture/s1/panorama.jpg')$$,
  '23514');

select harness.expect_count('jobs: an owner reads their own job',
  $$select 1 from public.pano_jobs where session_id = 't-owner-job'$$, 1);

select harness.expect_count('jobs: an owner reads their legacy unassociated job',
  $$select 1 from public.pano_jobs where id = 'pano_legacy_1'$$, 1);

select harness.expect_count('jobs: an owner cannot read another account''s job',
  $$select 1 from public.pano_jobs where session_id = 't-agent-job'$$, 0);

select harness.expect_affected('jobs: an owner updates their own job status',
  $$update public.pano_jobs
       set status = 'processing', updated_at = now()
     where session_id = 't-owner-job'$$, 1);

select harness.expect_affected('jobs: an owner cannot update another account''s job',
  $$update public.pano_jobs set status = 'error' where session_id = 't-agent-job'$$, 0);

select harness.expect_affected('jobs: an owner cannot delete their own job',
  $$delete from public.pano_jobs where session_id = 't-owner-job'$$, 0);

reset role;

-- 5b. The agent assigned to property 8.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', false);
set role authenticated;

select harness.expect_ok('jobs: an assigned agent inserts a job for the assigned property',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id)
    values ('pano_agent_1', 't-agent-job',
            '00000000-0000-0000-0000-000000000004', 'queued', 8)$$);

select harness.expect_count('jobs: an assigned agent reads the assigned property''s job',
  $$select 1 from public.pano_jobs where session_id = 't-agent-job'$$, 1);

select harness.expect_count('jobs: an agent cannot read an unassigned property''s job',
  $$select 1 from public.pano_jobs where session_id = 't-owner-job'$$, 0);

reset role;

-- 5c. The entrepreneur.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000005', false);
set role authenticated;

select harness.expect_error('jobs: an entrepreneur cannot insert a job',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id)
    values ('pano_entrep', 't-entrep',
            '00000000-0000-0000-0000-000000000005', 'queued', 7)$$,
  '42501');

select harness.expect_count('jobs: an entrepreneur reads no jobs at all',
  $$select 1 from public.pano_jobs$$, 0);

reset role;

-- 5d. The administrator.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;

select harness.expect_ok('jobs: an administrator inserts for any property',
  $$insert into public.pano_jobs (id, session_id, owner, status, property_id)
    values ('pano_admin_1', 't-admin-job',
            '00000000-0000-0000-0000-000000000001', 'queued', 9)$$);

select harness.expect_count('jobs: an administrator reads a legacy unassociated job',
  $$select 1 from public.pano_jobs where id = 'pano_legacy_1'$$, 1);

select harness.expect_affected('jobs: an administrator deletes any job',
  $$delete from public.pano_jobs where session_id = 't-agent-job'$$, 1);

reset role;

-- =============================================================================
-- 6. A USER CANNOT CHANGE A ROLE
-- =============================================================================
-- 6a. A plain authenticated account tries to promote itself.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000007', false);
set role authenticated;

select harness.expect_error('role: a user cannot promote themselves to admin',
  $$update public.users set role = 'admin'
     where user_id = '00000000-0000-0000-0000-000000000007'$$,
  '42501');

select harness.expect_error('role: a user cannot promote themselves to owner',
  $$update public.users set role = 'owner'
     where user_id = '00000000-0000-0000-0000-000000000007'$$,
  '42501');

select harness.expect_error('role: a user cannot change another account''s role',
  $$update public.users set role = 'admin'
     where user_id = '00000000-0000-0000-0000-000000000006'$$,
  '42501');

-- The guard must only block the role column, not ordinary profile edits.
select harness.expect_affected('role: a user may still edit their own profile',
  $$update public.users set full_name = 'Promoted By Nobody'
     where user_id = '00000000-0000-0000-0000-000000000007'$$, 1);

select harness.expect_value('role: the refused promotion left the role unchanged',
  $$select role from public.users
     where user_id = '00000000-0000-0000-0000-000000000007'$$, 'entrepreneur');

reset role;

-- 6b. An administrator may change a role.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
set role authenticated;

select harness.expect_affected('role: an administrator may promote an account',
  $$update public.users set role = 'agent'
     where user_id = '00000000-0000-0000-0000-000000000007'$$, 1);

select harness.expect_error('role: an administrator cannot set an unknown role',
  $$update public.users set role = 'superadmin'
     where user_id = '00000000-0000-0000-0000-000000000007'$$,
  '23514');

reset role;

-- 6c. The service path (no end-user identity) may provision roles. This is how
--     account creation works, and it is unreachable from the client because the
--     service-role key never ships in the app.
select set_config('request.jwt.claim.sub', '', false);

select harness.expect_affected('role: the service path may provision a role',
  $$update public.users set role = 'owner'
     where user_id = '00000000-0000-0000-0000-000000000007'$$, 1);

select harness.expect_value('role: the service-path change took effect',
  $$select role from public.users
     where user_id = '00000000-0000-0000-0000-000000000007'$$, 'owner');

-- =============================================================================
-- 7. THE FOUR-VALUE ROLE CONSTRAINT
-- =============================================================================
select harness.expect_ok('roles: admin is storable',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a1', 'r-admin@sitewise.test', 'admin')$$);

select harness.expect_ok('roles: owner is storable',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a2', 'r-owner@sitewise.test', 'owner')$$);

select harness.expect_ok('roles: agent is storable',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a3', 'r-agent@sitewise.test', 'agent')$$);

select harness.expect_ok('roles: entrepreneur is storable',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a4', 'r-entrep@sitewise.test', 'entrepreneur')$$);

select harness.expect_error('roles: property_owner is not a storable value',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a5', 'r-po@sitewise.test', 'property_owner')$$,
  '23514');

select harness.expect_error('roles: an unknown role is rejected',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a6', 'r-x@sitewise.test', 'superadmin')$$,
  '23514');

select harness.expect_error('roles: an empty role is rejected',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a7', 'r-empty@sitewise.test', '')$$,
  '23514');

select harness.expect_error('roles: a NULL role is rejected',
  $$insert into public.users (user_id, email, role)
    values ('00000000-0000-0000-0000-0000000000a8', 'r-null@sitewise.test', null)$$,
  '23502');

-- Registration must land on the least privileged role.
insert into public.users (user_id, email) values
  ('00000000-0000-0000-0000-0000000000a9', 'r-default@sitewise.test');

select harness.expect_value('roles: a self-registered account defaults to entrepreneur',
  $$select role from public.users
     where user_id = '00000000-0000-0000-0000-0000000000a9'$$, 'entrepreneur');

-- =============================================================================
-- SUMMARY
-- =============================================================================
select
  count(*) filter (where ok)      as passed,
  count(*) filter (where not ok)  as failed,
  count(*)                        as total
from harness.results;

select name, detail from harness.results where not ok order by at;
