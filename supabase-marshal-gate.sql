-- Marshal gate links: marshals check drivers in with a private link, no admin access.
-- Run once in Supabase → SQL Editor (after supabase-driver-passes.sql). Safe to run again.

-- Which marshal (or the team) checked each pass in
alter table public.driver_tickets add column if not exists checked_in_by text check (char_length(checked_in_by) <= 100);

-- One row per marshal link. Only a hash of the link's key is stored.
create table if not exists public.gate_keys (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  label      text not null check (char_length(label) between 1 and 100),
  key_hash   text not null unique,
  revoked    boolean not null default false,
  last_used_at timestamptz
);
alter table public.gate_keys enable row level security;
drop policy if exists "admins manage gate keys" on public.gate_keys;
create policy "admins manage gate keys" on public.gate_keys
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.gate_keys from anon, authenticated;
grant select, update, delete on public.gate_keys to authenticated;

-- The admin panel creates a link; the key is returned once and never stored in plain text.
create or replace function public.create_gate_key(gate_label text)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  b bytea := gen_random_bytes(24);
  k text := '';
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  for i in 0..23 loop k := k || substr(a, (get_byte(b, i) % length(a)) + 1, 1); end loop;
  insert into public.gate_keys (label, key_hash) values (left(trim(gate_label), 100), encode(digest(k, 'sha256'), 'hex'));
  return k;
end $$;
revoke execute on function public.create_gate_key(text) from public, anon;
grant execute on function public.create_gate_key(text) to authenticated;

-- Shared check-in: marks a pass used exactly once and says who did it.
create or replace function public.do_check_in(ticket_code text, by_whom text)
returns json language plpgsql security definer set search_path = public as $$
declare t public.driver_tickets;
begin
  select * into t from public.driver_tickets where code = upper(trim(ticket_code)) for update;
  if not found then return json_build_object('result', 'not_found'); end if;
  if t.revoked then return json_build_object('result', 'revoked', 'name', t.name, 'car', t.car); end if;
  if t.checked_in_at is not null then
    return json_build_object('result', 'already', 'name', t.name, 'car', t.car, 'at', t.checked_in_at, 'by', t.checked_in_by);
  end if;
  update public.driver_tickets set checked_in_at = now(), checked_in_by = by_whom where id = t.id;
  return json_build_object('result', 'ok', 'name', t.name, 'car', t.car, 'code', t.code);
end $$;
revoke execute on function public.do_check_in(text, text) from public, anon, authenticated;

-- Team scanner (admin panel)
create or replace function public.check_in_driver(ticket_code text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return public.do_check_in(ticket_code, 'Team');
end $$;
revoke execute on function public.check_in_driver(text) from public, anon;
grant execute on function public.check_in_driver(text) to authenticated;

-- Marshal scanner: works only with a valid, unrevoked marshal link
create or replace function public.gate_check_in(gate_key text, ticket_code text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare g public.gate_keys; res json;
begin
  select * into g from public.gate_keys where key_hash = encode(digest(coalesce(gate_key, ''), 'sha256'), 'hex') and not revoked;
  if not found then return json_build_object('result', 'bad_key'); end if;
  update public.gate_keys set last_used_at = now() where id = g.id;
  res := public.do_check_in(ticket_code, g.label);
  return (res::jsonb || jsonb_build_object(
    'in', (select count(*) from public.driver_tickets where not revoked and checked_in_at is not null),
    'total', (select count(*) from public.driver_tickets where not revoked)))::json;
end $$;
revoke execute on function public.gate_check_in(text, text) from public;
grant execute on function public.gate_check_in(text, text) to anon, authenticated;

-- Marshal page header: is this link valid, and how many are in?
create or replace function public.gate_status(gate_key text)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare g public.gate_keys;
begin
  select * into g from public.gate_keys where key_hash = encode(digest(coalesce(gate_key, ''), 'sha256'), 'hex') and not revoked;
  if not found then return json_build_object('ok', false); end if;
  return json_build_object('ok', true, 'label', g.label,
    'in', (select count(*) from public.driver_tickets where not revoked and checked_in_at is not null),
    'total', (select count(*) from public.driver_tickets where not revoked));
end $$;
revoke execute on function public.gate_status(text) from public;
grant execute on function public.gate_status(text) to anon, authenticated;
