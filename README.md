# TunerFest by Shift Nation

Website for Tuner Fest 6.0: Sunday, November 29, 2026 at Galleria Mall, Karen, Nairobi.

## What's here

| Path | What it is |
|---|---|
| `site/` | **The website to upload to your web host.** Upload everything inside it, keeping the folders. |
| `index.html` | Source page (also used for the claude.ai preview). |
| `assets/` | Logos, hero photo, event poster, gallery photos and the Supabase client library. |
| `gallery.json` | List of gallery photos and captions. |
| `supabase-setup.sql` | One-time database, photo storage and admin access setup for Supabase. |
| `tools/add_photos.py` | Adds a batch of photos to the gallery. |
| `tools/build_site.sh` | Rebuilds `site/` from `index.html` and `assets/`. |

## Pages

Home, Tickets, Register (show car or vendor booth), Events, Gallery, the Cashia KES 200 offer, and the team admin panel at `/admin`.

## Admin login and registrations

On the live site, registrations, car photos and the admin login use Supabase
(project `kzafeanvmrlmshhbgbbz`). The project URL and publishable key are set in `index.html`;
the access rules in `supabase-setup.sql` keep applications private to admins.

Make a team member an admin (after creating their user under Authentication → Users):

```sql
insert into public.admins (user_id)
select id from auth.users where email = 'person@example.com';
```

## Still to add

- Cashia sign-up and checkout links (`CASHIA_LINKS` in `index.html`)
- Social media profile links in the footer
