-- Driver passes: one QR pass per approved show car, plus passes the team creates by hand.
-- Run once in Supabase → SQL Editor. Safe to run again.

create table if not exists public.driver_tickets (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  code            text not null unique check (code ~ '^DRV-[A-Z2-9]{10}$'),
  registration_id uuid unique references public.registrations (id) on delete cascade,
  name            text not null check (char_length(name) between 1 and 200),
  car             text check (char_length(car) <= 200),
  revoked         boolean not null default false,
  checked_in_at   timestamptz
);
alter table public.driver_tickets enable row level security;

-- Random, unguessable pass codes like DRV-7KQ2M9XHTP
create or replace function public.new_driver_code()
returns text language plpgsql volatile set search_path = public, extensions as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := gen_random_bytes(10);
  r text := 'DRV-';
begin
  for i in 0..9 loop r := r || substr(a, (get_byte(b, i) % 32) + 1, 1); end loop;
  return r;
end $$;
alter table public.driver_tickets alter column code set default public.new_driver_code();

-- Approving a show car creates its pass; un-approving it switches the pass off.
create or replace function public.sync_driver_ticket()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.type <> 'car' then return new; end if;
  if new.status = 'approved' then
    insert into public.driver_tickets (registration_id, name, car)
    values (new.id, new.name, new.car)
    on conflict (registration_id) do update set revoked = false, name = excluded.name, car = excluded.car;
  else
    update public.driver_tickets set revoked = true where registration_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists registrations_driver_ticket on public.registrations;
create trigger registrations_driver_ticket
  after insert or update of status, name, car on public.registrations
  for each row execute function public.sync_driver_ticket();

-- Passes for cars approved before this existed
insert into public.driver_tickets (registration_id, name, car)
select id, name, car from public.registrations where type = 'car' and status = 'approved'
on conflict (registration_id) do nothing;

-- Team access
drop policy if exists "admins manage driver tickets" on public.driver_tickets;
create policy "admins manage driver tickets" on public.driver_tickets
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.driver_tickets from anon, authenticated;
grant select, insert, update, delete on public.driver_tickets to authenticated;

-- A driver opens their own pass by its secret code (the link in their email).
create or replace function public.get_driver_ticket(ticket_code text)
returns table (code text, name text, car text, revoked boolean, checked_in boolean)
language sql stable security definer set search_path = public as $$
  select t.code, t.name, t.car, t.revoked, t.checked_in_at is not null
  from public.driver_tickets t where t.code = upper(trim(ticket_code));
$$;
revoke execute on function public.get_driver_ticket(text) from public;
grant execute on function public.get_driver_ticket(text) to anon, authenticated;

-- Gate scan: checks a pass in exactly once. Team only.
create or replace function public.check_in_driver(ticket_code text)
returns json language plpgsql security definer set search_path = public as $$
declare t public.driver_tickets;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into t from public.driver_tickets where code = upper(trim(ticket_code)) for update;
  if not found then return json_build_object('result', 'not_found'); end if;
  if t.revoked then return json_build_object('result', 'revoked', 'name', t.name, 'car', t.car); end if;
  if t.checked_in_at is not null then
    return json_build_object('result', 'already', 'name', t.name, 'car', t.car, 'at', t.checked_in_at);
  end if;
  update public.driver_tickets set checked_in_at = now() where id = t.id;
  return json_build_object('result', 'ok', 'name', t.name, 'car', t.car, 'code', t.code);
end $$;
revoke execute on function public.check_in_driver(text) from public, anon;
grant execute on function public.check_in_driver(text) to authenticated;
