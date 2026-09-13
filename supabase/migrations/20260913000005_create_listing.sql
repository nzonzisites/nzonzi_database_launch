-- "e.g." in the spec's permissions field signals that list isn't exhaustive — adding a
-- dedicated permission for listing review rather than overloading review_sellers, since
-- application review and listing style-guide review are plausibly different responsibilities.
alter type platform_agent_permission add value 'review_listings';

create type listing_delivery_mode as enum ('remote', 'will_travel', 'both');
create type listing_status as enum ('draft', 'active', 'paused', 'sold_out', 'pending_re_review');

create table listing (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references app_user (id),
  title text not null,
  description text not null,

  -- Same category domain as Application.intended_category — defaults from it at creation,
  -- independently editable afterward. Reuses the other/category_other pattern to handle the
  -- edge case where the underlying Application itself was 'other'. See docs/decisions.md.
  category application_intended_category not null,
  category_other text,

  price_minor_units integer not null check (price_minor_units > 0),
  currency text not null default 'USD',

  delivery_mode listing_delivery_mode not null,

  status listing_status not null default 'draft',

  -- Not in spec Section 2's literal field list for Listing — added because the
  -- StatusChangeEvent note in that same section claims Listing "already carries
  -- reviewed_by/decision_reason," which is only true if these columns exist. Flagged in
  -- docs/decisions.md.
  reviewed_by uuid references platform_agent (id),
  decision_reason text,

  created_at timestamptz not null default now(),

  constraint listing_category_other_required
    check (category <> 'other' or category_other is not null),
  constraint listing_decision_reason_required
    check (reviewed_by is null or decision_reason is not null)
);

create index listing_seller_id_idx on listing (seller_id);
create index listing_status_idx on listing (status);
create index listing_category_idx on listing (category);

-- Role-gated transitions: RLS alone can't express "same UPDATE, different allowed target
-- depending on who's calling," so this trigger checks transition validity AND actor role
-- together. Literal transition list per spec — sold_out has no way back to active, which
-- reads like a likely spec gap (flagged, not fixed unilaterally).
create or replace function check_listing_status_transition()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_transition text;
  v_is_seller boolean;
  v_is_agent boolean;
begin
  if new.status = old.status then
    return new;
  end if;

  v_transition := old.status || '->' || new.status;

  if v_transition not in (
    'draft->active', 'active->paused', 'paused->active',
    'active->pending_re_review', 'pending_re_review->active',
    'pending_re_review->paused', 'active->sold_out'
  ) then
    raise exception 'Invalid listing status transition: %', v_transition;
  end if;

  v_is_seller := exists (
    select 1 from app_user u where u.id = new.seller_id and u.auth_provider_id = auth.uid()
  );
  v_is_agent := is_platform_agent_with('review_listings');

  if v_transition in ('active->paused', 'paused->active', 'active->pending_re_review', 'active->sold_out') then
    if not v_is_seller then
      raise exception 'Only the listing''s seller may perform this transition';
    end if;
    if v_transition = 'active->pending_re_review' then
      -- Prior review no longer applies to the edited content.
      new.reviewed_by := null;
      new.decision_reason := null;
    end if;
  elsif v_transition in ('draft->active', 'pending_re_review->active', 'pending_re_review->paused') then
    if not v_is_agent then
      raise exception 'Only a PlatformAgent with review_listings permission may perform this transition';
    end if;
    if new.reviewed_by is distinct from current_platform_agent_id() then
      raise exception 'reviewed_by must be set to the acting PlatformAgent''s own id';
    end if;
  end if;

  return new;
end;
$$;

create trigger listing_status_transition
  before update on listing
  for each row
  execute function check_listing_status_transition();

alter table listing enable row level security;

create policy "anyone can view active listings"
  on listing for select
  to anon, authenticated
  using (status = 'active');

create policy "seller can view their own listings"
  on listing for select
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = seller_id and u.auth_provider_id = auth.uid())
  );

create policy "platform agents with review_listings can view all listings"
  on listing for select
  to authenticated
  using (is_platform_agent_with('review_listings'));

create policy "seller can create their own listing"
  on listing for insert
  to authenticated
  with check (
    status = 'draft'
    and exists (
      select 1
      from app_user u
      join seller_profile sp on sp.user_id = u.id
      where u.id = seller_id and u.auth_provider_id = auth.uid()
    )
  );

create policy "seller can update their own listing"
  on listing for update
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = seller_id and u.auth_provider_id = auth.uid())
  )
  with check (
    exists (select 1 from app_user u where u.id = seller_id and u.auth_provider_id = auth.uid())
  );

create policy "platform agents with review_listings can update any listing"
  on listing for update
  to authenticated
  using (is_platform_agent_with('review_listings'))
  with check (is_platform_agent_with('review_listings'));
