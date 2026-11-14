-- Crack the Safe: two drops a day; the first person to crack each drop's secret combination wins
-- a single-use free-ticket code. Combinations and codes never leave the database except to the winner.
-- Run once in Supabase → SQL Editor (after supabase-launch-control.sql). Safe to run again.

-- 1. Settings (one row). Change from Admin → Crack the Safe.
create table if not exists public.safe_settings (
  id          integer primary key default 1 check (id = 1),
  drop_times  text[] not null default '{12:00,19:00}',   -- Nairobi time, HH:MM
  starts_at   timestamptz not null default now(),
  ends_at     timestamptz not null default '2026-11-28 23:59:00+03',
  max_guesses integer not null default 7 check (max_guesses between 3 and 20),
  max_guesses_per_ip_drop integer not null default 60 check (max_guesses_per_ip_drop between 7 and 1000)
);
insert into public.safe_settings (id) values (1) on conflict (id) do nothing;

-- 2. The free-ticket codes you paste in; each is given out once
create table if not exists public.safe_codes (
  id        bigint generated always as identity primary key,
  code      text not null unique check (char_length(code) between 3 and 60),
  added_at  timestamptz not null default now(),
  drop_id   text,
  given_to  text,
  given_at  timestamptz
);

-- 3. Each drop: when it opens, its secret combination, and who cracked it
create table if not exists public.safe_drops (
  id         text primary key,                 -- e.g. "2026-11-15 12:00"
  opens_at   timestamptz not null,
  closes_at  timestamptz not null,
  combo      text not null check (combo ~ '^[1-6]{4}$'),
  cracked_by text,
  cracked_at timestamptz,
  code_id    bigint references public.safe_codes (id)
);

-- 4. Players and every guess
create table if not exists public.safe_players (
  phone      text primary key check (phone ~ '^254[17][0-9]{8}$'),
  name       text not null check (char_length(name) between 2 and 40),
  won_drop   text,
  last_ip    text,
  created_at timestamptz not null default now()
);
create table if not exists public.safe_guesses (
  id       bigint generated always as identity primary key,
  drop_id  text not null references public.safe_drops (id) on delete cascade,
  phone    text not null references public.safe_players (phone) on delete cascade,
  ip       text,
  guess    text not null check (guess ~ '^[1-6]{4}$'),
  exact    integer not null,
  partial  integer not null,
  at       timestamptz not null default clock_timestamp()
);
create index if not exists safe_guesses_drop_phone on public.safe_guesses (drop_id, phone);
create index if not exists safe_guesses_drop_ip on public.safe_guesses (drop_id, ip);

-- Only the team reads these directly; players go through the safe_* functions below
alter table public.safe_settings enable row level security;
alter table public.safe_codes    enable row level security;
alter table public.safe_drops    enable row level security;
alter table public.safe_players  enable row level security;
alter table public.safe_guesses  enable row level security;
drop policy if exists "admins manage safe settings" on public.safe_settings;
create policy "admins manage safe settings" on public.safe_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage safe codes" on public.safe_codes;
create policy "admins manage safe codes" on public.safe_codes for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins read safe drops" on public.safe_drops;
create policy "admins read safe drops" on public.safe_drops for select to authenticated using (public.is_admin());
drop policy if exists "admins read safe players" on public.safe_players;
create policy "admins read safe players" on public.safe_players for select to authenticated using (public.is_admin());
drop policy if exists "admins read safe guesses" on public.safe_guesses;
create policy "admins read safe guesses" on public.safe_guesses for select to authenticated using (public.is_admin());
revoke all on public.safe_settings, public.safe_codes, public.safe_drops, public.safe_players, public.safe_guesses from anon, authenticated;
grant select, update on public.safe_settings to authenticated;
grant select, insert, delete on public.safe_codes to authenticated;
grant select on public.safe_drops, public.safe_players, public.safe_guesses to authenticated;

-- "Kevin Otieno" -> "Kev*** O."
create or replace function public.safe_mask(n text)
returns text language sql immutable as $$
  select left(w[1], 3) || '***' || case when array_length(w, 1) > 1 then ' ' || upper(left(w[array_length(w, 1)], 1)) || '.' else '' end
  from (select regexp_split_to_array(trim(coalesce(n, '')), '\s+') as w) x;
