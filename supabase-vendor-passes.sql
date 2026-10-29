-- Vendor passes: confirm a booth's M-PESA payment, then the vendor gets a QR pass (VND-XXXXXXXXXX).
-- Run once in Supabase → SQL Editor (after supabase-driver-passes.sql and supabase-marshal-gate.sql). Safe to run again.

-- Booth payments
alter table public.registrations add column if not exists paid_at     timestamptz;
alter table public.registrations add column if not exists mpesa_code  text check (char_length(mpesa_code) <= 30);
alter table public.registrations add column if not exists amount_paid integer check (amount_paid >= 0);

-- Passes now come in two kinds: driver (DRV-…) and vendor (VND-…)
alter table public.driver_tickets add column if not exists kind text not null default 'driver' check (kind in ('driver', 'vendor'));
alter table public.driver_tickets drop constraint if exists driver_tickets_code_check;
alter table public.driver_tickets add constraint driver_tickets_code_check check (code ~ '^(DRV|VND)-[A-Z2-9]{10}$');

create or replace function public.new_pass_code(prefix text)
returns text language plpgsql volatile set search_path = public, extensions as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := gen_random_bytes(10);
  r text := prefix || '-';
begin
  for i in 0..9 loop r := r || substr(a, (get_byte(b, i) % 32) + 1, 1); end loop;
  return r;
end $$;

-- Approving a show car creates its driver pass. Un-approving a car or a booth switches its pass off;
-- re-approving a paid booth switches its vendor pass back on.
create or replace function public.sync_driver_ticket()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.type = 'car' then
    if new.status = 'approved' then
      insert into public.driver_tickets (registration_id, name, car)
      values (new.id, new.name, new.car)
      on conflict (registration_id) do update set revoked = false, name = excluded.name, car = excluded.car;
    else
      update public.driver_tickets set revoked = true where registration_id = new.id;
    end if;
  else
    update public.driver_tickets set revoked = (new.status <> 'approved') where registration_id = new.id;
  end if;
  return new;
end $$;

-- Team only: record a booth's M-PESA payment and issue its vendor pass. Returns the pass code.
create or replace function public.confirm_booth_payment(reg_id uuid, mpesa text, amount integer)
returns text language plpgsql security definer set search_path = public as $$
declare r public.registrations; pass_code text;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  select * into r from public.registrations where id = reg_id and type = 'booth' for update;
  if not found then raise exception 'not a booth'; end if;
  if r.status <> 'approved' then raise exception 'approve the booth first'; end if;
  update public.registrations
     set paid_at = coalesce(paid_at, now()), mpesa_code = upper(left(trim(mpesa), 30)), amount_paid = amount
   where id = reg_id;
  insert into public.driver_tickets (registration_id, kind, code, name, car)
  values (reg_id, 'vendor', public.new_pass_code('VND'), r.business,
          left(concat_ws(' · ', r.booth_category, r.booth_size || ' tent', case when r.power then 'power' end), 200))
  on conflict (registration_id) do update set revoked = false
  returning driver_tickets.code into pass_code;
  return pass_code;
end $$;
revoke execute on function public.confirm_booth_payment(uuid, text, integer) from public, anon;
grant execute on function public.confirm_booth_payment(uuid, text, integer) to authenticated;

-- The pass page now says whether it's a driver or vendor pass
drop function if exists public.get_driver_ticket(text);
create function public.get_driver_ticket(ticket_code text)
returns table (code text, name text, car text, revoked boolean, checked_in boolean, kind text)
language sql stable security definer set search_path = public as $$
  select t.code, t.name, t.car, t.revoked, t.checked_in_at is not null, t.kind
  from public.driver_tickets t where t.code = upper(trim(ticket_code));
$$;
revoke execute on function public.get_driver_ticket(text) from public;
grant execute on function public.get_driver_ticket(text) to anon, authenticated;

-- Scans report the pass kind too
create or replace function public.do_check_in(ticket_code text, by_whom text)
returns json language plpgsql security definer set search_path = public as $$
declare t public.driver_tickets;
begin
  select * into t from public.driver_tickets where code = upper(trim(ticket_code)) for update;
  if not found then return json_build_object('result', 'not_found'); end if;
  if t.revoked then return json_build_object('result', 'revoked', 'name', t.name, 'car', t.car, 'kind', t.kind); end if;
  if t.checked_in_at is not null then
    return json_build_object('result', 'already', 'name', t.name, 'car', t.car, 'kind', t.kind, 'at', t.checked_in_at, 'by', t.checked_in_by);
  end if;
  update public.driver_tickets set checked_in_at = now(), checked_in_by = by_whom where id = t.id;
  return json_build_object('result', 'ok', 'name', t.name, 'car', t.car, 'kind', t.kind, 'code', t.code);
end $$;
revoke execute on function public.do_check_in(text, text) from public, anon, authenticated;
