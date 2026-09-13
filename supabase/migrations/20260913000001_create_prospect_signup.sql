create type prospect_interest as enum ('buyer', 'seller', 'both', 'unspecified');

create table prospect_signup (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  name text,
  affiliation text,
  interest prospect_interest not null,
  subscribed_at timestamptz not null default now(),
  unsubscribed_at timestamptz,
  source text
);

-- One row per email, case-insensitive. Resubscribing is an upsert that clears unsubscribed_at,
-- not a new row.
create unique index prospect_signup_email_lower_idx on prospect_signup (lower(email));

alter table prospect_signup enable row level security;

-- Public landing page form inserts with the anon key. No public read/update/delete —
-- unsubscribe/resubscribe and any internal querying go through service-role tooling
-- until those flows exist.
create policy "public can submit a prospect signup"
  on prospect_signup for insert
  to anon, authenticated
  with check (true);
