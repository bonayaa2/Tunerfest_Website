-- Cashia paused: the website no longer sells Cashia tickets.
-- The cashia_orders table and its rows are kept; only public access is switched off.
-- To bring Cashia back, restore the site from the `cashia-version` branch and run the
-- "turn back on" lines at the bottom.
drop policy if exists "anyone can order" on public.cashia_orders;
revoke insert on public.cashia_orders from anon, authenticated;
revoke execute on function public.get_cashia_ticket(text) from anon, authenticated;

-- Turn back on:
--   create policy "anyone can order" on public.cashia_orders for insert to anon, authenticated
--     with check (status = 'pending' and paid_at is null and checked_in_at is null and cashia_ref is null);
--   grant insert on public.cashia_orders to anon, authenticated;
--   grant execute on function public.get_cashia_ticket(text) to anon, authenticated;
