-- Millions of Dead Bands: additive Supabase setup
-- This version does not delete policies, alter existing votes, or assign
-- deadlines to existing matchups. It creates isolated, versioned RPC functions.
-- Before running: enable Authentication > Sign In / Providers > Anonymous Sign-Ins.

create table if not exists public.tournament_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.tournament_admins enable row level security;
-- No client-facing policies are created for this private administrator table.

create or replace function public.is_tournament_admin_v1()
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(select 1 from public.tournament_admins where user_id=auth.uid());
$$;
grant execute on function public.is_tournament_admin_v1() to authenticated;

create or replace function public.get_tournament_vote_totals_v1()
returns table(match_id bigint,artist_id bigint,vote_count bigint)
language sql stable security definer set search_path=public
as $$
  select v.match_id,v.artist_id,count(*)::bigint
  from public.votes v
  group by v.match_id,v.artist_id;
$$;
grant execute on function public.get_tournament_vote_totals_v1() to anon,authenticated;

create or replace function public.cast_tournament_vote_v1(p_match_id bigint,p_artist_id bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare m public.matches%rowtype;
begin
  if auth.uid() is null then raise exception 'Please start a guest voting session first.'; end if;
  select * into m from public.matches where id=p_match_id for update;
  if not found then raise exception 'Matchup not found.'; end if;
  if m.status <> 'pending' then raise exception 'Voting is closed for this matchup.'; end if;
  if m.closes_at is not null and m.closes_at <= now() then raise exception 'Voting deadline has passed.'; end if;
  if p_artist_id is distinct from m.artist_a and p_artist_id is distinct from m.artist_b then
    raise exception 'That artist is not part of this matchup.';
  end if;
  insert into public.votes(match_id,user_id,artist_id) values(p_match_id,auth.uid(),p_artist_id);
  return jsonb_build_object('ok',true);
exception when unique_violation then
  raise exception 'You have already voted in this matchup.';
end;
$$;
grant execute on function public.cast_tournament_vote_v1(bigint,bigint) to authenticated;

create or replace function public.close_expired_tournament_matches_v1()
returns integer language plpgsql security definer set search_path=public
as $$
declare changed integer;
begin
  update public.matches set status='closed'
  where status='pending' and closes_at is not null and closes_at <= now();
  get diagnostics changed=row_count;
  return changed;
end;
$$;
grant execute on function public.close_expired_tournament_matches_v1() to anon,authenticated;

create or replace function public.admin_resolve_tournament_match_v1(p_match_id bigint,p_winner_id bigint)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_tournament_admin_v1() then raise exception 'Administrator access required.'; end if;
  update public.matches set winner_id=p_winner_id,status='completed'
  where id=p_match_id and (artist_a=p_winner_id or artist_b=p_winner_id);
  if not found then raise exception 'Winner must be one of the two artists in this matchup.'; end if;
end;
$$;
grant execute on function public.admin_resolve_tournament_match_v1(bigint,bigint) to authenticated;

create or replace function public.admin_extend_tournament_match_v1(p_match_id bigint,p_closes_at timestamptz)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_tournament_admin_v1() then raise exception 'Administrator access required.'; end if;
  update public.matches set status='pending',closes_at=p_closes_at,winner_id=null where id=p_match_id;
  if not found then raise exception 'Matchup not found.'; end if;
end;
$$;
grant execute on function public.admin_extend_tournament_match_v1(bigint,timestamptz) to authenticated;

create or replace function public.admin_close_tournament_match_v1(p_match_id bigint)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_tournament_admin_v1() then raise exception 'Administrator access required.'; end if;
  update public.matches set status='closed',closes_at=now() where id=p_match_id;
  if not found then raise exception 'Matchup not found.'; end if;
end;
$$;
grant execute on function public.admin_close_tournament_match_v1(bigint) to authenticated;

-- ADMIN ENROLLMENT:
-- 1. Open the site once and copy the UUID shown on its Admin page.
-- 2. Replace the placeholder and run this one statement separately:
-- insert into public.tournament_admins(user_id) values ('YOUR-USER-UUID');
--
-- No existing tournament records or voting deadlines are changed by this setup.
-- The close-expired function changes only pending matches whose existing deadline
-- has passed, and is called by the website when it loads.
