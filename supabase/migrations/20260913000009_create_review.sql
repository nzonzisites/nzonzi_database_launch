create table review (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references marketplace_order (id),
  author_id uuid not null references app_user (id),
  rating integer not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),

  -- Not explicit in spec — standard review-integrity assumption, flagged in docs/decisions.md.
  constraint review_one_per_author_per_order unique (order_id, author_id)
);

create index review_order_id_idx on review (order_id);
create index review_author_id_idx on review (author_id);

-- "Both sides can leave a review once an outcome is recorded" (Flow B step 5) — gated on the
-- author's own side having self-reported first.
create or replace function check_review_insert()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order marketplace_order%rowtype;
  v_seller_user_id uuid;
begin
  select * into v_order from marketplace_order where id = new.order_id;

  if v_order.buyer_id = new.author_id then
    if v_order.outcome is null then
      raise exception 'Buyer must record an outcome before leaving a review';
    end if;
    return new;
  end if;

  select l.seller_id into v_seller_user_id from listing l where l.id = v_order.listing_id;

  if v_seller_user_id = new.author_id then
    if v_order.seller_outcome is null then
      raise exception 'Seller must record a seller_outcome before leaving a review';
    end if;
    return new;
  end if;

  raise exception 'author_id must be the order''s buyer or the order''s listing seller';
end;
$$;

create trigger review_insert_guard
  before insert on review
  for each row
  execute function check_review_insert();

-- Resolves the rating_average aggregation deferred in the User migration. Only buyer-authored
-- reviews count toward a seller's rating (there's no buyer-side rating_average in the spec).
-- Runs with elevated privilege, bypassing seller_profile's own column-grant restriction —
-- this is exactly the system-computed value a seller shouldn't be able to self-edit.
create or replace function update_seller_rating_average()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_seller_user_id uuid;
begin
  select l.seller_id into v_seller_user_id
  from marketplace_order o
  join listing l on l.id = o.listing_id
  where o.id = new.order_id
    and o.buyer_id = new.author_id;

  if v_seller_user_id is not null then
    update seller_profile sp
    set rating_average = (
      select avg(r.rating)
      from review r
      join marketplace_order o on o.id = r.order_id
      join listing l on l.id = o.listing_id
      where l.seller_id = v_seller_user_id
        and o.buyer_id = r.author_id
    )
    where sp.user_id = v_seller_user_id;
  end if;

  return new;
end;
$$;

create trigger review_update_seller_rating
  after insert on review
  for each row
  execute function update_seller_rating_average();

alter table review enable row level security;

create policy "anyone can read reviews"
  on review for select
  to anon, authenticated
  using (true);

create policy "author can create their own review"
  on review for insert
  to authenticated
  with check (
    exists (select 1 from app_user u where u.id = author_id and u.auth_provider_id = auth.uid())
  );

-- No update/delete policy for anon/authenticated — reviews are immutable once posted.
