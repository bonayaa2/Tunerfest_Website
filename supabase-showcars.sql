-- Public "Show cars" page: visitors see approved show cars (car name and photo only).
-- Owner names, emails and phone numbers stay private. Applied to the live project.

create or replace function public.show_cars()
returns table (id uuid, car text, photo_path text, reviewed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.car, r.photo_path, r.reviewed_at
  from public.registrations r
  where r.type = 'car' and r.status = 'approved'
  order by r.reviewed_at desc nulls last, r.created_at desc;
$$;
revoke execute on function public.show_cars() from public;
grant execute on function public.show_cars() to anon, authenticated;

-- True only for the photo of an approved show car.
create or replace function public.is_show_car_photo(object_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.registrations
                 where photo_path = object_name and type = 'car' and status = 'approved');
$$;
revoke execute on function public.is_show_car_photo(text) from public;
grant execute on function public.is_show_car_photo(text) to anon, authenticated;

-- Anyone may view the photo of an approved car; every other photo stays admin-only.
drop policy if exists "anyone views approved car photos" on storage.objects;
create policy "anyone views approved car photos" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'car-photos' and public.is_show_car_photo(name));
