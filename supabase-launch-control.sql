-- Launch Control: the TunerFest 6.0 reaction-time giveaway game.
-- The database decides the random green-light delay and does all the timing with its own clock.
-- Run once in Supabase → SQL Editor. Safe to run again.

-- 1. Settings (one row). Change the deadline from Admin → Launch Control.
create table if not exists public.game_settings (
  id                 integer primary key default 1 check (id = 1),
  deadline           timestamptz not null default '2026-11-17 23:59:00+03',
  amber_ms           integer not null default 1200 check (amber_ms between 300 and 5000),
  min_ms             integer not null default 100 check (min_ms between 50 and 300),
  max_runs_per_phone_day integer not null default 60 check (max_runs_per_phone_day between 3 and 1000),
  max_runs_per_ip_hour   integer not null default 150 check (max_runs_per_ip_hour between 3 and 5000)
);
insert into public.game_settings (id) values (1) on conflict (id) do nothing;

-- 2. One row per phone number: their best valid time is their score
create table if not exists public.game_players (
  phone        text primary key check (phone ~ '^254[17][0-9]{8}$'),
  name         text not null check (char_length(name) between 2 and 40),
  best_ms      integer,
  best_at      timestamptz,
  runs         integer not null default 0,
  valid_runs   integer not null default 0,
  false_starts integer not null default 0,
  flags        text[] not null default '{}',
  disqualified boolean not null default false,
  last_ip      text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists game_players_best on public.game_players (best_ms, best_at) where best_ms is not null and not disqualified;

-- 3. Every attempt, with the server's timestamps
create table if not exists public.game_runs (
  id         uuid primary key default gen_random_uuid(),
  phone      text not null references public.game_players (phone) on delete cascade,
  ip         text,
  started_at timestamptz not null default clock_timestamp(),
  armed_at   timestamptz,
  rtt_ms     integer,
  delay_ms   integer,
  green_at   timestamptz,
  tapped_at  timestamptz,
  client_ms  integer,
  server_ms  integer,
  score_ms   integer,
  result     text not null default 'started' check (result in ('started', 'armed', 'ok', 'false_start', 'too_fast', 'expired')),
  flag       text
);
create index if not exists game_runs_phone on public.game_runs (phone, started_at);
create index if not exists game_runs_ip on public.game_runs (ip, started_at);

-- Only the team can read these tables directly; players go through the lc_* functions below
alter table public.game_settings enable row level security;
alter table public.game_players  enable row level security;
alter table public.game_runs     enable row level security;
drop policy if exists "admins manage game settings" on public.game_settings;
create policy "admins manage game settings" on public.game_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage game players" on public.game_players;
create policy "admins manage game players" on public.game_players for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins read game runs" on public.game_runs;
create policy "admins read game runs" on public.game_runs for select to authenticated using (public.is_admin());
revoke all on public.game_settings, public.game_players, public.game_runs from anon, authenticated;
grant select, update on public.game_settings to authenticated;
grant select, update on public.game_players to authenticated;
grant select on public.game_runs to authenticated;

-- Helpers (not callable from the website)
create or replace function public.lc_ip()
returns text language sql stable set search_path = public as $$
  select coalesce(
    nullif(current_setting('request.headers', true)::json ->> 'cf-connecting-ip', ''),
    nullif(trim(split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1)), ''),
    'unknown');
$$;
-- 0712345678 / 712345678 / +254712345678 / 254712345678 (and 01…) → 254712345678
create or replace function public.lc_phone(p text)
returns text language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
begin
  if d ~ '^0[17][0-9]{8}$' then return '254' || substr(d, 2); end if;
  if d ~ '^[17][0-9]{8}$' then return '254' || d; end if;
  if d ~ '^254[17][0-9]{8}$' then return d; end if;
  return null;
end $$;
create or replace function public.lc_ms(a timestamptz, b timestamptz)
returns integer language sql immutable as $$ select round(extract(epoch from (b - a)) * 1000)::integer $$;
revoke execute on function public.lc_ip(), public.lc_phone(text), public.lc_ms(timestamptz, timestamptz) from public, anon, authenticated;

