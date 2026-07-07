-- ============================================================================
-- TRUST ESCROW WALLET — Week 1, File 3 of 4
-- 03_state_machine.sql : The escrow state machine
--
-- HOW TO RUN: SQL Editor → New query → paste ALL of this → Run.
-- Expected result at the bottom:
--   state-machine functions → 7
--   cashback fund (MAD)     → 10000.00
--
-- THE FLOW THIS IMPLEMENTS:
--   create_order_from_link : link tap  → order born + product snapshot FROZEN
--   deposit_to_escrow      : buyer pays → money locked in the order's escrow box
--   mark_shipped           : seller ships → in_transit
--   confirm_delivery       : buyer accepts → seller paid + buyer gets cashback
--   reject_delivery        : buyer refuses → product refunded, shipping settled
--   cancel_order           : abandon before/instead of shipping, full refund
--
-- EVERY transition: locks the order row (FOR UPDATE), verifies the caller is
-- the right party, verifies the CURRENT status allows the move, moves money
-- through post_transfer (file 02), stamps the order, logs a delivery event.
-- Wrong caller, wrong state, or a race → loud exception, zero money moved.
--
-- NOTE ON p_actor: for now the caller passes who is acting. In Week 2 these
-- get wrapped in thin RPCs that derive the actor from auth.uid(), so the
-- client can never lie about who it is.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. EVENT LOGGER — one-liner used by every transition
-- ---------------------------------------------------------------------------

create or replace function log_delivery_event(
  p_order   uuid,
  p_type    delivery_event_type,
  p_source  event_source,
  p_payload jsonb default '{}'
) returns void language plpgsql as $$
begin
  insert into delivery_events (order_id, event_type, source, payload)
  values (p_order, p_type, p_source, coalesce(p_payload, '{}'));
end $$;


-- ---------------------------------------------------------------------------
-- 1. CREATE ORDER FROM PAYMENT LINK
--    Freezes the product listing into product_snapshot — the seller can edit
--    the listing afterwards, but THIS order's evidence never changes.
-- ---------------------------------------------------------------------------

create or replace function create_order_from_link(
  p_buyer           uuid,
  p_slug            text,
  p_amount_shipping numeric default 35   -- typical Morocco last-mile fee
) returns uuid language plpgsql as $$
declare
  v_link     payment_links%rowtype;
  v_product  products%rowtype;
  v_order_id uuid;
  v_escrow   uuid;
begin
  -- who is buying?
  if exists (select 1 from profiles where id = p_buyer and is_blocked) then
    raise exception 'Buyer account is blocked';
  end if;
  if not exists (select 1 from profiles where id = p_buyer) then
    raise exception 'Buyer % not found', p_buyer;
  end if;
  if p_amount_shipping is null or p_amount_shipping < 0 then
    raise exception 'Invalid shipping amount %', p_amount_shipping;
  end if;

  -- lock the link so two buyers can't overshoot max_uses together
  select * into v_link from payment_links where slug = p_slug for update;
  if not found then
    raise exception 'Payment link "%" not found', p_slug;
  end if;
  if v_link.status <> 'active' then
    raise exception 'Payment link is %', v_link.status;
  end if;
  if v_link.expires_at is not null and v_link.expires_at <= now() then
    raise exception 'Payment link has expired';
  end if;
  if v_link.max_uses is not null and v_link.use_count >= v_link.max_uses then
    raise exception 'Payment link has reached its maximum number of uses';
  end if;

  -- the product behind the link
  select * into v_product from products where id = v_link.product_id;
  if v_product.is_active is not true then
    raise exception 'This product is no longer available';
  end if;
  if v_product.seller_id = p_buyer then
    raise exception 'You cannot buy your own product';
  end if;
  if exists (select 1 from profiles where id = v_product.seller_id and is_blocked) then
    raise exception 'Seller account is blocked';
  end if;

  -- the order, with the listing FROZEN as evidence
  insert into orders (product_id, payment_link_id, buyer_id, seller_id,
                      amount_product, amount_shipping, product_snapshot)
  values (
    v_product.id, v_link.id, p_buyer, v_product.seller_id,
    v_product.price_mad, round(p_amount_shipping, 2),
    jsonb_build_object(
      'product_id',  v_product.id,
      'title',       v_product.title,
      'description', v_product.description,
      'category',    v_product.category,
      'condition',   v_product.condition,
      'price_mad',   v_product.price_mad,
      'photos',      v_product.photos,
      'seller_id',   v_product.seller_id,
      'captured_at', now()
    )
  ) returning id into v_order_id;

  -- this order's own escrow box
  insert into accounts (type, order_id)
  values ('order_escrow', v_order_id)
  returning id into v_escrow;

  update orders set escrow_account_id = v_escrow where id = v_order_id;

  -- consume one use of the link
  update payment_links
  set use_count = use_count + 1,
      status = case
                 when max_uses is not null and use_count + 1 >= max_uses
                 then 'expired'::payment_link_status
                 else status
               end
  where id = v_link.id;

  perform log_delivery_event(v_order_id, 'order_created', 'buyer_app',
                             jsonb_build_object('slug', p_slug));
  return v_order_id;
