-- Approval email tracking (already applied to the live project on 2026-10-28).
alter table public.registrations
  add column if not exists emailed_status text check (emailed_status in ('approved', 'declined')),
  add column if not exists emailed_at timestamptz,
  add column if not exists email_error text check (char_length(email_error) <= 500);