-- Is the giveaway open, and until when?
create or replace function public.lc_status()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('open', now() < s.deadline, 'deadline', s.deadline,
    'players', (select count(*) from public.game_players where best_ms is not null and not disqualified))
  from public.game_settings s where s.id = 1;
$$;

-- 1) Start an attempt: checks the entry, the deadline and the attempt limits
create or replace function public.lc_start(p_name text, p_phone text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  s public.game_settings; ph text := public.lc_phone(p_phone);
  nm text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]<>]', '', 'g'), 40);
  v_ip text := public.lc_ip(); run_id uuid;
begin
  select * into s from public.game_settings where id = 1;
  if now() >= s.deadline then return json_build_object('error', 'closed'); end if;
  if ph is null then return json_build_object('error', 'bad_phone'); end if;
  if char_length(nm) < 2 then return json_build_object('error', 'bad_name'); end if;
  if (select count(*) from public.game_runs where phone = ph and started_at > now() - interval '1 day') >= s.max_runs_per_phone_day then
    return json_build_object('error', 'limit_phone');
  end if;
  if v_ip <> 'unknown' and (select count(*) from public.game_runs g where g.ip = v_ip and g.started_at > now() - interval '1 hour') >= s.max_runs_per_ip_hour then
    return json_build_object('error', 'limit_ip');
  end if;
  insert into public.game_players (phone, name, last_ip) values (ph, nm, v_ip)
  on conflict (phone) do update set name = excluded.name, last_ip = excluded.last_ip, updated_at = now();
  -- one attempt at a time per phone
  update public.game_runs set result = 'expired' where phone = ph and result in ('started', 'armed');
  insert into public.game_runs (phone, ip) values (ph, v_ip) returning id into run_id;
  return json_build_object('run_id', run_id, 'phone', ph);
end $$;

