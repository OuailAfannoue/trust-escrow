-- ============================================================================
-- TRUST ESCROW WALLET — Week 2, File 5
-- 05_auth_and_rls.sql : Auth wiring + Row Level Security + safe RPC layer
--
-- HOW TO RUN: SQL Editor → New query → paste ALL of this → Run.
-- Expected result at the bottom:
--   rls policies            → 13
--   auth + rpc functions    → 12
--   signup trigger          → 1
--   public_profiles view    → 1
--
-- WHAT THIS FILE DOES:
--   1. SIGNUP AUTOMATION: when someone signs up via Supabase Auth, a trigger
--      instantly creates their profile + wallet boxes. No orphan users.
--   2. RLS POLICIES: opens exactly the right doors — you see YOUR profile,
--      YOUR accounts, YOUR ledger lines, YOUR orders (as buyer or seller),
--      and active products. Nothing else. Nobody else's money, ever.
--   3. RPC WRAPPERS: the app never calls the engine directly. It calls thin
--      rpc_* functions that derive WHO IS ACTING from the login session
--      (auth.uid()), so the client physically cannot lie about identity.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. WHO AM I? — helpers used by policies and wrappers
--    (security definer = they run as the database owner, so they can read
--     profiles without tripping RLS recursion)
-- ---------------------------------------------------------------------------

create or replace function current_profile_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select id from profiles where auth_user_id = auth.uid();
$$;

create or replace function current_profile_role()
returns user_role
language sql stable security definer set search_path = public
as $$
  select role from profiles where auth_user_id = auth.uid();
$$;


-- ---------------------------------------------------------------------------
-- 2. SIGNUP AUTOMATION — auth.users → profiles + wallet boxes, atomically
--    Reads display_name and role from the signup metadata the app sends.
-- ---------------------------------------------------------------------------

create or replace function handle_new_auth_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_profile uuid;
  v_role    user_role;
begin
  v_role := case
              when new.raw_user_meta_data->>'role' in ('buyer','seller','courier')
              then (new.raw_user_meta_data->>'role')::user_role
              else 'buyer'
            end;

  insert into profiles (auth_user_id, role, display_name, phone_number)
  values (
    new.id,
    v_role,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), 'New User'), 60),
    new.phone
  )
  on conflict (auth_user_id) do nothing
  returning id into v_profile;

  if v_profile is null then
    select id into v_profile from profiles where auth_user_id = new.id;
  end if;

  perform ensure_user_accounts(v_profile);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();


-- ---------------------------------------------------------------------------
-- 3. RLS POLICIES — exactly 13 doors, each as narrow as possible
-- ---------------------------------------------------------------------------

-- profiles: see yourself, edit ONLY your display_name
create policy "profiles_select_own" on profiles
  for select to authenticated
  using (auth_user_id = auth.uid());

create policy "profiles_update_own" on profiles
  for update to authenticated
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- column-level lock: even on your own row, you can ONLY change display_name
-- (blocks self-promotion to seller, self-unblocking, wallet tampering)
revoke update on profiles from authenticated, anon;
grant  update (display_name) on profiles to authenticated;

-- accounts: see your own money boxes, never anyone else's
create policy "accounts_select_own" on accounts
  for select to authenticated
  using (owner_profile_id = current_profile_id());

-- ledger: see the lines that touch YOUR accounts (your transaction history)
create policy "ledger_select_own" on ledger_entries
  for select to authenticated
  using (account_id in
          (select id from accounts where owner_profile_id = current_profile_id()));

-- products: browse active listings; sellers also see their own inactive ones
create policy "products_select_active_or_own" on products
  for select to authenticated
  using (is_active or seller_id = current_profile_id());

create policy "products_insert_own_seller" on products
  for insert to authenticated
  with check (seller_id = current_profile_id()
              and current_profile_role() = 'seller');

create policy "products_update_own" on products
  for update to authenticated
  using (seller_id = current_profile_id())
  with check (seller_id = current_profile_id());

-- payment links: sellers manage their own; buyers use them via RPC only
create policy "links_select_own" on payment_links
  for select to authenticated
  using (seller_id = current_profile_id());

create policy "links_insert_own_seller" on payment_links
  for insert to authenticated
  with check (seller_id = current_profile_id()
              and current_profile_role() = 'seller'
              and exists (select 1 from products p
                          where p.id = product_id
                            and p.seller_id = current_profile_id()));

create policy "links_update_own" on payment_links
  for update to authenticated
  using (seller_id = current_profile_id())
  with check (seller_id = current_profile_id());

-- orders: visible to their two parties, writable by NOBODY (RPCs only)
create policy "orders_select_parties" on orders
  for select to authenticated
  using (buyer_id = current_profile_id() or seller_id = current_profile_id());

-- delivery events: the story of an order, visible to its two parties
create policy "events_select_parties" on delivery_events
  for select to authenticated
  using (exists (select 1 from orders o
                 where o.id = order_id
                   and (o.buyer_id = current_profile_id()
                        or o.seller_id = current_profile_id())));

-- disputes: visible to the order's parties (opening/resolving comes in Week 3)
create policy "disputes_select_parties" on disputes
  for select to authenticated
  using (exists (select 1 from orders o
                 where o.id = order_id
                   and (o.buyer_id = current_profile_id()
                        or o.seller_id = current_profile_id())));


-- ---------------------------------------------------------------------------
-- 4. PUBLIC PROFILE CARD — safe columns only (name + role), for showing
--    "Sold by Samir" without ever exposing phone numbers.
-- ---------------------------------------------------------------------------

