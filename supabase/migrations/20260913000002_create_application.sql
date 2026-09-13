create type application_work_modality as enum ('remote_only', 'travel_flexible', 'both');

create type application_intended_category as enum (
  'cosmetic_chemistry_formulation_science',
  'supply_chain_procurement_sourcing',
  'materials_science',
  'mechanical_manufacturing_engineering',
  'industrial_design',
  'applied_quant_qual_research',
  'arts_cultural_research',
  'other'
);

create type reference_contact_method as enum ('email', 'phone');

create type application_status as enum ('applied', 'under_review', 'approved', 'rejected');

create table application (
  id uuid primary key default gen_random_uuid(),
  prospect_signup_id uuid references prospect_signup (id),

  full_name text not null,
  email text not null,
  phone_or_whatsapp text not null,
  city_country text not null,
  affiliations text[] not null default '{}',
  external_links text[] not null default '{}',

  intended_category application_intended_category not null,
  intended_category_other text,
  work_modality application_work_modality not null,

  infrastructure_narrative text not null,
  expertise_narrative text not null,

  -- Each element: {"type": "file", "storage_path": "...", "filename": "..."} or {"type": "link", "url": "..."}
  work_samples jsonb not null default '[]'::jsonb,
  work_samples_explanation text,

  reference_name text not null,
  reference_relationship text not null,
  reference_contact_method reference_contact_method not null,
  reference_contact_value text not null,
  reference_whatsapp_available boolean,
  reference_may_contact boolean not null,

  additional_notes text,
  referral_source text,

  status application_status not null default 'applied',
  -- FK to platform_agent(id) added via ALTER TABLE once that table exists (Section 2 builds
  -- User/PlatformAgent after Application) — see docs/decisions.md.
  reviewed_by uuid,
  decision_reason text,

  created_at timestamptz not null default now(),

  constraint intended_category_other_required
    check (intended_category <> 'other' or intended_category_other is not null),
  constraint work_samples_explanation_required
    check (work_samples <> '[]'::jsonb or work_samples_explanation is not null),
  constraint decision_reason_required
    check (status not in ('approved', 'rejected') or decision_reason is not null)
);

create index application_email_lower_idx on application (lower(email));
create index application_prospect_signup_id_idx on application (prospect_signup_id);
create index application_status_idx on application (status);

create or replace function check_application_status_transition()
returns trigger
language plpgsql
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if (old.status, new.status) not in (
    ('applied', 'under_review'),
    ('under_review', 'approved'),
    ('under_review', 'rejected')
  ) then
    raise exception 'Invalid application status transition: % -> %', old.status, new.status;
  end if;

  return new;
end;
$$;

create trigger application_status_transition
  before update on application
  for each row
  execute function check_application_status_transition();

alter table application enable row level security;

-- No auth exists at application time (spec: auth is triggered at approval, not before), so the
-- public application form inserts with the anon key. No public read/update/delete —
-- PlatformAgent review access is added once User/PlatformAgent exist and RLS can check
-- reviewer permissions.
create policy "public can submit an application"
  on application for insert
  to anon, authenticated
  with check (true);
