-- =============================================================================
-- SiteWise · rollback of the four-role model
-- =============================================================================
--
-- Companion to:
--   supabase/migrations/20261116120000_sitewise_four_role_model.sql
--
-- This file is deliberately NOT a mirror image of the migration. The forward
-- change is safe to apply blind — every existing row already satisfies the new
-- constraint. The reverse change is not: narrowing the constraint back to three
-- values fails the moment a single account holds `owner`, and the tempting fix
-- (update those accounts to `entrepreneur`) silently strips their property
-- authority. That is a data decision, not a schema decision, so this script
-- refuses to make it.
--
-- WHAT THIS SCRIPT DOES
--   1. Counts `owner` rows. If any exist, it raises and aborts the whole
--      transaction — nothing is changed.
--   2. Only when the count is zero, restores the three-value CHECK
--      ('entrepreneur', 'agent', 'admin').
--   3. Verifies the result and reports what it deliberately left alone.
--
-- WHAT THIS SCRIPT DOES NOT DO
--   * It does not rewrite a single row. The forward migration rewrote none
--     either (it only replaced NULL roles, which are reported below), so there
--     is no data to undo.
--   * It does not drop `NOT NULL` on `role`. A NULL role makes every
--     authorisation decision ambiguous, and rolling forward again would have to
--     guess. If it genuinely must be nullable, the statement is at the bottom,
--     commented, with its cost stated.
--   * It does not touch `users_role_check`'s neighbours — no other constraint,
--     index, trigger, policy or foreign key on `public.users` is referenced.
--   * It does not delete anything. Dropping a constraint is not destructive;
--     dropping the table would be, and this never does that.
--
-- WHEN TO RUN THIS
--   Only after deciding that the deployment is being reverted. Reverting the
--   schema without reverting the application leaves the API accepting `owner`
--   while the database rejects it — the API would then fail at INSERT rather
--   than at authorisation, which is a worse failure mode, not a safer one.
--
-- PREREQUISITE INSPECTION (read-only, run first and keep the output)
--   SELECT role, count(*) FROM public.users GROUP BY role ORDER BY role;
--   SELECT user_id, role FROM public.users WHERE role = 'owner';
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. The guard. This is the point of the file.
-- -----------------------------------------------------------------------------
-- `owner` rows cannot be represented under the three-value constraint. Rather
-- than failing halfway through an ALTER, count first and stop with a message
-- that names the accounts and the reason.
do $$
declare
  owner_rows bigint;
  owner_sample text;
begin
  select count(*) into owner_rows from public.users where role = 'owner';

  if owner_rows > 0 then
    -- A few ids make the message actionable without dumping the whole table.
    select string_agg(user_id::text, ', ')
      into owner_sample
      from (select user_id from public.users where role = 'owner' limit 10) s;

    raise exception
      'Refusing to roll back: % account(s) hold the role ''owner'' (e.g. %). '
      'The three-value constraint cannot represent them. Decide per account '
      'first — confirm whether each really owns property via '
      'public.property.owner_id — and only then either (a) keep the four-role '
      'model, or (b) reclassify those accounts in a reviewed data migration and '
      're-run this script. Do not bulk-update owners to entrepreneurs to make '
      'this pass: that removes their property rights without a record.',
      owner_rows, coalesce(owner_sample, 'n/a');
  end if;

  raise notice
    'No ''owner'' rows found; the three-value constraint can be restored safely.';
end
$$;

-- -----------------------------------------------------------------------------
-- 2. Restore the three-value CHECK.
-- -----------------------------------------------------------------------------
-- Drop by name, because step 1 of the forward migration guarantees the name:
-- it always creates `users_role_check` after dropping whatever role CHECK it
-- found. Re-running the forward migration therefore never leaves this name in
-- an unexpected state.
alter table public.users drop constraint if exists users_role_check;

-- NOT VALID + VALIDATE again: the same non-blocking pair the forward migration
-- used. If validation fails here it means a non-owner row holds a value outside
-- the original three — a finding, not a reason to weaken the constraint.
alter table public.users
  add constraint users_role_check
  check (role in ('entrepreneur', 'agent', 'admin')) not valid;