end $$;


-- ---------------------------------------------------------------------------
-- 2. DEPOSIT TO ESCROW    pending_deposit → escrow_locked
--    Buyer's wallet → the order's escrow box (product + shipping, one shot).
-- ---------------------------------------------------------------------------

create or replace function deposit_to_escrow(
  p_order uuid,
  p_actor uuid
) returns void language plpgsql as $$
declare
  v_order orders%rowtype;
  v_total numeric;
begin
  select * into v_order from orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;

  if p_actor <> v_order.buyer_id then
    raise exception 'Only the buyer can deposit into escrow';
  end if;
  if v_order.status <> 'pending_deposit' then
    raise exception 'Cannot deposit: order is already %', v_order.status;
  end if;

  v_total := v_order.amount_product + v_order.amount_shipping;

  perform post_transfer(wallet_of(v_order.buyer_id),
                        v_order.escrow_account_id,
                        v_total, 'escrow_lock', p_order);

  update orders
  set status = 'escrow_locked', deposited_at = now()
  where id = p_order;

  perform log_delivery_event(p_order, 'deposit_received', 'buyer_app',
                             jsonb_build_object('amount_mad', v_total));
end $$;


-- ---------------------------------------------------------------------------
-- 3. MARK SHIPPED    escrow_locked → in_transit
-- ---------------------------------------------------------------------------

create or replace function mark_shipped(
  p_order         uuid,
  p_actor         uuid,
  p_courier_phone text default null
) returns void language plpgsql as $$
declare
  v_order orders%rowtype;
begin
  select * into v_order from orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;

  if p_actor <> v_order.seller_id then
    raise exception 'Only the seller can mark the order as shipped';
  end if;
  if v_order.status <> 'escrow_locked' then
    raise exception 'Cannot ship: order is % (money must be locked first)', v_order.status;
  end if;

  update orders
  set status = 'in_transit',
      shipped_at = now(),
      courier_phone = coalesce(p_courier_phone, courier_phone)
  where id = p_order;

  perform log_delivery_event(p_order, 'marked_shipped', 'seller_dashboard',
                             jsonb_build_object('courier_phone', p_courier_phone));
end $$;


-- ---------------------------------------------------------------------------
-- 4. CONFIRM DELIVERY    in_transit → delivered_confirmed
--    The happy ending: seller gets the full escrow, buyer earns cashback.
--    Cashback degrades gracefully: if the marketing fund is dry, the
--    confirmation still succeeds (never block a customer's delivery over
--    our own budget) — it just logs that cashback was skipped.
-- ---------------------------------------------------------------------------

