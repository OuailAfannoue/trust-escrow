-- ============================================================================
-- TRUST ESCROW WALLET — Week 1, File 1 of 4
-- 01_schema.sql : Core schema (tables, enums, indexes, safety rails)
--
-- HOW TO RUN: Supabase Dashboard → SQL Editor → New query → paste ALL of this
-- file → click "Run". Expected result: a small table at the bottom listing
-- every created table, and "Success. No rows returned" style messages above.
--
-- DESIGN PRINCIPLES BAKED IN HERE:
--   1. No stored balances. Money exists ONLY as append-only ledger entries.
--      A balance is always computed, never edited. (Functions come in file 02.)
--   2. Every order freezes a product_snapshot at checkout — dispute evidence
--      that the seller cannot rewrite afterwards.
--   3. Escrow is a real account per order, so we can prove per-order that
--      every frozen dirham ended up somewhere legitimate.
--   4. RLS is enabled on every table with NO policies yet. Translation: the
--      public API can touch nothing; only the SQL editor / service role can.
--      We write real policies in Week 2 when auth exists.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. ENUMS — the vocabulary of the system
-- ---------------------------------------------------------------------------

create type user_role as enum ('buyer', 'seller', 'courier', 'admin');

create type account_type as enum (
  'user_available',        -- spendable wallet money of one user
  'user_cashback_pending', -- earned cashback not yet unlocked
  'order_escrow',          -- frozen funds of ONE specific order
  'platform_cash_in',      -- the "outside world": top-ups enter from here
  'platform_marketing',    -- funds the 25 MAD cashback
  'platform_revenue'       -- our future fees land here
);

create type order_status as enum (
  'pending_deposit',     -- order created, buyer has not paid yet
  'escrow_locked',       -- buyer paid, money frozen, seller must ship
  'in_transit',          -- seller marked shipped
  'delivered_confirmed', -- buyer accepted → money released to seller
  'delivery_rejected',   -- buyer refused → money refunded to buyer
  'disputed',            -- contested handoff, frozen until resolution
  'cancelled'            -- abandoned before any money moved
);

create type payment_link_status as enum ('active', 'paused', 'expired');

create type dispute_reason as enum (
  'not_as_described', 'damaged', 'wrong_item',
  'counterfeit', 'incomplete', 'other'
);

create type dispute_status as enum (
  'open', 'under_review',
  'resolved_refund_buyer',  -- arbitration → buyer wins
  'resolved_pay_seller',    -- arbitration → seller wins
  'cancelled'
);

create type delivery_event_type as enum (
  'order_created', 'deposit_received', 'marked_shipped',
  'courier_link_sent', 'qr_generated', 'qr_scanned',
  'buyer_confirmed', 'buyer_rejected', 'dispute_opened', 'note'
);

create type event_source as enum (
  'buyer_app', 'seller_dashboard', 'courier_link',
  'carrier_webhook', 'system'
);


-- ---------------------------------------------------------------------------
-- 1. PROFILES — people (buyers, sellers, couriers)
--    Week 1: standalone rows so we can test freely.
--    Week 2: auth_user_id gets wired to Supabase Auth (auth.users).
-- ---------------------------------------------------------------------------

