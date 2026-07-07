-- ============================================================================
-- TRUST ESCROW WALLET — Week 1, File 4 of 4
-- 04_attack_tests.sql : We play the villain. The engine must win every round.
--
-- HOW TO RUN: SQL Editor → New query → paste ALL of this → Run.
--
-- WHAT TO EXPECT: a result table of ~24 numbered lines. EVERY line must start
-- with PASS (the last one says CLEANUP). If ANY line starts with FAIL or
-- ABORTED, copy the whole output and send it back — do not build on top of a
-- failing engine.
--
-- SAFETY: all test data (users, products, orders, money) is created inside a
-- subtransaction that is deliberately rolled back at the end. Your database
-- is left exactly as it was — the append-only ledger stays clean.
-- ============================================================================

-- scratch table for the report (temporary: vanishes when the session ends)
create temp table if not exists _test_report (seq serial primary key, line text);
truncate _test_report;

do $$
declare
  report     text[] := array[]::text[];
  v_samir    uuid;   -- seller
  v_btissam  uuid;   -- honest buyer
  v_karim    uuid;   -- second buyer / attacker
  v_product  uuid;
  v_exp_prod uuid;   -- expensive product for the overdraft attack
  v_order1   uuid;   -- happy path (btissam)
  v_order2   uuid;   -- overdraft attempt (karim)
  v_order3   uuid;   -- rejection path (karim)
  v_txt      text;
  v_num      numeric;
  v_status   order_status;
