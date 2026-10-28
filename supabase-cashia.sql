-- Cashia tickets (already applied to the live project on 2026-10-28).
-- Separate from Little Africa tickets. Prices are locked here, not in the browser.
create table public.cashia_orders (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  code          text not null unique check (code ~ '^TF6-[A-Z2-9]{10}$'),
  tier          text not null check (tier in ('early', 'advanced')),
  quantity      int  not null check (quantity between 1 and 10),
  unit_price    int  not null,
  total         int  generated always as (unit_price * quantity) stored,
  name          text not null check (char_length(name) between 1 and 200),
  email         text not null check (char_length(email) between 3 and 200),
  phone         text not null check (char_length(phone) between 1 and 50),
  status        text not null default 'pending' check (status in ('pending', 'paid', 'cancelled')),
  cashia_ref    text check (char_length(cashia_ref) <= 100),
  paid_at       timestamptz,
  checked_in_at timestamptz,
  constraint cashia_price check (unit_price = case tier when 'early' then 600 when 'advanced' then 800 end)
);
alter table public.cashia_orders enable row level security;

create policy "anyone can order" on public.cashia_orders
  for insert to anon, authenticated
  with check (
    status = 'pending' and paid_at is null and checked_in_at is null and cashia_ref is null
    and (tier <> 'early' or now() < timestamptz '2026-10-31 00:00:00+03')
  );
create policy "admins read orders" on public.cashia_orders
  for select to authenticated using (public.is_admin());
create policy "admins update orders" on public.cashia_orders
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete orders" on public.cashia_orders
  for delete to authenticated using (public.is_admin());

revoke all on public.cashia_orders from anon, authenticated;
grant insert on public.cashia_orders to anon, authenticated;
grant select, update, delete on public.cashia_orders to authenticated;

-- A buyer looks up only their own ticket, by its secret code.
create or replace function public.get_cashia_ticket(ticket_code text)
returns table (code text, tier text, quantity int, total int, name text, status text, checked_in boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.code, o.tier, o.quantity, o.total, o.name, o.status, o.checked_in_at is not null, o.created_at
  from public.cashia_orders o
  where o.code = upper(trim(ticket_code));
$$;
revoke execute on function public.get_cashia_ticket(text) from public;
grant execute on function public.get_cashia_ticket(text) to anon, authenticated;
