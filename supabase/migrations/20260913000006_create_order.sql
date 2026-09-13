create type order_type as enum ('access_unlock', 'subscription', 'full_transaction');
create type order_status as enum ('pending', 'fulfilled', 'disputed', 'cancelled');
create type order_outcome as enum ('no_response', 'in_discussion', 'engaged_offplatform', 'not_pursued');
create type order_seller_outcome as enum ('no_contact', 'discussed', 'engaged', 'declined');
create type order_cancellation_initiator as enum ('seller', 'trust_safety_review');

-- Named marketplace_order, not "order" — reserved SQL keyword.
create table marketplace_order (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references app_user (id),
  -- Single nullable FK per user decision (2026-09-13): every MVP flow ties a non-subscription
  -- order to a specific listing, never a seller without one. Seller is derived via
  -- listing.seller_id when needed — no redundant column, no sync trigger.
  listing_id uuid references listing (id),
  type order_type not null,
  -- No allowed-transitions list exists in the spec for this field (unlike Application/
  -- Listing/Payment/Report, which all have one) — see check_marketplace_order_update below
  -- and docs/decisions.md. Not inventing a full state machine for pending/fulfilled/disputed.
  status order_status not null default 'pending',
  outcome order_outcome,
  seller_outcome order_seller_outcome,
  -- Spec lists only seller | trust_safety_review here — no buyer option. Implemented
  -- literally; flagged in docs/decisions.md as a possible spec gap.
  cancellation_initiator order_cancellation_initiator,
  created_at timestamptz not null default now()
);

create index marketplace_order_buyer_id_idx on marketplace_order (buyer_id);
create index marketplace_order_listing_id_idx on marketplace_order (listing_id);
create index marketplace_order_status_idx on marketplace_order (status);

-- Actor-gated field changes: outcome is buyer-only, seller_outcome is seller-only, and the
-- only status change currently permitted via a client role is the cancellation path (seller
-- self-cancel, or trust_safety_review escalation by a review_reports PlatformAgent). Any other
-- status change (e.g. marking fulfilled/disputed) is unspecified in the spec and rejected here
-- pending clarification — use service-role tooling until that's resolved.
create or replace function check_marketplace_order_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_is_buyer boolean;
  v_is_seller boolean;
  v_is_trust_safety_agent boolean;
begin
  v_is_buyer := exists (
    select 1 from app_user u where u.id = new.buyer_id and u.auth_provider_id = auth.uid()
  );
  v_is_seller := new.listing_id is not null and exists (
    select 1
    from listing l
    join app_user u on u.id = l.seller_id
    where l.id = new.listing_id and u.auth_provider_id = auth.uid()
  );
  v_is_trust_safety_agent := is_platform_agent_with('review_reports');

  if new.outcome is distinct from old.outcome and not v_is_buyer then
    raise exception 'Only the buyer may set outcome';
  end if;

  if new.seller_outcome is distinct from old.seller_outcome and not v_is_seller then
    raise exception 'Only the listing''s seller may set seller_outcome';
  end if;

  if new.status is distinct from old.status or new.cancellation_initiator is distinct from old.cancellation_initiator then
    if new.status = 'cancelled' and old.status <> 'cancelled' then
      if new.cancellation_initiator = 'seller' then
        if not v_is_seller then
          raise exception 'Only the listing''s seller may self-cancel';
        end if;
      elsif new.cancellation_initiator = 'trust_safety_review' then
        if not v_is_trust_safety_agent then
          raise exception 'Only a PlatformAgent with review_reports permission may cancel via trust & safety escalation';
        end if;
      else
        raise exception 'cancellation_initiator must be seller or trust_safety_review when cancelling';
      end if;
    else
      raise exception 'This status change is not yet supported — unspecified in the spec (see docs/decisions.md); use service-role tooling';
    end if;
  end if;

  return new;
end;
$$;

create trigger marketplace_order_update_guard
  before update on marketplace_order
  for each row
  execute function check_marketplace_order_update();

alter table marketplace_order enable row level security;

create policy "buyer can view their own orders"
  on marketplace_order for select
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = buyer_id and u.auth_provider_id = auth.uid())
  );

create policy "seller can view orders on their own listings"
  on marketplace_order for select
  to authenticated
  using (
    listing_id is not null and exists (
      select 1 from listing l join app_user u on u.id = l.seller_id
      where l.id = listing_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "platform agents with review_reports can view all orders"
  on marketplace_order for select
  to authenticated
  using (is_platform_agent_with('review_reports'));

create policy "buyer can create their own order"
  on marketplace_order for insert
  to authenticated
  with check (
    exists (select 1 from app_user u where u.id = buyer_id and u.auth_provider_id = auth.uid())
    and (
      listing_id is null
      or exists (select 1 from listing l where l.id = listing_id and l.status = 'active')
    )
  );

create policy "buyer can update their own order"
  on marketplace_order for update
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = buyer_id and u.auth_provider_id = auth.uid())
  )
  with check (
    exists (select 1 from app_user u where u.id = buyer_id and u.auth_provider_id = auth.uid())
  );

create policy "seller can update orders on their own listings"
  on marketplace_order for update
  to authenticated
  using (
    listing_id is not null and exists (
      select 1 from listing l join app_user u on u.id = l.seller_id
      where l.id = listing_id and u.auth_provider_id = auth.uid()
    )
  )
  with check (
    listing_id is not null and exists (
      select 1 from listing l join app_user u on u.id = l.seller_id
      where l.id = listing_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "platform agents with review_reports can update any order"
  on marketplace_order for update
  to authenticated
  using (is_platform_agent_with('review_reports'))
  with check (is_platform_agent_with('review_reports'));
