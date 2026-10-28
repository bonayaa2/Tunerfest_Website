-- TunerFest / Shift Nation: database, photo storage and admin access.
-- Run this once in Supabase: Dashboard → SQL Editor → New query → paste → Run.

-- 1. Applications (show cars and vendor booths)
create table if not exists public.registrations (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  type           text not null check (type in ('car', 'booth')),
  status         text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  name           text not null check (char_length(name) between 1 and 200),
  email          text not null check (char_length(email) between 3 and 200),
  phone          text not null check (char_length(phone) between 1 and 50),
  instagram      text check (char_length(instagram) <= 100),
  car            text check (char_length(car) <= 200),
  photo_path     text check (char_length(photo_path) <= 300),
  business       text check (char_length(business) <= 200),
  booth_category text check (char_length(booth_category) <= 100),
  booth_size     text check (char_length(booth_size) <= 50),
  power          boolean,
  notes          text check (char_length(notes) <= 2000),
  reviewed_at    timestamptz
);
alter table public.registrations enable row level security;

-- 2. Who counts as an admin (add rows here for each team member)
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);
alter table public.admins enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

drop policy if exists "admins see themselves" on public.admins;
create policy "admins see themselves" on public.admins
  for select to authenticated using (user_id = auth.uid());

-- 3. Rules for applications
-- Anyone may send an application, but only as a new, pending one.
drop policy if exists "anyone can apply" on public.registrations;
create policy "anyone can apply" on public.registrations
  for insert to anon, authenticated
  with check (status = 'pending' and reviewed_at is null);

-- Only admins can see, review or remove applications.
drop policy if exists "admins read" on public.registrations;
create policy "admins read" on public.registrations
  for select to authenticated using (public.is_admin());
drop policy if exists "admins review" on public.registrations;
create policy "admins review" on public.registrations
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins remove" on public.registrations;
create policy "admins remove" on public.registrations
  for delete to authenticated using (public.is_admin());

-- Table privileges for the website (newer projects don't grant these automatically).
-- The policies above still decide which rows each visitor can touch.
revoke all on public.admins from anon, authenticated;
revoke all on public.registrations from anon, authenticated;
grant select on public.admins to authenticated;
grant insert on public.registrations to anon, authenticated;
grant select, update, delete on public.registrations to authenticated;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- 4. Private photo storage (JPEG only, 5 MB max)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('car-photos', 'car-photos', false, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

drop policy if exists "anyone can upload car photos" on storage.objects;
create policy "anyone can upload car photos" on storage.objects
  for insert to anon, authenticated with check (bucket_id = 'car-photos');
drop policy if exists "admins view car photos" on storage.objects;
create policy "admins view car photos" on storage.objects
  for select to authenticated using (bucket_id = 'car-photos' and public.is_admin());
drop policy if exists "admins delete car photos" on storage.objects;
create policy "admins delete car photos" on storage.objects
  for delete to authenticated using (bucket_id = 'car-photos' and public.is_admin());

-- 5. Make someone an admin (after creating their login under Authentication → Users):
--   insert into public.admins (user_id)
--   select id from auth.users where email = 'you@example.com';
