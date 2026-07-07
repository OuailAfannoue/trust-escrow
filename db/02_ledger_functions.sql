-- ============================================================================
-- TRUST ESCROW WALLET — Week 1, File 2 of 4
-- 02_ledger_functions.sql : The money engine
--
-- HOW TO RUN: SQL Editor → New query → paste ALL of this → Run.
-- Expected result at the bottom:
--   functions installed        → 8
--   append-only triggers       → 4
--   balanced-transfer guard    → 1
--
-- WHAT THIS FILE GUARANTEES:
--   1. Ledger rows can NEVER be updated, deleted, or truncated. History is
--      permanent. Same for delivery_events (your evidence trail).
--   2. Every transfer MUST sum to zero across its two rows — enforced by the
--      database itself at commit time, even against manual SQL tampering.
--   3. post_transfer() is the ONLY sane way money moves: it locks both
--      accounts (in a deadlock-proof order), checks funds, and writes the
--      pair atomically. Two simultaneous payments of the same dirham → one
--      succeeds, one fails with 'insufficient funds'. No double-spend.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. APPEND-ONLY GUARDS — history cannot be rewritten
-- ---------------------------------------------------------------------------

create or replace function forbid_mutation()
returns trigger language plpgsql as $$
begin
  raise exception 'Table "%" is append-only: % is forbidden', tg_table_name, tg_op;
end $$;

-- ledger: no update, no delete, no truncate
create trigger trg_ledger_no_mutation
  before update or delete on ledger_entries
  for each row execute function forbid_mutation();

create trigger trg_ledger_no_truncate
  before truncate on ledger_entries
  for each statement execute function forbid_mutation();

-- delivery evidence trail: same protection
create trigger trg_events_no_mutation
  before update or delete on delivery_events
  for each row execute function forbid_mutation();

create trigger trg_events_no_truncate
  before truncate on delivery_events
  for each statement execute function forbid_mutation();


-- ---------------------------------------------------------------------------
-- 2. CONSERVATION LAW — every transfer must balance to exactly zero.
--    This is a DEFERRED constraint trigger: it fires at COMMIT, after both
--    rows of a pair are in. A lone, hand-inserted ledger row (someone trying
--    to conjure money out of thin air via raw SQL) kills the whole
--    transaction at commit time.
-- ---------------------------------------------------------------------------

create or replace function assert_transfer_balanced()
returns trigger language plpgsql as $$
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

create constraint trigger trg_transfer_balanced
  after insert on ledger_entries
  deferrable initially deferred
  for each row execute function assert_transfer_balanced();


-- ---------------------------------------------------------------------------
-- 3. BALANCES — always computed from history, never stored
-- ---------------------------------------------------------------------------

create or replace function account_balance(p_account_id uuid)
returns numeric language sql stable as $$
  select coalesce(sum(amount), 0)
  from ledger_entries
  where account_id = p_account_id;
$$;

-- one row per account with its live balance (handy for dashboards & debugging)
create view account_balances
with (security_invoker = on)   -- view respects RLS, no back door
as
select
  a.id,
  a.type,
  a.owner_profile_id,
  a.order_id,
  coalesce(sum(l.amount), 0)::numeric(14,2) as balance
from accounts a
left join ledger_entries l on l.account_id = a.id
group by a.id;


-- ---------------------------------------------------------------------------
-- 4. ACCOUNT HELPERS — find or create a user's money boxes
-- ---------------------------------------------------------------------------

-- creates the two wallet boxes for a user if missing; returns the spendable one
create or replace function ensure_user_accounts(p_profile uuid)
returns uuid language plpgsql as $$
declare
  v_available uuid;
begin
  select id into v_available
  from accounts
  where owner_profile_id = p_profile and type = 'user_available';

  if v_available is null then
    insert into accounts (type, owner_profile_id)
    values ('user_available', p_profile)
    returning id into v_available;
  end if;

  if not exists (
    select 1 from accounts
    where owner_profile_id = p_profile and type = 'user_cashback_pending'
  ) then
    insert into accounts (type, owner_profile_id)
    values ('user_cashback_pending', p_profile);
  end if;

  return v_available;
end $$;

-- strict lookups used by the state machine (fail loudly if missing)
create or replace function wallet_of(p_profile uuid)
returns uuid language plpgsql stable as $$
declare v uuid;
begin
  select id into v from accounts
  where owner_profile_id = p_profile and type = 'user_available';
  if v is null then
    raise exception 'Profile % has no wallet (call ensure_user_accounts first)', p_profile;
  end if;
  return v;
