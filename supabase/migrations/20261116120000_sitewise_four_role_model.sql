-- =============================================================================
-- SiteWise · four-role model
-- =============================================================================
--
-- WHAT THIS CHANGES
--   `public.users.role` accepts exactly: 'admin', 'owner', 'agent',
--   'entrepreneur'.
--
--   Before this migration it accepted three values — 'entrepreneur', 'agent',
--   'admin' — and the FastAPI RBAC layer normalised the legacy spelling
--   `property_owner` onto `entrepreneur`. That mapping is the bug this change
--   exists to remove: Property Owner is now a first-class role with its own
--   property rights, and an owner folded into `entrepreneur` would have no
--   property authority at all.
--
-- WHAT THIS DOES NOT DO
--   * It does not recreate or replace `public.users`.
--   * It does not touch any other column, constraint, index, trigger, policy or
--     foreign key on `public.users`.
--   * It does not convert any account. Existing `entrepreneur` rows stay
--     entrepreneurs, and existing `property_owner`-era accounts are **not**
--     promoted automatically — their ownership records have to be verified
--     first. See the "DATA MIGRATION" section at the bottom.
--
-- WHY THE CONSTRAINT IS DROPPED BY LOOKUP, NOT BY NAME
--   The live constraint's name is not known: it may be `users_role_check`, or
--   something a previous migration named. Dropping a guessed name would either
--   fail or, worse, silently leave the three-value constraint in place while a
--   second, weaker one is added beside it. This block finds every CHECK
--   constraint on `public.users` whose definition mentions both `role` and one
--   of the legacy role values, and replaces only those.
--
-- REVIEW BEFORE EXECUTION
--   This is a proposed migration. Run the INSPECT query below first and confirm
--   the constraint it finds is the role constraint, and nothing else.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- INSPECT (read-only). Run this on its own and read the output before applying.
-- -----------------------------------------------------------------------------
-- SELECT con.conname,
--        pg_get_constraintdef(con.oid) AS definition,
--        con.convalidated
--   FROM pg_constraint con
--   JOIN pg_class rel ON rel.oid = con.conrelid
--   JOIN pg_namespace ns ON ns.oid = rel.relnamespace
--  WHERE ns.nspname = 'public'
--    AND rel.relname = 'users'
--    AND con.contype = 'c'
--  ORDER BY con.conname;
--
-- SELECT column_name, data_type, column_default, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'users'
--  ORDER BY ordinal_position;
--
-- SELECT role, count(*) FROM public.users GROUP BY role ORDER BY role;

begin;

-- -----------------------------------------------------------------------------
-- 1. Replace the role CHECK constraint. Only the role one.
-- -----------------------------------------------------------------------------
do $$
declare
  found_constraint text;
  found_definition text;
  replaced integer := 0;
begin
  for found_constraint, found_definition in
    select con.conname, pg_get_constraintdef(con.oid)
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
     where ns.nspname = 'public'
       and rel.relname = 'users'
       and con.contype = 'c'
       -- A role CHECK always mentions at least one role value. Requiring the
       -- word `role` as well keeps this from matching an unrelated CHECK that
       -- happens to quote a role name in a comment.
       and pg_get_constraintdef(con.oid) ilike '%role%'
       and (
            pg_get_constraintdef(con.oid) ilike '%entrepreneur%'
         or pg_get_constraintdef(con.oid) ilike '%admin%'
         or pg_get_constraintdef(con.oid) ilike '%agent%'
       )
  loop
    raise notice 'Dropping role CHECK constraint: % (%)',
      found_constraint, found_definition;
    execute format('alter table public.users drop constraint %I', found_constraint);
    replaced := replaced + 1;
  end loop;

  if replaced = 0 then
    raise notice
      'No existing role CHECK constraint found. The new one is added below; '
      'if this table previously had no constraint at all, say so in the review.';
  else
    raise notice 'Replaced % role CHECK constraint(s).', replaced;
  end if;
end
$$;

-- Idempotent: a re-run after a partial failure must not fail on the name.
alter table public.users drop constraint if exists users_role_check;

-- NOT VALID + VALIDATE is the standard non-blocking pair. Every existing row is
-- already one of the three old values, all of which remain legal, so validation
-- cannot fail — and if it does, that is a finding worth stopping for.
alter table public.users
  add constraint users_role_check
  check (role in ('admin', 'owner', 'agent', 'entrepreneur')) not valid;

alter table public.users validate constraint users_role_check;