create or replace function confirm_delivery(
  p_order uuid,
  p_actor uuid
) returns void language plpgsql as $$
declare
  v_order            orders%rowtype;
  v_total            numeric;
  v_escrow_balance   numeric;
  v_marketing        uuid;
  v_cashback_granted boolean := false;
begin
  select * into v_order from orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;

  if p_actor <> v_order.buyer_id then
    raise exception 'Only the buyer can confirm delivery';
  end if;
  if v_order.status <> 'in_transit' then
    raise exception 'Cannot confirm: order is % (must be in_transit)', v_order.status;
  end if;

  -- paranoia pays: the escrow box must hold EXACTLY what was deposited
  v_total          := v_order.amount_product + v_order.amount_shipping;
  v_escrow_balance := account_balance(v_order.escrow_account_id);
  if v_escrow_balance <> v_total then
    raise exception 'ESCROW INTEGRITY VIOLATION on order %: holds % MAD, expected % MAD',
                    p_order, v_escrow_balance, v_total;
  end if;

  -- release everything to the seller (MVP rule: seller settles the courier
  -- off-platform; courier split becomes its own transfer in Phase 4)
  perform ensure_user_accounts(v_order.seller_id);
  perform post_transfer(v_order.escrow_account_id,
                        wallet_of(v_order.seller_id),
                        v_total, 'escrow_release', p_order);

  -- the hook: cashback into the buyer's pending box
  if v_order.cashback_mad > 0 then
    select id into v_marketing from accounts where type = 'platform_marketing';
    if account_balance(v_marketing) >= v_order.cashback_mad then
      perform ensure_user_accounts(v_order.buyer_id);
      perform post_transfer(v_marketing,
                            cashback_account_of(v_order.buyer_id),
                            v_order.cashback_mad, 'cashback_grant', p_order);
      v_cashback_granted := true;
    end if;
  end if;

  update orders
  set status = 'delivered_confirmed', resolved_at = now()
  where id = p_order;

  perform log_delivery_event(p_order, 'buyer_confirmed', 'buyer_app',
    jsonb_build_object('released_mad', v_total,
                       'cashback_granted', v_cashback_granted));
end $$;


-- ---------------------------------------------------------------------------
-- 5. REJECT DELIVERY    in_transit → delivery_rejected
--    Business rule (deliberate, one-line knob): the PRODUCT amount returns to
--    the buyer instantly; the SHIPPING amount goes to the seller, who owes
--    the courier. Rejection is free on the product, but the trip got paid —
--    that asymmetry is exactly what kills casual fake orders.
-- ---------------------------------------------------------------------------

create or replace function reject_delivery(
  p_order uuid,
  p_actor uuid,
  p_note  text default null
) returns void language plpgsql as $$
declare
  v_order orders%rowtype;
begin
  select * into v_order from orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;

  if p_actor <> v_order.buyer_id then
    raise exception 'Only the buyer can reject delivery';
  end if;
  if v_order.status <> 'in_transit' then
    raise exception 'Cannot reject: order is % (must be in_transit)', v_order.status;
  end if;

  -- product money back to the buyer, instantly
  perform post_transfer(v_order.escrow_account_id,
                        wallet_of(v_order.buyer_id),
                        v_order.amount_product, 'escrow_refund', p_order);

  -- shipping settles to the seller (they pay the courier off-platform)
  if v_order.amount_shipping > 0 then
    perform ensure_user_accounts(v_order.seller_id);
    perform post_transfer(v_order.escrow_account_id,
                          wallet_of(v_order.seller_id),
                          v_order.amount_shipping, 'shipping_settlement', p_order);
  end if;

  update orders
  set status = 'delivery_rejected', resolved_at = now()
  where id = p_order;

  perform log_delivery_event(p_order, 'buyer_rejected', 'buyer_app',
    jsonb_build_object('refunded_mad', v_order.amount_product,
                       'note', p_note));
