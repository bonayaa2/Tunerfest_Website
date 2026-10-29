-- Vendor passes admit 5 booth staff: the same pass scans up to 5 times. Driver passes stay at 1.
-- Run once in Supabase → SQL Editor (after supabase-vendor-passes.sql). Safe to run again.

alter table public.driver_tickets add column if not exists admits integer not null default 1 check (admits between 1 and 50);
alter table public.driver_tickets add column if not exists used    integer not null default 0 check (used >= 0);
update public.driver_tickets set admits = 5 where kind = 'vendor' and admits <> 5;
update public.driver_tickets set used = 1 where checked_in_at is not null and used = 0;

-- New vendor passes admit 5
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
  insert into public.driver_tickets (registration_id, kind, code, name, car, admits)
  values (reg_id, 'vendor', public.new_pass_code('VND'), r.business,
          left(concat_ws(' · ', r.booth_category, r.booth_size || ' tent', case when r.power then 'power' end), 200), 5)
  on conflict (registration_id) do update set revoked = false
  returning driver_tickets.code into pass_code;
  return pass_code;
end $$;
revoke execute on function public.confirm_booth_payment(uuid, text, integer) from public, anon;
grant execute on function public.confirm_booth_payment(uuid, text, integer) to authenticated;

-- Each scan uses one entry; the pass counts as checked in from the first scan
create or replace function public.do_check_in(ticket_code text, by_whom text)
returns json language plpgsql security definer set search_path = public as $$
declare t public.driver_tickets; n integer;
begin
  select * into t from public.driver_tickets where code = upper(trim(ticket_code)) for update;
  if not found then return json_build_object('result', 'not_found'); end if;
  if t.revoked then return json_build_object('result', 'revoked', 'name', t.name, 'car', t.car, 'kind', t.kind); end if;
  if t.used >= t.admits then
    return json_build_object('result', 'already', 'name', t.name, 'car', t.car, 'kind', t.kind, 'at', t.checked_in_at,
                             'by', t.checked_in_by, 'used', t.used, 'admits', t.admits);
  end if;
  update public.driver_tickets
     set used = used + 1, checked_in_at = coalesce(checked_in_at, now()), checked_in_by = coalesce(checked_in_by, by_whom)
   where id = t.id
   returning used into n;
  return json_build_object('result', 'ok', 'name', t.name, 'car', t.car, 'kind', t.kind, 'code', t.code, 'used', n, 'admits', t.admits);
end $$;
revoke execute on function public.do_check_in(text, text) from public, anon, authenticated;

-- The pass page shows how many entries are left
drop function if exists public.get_driver_ticket(text);
create function public.get_driver_ticket(ticket_code text)
returns table (code text, name text, car text, revoked boolean, checked_in boolean, kind text, admits integer, used integer)
language sql stable security definer set search_path = public as $$
  select t.code, t.name, t.car, t.revoked, t.used >= t.admits, t.kind, t.admits, t.used
  from public.driver_tickets t where t.code = upper(trim(ticket_code));
$$;
revoke execute on function public.get_driver_ticket(text) from public;
grant execute on function public.get_driver_ticket(text) to anon, authenticated;
