-- ============================================================================
-- TRUST ESCROW WALLET — Week 2, File 7
-- 07_storage_and_links.sql : photo storage + payment link generator
--
-- HOW TO RUN: paste all → Run. Expected result:
--   photo bucket           → 1
--   link generator rpc     → 1
--   photo upload policy    → 1   (if this shows 0, see the note in chat)
--
-- WHAT THIS INSTALLS:
--   1. A public storage bucket 'product-photos'. Anyone can VIEW photos
--      (needed for listings and payment link pages); only logged-in users
--      can UPLOAD, and only into a folder named after their own profile id.
--   2. rpc_create_payment_link(product_id) → generates a unique 8-character
--      slug for sharing in WhatsApp/Instagram DMs. Sellers only, own
--      products only, collision-proof.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. THE PHOTO BUCKET (public read; re-running is safe)
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('product-photos', 'product-photos', true)
on conflict (id) do nothing;


-- ---------------------------------------------------------------------------
-- 2. UPLOAD POLICY — you may only upload into YOUR OWN folder:
--    product-photos/<your-profile-id>/whatever.jpg
--    (wrapped so the file still succeeds if your project requires creating
--     storage policies via the dashboard — the verification will show 0)
-- ---------------------------------------------------------------------------

do $$
begin
  begin
    create policy "product_photos_upload_own"
      on storage.objects
      for insert to authenticated
      with check (
        bucket_id = 'product-photos'
        and (storage.foldername(name))[1] = current_profile_id()::text
      );
  exception when others then
    null;  -- likely insufficient privilege or already exists; check verification
  end;
end $$;


-- ---------------------------------------------------------------------------
-- 3. PAYMENT LINK GENERATOR — the seller's shareable code
-- ---------------------------------------------------------------------------

create or replace function rpc_create_payment_link(p_product uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_actor uuid := current_profile_id();
  v_slug  text;
  v_tries int  := 0;
begin
  if v_actor is null then
    raise exception 'Not authenticated';
  end if;
  if current_profile_role() <> 'seller' then
    raise exception 'Only sellers can create payment links';
  end if;
  if not exists (select 1 from products
                 where id = p_product and seller_id = v_actor) then
    raise exception 'Product not found or not yours';
  end if;

  loop
    v_tries := v_tries + 1;
    -- 8 random characters, a-z0-9 → 2.8 trillion combinations
    select string_agg(
             substr('abcdefghijklmnopqrstuvwxyz0123456789',
                    (floor(random() * 36))::int + 1, 1), '')
    into v_slug
    from generate_series(1, 8);

    begin
      insert into payment_links (product_id, seller_id, slug)
      values (p_product, v_actor, v_slug);
      return v_slug;
    exception when unique_violation then
      if v_tries > 5 then
        raise exception 'Could not generate a unique link, please try again';
      end if;
      -- collision (astronomically rare) → loop and try another slug
    end;
  end loop;
end $$;

revoke execute on function rpc_create_payment_link(uuid) from public, anon;
grant  execute on function rpc_create_payment_link(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 4. VERIFY
-- ---------------------------------------------------------------------------

select 'photo bucket' as check_name, count(*)::text as result
from storage.buckets where id = 'product-photos'

union all

select 'link generator rpc', count(*)::text
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'rpc_create_payment_link'

union all

select 'photo upload policy', count(*)::text
from pg_policies
where schemaname = 'storage' and policyname = 'product_photos_upload_own';