create or replace view public_profiles as
  select id, display_name, role, created_at from profiles;

grant select on public_profiles to authenticated, anon;


-- ---------------------------------------------------------------------------
-- 5. THE RPC LAYER — what the app actually calls.
--    Every wrapper: derives the actor from the session, then delegates to the
--    hostile-tested engine. security definer = runs as owner, so the engine's
--    revoked permissions and RLS stay sealed to direct callers.
-- ---------------------------------------------------------------------------

-- simulated top-up (MVP only; a BaaS partner webhook replaces this later)
create or replace function rpc_topup(p_amount numeric)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000 then
    raise exception 'Top-up must be between 1 and 10000 MAD';
  end if;
  return topup_wallet(v_actor, p_amount);
end $$;

-- my wallet, one call: available + pending cashback
create or replace function rpc_my_wallet()
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  perform ensure_user_accounts(v_actor);
  return jsonb_build_object(
    'profile_id',           v_actor,
    'available_mad',        account_balance(wallet_of(v_actor)),
    'cashback_pending_mad', account_balance(cashback_account_of(v_actor))
  );
end $$;

-- preview a payment link before committing (safe fields only)
create or replace function rpc_get_link_preview(p_slug text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v jsonb;
begin
  select jsonb_build_object(
           'slug',   l.slug,
           'status', l.status,
           'usable', (l.status = 'active'
                      and (l.expires_at is null or l.expires_at > now())
                      and (l.max_uses is null or l.use_count < l.max_uses)
                      and p.is_active),
           'product', jsonb_build_object(
             'title', p.title, 'description', p.description,
             'category', p.category, 'condition', p.condition,
             'price_mad', p.price_mad, 'photos', p.photos),
           'seller', jsonb_build_object(
             'id', s.id, 'display_name', s.display_name))
  into v
  from payment_links l
  join products p on p.id = l.product_id
  join profiles s on s.id = l.seller_id
  where l.slug = p_slug;

  if v is null then raise exception 'Payment link "%" not found', p_slug; end if;
  return v;
end $$;

-- the six state-machine wrappers: actor is ALWAYS the logged-in user
create or replace function rpc_create_order(p_slug text, p_shipping numeric default 35)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  return create_order_from_link(v_actor, p_slug, p_shipping);
end $$;

create or replace function rpc_deposit(p_order uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  perform deposit_to_escrow(p_order, v_actor);
end $$;

create or replace function rpc_mark_shipped(p_order uuid, p_courier_phone text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  perform mark_shipped(p_order, v_actor, p_courier_phone);
end $$;

create or replace function rpc_confirm_delivery(p_order uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  perform confirm_delivery(p_order, v_actor);
end $$;

create or replace function rpc_reject_delivery(p_order uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  perform reject_delivery(p_order, v_actor, p_note);
end $$;

create or replace function rpc_cancel_order(p_order uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_actor uuid := current_profile_id();
begin
  if v_actor is null then raise exception 'Not authenticated'; end if;
  perform cancel_order(p_order, v_actor);
end $$;


-- ---------------------------------------------------------------------------
-- 6. DOOR PERMISSIONS — logged-in users may knock on the RPCs; anonymous
--    visitors may only preview payment links (for the public link pages).
-- ---------------------------------------------------------------------------

revoke execute on function rpc_topup(numeric)                        from public, anon;
revoke execute on function rpc_my_wallet()                           from public, anon;
revoke execute on function rpc_create_order(text, numeric)           from public, anon;
revoke execute on function rpc_deposit(uuid)                         from public, anon;
revoke execute on function rpc_mark_shipped(uuid, text)              from public, anon;
revoke execute on function rpc_confirm_delivery(uuid)                from public, anon;
revoke execute on function rpc_reject_delivery(uuid, text)           from public, anon;
revoke execute on function rpc_cancel_order(uuid)                    from public, anon;

grant execute on function rpc_topup(numeric)                         to authenticated;
grant execute on function rpc_my_wallet()                            to authenticated;
grant execute on function rpc_create_order(text, numeric)            to authenticated;
grant execute on function rpc_deposit(uuid)                          to authenticated;
grant execute on function rpc_mark_shipped(uuid, text)               to authenticated;
grant execute on function rpc_confirm_delivery(uuid)                 to authenticated;
grant execute on function rpc_reject_delivery(uuid, text)            to authenticated;
grant execute on function rpc_cancel_order(uuid)                     to authenticated;

grant execute on function rpc_get_link_preview(text)                 to authenticated, anon;


-- ---------------------------------------------------------------------------
-- 7. VERIFY — expect: 13 policies, 12 functions, 1 trigger, 1 view
-- ---------------------------------------------------------------------------

select 'rls policies' as check_name, count(*)::text as result
from pg_policies where schemaname = 'public'

union all

select 'auth + rpc functions', count(*)::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('handle_new_auth_user','current_profile_id','current_profile_role',
                    'rpc_create_order','rpc_deposit','rpc_mark_shipped',
                    'rpc_confirm_delivery','rpc_reject_delivery','rpc_cancel_order',
                    'rpc_topup','rpc_my_wallet','rpc_get_link_preview')

union all

select 'signup trigger', count(*)::text
from pg_trigger where tgname = 'on_auth_user_created'

union all

select 'public_profiles view', count(*)::text
from information_schema.views
where table_schema = 'public' and table_name = 'public_profiles';
