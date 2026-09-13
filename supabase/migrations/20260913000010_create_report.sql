create type report_reason as enum (
  'false_listing_claims', 'service_not_delivered_as_described', 'unprofessional_conduct', 'other'
);
create type report_status as enum (
  'submitted', 'under_review', 'resolved_no_action', 'resolved_listing_suspended', 'resolved_user_suspended'
);

create table report (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references app_user (id),
  -- Genuine either/or (Flow C: "against a listing or user") — two distinct target types,
  -- neither derivable from the other, unlike Order's listing_id/seller_id. Exactly one must
  -- be set.
  reported_listing_id uuid references listing (id),
  reported_user_id uuid references app_user (id),
  reason report_reason not null,
  description text not null,
  status report_status not null default 'submitted',
  reviewed_by uuid references platform_agent (id),
  -- Not in spec's literal Report field list — added because the transition rule explicitly
  -- requires "a reason" on any resolved_* outcome, and Report is excluded from
  -- StatusChangeEvent (per that table's own note, because it "already carries
  -- reviewed_by/decision_reason"), so this has nowhere else to live. See docs/decisions.md.
  decision_reason text,
  created_at timestamptz not null default now(),

  constraint report_exactly_one_target
    check ((reported_listing_id is not null)::int + (reported_user_id is not null)::int = 1),
  constraint report_decision_reason_required
    check (
      status not in ('resolved_no_action', 'resolved_listing_suspended', 'resolved_user_suspended')
      or decision_reason is not null
    )
);

create index report_reporter_id_idx on report (reporter_id);
create index report_reported_listing_id_idx on report (reported_listing_id);
create index report_reported_user_id_idx on report (reported_user_id);
create index report_status_idx on report (status);

-- Enforces the spec's explicit transition list, same pattern as Application. Report's
-- transitions are entirely PlatformAgent-driven (no seller/buyer self-service step, unlike
-- Listing/Order), so this is simpler than those triggers.
create or replace function check_report_status_transition()
returns trigger
language plpgsql
as $$
begin
  if new.status = old.status then
    return new;
  end if;

  if (old.status, new.status) not in (
    ('submitted', 'under_review'),
    ('under_review', 'resolved_no_action'),
    ('under_review', 'resolved_listing_suspended'),
    ('under_review', 'resolved_user_suspended')
  ) then
    raise exception 'Invalid report status transition: % -> %', old.status, new.status;
  end if;

  return new;
end;
$$;

create trigger report_status_transition
  before update on report
  for each row
  execute function check_report_status_transition();

alter table report enable row level security;

create policy "reporter can view their own reports"
  on report for select
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = reporter_id and u.auth_provider_id = auth.uid())
  );

create policy "platform agents with review_reports can view all reports"
  on report for select
  to authenticated
  using (is_platform_agent_with('review_reports'));

create policy "reporter can submit a report"
  on report for insert
  to authenticated
  with check (
    exists (select 1 from app_user u where u.id = reporter_id and u.auth_provider_id = auth.uid())
  );

-- No update policy for the reporter — reports are immutable once submitted from their side
-- (not explicit in spec, consistent with erring restrictive where unspecified).

create policy "platform agents with review_reports can review reports"
  on report for update
  to authenticated
  using (is_platform_agent_with('review_reports'))
  with check (
    is_platform_agent_with('review_reports')
    and reviewed_by = current_platform_agent_id()
  );
