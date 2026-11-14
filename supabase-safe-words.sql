-- Crack the Safe, car-word edition: each drop's secret is a 5-letter car word (Wordle-style, 6 guesses).
--   g = right letter, right place   a = in the word, somewhere else   x = not in the word
-- Run once in Supabase → SQL Editor, after supabase-crack-the-safe.sql and supabase-safe-simpler.sql. Safe to run again.

-- 1. The secret words (only the team can see this list). Add or remove words here or from the admin later.
create table if not exists public.safe_words (
  word    text primary key check (word ~ '^[A-Z]{5}$'),
  used_at timestamptz
);
insert into public.safe_words (word) values
  ('VALVE'), ('CRANK'), ('SHAFT'), ('CHOKE'), ('IDLER'), ('STRUT'), ('SHOCK'), ('SPOOL'), ('BOOST'), ('ROTOR'),
  ('TREAD'), ('BEZEL'), ('RELAY'), ('DIODE'), ('HITCH'), ('KNOCK'), ('NITRO'), ('DRIFT'), ('SLICK'), ('FLARE'),
  ('CARBS'), ('DIFFS'), ('WIPER'), ('SPARK'), ('PLUGS'), ('COILS'), ('TURBO'), ('GEARS'), ('AXLES'), ('WINCH'),
  ('GRILL'), ('COUPE'), ('RALLY'), ('PEDAL'), ('LEVER'), ('SPOKE'), ('DECAL'), ('VENTS') on conflict do nothing;
alter table public.safe_words enable row level security;
drop policy if exists "admins manage safe words" on public.safe_words;
create policy "admins manage safe words" on public.safe_words for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.safe_words from anon, authenticated;
grant select, insert, delete on public.safe_words to authenticated;

-- 2. Drops and guesses can now hold words (old digit codes stay valid in the history); each guess keeps its colours
alter table public.safe_guesses add column if not exists marks text;
alter table public.safe_drops   drop constraint if exists safe_drops_combo_check;
alter table public.safe_drops   add constraint safe_drops_combo_check check (combo ~ '^([1-6]{4}|[A-Z]{5})$');
alter table public.safe_guesses drop constraint if exists safe_guesses_guess_check;
alter table public.safe_guesses add constraint safe_guesses_guess_check check (guess ~ '^([1-6]{4}|[A-Z]{5})$');
update public.safe_settings set max_guesses = 6 where id = 1 and max_guesses = 7;

-- 3. Colour every letter of a guess (any length; repeated letters handled like Wordle)
create or replace function public.safe_marks(g text, combo text)
returns text language plpgsql immutable as $$
declare n integer := length(combo); m text[]; rest text[] := '{}'; i integer; k integer; ch text;
begin
  m := array_fill('x'::text, array[n]);
  for i in 1..n loop
    if substr(g, i, 1) = substr(combo, i, 1) then m[i] := 'g'; else rest := rest || substr(combo, i, 1); end if;
  end loop;
  for i in 1..n loop
    if m[i] <> 'g' then
      ch := substr(g, i, 1); k := array_position(rest, ch);
      if k is not null then m[i] := 'a'; rest := rest[1:k-1] || rest[k+1:]; end if;
    end if;
  end loop;
  return array_to_string(m, '');
end $$;
revoke execute on function public.safe_marks(text, text) from public, anon, authenticated;

-- 4. Each new drop picks a word that hasn't been used (or the longest-unused one)
create or replace function public.safe_current_drop()
returns public.safe_drops language plpgsql volatile security definer set search_path = public as $$
declare
  s public.safe_settings; d public.safe_drops; n timestamptz := now();
  today date := (n at time zone 'Africa/Nairobi')::date;
  slot timestamptz; best timestamptz; nxt timestamptz; t text; day date; w text;
begin
  select * into s from public.safe_settings where id = 1;
  for day in select today - 1 union all select today union all select today + 1 loop
    foreach t in array s.drop_times loop
      slot := (day + t::time) at time zone 'Africa/Nairobi';
      if slot <= n and (best is null or slot > best) then best := slot; end if;
      if slot > n and (nxt is null or slot < nxt) then nxt := slot; end if;
    end loop;
  end loop;
  if best is null or n < s.starts_at or n >= s.ends_at then return null; end if;
  select * into d from public.safe_drops where opens_at = best;
  if found then return d; end if;
  select word into w from public.safe_words order by used_at nulls first, random() limit 1 for update skip locked;
  if w is null then return null; end if;
  insert into public.safe_drops (id, opens_at, closes_at, combo)
  values (to_char(best at time zone 'Africa/Nairobi', 'YYYY-MM-DD HH24:MI'), best, least(nxt, s.ends_at), w)
  on conflict (id) do nothing;
  update public.safe_words set used_at = now() where word = w;
  select * into d from public.safe_drops where opens_at = best;
  return d;