alter table public.users validate constraint users_role_check;

-- -----------------------------------------------------------------------------
-- 3. Verify, and report what was intentionally left as-is.
-- -----------------------------------------------------------------------------
do $$
declare
  role_constraint text;
  owner_rows bigint;
  bad_rows bigint;
  total_rows bigint;
  null_rows bigint;
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
    raise exception 'users_role_check is missing after rollback';
  end if;
  if role_constraint ilike '%owner%' then
    raise exception
      'users_role_check still accepts owner after rollback: %', role_constraint;
  end if;

  select count(*) into owner_rows from public.users where role = 'owner';
  if owner_rows > 0 then
    -- Unreachable given the guard, but checked anyway: a concurrent insert
    -- between the guard and the ALTER would surface here rather than silently.
    raise exception '% account(s) hold ''owner'' but the constraint forbids it',
      owner_rows;
  end if;

  select count(*) into bad_rows
    from public.users
   where role not in ('entrepreneur', 'agent', 'admin');
  if bad_rows > 0 then
    raise exception
      '% row(s) hold a role outside the restored three-value set', bad_rows;
  end if;

  select count(*) into total_rows from public.users;
  select count(*) into null_rows from public.users where role is null;
  raise notice
    'Rollback verified: % row(s) total, all within entrepreneur/agent/admin.',
    total_rows;

  -- Stated explicitly so the next reader does not assume it was overlooked.
  if null_rows = 0 then
    raise notice
      'NOT NULL on public.users.role was left in place (0 NULL rows). This is '
      'intentional: a NULL role has no safe interpretation.';
  else
    raise warning
      '% row(s) have a NULL role. They were not modified by this rollback and '
      'the forward migration would set them to entrepreneur.', null_rows;
  end if;

  raise notice
    'The DEFAULT role remains ''entrepreneur''. The forward migration did not '
    'change it and neither does this rollback.';

  select count(*) into trigger_count
    from pg_trigger t
    join pg_class rel on rel.oid = t.tgrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
   where ns.nspname = 'public' and rel.relname = 'users' and not t.tgisinternal;
  raise notice 'public.users still has % non-internal trigger(s).',
    trigger_count;

  select count(*) into fk_count
    from pg_constraint con
   where con.contype = 'f'
     and con.confrelid = 'public.users'::regclass;
  raise notice '% foreign key(s) still reference public.users.', fk_count;
end
$$;

commit;

-- =============================================================================
-- NOT ROLLED BACK, ON PURPOSE
-- =============================================================================
-- 1. `alter table public.users alter column role set not null;`
--    Reverting it re-permits an ambiguous state that the forward migration had
--    to repair. If it truly must be nullable:
--
--      ALTER TABLE public.users ALTER COLUMN role DROP NOT NULL;
--
--    ...and accept that every authorisation path must then treat NULL as
--    "no role", not as a default.
--
-- 2. The role-change guard trigger `sitewise_users_role_guard`
--    (from 20261116120200_sitewise_panorama_storage_rls.sql) is a separate
--    migration and is not touched here. Reverting the four-role model while
--    that guard stays installed is safe — the guard checks caller identity, not
--    the set of legal role strings. Drop it only if that migration is reverted
--    too.
--
-- 3. Any `pano_jobs.property_id` associations created while the four-role model
--    was live. Those belong to the property link migration and are handled by
--    its own rollback section.
--
-- =============================================================================
-- POST-ROLLBACK APPLICATION CHECK
-- =============================================================================
-- The backend and Flutter role parsers still understand `owner` after this
-- rollback — `AppRole.fromWire` / `normalize_role` map the wire values and
-- `property_owner` → `owner` regardless of the constraint. That is intentional
-- and harmless: the code tolerates a role the database will not store. What
-- must NOT be left running is a UI that offers "Property Owner" as a
-- selectable role while the constraint rejects it. Revert the API/UI role list
-- in the same release, or keep the schema change and roll forward instead.
