create type payment_status as enum (
  'pending', 'paid', 'held_in_escrow', 'evidence_submitted', 'released', 'refunded'
);

create table payment (
  id uuid primary key default gen_random_uuid(),
  -- At most one Payment per Order — not explicit in spec, but nothing suggests multiple
  -- payment attempts per order either. See docs/decisions.md.
  order_id uuid not null unique references marketplace_order (id),
  amount_minor_units integer not null check (amount_minor_units > 0),
  currency text not null default 'USD',
  -- Buyer's local currency, only set when different from the canonical amount/currency above.
  display_amount_minor_units integer,
  display_currency text,
  status payment_status not null default 'pending',
  -- Each element: {"type": "file", "storage_path": "...", "filename": "..."} or
  -- {"type": "link", "url": "..."} — same placeholder shape as Application.work_samples.
  delivery_evidence jsonb,
  created_at timestamptz not null default now()
);

create index payment_status_idx on payment (status);

-- Enforces the spec's explicit transition list. pending->paid and paid->held_in_escrow
-- represent Stripe webhook confirmations — service-role only, never a client action, since
-- no actual payment processing exists yet (see migration header note / docs/decisions.md).
create or replace function check_payment_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_transition text;
  v_is_buyer boolean;
  v_is_seller boolean;
begin
  if new.status = old.status then
    return new;
  end if;

  v_transition := old.status || '->' || new.status;

  if v_transition in ('pending->paid', 'paid->held_in_escrow') then
    if auth.role() <> 'service_role' then
      raise exception 'Only automated payment processing (service role) may perform this transition: %', v_transition;
    end if;
    return new;
  end if;

  v_is_buyer := exists (
    select 1
    from marketplace_order o
    join app_user u on u.id = o.buyer_id
    where o.id = new.order_id and u.auth_provider_id = auth.uid()
  );
  v_is_seller := exists (
    select 1
    from marketplace_order o
    join listing l on l.id = o.listing_id
    join app_user u on u.id = l.seller_id
    where o.id = new.order_id and u.auth_provider_id = auth.uid()
  );

  if v_transition = 'held_in_escrow->evidence_submitted' then
    if not v_is_seller then
      raise exception 'Only the order''s seller may submit delivery evidence';
    end if;
    if new.delivery_evidence is null then
      raise exception 'delivery_evidence is required when submitting evidence';
    end if;
  elsif v_transition = 'held_in_escrow->released' then
    if not v_is_buyer then
      raise exception 'Only the order''s buyer may confirm release';
    end if;
  elsif v_transition in ('evidence_submitted->released', 'evidence_submitted->refunded') then
    if not is_platform_agent_with('manage_evidence_review') then
      raise exception 'Only a PlatformAgent with manage_evidence_review permission may resolve submitted evidence';
    end if;
  elsif new.status = 'refunded' and old.status <> 'refunded' then
    -- Wildcard trust & safety escalation, from any other status, per spec's literal wording.
    if not is_platform_agent_with('issue_refunds') then
      raise exception 'Only a PlatformAgent with issue_refunds permission may refund via escalation';
    end if;
  else
    raise exception 'Invalid payment status transition: %', v_transition;
  end if;

  return new;
end;
$$;

create trigger payment_update_guard
  before update on payment
  for each row
  execute function check_payment_update();

alter table payment enable row level security;

create policy "buyer can view payments on their own orders"
  on payment for select
  to authenticated
  using (
    exists (
      select 1 from marketplace_order o
      join app_user u on u.id = o.buyer_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "seller can view payments on orders for their own listings"
  on payment for select
  to authenticated
  using (
    exists (
      select 1
      from marketplace_order o
      join listing l on l.id = o.listing_id
      join app_user u on u.id = l.seller_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "platform agents with evidence or refund permission can view all payments"
  on payment for select
  to authenticated
  using (
    is_platform_agent_with('manage_evidence_review') or is_platform_agent_with('issue_refunds')
  );

create policy "buyer can create a payment for their own order"
  on payment for insert
  to authenticated
  with check (
    status = 'pending'
    and exists (
      select 1 from marketplace_order o
      join app_user u on u.id = o.buyer_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "buyer can update payments on their own orders"
  on payment for update
  to authenticated
  using (
    exists (
      select 1 from marketplace_order o
      join app_user u on u.id = o.buyer_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from marketplace_order o
      join app_user u on u.id = o.buyer_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "seller can update payments on orders for their own listings"
  on payment for update
  to authenticated
  using (
    exists (
      select 1
      from marketplace_order o
      join listing l on l.id = o.listing_id
      join app_user u on u.id = l.seller_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from marketplace_order o
      join listing l on l.id = o.listing_id
      join app_user u on u.id = l.seller_id
      where o.id = order_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "platform agents with evidence or refund permission can update any payment"
  on payment for update
  to authenticated
  using (
    is_platform_agent_with('manage_evidence_review') or is_platform_agent_with('issue_refunds')
  )
  with check (
    is_platform_agent_with('manage_evidence_review') or is_platform_agent_with('issue_refunds')
  );
