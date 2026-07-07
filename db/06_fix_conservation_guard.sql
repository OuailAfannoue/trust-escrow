-- ============================================================================
-- TRUST ESCROW WALLET — Week 2, File 6 (hotfix)
-- 06_fix_conservation_guard.sql
--
-- BUG: the balanced-transfer guard ran with the CALLER's permissions. Through
-- the app, the caller is the `authenticated` role, whose RLS view of the
-- ledger only includes rows touching their own accounts — so the guard saw
-- half of every legitimate pair and cried fraud on real transfers.
--
-- FIX: make the guard SECURITY DEFINER — the auditor always checks the books
-- with full vision, no matter who triggered the audit. Same logic, same
-- strictness; thin-air attacks still die exactly as in test 19.
--
-- HOW TO RUN: paste all → Run. Expected result:
--   guard has full vision → true
-- ============================================================================

create or replace function assert_transfer_balanced()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_sum numeric;
begin
  select coalesce(sum(amount), 0) into v_sum
  from ledger_entries
  where transfer_id = new.transfer_id;

  if v_sum <> 0 then
    raise exception
      'Unbalanced transfer % (sum = %). Money cannot be created or destroyed.',
      new.transfer_id, v_sum;
  end if;
  return null;
end $$;

-- verify: prosecdef = true means the function now runs as its owner
select 'guard has full vision' as check_name,
       p.prosecdef::text      as result
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'assert_transfer_balanced';