end $$;


-- ---------------------------------------------------------------------------
-- 6. CANCEL ORDER
--    pending_deposit → cancelled : by buyer OR seller (no money involved)
--    escrow_locked   → cancelled : by SELLER only (declining the sale),
--                                  FULL refund to buyer, shipping included.
--    After shipping, cancel is impossible — it becomes confirm/reject.
-- ---------------------------------------------------------------------------

create or replace function cancel_order(
  p_order uuid,
  p_actor uuid
) returns void language plpgsql as $$
declare
  v_order orders%rowtype;
  v_total numeric;
begin
  select * into v_order from orders where id = p_order for update;
  if not found then raise exception 'Order % not found', p_order; end if;

  if v_order.status = 'pending_deposit' then
    if p_actor not in (v_order.buyer_id, v_order.seller_id) then
      raise exception 'Only the buyer or seller can cancel this order';
    end if;
    -- no money has moved; just close it

  elsif v_order.status = 'escrow_locked' then
    if p_actor <> v_order.seller_id then
      raise exception 'After deposit, only the seller can cancel (buyer money is protected)';
    end if;
    v_total := v_order.amount_product + v_order.amount_shipping;
    perform post_transfer(v_order.escrow_account_id,
                          wallet_of(v_order.buyer_id),
                          v_total, 'escrow_refund', p_order);

  else
    raise exception 'Cannot cancel: order is % ', v_order.status;
  end if;

  update orders
  set status = 'cancelled', resolved_at = now()
  where id = p_order;

  perform log_delivery_event(p_order, 'note', 'system',
    jsonb_build_object('event', 'order_cancelled', 'by', p_actor));
end $$;


-- ---------------------------------------------------------------------------
-- 7. SEED THE CASHBACK FUND — 10,000 simulated MAD of marketing budget
--    (guarded: only seeds if the fund is empty, so re-running is safe)
-- ---------------------------------------------------------------------------

do $$
declare
  v_mkt  uuid;
  v_cash uuid;
begin
  select id into v_mkt  from accounts where type = 'platform_marketing';
  select id into v_cash from accounts where type = 'platform_cash_in';
  if account_balance(v_mkt) = 0 then
    perform post_transfer(v_cash, v_mkt, 10000, 'marketing_budget_seed');
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 8. LOCK THE SIDE DOORS — money functions are server-side only.
--    (Week 2 adds thin auth-aware RPC wrappers for the app to call.)
-- ---------------------------------------------------------------------------

revoke execute on function post_transfer(uuid, uuid, numeric, text, uuid)          from public, anon, authenticated;
revoke execute on function topup_wallet(uuid, numeric)                             from public, anon, authenticated;
revoke execute on function ensure_user_accounts(uuid)                              from public, anon, authenticated;
revoke execute on function create_order_from_link(uuid, text, numeric)             from public, anon, authenticated;
revoke execute on function deposit_to_escrow(uuid, uuid)                           from public, anon, authenticated;
revoke execute on function mark_shipped(uuid, uuid, text)                          from public, anon, authenticated;
revoke execute on function confirm_delivery(uuid, uuid)                            from public, anon, authenticated;
revoke execute on function reject_delivery(uuid, uuid, text)                       from public, anon, authenticated;
revoke execute on function cancel_order(uuid, uuid)                                from public, anon, authenticated;
revoke execute on function log_delivery_event(uuid, delivery_event_type, event_source, jsonb) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 9. VERIFY — expect: 7 functions, cashback fund = 10000.00
-- ---------------------------------------------------------------------------

select 'state-machine functions' as check_name, count(*)::text as result
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('log_delivery_event','create_order_from_link','deposit_to_escrow',
                    'mark_shipped','confirm_delivery','reject_delivery','cancel_order')

union all

select 'cashback fund (MAD)',
       account_balance((select id from accounts where type = 'platform_marketing'))::text;