$$;

-- The drop happening now (created on first use, with a fresh random combination), or null outside the giveaway
create or replace function public.safe_current_drop()
returns public.safe_drops language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  s public.safe_settings; d public.safe_drops; n timestamptz := now();
  today date := (n at time zone 'Africa/Nairobi')::date;
  slot timestamptz; best timestamptz; nxt timestamptz; t text; day date;
  c text := ''; b bytea := gen_random_bytes(4);
begin
  select * into s from public.safe_settings where id = 1;
  -- latest drop time at or before now, and the next one after it
  for day in select today - 1 union all select today union all select today + 1 loop
    foreach t in array s.drop_times loop
      slot := (day + t::time) at time zone 'Africa/Nairobi';
      if slot <= n and (best is null or slot > best) then best := slot; end if;
      if slot > n and (nxt is null or slot < nxt) then nxt := slot; end if;
    end loop;
  end loop;
  if best is null or best < s.starts_at - interval '1 day' or n < s.starts_at or n >= s.ends_at then return null; end if;
  select * into d from public.safe_drops where opens_at = best;
  if found then return d; end if;
  for i in 0..3 loop c := c || (get_byte(b, i) % 6 + 1)::text; end loop;
  insert into public.safe_drops (id, opens_at, closes_at, combo)
  values (to_char(best at time zone 'Africa/Nairobi', 'YYYY-MM-DD HH24:MI'), best, least(nxt, s.ends_at), c)
  on conflict (id) do nothing;
  select * into d from public.safe_drops where opens_at = best;
  return d;
end $$;

-- When is the next drop (for the countdown)?
create or replace function public.safe_next_drop()
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare s public.safe_settings; n timestamptz := now(); today date := (n at time zone 'Africa/Nairobi')::date; nxt timestamptz; slot timestamptz; t text; day date;
begin
  select * into s from public.safe_settings where id = 1;
  for day in select today union all select today + 1 union all select today + 2 loop
    foreach t in array s.drop_times loop
      slot := (day + t::time) at time zone 'Africa/Nairobi';
      if slot > n and slot >= s.starts_at and slot < s.ends_at and (nxt is null or slot < nxt) then nxt := slot; end if;
    end loop;
  end loop;
  return nxt;
end $$;

revoke execute on function public.safe_current_drop(), public.safe_next_drop(), public.safe_mask(text) from public, anon, authenticated;

-- Public status: is a safe open right now, when is the next drop, and who has won so far
create or replace function public.safe_status(p_phone text default null)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  s public.safe_settings; d public.safe_drops; ph text := public.lc_phone(p_phone); used integer := 0;
  codes_left integer; phase text; won text;
begin
  select * into s from public.safe_settings where id = 1;
  d := public.safe_current_drop();
  select count(*) into codes_left from public.safe_codes where given_to is null;
  if now() >= s.ends_at then phase := 'ended';
  elsif d.id is null then phase := 'waiting';
  elsif d.cracked_by is not null then phase := 'cracked';
  elsif codes_left = 0 then phase := 'no_codes';
  else phase := 'open';
  end if;
  if ph is not null then
    select won_drop into won from public.safe_players where phone = ph;
    if d.id is not null then select count(*) into used from public.safe_guesses where drop_id = d.id and phone = ph; end if;
  end if;
  return json_build_object(
    'phase', phase, 'drop', d.id, 'opened_at', d.opens_at, 'next_at', public.safe_next_drop(), 'ends_at', s.ends_at,
    'max_guesses', s.max_guesses, 'guesses_used', used, 'already_won', won is not null,
    'my_guesses', case when ph is not null and d.id is not null then coalesce((select json_agg(json_build_object('guess', g.guess, 'exact', g.exact, 'partial', g.partial) order by g.id desc)
                       from public.safe_guesses g where g.drop_id = d.id and g.phone = ph), '[]'::json) else '[]'::json end,
    'cracked_by', case when d.cracked_by is not null then (select public.safe_mask(name) from public.safe_players where phone = d.cracked_by) end,
    'cracked_at', d.cracked_at,
    'winners', coalesce((select json_agg(json_build_object('name', public.safe_mask(p.name), 'drop', x.id) order by x.cracked_at desc)
                         from public.safe_drops x join public.safe_players p on p.phone = x.cracked_by), '[]'::json));
