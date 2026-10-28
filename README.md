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
| `supabase-cashia.sql` | Cashia tickets table and ticket lookup (already applied). |
| `tools/add_photos.py` | Adds a batch of photos to the gallery. |
| `tools/build_site.sh` | Rebuilds `site/` from `index.html` and `assets/`. |

## Hosting

Vercel deploys the `site/` folder (set in `vercel.json`) on every push to `main`.
After editing `index.html` or `assets/`, run `tools/build_site.sh` so `site/` is rebuilt before committing.

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

## Approval emails

Approving or declining a show car or booth in the admin panel emails the applicant from
info@shiftnation.org, through the `notify-applicant` Supabase Edge Function (`supabase/functions/`)
and Resend. It needs the `RESEND_API_KEY` secret in Supabase → Edge Functions → Secrets.

## Cashia tickets

Sold on the Cashia page, separately from Little Africa. A buyer orders, pays with Cashia using their
order code (`TF6-…`) as the reference, an admin marks the order paid in **Admin → Cashia tickets**,
and the buyer's ticket page (`/#ticket-TF6-…`) shows a QR code. At the gate, search the code and click **Check in**.

## Still to add

- Cashia sign-up link and payment details (`CASHIA_LINKS` in `index.html`)
- Automatic payment confirmation from Cashia's API (replaces marking orders paid by hand)
- Social media profile links in the footer
