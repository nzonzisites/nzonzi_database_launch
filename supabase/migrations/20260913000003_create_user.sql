create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ── app_user ──────────────────────────────────────────────────────────────
-- Named app_user, not "user" — reserved word in Postgres.

create table app_user (
  id uuid primary key default gen_random_uuid(),
  -- References Supabase Auth's identity. Deliberately kept separate from id (see
  -- docs/decisions.md) so Nzonzi's internal identifier is stable even if the auth
  -- backend ever changes.
  auth_provider_id uuid not null unique references auth.users (id),
  email text not null,
  full_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index app_user_email_lower_idx on app_user (lower(email));

create trigger app_user_set_updated_at
  before update on app_user
  for each row
  execute function set_updated_at();

alter table app_user enable row level security;

create policy "users can insert their own row"
  on app_user for insert
  to authenticated
  with check (auth_provider_id = auth.uid());

create policy "users can read their own row"
  on app_user for select
  to authenticated
  using (auth_provider_id = auth.uid());

create policy "users can update their own row"
  on app_user for update
  to authenticated
  using (auth_provider_id = auth.uid())
  with check (auth_provider_id = auth.uid());

-- ── buyer_profile ────────────────────────────────────────────────────────
-- "buyer_type = other" has no companion free-text field in the spec (unlike
-- Application.intended_category_other) — not adding one, per docs/decisions.md.

create type buyer_type as enum (
  'market_entry_gtm_research',
  'product_development_formulation',
  'supply_chain_sourcing',
  'event_speaker_sourcing',
  'academic_or_policy_research',
  'other'
);

create table buyer_profile (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references app_user (id) on delete cascade,
  buyer_type buyer_type not null,
  created_at timestamptz not null default now()
);

alter table buyer_profile enable row level security;

create policy "users can manage their own buyer profile"
  on buyer_profile for all
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = buyer_profile.user_id and u.auth_provider_id = auth.uid())
  )
  with check (
    exists (select 1 from app_user u where u.id = buyer_profile.user_id and u.auth_provider_id = auth.uid())
  );

-- ── seller_profile ───────────────────────────────────────────────────────
-- Public-readable fields only. payout_details lives in seller_payout_detail (private).

create type seller_verification_status as enum ('unverified', 'verified');

create table seller_profile (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references app_user (id) on delete cascade,
  bio text,
  headshot text, -- storage path or URL
  location text,
  rating_average numeric, -- aggregation mechanism added once the Review model exists
  -- Each element: {"source": "...", "description": "...", "url": "..."} — structure not
  -- specified in the spec beyond "third-party validation not originating as a platform review".
  external_testimonials jsonb not null default '[]'::jsonb,
  -- Status-change history via StatusChangeEvent (see spec Section 2) — the enforcement
  -- mechanism and the PlatformAgent-can-set policy are added once PlatformAgent and
  -- StatusChangeEvent exist, same ordering issue as Application.reviewed_by.
  verification_status seller_verification_status not null default 'unverified',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger seller_profile_set_updated_at
  before update on seller_profile
  for each row
  execute function set_updated_at();

alter table seller_profile enable row level security;

create policy "anyone can read seller profiles"
  on seller_profile for select
  to anon, authenticated
  using (true);

-- Onboarding gate: a seller_profile row can only be created for a user whose email
-- matches an approved Application. Matches Flow A step 3-4.
create policy "seller can create own profile only if application approved"
  on seller_profile for insert
  to authenticated
  with check (
    exists (
      select 1
      from app_user u
      join application a on lower(a.email) = lower(u.email)
      where u.id = seller_profile.user_id
        and u.auth_provider_id = auth.uid()
        and a.status = 'approved'
    )
  );

create policy "seller can update own profile"
  on seller_profile for update
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = seller_profile.user_id and u.auth_provider_id = auth.uid())
  )
  with check (
    exists (select 1 from app_user u where u.id = seller_profile.user_id and u.auth_provider_id = auth.uid())
  );

-- RLS is row-level only — without this, "seller can update own profile" would let a
-- seller silently set their own verification_status or rating_average. Narrow the
-- actual column grant so only the genuinely self-editable fields are writable; the rest
-- (verification_status, rating_average) are only settable via a role with no such
-- restriction (service_role today; a PlatformAgent-scoped policy once that table exists).
revoke update on seller_profile from authenticated;
grant update (bio, headshot, location, external_testimonials) on seller_profile to authenticated;

-- ── seller_payout_detail ─────────────────────────────────────────────────
-- Private. No anon/public policy at all. Structure of payout_details itself is left as
-- a loose jsonb placeholder — Phase 3/Stripe Connect specifics aren't spec'd yet, and
-- payments logic is explicitly out of scope for this build.

create table seller_payout_detail (
  id uuid primary key default gen_random_uuid(),
  seller_profile_id uuid not null unique references seller_profile (id) on delete cascade,
  payout_details jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger seller_payout_detail_set_updated_at
  before update on seller_payout_detail
  for each row
  execute function set_updated_at();

alter table seller_payout_detail enable row level security;

create policy "seller can manage their own payout details"
  on seller_payout_detail for all
  to authenticated
  using (
    exists (
      select 1
      from seller_profile sp
      join app_user u on u.id = sp.user_id
      where sp.id = seller_payout_detail.seller_profile_id
        and u.auth_provider_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1
      from seller_profile sp
      join app_user u on u.id = sp.user_id
      where sp.id = seller_payout_detail.seller_profile_id
        and u.auth_provider_id = auth.uid()
    )
  );