-- 2) Arm it: the server picks the random delay and fixes when the light turns green.
--    The time between start and arm is the player's network round trip, used to correct for lag.
create or replace function public.lc_arm(p_run uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare r public.game_runs; s public.game_settings; t timestamptz := clock_timestamp(); d integer;
begin
  select * into s from public.game_settings where id = 1;
  select * into r from public.game_runs where id = p_run and result = 'started' for update;
  if not found or r.started_at < t - interval '30 seconds' then return json_build_object('error', 'bad_run'); end if;
  d := 1000 + floor(random() * 3001)::integer;   -- 1–4 s after the ambers
  update public.game_runs
     set armed_at = t, rtt_ms = public.lc_ms(r.started_at, t), delay_ms = d,
         green_at = t + make_interval(secs => (s.amber_ms + d) / 1000.0), result = 'armed'
   where id = p_run;
  return json_build_object('amber_ms', s.amber_ms, 'wait_ms', s.amber_ms + d);
end $$;

-- 3) Tap: the server times it with its own clock, checks the phone's own measurement against it,
--    and keeps the player's best valid time
create or replace function public.lc_tap(p_run uuid, p_client_ms integer, p_false_start boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  r public.game_runs; s public.game_settings; p public.game_players;
  t timestamptz := clock_timestamp(); elapsed integer; rtt integer; tol integer; comp integer;
  score integer; fl text; best integer; rnk integer; new_flags text[];
begin
  select * into s from public.game_settings where id = 1;
  select * into r from public.game_runs where id = p_run and result = 'armed' for update;
  if not found then return json_build_object('error', 'bad_run'); end if;
  elapsed := public.lc_ms(r.green_at, t);

  -- tapped before green (seen by the phone, or by the server's clock) = false start
  if p_false_start or elapsed < 0 then
    update public.game_runs set tapped_at = t, server_ms = elapsed, client_ms = p_client_ms, result = 'false_start' where id = p_run;
    update public.game_players set runs = runs + 1, false_starts = false_starts + 1, updated_at = now() where phone = r.phone;
    return json_build_object('result', 'false_start');
  end if;
  if elapsed > 15000 or t > s.deadline + interval '1 minute' then
    update public.game_runs set tapped_at = t, server_ms = elapsed, result = 'expired' where id = p_run;
    return json_build_object('result', 'expired');
  end if;

  -- the server's time includes the network trip; take that off, within limits
  rtt := least(coalesce(r.rtt_ms, 0), 800);
  tol := greatest(150, rtt / 2);
  comp := elapsed - rtt;
  if p_client_ms is null or p_client_ms < 0 then score := comp; fl := 'no_phone_time';
  elsif p_client_ms < comp - tol then score := comp; fl := 'timing_mismatch';   -- phone claims faster than possible
  else score := p_client_ms;
  end if;
  if r.rtt_ms > 800 then fl := coalesce(fl, 'slow_network'); end if;

  select * into p from public.game_players where phone = r.phone for update;
  if score < s.min_ms then
    update public.game_runs set tapped_at = t, server_ms = elapsed, client_ms = p_client_ms, score_ms = score, result = 'too_fast', flag = coalesce(fl, 'impossible_time') where id = p_run;
    update public.game_players set runs = runs + 1, updated_at = now(),
      flags = (select array_agg(distinct f) from unnest(flags || array['impossible_time']) f) where phone = r.phone;
    return json_build_object('result', 'too_fast');
  end if;

  update public.game_runs set tapped_at = t, server_ms = elapsed, client_ms = p_client_ms, score_ms = score, result = 'ok', flag = fl where id = p_run;

  -- patterns worth a closer look before giving out prizes
  new_flags := p.flags;
  if fl = 'timing_mismatch' and (select count(*) from public.game_runs where phone = r.phone and flag = 'timing_mismatch') >= 3 then new_flags := new_flags || array['repeated_timing_mismatch']; end if;
  if (select count(*) from public.game_runs where phone = r.phone and result = 'ok' and score_ms < 130) >= 3 then new_flags := new_flags || array['many_under_0.130s']; end if;
  if (select count(*) >= 6 and stddev_samp(score_ms) < 4 from (select score_ms from public.game_runs where phone = r.phone and result = 'ok' order by tapped_at desc limit 6) x) then
    new_flags := new_flags || array['robotic_consistency'];
  end if;

  update public.game_players
     set runs = runs + 1, valid_runs = valid_runs + 1, updated_at = now(),
         best_ms = case when best_ms is null or score < best_ms then score else best_ms end,
         best_at = case when best_ms is null or score < best_ms then t else best_at end,
         flags = (select coalesce(array_agg(distinct f), '{}') from unnest(new_flags) f)
   where phone = r.phone
   returning best_ms into best;
  select 1 + count(*) into rnk from public.game_players g
   where g.best_ms is not null and not g.disqualified and (g.best_ms < best or (g.best_ms = best and g.best_at < (select best_at from public.game_players where phone = r.phone)));
  return json_build_object('result', 'ok', 'ms', score, 'best_ms', best, 'rank', rnk);
end $$;

-- Public leaderboard: top 10, names masked, no phone numbers
create or replace function public.lc_leaderboard()
returns table (rank bigint, name text, best_ms integer)
language sql stable security definer set search_path = public as $$
  -- "Kevin Otieno" -> "Kev*** O."
  select row_number() over (order by g.best_ms, g.best_at),
         left(w[1], 3) || '***' || case when array_length(w, 1) > 1 then ' ' || upper(left(w[array_length(w, 1)], 1)) || '.' else '' end,
         g.best_ms
  from public.game_players g, lateral (select regexp_split_to_array(trim(g.name), '\s+') as w) n
  where g.best_ms is not null and not g.disqualified
  order by g.best_ms, g.best_at
  limit 10;
$$;

revoke execute on function public.lc_status(), public.lc_start(text, text), public.lc_arm(uuid), public.lc_tap(uuid, integer, boolean), public.lc_leaderboard() from public;
grant execute on function public.lc_status(), public.lc_start(text, text), public.lc_arm(uuid), public.lc_tap(uuid, integer, boolean), public.lc_leaderboard() to anon, authenticated;