end $$;

create or replace function cashback_account_of(p_profile uuid)
returns uuid language plpgsql stable as $$
declare v uuid;
begin
  select id into v from accounts
  where owner_profile_id = p_profile and type = 'user_cashback_pending';
  if v is null then
    raise exception 'Profile % has no cashback account', p_profile;
  end if;
  return v;
end $$;


-- ---------------------------------------------------------------------------
-- 5. POST_TRANSFER — the ONLY door money walks through.
--    Atomic, locked, overdraft-proof, deadlock-proof.
-- ---------------------------------------------------------------------------

create or replace function post_transfer(
  p_from   uuid,
  p_to     uuid,
  p_amount numeric,
  p_reason text,
  p_order  uuid default null
)
returns uuid language plpgsql as $$
declare
  v_transfer_id  uuid := gen_random_uuid();
  v_amount       numeric := round(p_amount, 2);
  v_from_type    account_type;
  v_from_currency char(3);
  v_to_currency   char(3);
  v_locked       int := 0;
  v_balance      numeric;
  r              record;
begin
  -- sanity checks
  if v_amount is null or v_amount <= 0 then
    raise exception 'Transfer amount must be > 0 (got %)', p_amount;
  end if;
  if p_from = p_to then
    raise exception 'Cannot transfer from an account to itself';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A transfer must carry a reason';
  end if;

  -- lock BOTH accounts, always in the same (id) order → no deadlocks when
  -- two transfers touch the same accounts in opposite directions
  for r in
    select id, type, currency
    from accounts
    where id in (p_from, p_to)
    order by id
    for update
  loop
    v_locked := v_locked + 1;
    if r.id = p_from then
      v_from_type     := r.type;
      v_from_currency := r.currency;
    else
      v_to_currency   := r.currency;
    end if;
  end loop;

  if v_locked <> 2 then
    raise exception 'One or both accounts do not exist (from=%, to=%)', p_from, p_to;
  end if;
  if v_from_currency <> v_to_currency then
    raise exception 'Currency mismatch (% vs %)', v_from_currency, v_to_currency;
  end if;

  -- overdraft check: platform_cash_in represents the outside world and is
  -- allowed to go negative (that's real money entering the system).
  -- Every OTHER account can never spend more than it holds.
  if v_from_type <> 'platform_cash_in' then
    v_balance := account_balance(p_from);
    if v_balance < v_amount then
      raise exception 'Insufficient funds: balance % MAD < % MAD', v_balance, v_amount;
    end if;
  end if;

  -- the double entry: money leaves one box (+enters the other), sum = 0
  insert into ledger_entries (transfer_id, account_id, amount, reason, order_id)
  values
    (v_transfer_id, p_from, -v_amount, p_reason, p_order),
    (v_transfer_id, p_to,    v_amount, p_reason, p_order);

  return v_transfer_id;
end $$;


-- ---------------------------------------------------------------------------
-- 6. TOPUP_WALLET — simulated cash-in for the MVP.
--    (In production this fires only after a real cash-in event from the
--    BaaS partner / Cash Plus agent network. Same function, real trigger.)
-- ---------------------------------------------------------------------------

create or replace function topup_wallet(p_profile uuid, p_amount numeric)
returns uuid language plpgsql as $$
declare
  v_wallet  uuid;
  v_cash_in uuid;
begin
  v_wallet := ensure_user_accounts(p_profile);

  select id into v_cash_in from accounts where type = 'platform_cash_in';

  return post_transfer(v_cash_in, v_wallet, p_amount, 'topup');
end $$;


-- ---------------------------------------------------------------------------
-- 7. VERIFY — expect: 8 functions, 4 append-only triggers, 1 balance guard
-- ---------------------------------------------------------------------------

select 'functions installed' as check_name, count(*)::text as result
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('forbid_mutation','assert_transfer_balanced','account_balance',
                    'ensure_user_accounts','wallet_of','cashback_account_of',
                    'post_transfer','topup_wallet')

union all

select 'append-only triggers', count(*)::text
from pg_trigger
where tgname in ('trg_ledger_no_mutation','trg_ledger_no_truncate',
                 'trg_events_no_mutation','trg_events_no_truncate')

union all

select 'balanced-transfer guard', count(*)::text
from pg_trigger
where tgname = 'trg_transfer_balanced';