end $$;
revoke execute on function public.safe_current_drop() from public, anon, authenticated;

-- 5. Guesses: 5 letters A–Z, scored per letter
create or replace function public.safe_guess(p_name text, p_phone text, p_guess text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  s public.safe_settings; d public.safe_drops; ph text := public.lc_phone(p_phone);
  nm text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]<>]', '', 'g'), 40);
  v_ip text := public.lc_ip(); g text := upper(trim(coalesce(p_guess, '')));
  used integer; mk text; ex integer; pa integer; won_code public.safe_codes; claimed integer;
begin
  select * into s from public.safe_settings where id = 1;
  if ph is null then return json_build_object('error', 'bad_phone'); end if;
  if char_length(nm) < 2 then return json_build_object('error', 'bad_name'); end if;
  if now() >= s.ends_at then return json_build_object('error', 'ended'); end if;
  d := public.safe_current_drop();
  if d.id is null then return json_build_object('error', 'waiting'); end if;
  if length(g) <> length(d.combo) or (d.combo ~ '^[A-Z]+$' and g !~ '^[A-Z]+$') or (d.combo ~ '^[1-6]+$' and g !~ '^[1-6]+$') then
    return json_build_object('error', 'bad_guess', 'length', length(d.combo));
  end if;
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

  mk := public.safe_marks(g, d.combo);
  ex := length(mk) - length(replace(mk, 'g', ''));
  pa := length(mk) - length(replace(mk, 'a', ''));
  insert into public.safe_guesses (drop_id, phone, ip, guess, exact, partial, marks) values (d.id, ph, v_ip, g, ex, pa, mk);

  if ex < length(d.combo) then
    return json_build_object('result', 'try', 'marks', mk, 'left', s.max_guesses - used - 1);
  end if;

  update public.safe_drops set cracked_by = ph, cracked_at = clock_timestamp() where id = d.id and cracked_by is null;
  get diagnostics claimed = row_count;
  if claimed = 0 then return json_build_object('result', 'too_late', 'marks', mk); end if;
  select * into won_code from public.safe_codes where given_to is null order by id limit 1 for update skip locked;
  if not found then
    update public.safe_drops set cracked_by = null, cracked_at = null where id = d.id;
    return json_build_object('error', 'no_codes');
  end if;
  update public.safe_codes set given_to = ph, given_at = now(), drop_id = d.id where id = won_code.id;
  update public.safe_drops set code_id = won_code.id where id = d.id;
  update public.safe_players set won_drop = d.id where phone = ph;
  return json_build_object('result', 'won', 'code', won_code.code, 'marks', mk);
end $$;

-- 6. Status also says how long the word is
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
    'length', coalesce(length(d.combo), 5), 'letters', coalesce(d.combo ~ '^[A-Z]+$', true),
    'max_guesses', s.max_guesses, 'guesses_used', used, 'already_won', won is not null,
    'my_guesses', case when ph is not null and d.id is not null then coalesce((select json_agg(json_build_object('guess', g.guess, 'marks', coalesce(g.marks, public.safe_marks(g.guess, d.combo))) order by g.id desc)
                       from public.safe_guesses g where g.drop_id = d.id and g.phone = ph), '[]'::json) else '[]'::json end,
    'cracked_by', case when d.cracked_by is not null then (select public.safe_mask(name) from public.safe_players where phone = d.cracked_by) end,
    'cracked_at', d.cracked_at,
    'winners', coalesce((select json_agg(json_build_object('name', public.safe_mask(p.name), 'drop', x.id) order by x.cracked_at desc)
                         from public.safe_drops x join public.safe_players p on p.phone = x.cracked_by), '[]'::json));
end $$;

revoke execute on function public.safe_status(text), public.safe_guess(text, text, text) from public;
grant execute on function public.safe_status(text), public.safe_guess(text, text, text) to anon, authenticated;
