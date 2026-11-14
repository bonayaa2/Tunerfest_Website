-- Launch Control update: one go per phone number (3 attempts in total), and a full public leaderboard
-- with everyone's name and best time. Run once in Supabase → SQL Editor, after supabase-launch-control.sql.

-- 1. How many attempts each phone number gets, in total
alter table public.game_settings add column if not exists attempts_per_player integer not null default 3 check (attempts_per_player between 1 and 100);

-- 2. Starting an attempt: refused once the number has used its attempts (abandoned attempts count too)
create or replace function public.lc_start(p_name text, p_phone text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  s public.game_settings; ph text := public.lc_phone(p_phone);
  nm text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]<>]', '', 'g'), 40);
  v_ip text := public.lc_ip(); run_id uuid; used integer; p public.game_players; rnk integer;
begin
  select * into s from public.game_settings where id = 1;
  if now() >= s.deadline then return json_build_object('error', 'closed'); end if;
  if ph is null then return json_build_object('error', 'bad_phone'); end if;
  if char_length(nm) < 2 then return json_build_object('error', 'bad_name'); end if;
  select count(*) into used from public.game_runs where phone = ph;
  if used >= s.attempts_per_player then
    select * into p from public.game_players where phone = ph;
    select 1 + count(*) into rnk from public.game_players g
     where g.best_ms is not null and not g.disqualified and (g.best_ms < p.best_ms or (g.best_ms = p.best_ms and g.best_at < p.best_at));
    return json_build_object('error', 'used', 'best_ms', p.best_ms, 'rank', case when p.best_ms is null then null else rnk end);
  end if;
  if v_ip <> 'unknown' and (select count(*) from public.game_runs g where g.ip = v_ip and g.started_at > now() - interval '1 hour') >= s.max_runs_per_ip_hour then
    return json_build_object('error', 'limit_ip');
  end if;
  insert into public.game_players (phone, name, last_ip) values (ph, nm, v_ip)
  on conflict (phone) do update set name = excluded.name, last_ip = excluded.last_ip, updated_at = now();
  update public.game_runs set result = 'expired' where phone = ph and result in ('started', 'armed');
  insert into public.game_runs (phone, ip) values (ph, v_ip) returning id into run_id;
  return json_build_object('run_id', run_id, 'phone', ph, 'left', s.attempts_per_player - used - 1);
end $$;

-- 3. Public leaderboard: everyone's name and best time, fastest first (never phone numbers)
create or replace function public.lc_leaderboard()
returns table (rank bigint, name text, best_ms integer)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by g.best_ms, g.best_at), g.name, g.best_ms
  from public.game_players g
  where g.best_ms is not null and not g.disqualified
  order by g.best_ms, g.best_at
  limit 500;
$$;

revoke execute on function public.lc_start(text, text), public.lc_leaderboard() from public;
grant execute on function public.lc_start(text, text), public.lc_leaderboard() to anon, authenticated;