-- -----------------------------------------------------------------------------
-- 2. Ordinary registration keeps the least privileged role.
-- -----------------------------------------------------------------------------
-- Only the DEFAULT is set; no row is rewritten. `entrepreneur` stays the
-- default because a self-registered account has no verified property yet, and
-- the migration must not hand out owner rights at sign-up.
alter table public.users alter column role set default 'entrepreneur';

-- A NULL role would make every authorisation decision ambiguous. This is a
-- separate statement so a legacy NULL is reported clearly rather than surfacing
-- as "cannot add constraint".
update public.users set role = 'entrepreneur' where role is null;

alter table public.users alter column role set not null;

-- -----------------------------------------------------------------------------
-- 3. Verify. These raise if the state is wrong, so the transaction aborts.
-- -----------------------------------------------------------------------------
do $$
declare
  role_constraint text;
  bad_rows bigint;
  total_rows bigint;
  trigger_count integer;
  fk_count integer;
begin
  select pg_get_constraintdef(con.oid) into role_constraint
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
   where ns.nspname = 'public'
     and rel.relname = 'users'
     and con.contype = 'c'
     and con.conname = 'users_role_check';

  if role_constraint is null then
    raise exception 'users_role_check was not created';
  end if;
  if role_constraint not ilike '%owner%' then
    raise exception 'users_role_check does not accept owner: %', role_constraint;
  end if;

  select count(*) into bad_rows
    from public.users
   where role not in ('admin', 'owner', 'agent', 'entrepreneur');
  if bad_rows > 0 then
    raise exception '% row(s) hold a role outside the four-value set', bad_rows;
  end if;

  select count(*) into total_rows from public.users;
  raise notice 'public.users holds % row(s); all within the four roles.', total_rows;

  -- The role-protection and identity-sync triggers must survive: this migration
  -- never drops a trigger, and this check fails loudly if one has gone missing
  -- for an unrelated reason.
  select count(*) into trigger_count
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
   where ns.nspname = 'public' and rel.relname = 'users' and not t.tgisinternal;
  raise notice 'public.users has % non-internal trigger(s) after the change.',
    trigger_count;
  if trigger_count = 0 then
    raise warning
      'public.users has no triggers. If this project relies on a role-change or '
      'account-status trigger, restore it before deploying the API change.';
  end if;

  -- Foreign keys pointing at public.users must be untouched.
  select count(*) into fk_count
    from pg_constraint con
   where con.contype = 'f'
     and con.confrelid = 'public.users'::regclass;
  raise notice '% foreign key(s) still reference public.users.', fk_count;
end
$$;

commit;

-- =============================================================================
-- ROLLBACK
-- =============================================================================
-- There is no way back to a three-value constraint while `owner` rows exist, and
-- that is intentional: rolling back must be a decision, not a re-run.
--
-- 1. Count the damage first:
--
--      SELECT count(*) FROM public.users WHERE role = 'owner';
--
-- 2. If that count is zero, the constraint can be narrowed again:
--
--      ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
--      ALTER TABLE public.users
--        ADD CONSTRAINT users_role_check
--        CHECK (role IN ('entrepreneur', 'agent', 'admin'));
--
-- 3. If it is not zero, the accounts must be reclassified first — and that is a
--    data decision for the project owner, not a migration. Never blanket-update
--    owners to entrepreneurs to make a rollback pass: it silently removes their
--    property rights.
--
-- A runnable copy of the safe path lives in
-- `supabase/rollback/20261116120000_sitewise_four_role_model.down.sql`.

-- =============================================================================
-- DATA MIGRATION — deliberately NOT executed
-- =============================================================================
-- Accounts whose stored role predates the four-role model need human review,
-- because "this account owns property 12" is a fact about the property table,
-- not about the role string. Two cases exist:
--
-- a) Rows that still literally hold 'property_owner'. They are not legal under
--    either constraint, so they must already have been normalised somewhere. If
--    any are found, decide per account:
--
--      SELECT user_id, role FROM public.users WHERE role = 'property_owner';
--
-- b) Rows that hold 'entrepreneur' but are recorded as an owner of a property.
--    These are the accounts the old normalisation mislabelled. Find them, do not
--    guess them:
--
--      SELECT u.user_id, u.role, p.property_id
--        FROM public.users u
--        JOIN public.property p ON p.owner_id = u.user_id
--       WHERE u.role = 'entrepreneur';
--
--    Only after that list has been reviewed and the ownership records confirmed
--    should a targeted update be written. Do not run a blanket UPDATE: some of
--    those accounts may legitimately be entrepreneurs who are also recorded
--    against a property for other reasons.
