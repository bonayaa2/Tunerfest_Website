-- Crack the Safe, simpler: every digit of a guess gets its own colour, like Wordle.
--   g = right digit, right place   a = in the code, somewhere else   x = not in the code
-- Run once in Supabase → SQL Editor, after supabase-crack-the-safe.sql. Safe to run again.

alter table public.safe_guesses add column if not exists marks text;

-- Colour each digit of a guess against the combination (handles repeated digits properly)
create or replace function public.safe_marks(g text, combo text)
returns text language plpgsql immutable as $$
declare m text[] := array['x','x','x','x']; left_over integer[] := array[0,0,0,0,0,0]; d integer; i integer;
begin
  for i in 1..4 loop
    if substr(g, i, 1) = substr(combo, i, 1) then m[i] := 'g';
    else d := substr(combo, i, 1)::integer; left_over[d] := left_over[d] + 1; end if;
  end loop;
  for i in 1..4 loop
    if m[i] <> 'g' then
      d := substr(g, i, 1)::integer;
      if left_over[d] > 0 then m[i] := 'a'; left_over[d] := left_over[d] - 1; end if;
    end if;
  end loop;
  return array_to_string(m, '');
end $$;
revoke execute on function public.safe_marks(text, text) from public, anon, authenticated;

-- Guesses now return the colour of each digit
create or replace function public.safe_guess(p_name text, p_phone text, p_guess text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  s public.safe_settings; d public.safe_drops; ph text := public.lc_phone(p_phone);
  nm text := left(regexp_replace(trim(coalesce(p_name, '')), '[[:cntrl:]<>]', '', 'g'), 40);
  v_ip text := public.lc_ip(); g text := trim(coalesce(p_guess, ''));
  used integer; mk text; ex integer; pa integer; won_code public.safe_codes; claimed integer;
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

  mk := public.safe_marks(g, d.combo);
  ex := length(mk) - length(replace(mk, 'g', ''));
  pa := length(mk) - length(replace(mk, 'a', ''));
  insert into public.safe_guesses (drop_id, phone, ip, guess, exact, partial, marks) values (d.id, ph, v_ip, g, ex, pa, mk);

  if ex < 4 then
    return json_build_object('result', 'try', 'marks', mk, 'exact', ex, 'partial', pa, 'left', s.max_guesses - used - 1);
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

-- Status sends the player's own guesses back with their colours (so a reload keeps the clues)
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
    'my_guesses', case when ph is not null and d.id is not null then coalesce((select json_agg(json_build_object('guess', g.guess, 'marks', coalesce(g.marks, public.safe_marks(g.guess, d.combo))) order by g.id desc)
                       from public.safe_guesses g where g.drop_id = d.id and g.phone = ph), '[]'::json) else '[]'::json end,
    'cracked_by', case when d.cracked_by is not null then (select public.safe_mask(name) from public.safe_players where phone = d.cracked_by) end,
    'cracked_at', d.cracked_at,
    'winners', coalesce((select json_agg(json_build_object('name', public.safe_mask(p.name), 'drop', x.id) order by x.cracked_at desc)
                         from public.safe_drops x join public.safe_players p on p.phone = x.cracked_by), '[]'::json));
end $$;

revoke execute on function public.safe_status(text), public.safe_guess(text, text, text) from public;
grant execute on function public.safe_status(text), public.safe_guess(text, text, text) to anon, authenticated;
