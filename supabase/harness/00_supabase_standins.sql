-- =============================================================================
-- SiteWise SQL harness · stand-ins for the Supabase-managed environment
-- =============================================================================
--
-- This file is NOT a migration. It recreates, in a throwaway database, the parts
-- of a Supabase project that the SiteWise migrations assume already exist:
--
--   * the `anon`, `authenticated` and `service_role` roles;
--   * `auth.uid()`, backed by `request.jwt.claim.sub` exactly as Supabase does;
--   * `storage.buckets`, `storage.objects` and `storage.foldername(text)`;
--   * the table GRANTs Supabase gives those roles.
--
-- Why this exists: the migrations cannot be executed against a plain PostgreSQL
-- instance, so without this harness the row-level policies would ship with
-- verification blocks that nobody had ever run. With it, every policy is
-- exercised by real SQL in `20_policy_tests.sql`.
--
-- FIDELITY NOTES — the places this could mislead, and how they are avoided
--   1. `storage.objects` has RLS ENABLED here, because Supabase enables it.
--      Enabling it is not a test convenience: without it the policies would be
--      inert and "anonymous cannot upload" would pass for the wrong reason.
--   2. `anon` and `authenticated` are GRANTed the same table privileges, so the
--      only difference between them is the policy set. If `anon` had no GRANT,
--      its upload would fail with "permission denied for table objects" — the
--      right outcome for the wrong reason.
--   3. Tables are owned by `postgres`; the tests switch to `authenticated` with
--      `set role`, so RLS applies (a table owner would bypass it). The policies
--      are therefore genuinely evaluated, not bypassed.
--   4. `auth.uid()` reads a session GUC. That is how Supabase implements it, and
--      setting the GUC is equivalent to presenting a JWT — it is not an RLS
--      bypass.
--
-- NOT modelled: PostgREST, the Storage API process, JWT verification, and
-- Supabase's own triggers on `auth.users`. None of them affect the policy logic.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Roles. Supabase creates these; NOLOGIN because nothing logs in as them.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- 2. `auth.uid()`
-- -----------------------------------------------------------------------------
create schema if not exists auth;

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
  )::uuid;
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. `storage` schema
-- -----------------------------------------------------------------------------
create schema if not exists storage;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  owner              uuid,
  public             boolean not null default false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null references storage.buckets (id),
  name       text not null,
  owner      uuid,
  metadata   jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bucket_id, name)
);

-- Supabase enables RLS on storage.objects. Everything below depends on it.
alter table storage.objects enable row level security;

-- Supabase's helper: the path's folder segments, excluding the object name.
-- 'properties/7/sessions/s1/panorama.jpg' -> {properties,7,sessions,s1}
create or replace function storage.foldername(name text)
returns text[]
language sql
immutable
as $$
  select (string_to_array(name, '/'))[1 : greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)];
$$;

grant usage on schema storage to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Public schema privileges
-- -----------------------------------------------------------------------------
grant usage on schema public to anon, authenticated, service_role;
