create type platform_agent_permission as enum (
  'review_sellers',
  'review_reports',
  'issue_refunds',
  'manage_evidence_review'
);

create table platform_agent (
  id uuid primary key default gen_random_uuid(),
  -- Kept fully separate from buyer/seller profiles per spec ("staff generally shouldn't
  -- transact as a buyer/seller on the same identity") — that's a business convention, not
  -- enforced here as a hard constraint, since spec says "generally," not "never."
  user_id uuid not null unique references app_user (id),
  permissions platform_agent_permission[] not null default '{}',
  created_at timestamptz not null default now()
);

alter table platform_agent enable row level security;

-- Self-read only. No insert/update/delete for anon/authenticated at all — granting or
-- revoking staff permissions is a service-role/admin action, same self-elevation concern
-- as seller_profile.verification_status.
create policy "agents can read their own row"
  on platform_agent for select
  to authenticated
  using (
    exists (select 1 from app_user u where u.id = platform_agent.user_id and u.auth_provider_id = auth.uid())
  );

-- ── Reusable permission-check helpers ───────────────────────────────────
-- Introduced here since Application's review policies (below) need them, and Report/Listing
-- review policies will reuse them later — keeps the "is caller a PlatformAgent with
-- permission X" check consistent instead of re-deriving it per policy.

create or replace function is_platform_agent_with(p_permission platform_agent_permission)
returns boolean
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select exists (
    select 1
    from platform_agent pa
    join app_user u on u.id = pa.user_id
    where u.auth_provider_id = auth.uid()
      and p_permission = any(pa.permissions)
  );
$$;

grant execute on function is_platform_agent_with(platform_agent_permission) to authenticated;

create or replace function current_platform_agent_id()
returns uuid
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select pa.id
  from platform_agent pa
  join app_user u on u.id = pa.user_id
  where u.auth_provider_id = auth.uid()
  limit 1;
$$;

grant execute on function current_platform_agent_id() to authenticated;

-- ── Backfill: Application.reviewed_by FK (deferred from that migration) ────

alter table application
  add constraint application_reviewed_by_fkey
  foreign key (reviewed_by) references platform_agent (id);

-- ── Backfill: Application review access (no SELECT/UPDATE policy existed until now) ──
-- with check stamps reviewed_by as the acting agent's own id, so review activity is always
-- attributable (spec: "any action ... should record which PlatformAgent performed it").

create policy "platform agents with review_sellers can view applications"
  on application for select
  to authenticated
  using (is_platform_agent_with('review_sellers'));

create policy "platform agents with review_sellers can review applications"
  on application for update
  to authenticated
  using (is_platform_agent_with('review_sellers'))
  with check (
    is_platform_agent_with('review_sellers')
    and reviewed_by = current_platform_agent_id()
  );

-- ── Backfill: seller_profile.verification_status write path ────────────────
-- Deliberately NOT a table-level grant to `authenticated` — see message accompanying this
-- migration for why that would leak into the seller's own-row update policy. The reason
-- argument is required now (mirrors the required-reason pattern used elsewhere in the spec);
-- once StatusChangeEvent exists, this function is extended to insert that audit row in the
-- same transaction, satisfying the "same transaction as the status update" requirement.

create or replace function set_seller_verification_status(
  p_seller_profile_id uuid,
  p_new_status seller_verification_status,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not is_platform_agent_with('review_sellers') then
    raise exception 'Not authorized: caller is not a PlatformAgent with review_sellers permission';
  end if;

  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required to change seller verification status';
  end if;

  update seller_profile
  set verification_status = p_new_status
  where id = p_seller_profile_id;

  if not found then
    raise exception 'seller_profile % not found', p_seller_profile_id;
  end if;

  -- TODO once StatusChangeEvent exists: insert the audit row here, in this same
  -- transaction (entity_type = 'user_verification', actor_id/actor_role from the caller,
  -- previous_status captured before the update above, new_status = p_new_status,
  -- reason = p_reason).
end;
$$;

grant execute on function set_seller_verification_status(uuid, seller_verification_status, text) to authenticated;