end $$;

-- A guess: right place (exact) and right digit wrong place (partial). The first to get all 4 wins a code.
create or replace function public.safe_guess(p_name text, p_phone text, p_guess text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  s public.safe_settings; d public.safe_drops; ph text := public.lc_phone(p_phone);
  nm text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]<>]', '', 'g'), 40);
  v_ip text := public.lc_ip(); g text := trim(coalesce(p_guess, ''));
  used integer; ex integer := 0; pa integer := 0; i integer; dg text; won_code public.safe_codes; claimed integer;
begin
  select * into s from public.safe_settings where id = 1;
  if ph is null then return json_build_object('error', 'bad_phone'); end if;
  if char_length(nm) < 2 then return json_build_object('error', 'bad_name'); end if;
  if g !~ '^[1-6]{4}$' then return json_build_object('error', 'bad_guess'); end if;
  if now() >= s.ends_at then return json_build_object('error', 'ended'); end if;
  d := public.safe_current_drop();
  if d.id is null then return json_build_object('error', 'waiting'); end if;
  if d.cracked_by is not null then return json_build_object('error', 'cracked', 'cracked_by', (select public.safe_mask(name) from public.safe_players where phone = d.cracked_by)); end if;
  if not exists (select 1 from public.safe_codes where given_to is null) then return json_build_object('error', 'no_codes'); end if;

  insert into public.safe_players (phone, name, last_ip) values (ph, nm, v_ip)
  on conflict (phone) do update set name = excluded.name, last_ip = excluded.last_ip;
  if (select won_drop from public.safe_players where phone = ph) is not null then return json_build_object('error', 'already_won'); end if;
  select count(*) into used from public.safe_guesses where drop_id = d.id and phone = ph;
  if used >= s.max_guesses then return json_build_object('error', 'out_of_guesses'); end if;
  if v_ip <> 'unknown' and (select count(*) from public.safe_guesses where drop_id = d.id and ip = v_ip) >= s.max_guesses_per_ip_drop then
    return json_build_object('error', 'limit_ip');
  end if;

  -- score the guess (digits may repeat)
  for i in 1..4 loop if substr(g, i, 1) = substr(d.combo, i, 1) then ex := ex + 1; end if; end loop;
  for dg in select unnest(array['1','2','3','4','5','6']) loop
    pa := pa + least(length(g) - length(replace(g, dg, '')), length(d.combo) - length(replace(d.combo, dg, '')));
  end loop;
  pa := pa - ex;
  insert into public.safe_guesses (drop_id, phone, ip, guess, exact, partial) values (d.id, ph, v_ip, g, ex, pa);

  if ex < 4 then
    return json_build_object('result', 'try', 'exact', ex, 'partial', pa, 'left', s.max_guesses - used - 1);
  end if;

  -- cracked: only the first person through gets the drop, and one code
  update public.safe_drops set cracked_by = ph, cracked_at = clock_timestamp() where id = d.id and cracked_by is null;
  get diagnostics claimed = row_count;
  if claimed = 0 then return json_build_object('result', 'too_late', 'exact', 4, 'partial', 0); end if;
  select * into won_code from public.safe_codes where given_to is null order by id limit 1 for update skip locked;
  if not found then
    update public.safe_drops set cracked_by = null, cracked_at = null where id = d.id;
    return json_build_object('error', 'no_codes');
  end if;
  update public.safe_codes set given_to = ph, given_at = now(), drop_id = d.id where id = won_code.id;
  update public.safe_drops set code_id = won_code.id where id = d.id;
  update public.safe_players set won_drop = d.id where phone = ph;
  return json_build_object('result', 'won', 'code', won_code.code, 'exact', 4, 'partial', 0);
end $$;

revoke execute on function public.safe_status(text), public.safe_guess(text, text, text) from public;
grant execute on function public.safe_status(text), public.safe_guess(text, text, text) to anon, authenticated;