create table profiles (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid unique,                    -- linked to auth.users in Week 2
  role          user_role not null,
  phone_number  text unique,                    -- becomes NOT NULL with real auth
  display_name  text not null check (char_length(display_name) between 2 and 60),
  is_blocked    boolean not null default false, -- fraud kill-switch
  created_at    timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 2. ACCOUNTS — the "boxes" money can sit in
--    Users get wallet boxes, each order gets its own escrow box,
--    and the platform has three system boxes.
-- ---------------------------------------------------------------------------

create table accounts (
  id                uuid primary key default gen_random_uuid(),
  type              account_type not null,
  owner_profile_id  uuid references profiles (id),
  order_id          uuid,             -- FK to orders added below (circular ref)
  currency          char(3) not null default 'MAD',
  created_at        timestamptz not null default now(),

  -- user boxes must have an owner; platform boxes must not
  constraint account_ownership_shape check (
    (type in ('user_available', 'user_cashback_pending')
        and owner_profile_id is not null and order_id is null)
    or
    (type = 'order_escrow'
        and owner_profile_id is null)  -- escrow belongs to the ORDER, to no one person
    or
    (type in ('platform_cash_in', 'platform_marketing', 'platform_revenue')
        and owner_profile_id is null and order_id is null)
  )
);

-- exactly ONE wallet and ONE cashback box per user
create unique index uq_one_wallet_per_user
  on accounts (owner_profile_id, type)
  where type in ('user_available', 'user_cashback_pending');

-- exactly ONE escrow box per order
create unique index uq_one_escrow_per_order
  on accounts (order_id)
  where type = 'order_escrow';

-- exactly ONE of each platform box
create unique index uq_singleton_platform_accounts
  on accounts (type)
  where type in ('platform_cash_in', 'platform_marketing', 'platform_revenue');


-- ---------------------------------------------------------------------------
-- 3. LEDGER — the single source of truth for money. Append-only.
--    A "transfer" = two rows sharing one transfer_id:
--    a negative amount leaving one account, a positive amount entering another.
--    They always sum to zero → money is conserved, it can only MOVE.
--    (The posting function + the no-UPDATE/no-DELETE guard live in file 02.)
-- ---------------------------------------------------------------------------

create table ledger_entries (
  id          bigint generated always as identity primary key,
  transfer_id uuid not null,
  account_id  uuid not null references accounts (id),
  amount      numeric(12,2) not null check (amount <> 0),  -- signed: - out, + in
  reason      text not null,      -- e.g. 'topup', 'escrow_lock', 'escrow_release',
                                  --      'escrow_refund', 'cashback_grant'
  order_id    uuid,               -- FK added below (circular ref)
  created_at  timestamptz not null default now()
);

create index ix_ledger_account  on ledger_entries (account_id);
create index ix_ledger_transfer on ledger_entries (transfer_id);
create index ix_ledger_order    on ledger_entries (order_id);


-- ---------------------------------------------------------------------------
-- 4. PRODUCTS — mandatory detailed listings (your fraud filter + evidence base)
-- ---------------------------------------------------------------------------

create table products (
  id          uuid primary key default gen_random_uuid(),
  seller_id   uuid not null references profiles (id),
  title       text not null check (char_length(title) between 5 and 120),
  description text not null check (char_length(description) >= 20),
  category    text not null,
  condition   text not null default 'new'
              check (condition in ('new', 'like_new', 'used')),
  price_mad   numeric(12,2) not null check (price_mad > 0),
  photos      jsonb not null
              check (jsonb_typeof(photos) = 'array'
                     and jsonb_array_length(photos) >= 2),  -- min 2 photos, mandatory
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index ix_products_seller on products (seller_id);

-- keep updated_at honest
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger trg_products_touch
  before update on products
  for each row execute function touch_updated_at();


-- ---------------------------------------------------------------------------
-- 5. PAYMENT LINKS — one shareable link per product for DM/social selling
-- ---------------------------------------------------------------------------

create table payment_links (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references products (id),
  seller_id   uuid not null references profiles (id),
  slug        text not null unique
              check (slug ~ '^[a-zA-Z0-9_-]{6,24}$'),  -- e.g. 'xR7k2p'
  status      payment_link_status not null default 'active',
  expires_at  timestamptz,
  max_uses    integer check (max_uses is null or max_uses > 0),
  use_count   integer not null default 0 check (use_count >= 0),
  created_at  timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 6. ORDERS — the escrow state machine lives on this row
--    product_snapshot = the FROZEN copy of the listing at checkout time.
-- ---------------------------------------------------------------------------

create table orders (
  id                uuid primary key default gen_random_uuid(),
  product_id        uuid not null references products (id),
  payment_link_id   uuid references payment_links (id),
  buyer_id          uuid not null references profiles (id),
  seller_id         uuid not null references profiles (id),
  amount_product    numeric(12,2) not null check (amount_product > 0),
  amount_shipping   numeric(12,2) not null default 0 check (amount_shipping >= 0),
  cashback_mad      numeric(12,2) not null default 25 check (cashback_mad >= 0),
  status            order_status not null default 'pending_deposit',
  product_snapshot  jsonb not null,   -- immutable evidence: title, desc, price, photos
  escrow_account_id uuid references accounts (id),
  courier_phone     text,
  created_at        timestamptz not null default now(),
  deposited_at      timestamptz,
  shipped_at        timestamptz,
  resolved_at       timestamptz,

  constraint buyer_is_not_seller check (buyer_id <> seller_id)
);

create index ix_orders_buyer  on orders (buyer_id);
create index ix_orders_seller on orders (seller_id);
create index ix_orders_status on orders (status);

-- now close the circular references declared earlier
alter table accounts
  add constraint fk_accounts_order
  foreign key (order_id) references orders (id);

alter table ledger_entries
  add constraint fk_ledger_order
  foreign key (order_id) references orders (id);


-- ---------------------------------------------------------------------------
-- 7. DELIVERY EVENTS — append-only trail of the physical journey.
--    Anything can feed it (seller click, courier magic link, later: carrier
--    webhooks) and everything feeds the SAME table → integrations plug in
--    without schema changes.
-- ---------------------------------------------------------------------------

create table delivery_events (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references orders (id),
  event_type  delivery_event_type not null,
  source      event_source not null,
  payload     jsonb not null default '{}',   -- gps, timestamps, courier phone, etc.
  created_at  timestamptz not null default now()
);

create index ix_delivery_events_order on delivery_events (order_id);


-- ---------------------------------------------------------------------------
-- 8. DISPUTES — contested handoffs, with buyer evidence frozen too
-- ---------------------------------------------------------------------------

create table disputes (
  id               uuid primary key default gen_random_uuid(),
  order_id         uuid not null references orders (id),
  opened_by        uuid not null references profiles (id),
  reason           dispute_reason not null,
  description      text not null check (char_length(description) >= 10),
  evidence         jsonb not null default '[]',  -- photo paths captured at handoff
  status           dispute_status not null default 'open',
  resolution_notes text,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz
);

-- only one LIVE dispute per order at a time
create unique index uq_one_open_dispute_per_order
  on disputes (order_id)
  where status in ('open', 'under_review');


-- ---------------------------------------------------------------------------
-- 9. SEED the three platform accounts (money's entry point, cashback fund, fees)
-- ---------------------------------------------------------------------------

insert into accounts (type) values
  ('platform_cash_in'),
  ('platform_marketing'),
  ('platform_revenue');


-- ---------------------------------------------------------------------------
-- 10. LOCK THE FRONT DOOR — RLS on, zero policies = public API sees nothing.
--     (The SQL editor and server-side code bypass RLS, so Week 1 tests still
--     run fine. Real per-user policies arrive in Week 2 with auth.)
-- ---------------------------------------------------------------------------

alter table profiles        enable row level security;
alter table accounts        enable row level security;
alter table ledger_entries  enable row level security;
alter table products        enable row level security;
alter table payment_links   enable row level security;
alter table orders          enable row level security;
alter table delivery_events enable row level security;
alter table disputes        enable row level security;


-- ---------------------------------------------------------------------------
-- 11. VERIFY — you should see 8 tables and 3 platform accounts below
-- ---------------------------------------------------------------------------

select 'tables created' as check_name,
       count(*)::text   as result
from information_schema.tables
where table_schema = 'public'
  and table_name in ('profiles','accounts','ledger_entries','products',
                     'payment_links','orders','delivery_events','disputes')

union all

select 'platform accounts seeded',
       count(*)::text
from accounts
where type in ('platform_cash_in','platform_marketing','platform_revenue');