begin
  begin  -- ======= everything inside here gets rolled back at the end =======

    -- make the "money conservation" guard fire per-statement instead of at
    -- commit, so we can catch it red-handed inside this test run
    set constraints all immediate;

    -- ---------------- FIXTURES ----------------
    insert into profiles (role, display_name, phone_number)
      values ('seller', 'Samir Seller', '+212600000001') returning id into v_samir;
    insert into profiles (role, display_name, phone_number)
      values ('buyer', 'Btissam Buyer', '+212600000002') returning id into v_btissam;
    insert into profiles (role, display_name, phone_number)
      values ('buyer', 'Karim Buyer', '+212600000003') returning id into v_karim;

    perform ensure_user_accounts(v_samir);
    perform topup_wallet(v_btissam, 1000);
    perform topup_wallet(v_karim, 1000);

    insert into products (seller_id, title, description, category, price_mad, photos)
    values (v_samir, 'iPhone 12 128GB Black',
            'Original iPhone 12, 128GB, black, sealed box with all accessories and invoice.',
            'electronics', 500,
            '["photos/iphone-front.jpg","photos/iphone-back.jpg"]'::jsonb)
    returning id into v_product;

    insert into payment_links (product_id, seller_id, slug)
    values (v_product, v_samir, 'iph12-test01');

    report := array_append(report, 'PASS 00 — fixtures ready: 1 seller, 2 buyers with 1000 MAD each, 1 listed product');

    -- ---------------- TEST 01: bare listing rejected ----------------
    begin
      insert into products (seller_id, title, description, category, price_mad, photos)
      values (v_samir, 'Cheap thing', 'x', 'misc', 10, '["one.jpg"]'::jsonb);
      report := array_append(report, 'FAIL 01 — a listing with 1 photo and no description was accepted');
    exception when others then
      report := array_append(report, ('PASS 01 — lazy/bare listing rejected by the database ['
                           || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 02: snapshot is frozen ----------------
    v_order1 := create_order_from_link(v_btissam, 'iph12-test01', 35);
    update products set title = 'HACKED — was never an iPhone' where id = v_product;
    select product_snapshot->>'title' into v_txt from orders where id = v_order1;
    if v_txt = 'iPhone 12 128GB Black' then
      report := array_append(report, 'PASS 02 — seller edited the listing AFTER the order; the order''s frozen snapshot did not change');
    else
      report := array_append(report, ('FAIL 02 — snapshot changed to: ' || v_txt));
    end if;
    update products set title = 'iPhone 12 128GB Black' where id = v_product;

    -- ---------------- TEST 03: cannot buy your own product ----------------
    begin
      perform create_order_from_link(v_samir, 'iph12-test01', 35);
      report := array_append(report, 'FAIL 03 — a seller bought their own product (cashback farming door open!)');
    exception when others then
      report := array_append(report, ('PASS 03 — self-purchase blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 04: stranger cannot pay someone else's order ----
    begin
      perform deposit_to_escrow(v_order1, v_karim);
      report := array_append(report, 'FAIL 04 — a stranger deposited into someone else''s order');
    exception when others then
      report := array_append(report, ('PASS 04 — stranger deposit blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 05: legit deposit locks the money ----------------
    perform deposit_to_escrow(v_order1, v_btissam);
    select status into v_status from orders where id = v_order1;
    if account_balance(wallet_of(v_btissam)) = 465
       and account_balance((select escrow_account_id from orders where id = v_order1)) = 535
       and v_status = 'escrow_locked' then
      report := array_append(report, 'PASS 05 — deposit OK: buyer 1000→465 MAD, escrow holds 535 MAD, status escrow_locked');
    else
      report := array_append(report, ('FAIL 05 — balances wrong after deposit (buyer='
                           || account_balance(wallet_of(v_btissam))::text || ')'));
    end if;

    -- ---------------- TEST 06: double deposit ----------------
    begin
      perform deposit_to_escrow(v_order1, v_btissam);
      report := array_append(report, 'FAIL 06 — the same order was paid TWICE');
    exception when others then
      report := array_append(report, ('PASS 06 — double deposit blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 07: spending money you don't have ----------------
    insert into products (seller_id, title, description, category, price_mad, photos)
    values (v_samir, 'MacBook Pro 16 M3 Max',
            'MacBook Pro 16 inch, M3 Max, 64GB RAM, 2TB SSD, brand new sealed.',
            'electronics', 5000,
            '["photos/mbp-1.jpg","photos/mbp-2.jpg"]'::jsonb)
    returning id into v_exp_prod;
    insert into payment_links (product_id, seller_id, slug)
    values (v_exp_prod, v_samir, 'mbp16-test01');

    v_order2 := create_order_from_link(v_karim, 'mbp16-test01', 35);
    begin
      perform deposit_to_escrow(v_order2, v_karim);  -- karim has 1000, needs 5035
      report := array_append(report, 'FAIL 07 — overdraft: karim paid 5035 MAD holding only 1000');
    exception when others then
      report := array_append(report, ('PASS 07 — overdraft blocked [' || left(sqlerrm, 60) || ']'));
    end;
    if account_balance(wallet_of(v_karim)) = 1000 then
      report := array_append(report, 'PASS 08 — failed payment moved ZERO money (karim still has exactly 1000 MAD)');
    else
      report := array_append(report, 'FAIL 08 — a failed payment leaked money from karim''s wallet');
    end if;

    -- ---------------- TEST 09: confirm before shipping ----------------
    begin
      perform confirm_delivery(v_order1, v_btissam);
      report := array_append(report, 'FAIL 09 — delivery confirmed before anything shipped');
    exception when others then
      report := array_append(report, ('PASS 09 — confirm-before-ship blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 10: only the seller ships ----------------
    begin
      perform mark_shipped(v_order1, v_btissam, null);
      report := array_append(report, 'FAIL 10 — the BUYER marked the order as shipped');
    exception when others then
      report := array_append(report, ('PASS 10 — non-seller shipping blocked [' || left(sqlerrm, 60) || ']'));
    end;
    perform mark_shipped(v_order1, v_samir, '+212611111111');
    select status into v_status from orders where id = v_order1;
    if v_status = 'in_transit' then
      report := array_append(report, 'PASS 11 — seller shipped: order is in_transit, courier phone recorded');
    else
      report := array_append(report, ('FAIL 11 — expected in_transit, got ' || v_status::text));
    end if;

    -- ---------------- TEST 12: only the buyer decides the handoff ----------
    begin
      perform confirm_delivery(v_order1, v_samir);
      report := array_append(report, 'FAIL 12 — the SELLER confirmed their own delivery (self-payout!)');
    exception when others then
      report := array_append(report, ('PASS 12 — seller self-confirm blocked [' || left(sqlerrm, 60) || ']'));
    end;
    begin
      perform reject_delivery(v_order1, v_samir, 'seller trying to reject');
      report := array_append(report, 'FAIL 13 — the SELLER rejected the delivery');
    exception when others then
      report := array_append(report, ('PASS 13 — seller reject blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 14: the happy ending ----------------
    perform confirm_delivery(v_order1, v_btissam);
    select status into v_status from orders where id = v_order1;
    if account_balance(wallet_of(v_samir)) = 535
       and v_status = 'delivered_confirmed' then
      report := array_append(report, 'PASS 14 — buyer confirmed: seller INSTANTLY paid 535 MAD (vs 7-14 days with couriers)');
    else
      report := array_append(report, ('FAIL 14 — seller balance is '
                           || account_balance(wallet_of(v_samir))::text));
    end if;
    if account_balance(cashback_account_of(v_btissam)) = 25 then
      report := array_append(report, 'PASS 15 — buyer earned exactly 25 MAD cashback');
    else
      report := array_append(report, ('FAIL 15 — cashback is '
                           || account_balance(cashback_account_of(v_btissam))::text));
    end if;
    if account_balance((select escrow_account_id from orders where id = v_order1)) = 0 then
      report := array_append(report, 'PASS 16 — the order''s escrow box is empty: every dirham accounted for');
    else
      report := array_append(report, 'FAIL 16 — money left behind in escrow!');
    end if;

    -- ---------------- TEST 17: the classic double-spend ----------------
    begin
      perform confirm_delivery(v_order1, v_btissam);
      report := array_append(report, 'FAIL 17 — DOUBLE CONFIRM: seller was paid twice!');
    exception when others then
      report := array_append(report, ('PASS 17 — double confirm blocked [' || left(sqlerrm, 60) || ']'));
    end;
    begin
      perform reject_delivery(v_order1, v_btissam, 'refund me anyway');
      report := array_append(report, 'FAIL 18 — confirm-then-reject: buyer got product AND refund!');
    exception when others then
      report := array_append(report, ('PASS 18 — reject-after-confirm blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 19: conjuring money from thin air ----------------
    begin
      insert into ledger_entries (transfer_id, account_id, amount, reason)
      values (gen_random_uuid(), wallet_of(v_karim), 999999, 'free money hack');
      report := array_append(report, 'FAIL 19 — a lone ledger row CREATED 999999 MAD from nothing');
    exception when others then
      report := array_append(report, ('PASS 19 — thin-air money killed by the conservation guard ['
                           || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 20: rewriting history ----------------
    begin
      update ledger_entries set amount = 0
      where id = (select min(id) from ledger_entries);
      report := array_append(report, 'FAIL 20 — a past ledger entry was EDITED');
    exception when others then
      report := array_append(report, ('PASS 20 — ledger edit blocked [' || left(sqlerrm, 60) || ']'));
    end;
    begin
      delete from ledger_entries where id = (select min(id) from ledger_entries);
      report := array_append(report, 'FAIL 21 — a past ledger entry was DELETED');
    exception when others then
      report := array_append(report, ('PASS 21 — ledger delete blocked [' || left(sqlerrm, 60) || ']'));
    end;

    -- ---------------- TEST 22: the rejection path, end to end ----------------
    v_order3 := create_order_from_link(v_karim, 'iph12-test01', 35);
    begin
      perform mark_shipped(v_order3, v_samir, null);  -- shipping an UNPAID order
      report := array_append(report, 'FAIL 22 — seller shipped against an order with no money locked');
    exception when others then
      report := array_append(report, ('PASS 22 — ship-before-deposit blocked [' || left(sqlerrm, 60) || ']'));
    end;

    perform deposit_to_escrow(v_order3, v_karim);
    perform mark_shipped(v_order3, v_samir, '+212622222222');
    perform reject_delivery(v_order3, v_karim, 'Not the color in the photos');

    select status into v_status from orders where id = v_order3;
    if account_balance(wallet_of(v_karim)) = 965              -- 1000 - 535 + 500 refund
       and account_balance(wallet_of(v_samir)) = 570          -- 535 + 35 shipping
       and account_balance(cashback_account_of(v_karim)) = 0  -- no cashback on rejection
       and account_balance((select escrow_account_id from orders where id = v_order3)) = 0
       and v_status = 'delivery_rejected' then
      report := array_append(report, 'PASS 23 — rejection: karim instantly refunded 500 MAD, shipping (35) settled to seller, NO cashback, escrow empty');
    else
      report := array_append(report, ('FAIL 23 — rejection balances wrong (karim='
                           || account_balance(wallet_of(v_karim))::text
                           || ', samir=' || account_balance(wallet_of(v_samir))::text || ')'));
    end if;

    -- ---------------- TEST 24: the conservation law, globally ----------------
    select coalesce(sum(amount), 0) into v_num from ledger_entries;
    if v_num = 0 then
      report := array_append(report, 'PASS 24 — GRAND TOTAL of every ledger entry ever = 0.00: money only ever MOVED');
    else
      report := array_append(report, ('FAIL 24 — the ledger does not sum to zero: ' || v_num::text));
    end if;

    -- ======= force the rollback: wipe every trace of the test data =======
    raise exception '__ROLLBACK_TESTS__';

  exception when others then
    if sqlerrm = '__ROLLBACK_TESTS__' then
      report := array_append(report, 'PASS CLEANUP — all test users, orders and money rolled back; database left untouched');
    else
      report := array_append(report, ('ABORTED EARLY — unexpected error: ' || sqlerrm));
    end if;
  end;

  insert into _test_report (line) select unnest(report);
end $$;

-- the verdict
select seq as "#", line as result from _test_report order by seq;
