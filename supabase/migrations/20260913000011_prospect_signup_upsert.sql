create or replace function public.upsert_prospect_signup(
  p_email text,
  p_interest prospect_interest,
  p_source text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing_interest prospect_interest;
begin
  select interest into v_existing_interest
  from prospect_signup
  where lower(email) = lower(p_email);

  if not found then
    insert into prospect_signup (email, interest, source)
    values (p_email, p_interest, p_source);
    return;
  end if;

  if v_existing_interest = p_interest or v_existing_interest = 'both' then
    update prospect_signup
    set unsubscribed_at = null
    where lower(email) = lower(p_email);
    return;
  end if;

  update prospect_signup
  set interest = 'both',
      unsubscribed_at = null
  where lower(email) = lower(p_email);
end;
$$;

grant execute on function public.upsert_prospect_signup(text, prospect_interest, text) to anon, authenticated;
