-- Nekius Dispatch — database schema (Supabase / Postgres)
-- This matches what is running on the live project (applied 2026-10-13).
-- The earlier prototype's empty tables were moved into the `legacy` schema
-- (not exposed to the app) instead of being deleted.
--
-- Differences from a "textbook" setup, on purpose:
--  * Foreign keys have no ON DELETE actions. Clients/volunteers/drivers are
--    set Inactive rather than deleted, so this never matters in the app.
--  * Used invites are kept; the app only lists invites with no account yet.

-- =========================================================
-- Tables
-- =========================================================
create table profiles (
  id uuid primary key references auth.users(id),
  email text not null,
  role text not null default 'dispatcher' check (role in ('editor','dispatcher')),
  created_at timestamptz not null default now()
);

create table invites (
  email text primary key,
  role text not null default 'dispatcher' check (role in ('editor','dispatcher')),
  invited_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  note text,
  is_mashilach boolean not null default false,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table volunteers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  note text,
  status text not null default 'active' check (status in ('active','inactive','temporary_inactive')),
  temp_inactive_from date,
  temp_inactive_until date,
  bag_capacity text check (bag_capacity in ('1','2','3','4plus')),
  wash_frequency text check (wash_frequency in ('once_monthly','twice_monthly')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table drivers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  email text,
  address text,
  contact_sms boolean not null default false,
  contact_whatsapp boolean not null default false,
  status text not null default 'active' check (status in ('active','inactive')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table requests (
  id bigint generated always as identity primary key,
  client_id uuid references clients(id),
  volunteer_id uuid references volunteers(id),
  pickup_driver_id uuid references drivers(id),
  return_driver_id uuid references drivers(id),
  bags integer check (bags between 1 and 50), -- 4 is shown as "4+"
  requested_for timestamptz,
  status text not null default 'open' check (status in (
    'open','assigned','posted_pickup','delivered','finished',
    'posted_return','completed','not_covered','cancelled'
  )),
  notes text,
  completed_at timestamptz, -- set automatically when status becomes 'completed'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table app_settings (
  id int primary key default 1 check (id = 1),
  mashilach_address text,
  mashilach_note text,
  default_bag_options jsonb,
  post_message_template jsonb not null default '{"before":"","between":" to ","after":""}',
  driver_message_pickup_template text not null default
    E'Laundry pickup — Request #{request_id}\n\nPick up from: {client_name}\n{client_address}\n{client_note}\nBags: {bags}\nWhen: {requested_for}\n\nDeliver to: {volunteer_name}\n{volunteer_address}\n{volunteer_note}',
  driver_message_return_template text not null default
    E'Laundry return — Request #{request_id}\n\nPick up from: {volunteer_name}\n{volunteer_address}\n{volunteer_note}\n\nDeliver to: {client_name}\n{client_address}\n{client_note}'
);
insert into app_settings (id, mashilach_address, mashilach_note)
values (1, '770 Eastern Parkway, Brooklyn, NY 11213', '');

-- =========================================================
-- Timestamps
-- =========================================================
create function touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create function touch_request()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  if new.status = 'completed' and (tg_op = 'INSERT' or old.status is distinct from 'completed') then
    new.completed_at := now();
  elsif new.status <> 'completed' then
    new.completed_at := null;
  end if;
  return new;
end;
$$;

create trigger clients_touch before update on clients for each row execute function touch_updated_at();
create trigger volunteers_touch before update on volunteers for each row execute function touch_updated_at();
create trigger drivers_touch before update on drivers for each row execute function touch_updated_at();
create trigger requests_touch before insert or update on requests for each row execute function touch_request();

-- =========================================================
-- Access helpers (security definer so RLS policies can call them
-- without recursing into the profiles policies)
-- =========================================================
create function is_known_user()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid());
$$;

create function is_editor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'editor');
$$;

-- First-ever signup becomes Editor; everyone else must be on the invite list.
-- Used invites stay in the table; the app hides invites that already have an account.
create function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  invited_role text;
begin
  if not exists (select 1 from profiles) then
    insert into profiles (id, email, role) values (new.id, new.email, 'editor');
    return new;
  end if;

  select role into invited_role from invites where lower(email) = lower(new.email);
  if invited_role is null then
    raise exception 'NOT_INVITED: This email has not been invited.';
  end if;

  insert into profiles (id, email, role) values (new.id, new.email, invited_role);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

revoke execute on function handle_new_user() from public, anon, authenticated;
revoke execute on function is_editor() from public, anon;
revoke execute on function is_known_user() from public, anon;
grant execute on function handle_new_user() to supabase_auth_admin;
grant select, insert on profiles to supabase_auth_admin;
grant select on invites to supabase_auth_admin;

-- =========================================================
-- Row Level Security
-- =========================================================
alter table profiles enable row level security;
alter table invites enable row level security;
alter table clients enable row level security;
alter table volunteers enable row level security;
alter table drivers enable row level security;
alter table requests enable row level security;
alter table app_settings enable row level security;

create policy profiles_select on profiles for select to authenticated using (is_known_user());
create policy profiles_manage_editor on profiles for all to authenticated using (is_editor()) with check (is_editor());

create policy invites_all_editor on invites for all to authenticated using (is_editor()) with check (is_editor());

create policy clients_all_known on clients for all to authenticated using (is_known_user()) with check (is_known_user());
create policy volunteers_all_known on volunteers for all to authenticated using (is_known_user()) with check (is_known_user());
create policy drivers_all_known on drivers for all to authenticated using (is_known_user()) with check (is_known_user());
create policy requests_all_known on requests for all to authenticated using (is_known_user()) with check (is_known_user());

create policy settings_select_known on app_settings for select to authenticated using (is_known_user());
create policy settings_update_editor on app_settings for update to authenticated using (is_editor()) with check (is_editor());

-- =========================================================
-- 2026-10-13: availability, private notes, dispatcher names,
-- more wash frequencies
-- =========================================================
alter table volunteers add column if not exists available_days smallint[] not null default '{}'; -- 0 = Sunday … 6 = Saturday
alter table volunteers add column if not exists private_note text; -- dispatchers only; `note` is the address note drivers see
alter table clients add column if not exists private_note text;
alter table profiles add column if not exists name text;
alter table requests add column if not exists created_by uuid default auth.uid() references profiles(id);

alter table volunteers drop constraint volunteers_wash_frequency_check;
alter table volunteers add constraint volunteers_wash_frequency_check
  check (wash_frequency in ('weekly','three_monthly','twice_monthly','once_monthly'));

-- Lets a signed-in user set their own display name (and nothing else about their profile)
create or replace function set_my_name(new_name text)
returns void language sql security definer set search_path = public as $$
  update profiles set name = nullif(trim(new_name), '') where id = auth.uid();
$$;
revoke execute on function set_my_name(text) from public, anon;
grant execute on function set_my_name(text) to authenticated;

-- handle_new_user now also stores the name typed on the sign-up screen
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  invited_role text;
  display_name text := nullif(trim(new.raw_user_meta_data->>'name'), '');
begin
  if not exists (select 1 from profiles) then
    insert into profiles (id, email, role, name) values (new.id, new.email, 'editor', display_name);
    return new;
  end if;

  select role into invited_role from invites where lower(email) = lower(new.email);
  if invited_role is null then
    raise exception 'NOT_INVITED: This email has not been invited.';
  end if;

  insert into profiles (id, email, role, name) values (new.id, new.email, invited_role, display_name);
  return new;
end;
$$;

-- 2026-10-13: who created each client / volunteer / driver
alter table clients add column if not exists created_by uuid default auth.uid() references profiles(id);
alter table volunteers add column if not exists created_by uuid default auth.uid() references profiles(id);
alter table drivers add column if not exists created_by uuid default auth.uid() references profiles(id);

-- =========================================================
-- 2026-10-13: Recurring requests
-- Editors create them; every signed-in user can see them and fill in
-- the volunteer / drivers. An hourly job (pg_cron) and the app on load
-- call generate_recurring_requests(), which creates the real request for
-- today and tomorrow (New York time) exactly once per date.
-- =========================================================
create table recurring_requests (
  id bigint generated always as identity primary key,
  client_id uuid not null references clients(id),
  volunteer_id uuid references volunteers(id),
  pickup_driver_id uuid references drivers(id),
  return_driver_id uuid references drivers(id),
  bags integer not null default 1 check (bags between 1 and 50),
  days smallint[] not null default '{}',          -- 0 = Sunday … 5 = Friday
  time_of_day time not null default '10:00',      -- New York time
  notes text,
  active boolean not null default true,
  created_by uuid default auth.uid() references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table recurring_runs (
  recurring_id bigint not null references recurring_requests(id) on delete cascade,
  run_date date not null,
  request_id bigint references requests(id) on delete set null,
  primary key (recurring_id, run_date)
);
alter table requests add column recurring_id bigint references recurring_requests(id) on delete set null;
create trigger recurring_touch before update on recurring_requests for each row execute function touch_updated_at();

create function recurring_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not is_editor() and (
    new.client_id is distinct from old.client_id or new.bags is distinct from old.bags or
    new.days is distinct from old.days or new.time_of_day is distinct from old.time_of_day or
    new.notes is distinct from old.notes or new.active is distinct from old.active
  ) then
    raise exception 'Only an editor can change a recurring request.';
  end if;
  return new;
end;
$$;
create trigger recurring_guard before update on recurring_requests for each row execute function recurring_guard();

alter table recurring_requests enable row level security;
alter table recurring_runs enable row level security;
create policy recurring_select_known on recurring_requests for select to authenticated using (is_known_user());
create policy recurring_update_known on recurring_requests for update to authenticated using (is_known_user()) with check (is_known_user());
create policy recurring_insert_editor on recurring_requests for insert to authenticated with check (is_editor());
create policy recurring_manage_editor on recurring_requests for all to authenticated using (is_editor()) with check (is_editor());
create policy runs_select_known on recurring_runs for select to authenticated using (is_known_user());

create function generate_recurring_requests() returns integer language plpgsql security definer set search_path = public as $$
declare
  rr record; d date; new_id bigint; made integer := 0;
  today date := (now() at time zone 'America/New_York')::date;
begin
  for rr in select * from recurring_requests where active loop
    foreach d in array array[today, today + 1] loop
      if extract(dow from d)::int = any(rr.days) then
        insert into recurring_runs (recurring_id, run_date) values (rr.id, d) on conflict do nothing;
        if found then
          insert into requests (client_id, volunteer_id, pickup_driver_id, return_driver_id, bags, requested_for, notes, status, created_by, recurring_id)
          values (rr.client_id, rr.volunteer_id, rr.pickup_driver_id, rr.return_driver_id, rr.bags,
                  (d + rr.time_of_day) at time zone 'America/New_York', rr.notes,
                  'open', rr.created_by, rr.id)  -- always starts as Open
          returning id into new_id;
          update recurring_runs set request_id = new_id where recurring_id = rr.id and run_date = d;
          made := made + 1;
        end if;
      end if;
    end loop;
  end loop;
  return made;
end;
$$;
revoke execute on function generate_recurring_requests() from public, anon;
grant execute on function generate_recurring_requests() to authenticated;
create extension if not exists pg_cron;
select cron.schedule('kvisa-recurring-requests', '5 * * * *', 'select public.generate_recurring_requests()');

-- =========================================================
-- 2026-10-13: repeat patterns, one-date changes and skips
-- (generate_recurring_requests above is superseded by the version below)
-- =========================================================
alter table recurring_requests add column repeat text not null default 'weekly' check (repeat in ('weekly','monthly'));
alter table recurring_requests add column interval_weeks smallint not null default 1 check (interval_weeks between 1 and 8);
alter table recurring_requests add column start_date date not null default ((now() at time zone 'America/New_York')::date);
alter table recurring_requests add column month_weeks smallint[] not null default '{}'; -- 1..4 = 1st..4th, 5 = last

create table recurring_overrides (
  recurring_id bigint not null references recurring_requests(id) on delete cascade,
  run_date date not null,
  changes jsonb not null default '{}',   -- e.g. {"volunteer_id": "...", "pickup_driver_id": null}
  skip boolean not null default false,   -- editors only (overrides_guard)
  updated_at timestamptz not null default now(),
  primary key (recurring_id, run_date)
);
alter table recurring_overrides enable row level security;
create policy overrides_select_known on recurring_overrides for select to authenticated using (is_known_user());
create policy overrides_insert_known on recurring_overrides for insert to authenticated with check (is_known_user());
create policy overrides_update_known on recurring_overrides for update to authenticated using (is_known_user()) with check (is_known_user());

create function overrides_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not is_editor() and new.skip is distinct from (case when tg_op = 'UPDATE' then old.skip else false end) then
    raise exception 'Only an editor can skip a date.';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger overrides_guard before insert or update on recurring_overrides for each row execute function overrides_guard();
-- recurring_guard() also protects repeat, interval_weeks, start_date and month_weeks (editor-only)

create function recurring_occurs(rr recurring_requests, d date) returns boolean language plpgsql immutable as $$
declare n int; wk int;
begin
  if d < rr.start_date or not (extract(dow from d)::int = any(rr.days)) then return false; end if;
  if rr.repeat = 'monthly' then
    n := (extract(day from d)::int - 1) / 7 + 1;
    return n = any(rr.month_weeks) or (5 = any(rr.month_weeks) and extract(month from d + 7) <> extract(month from d));
  end if;
  wk := ((d - extract(dow from d)::int) - (rr.start_date - extract(dow from rr.start_date)::int)) / 7;
  return wk % rr.interval_weeks = 0;
end;
$$;

create or replace function generate_recurring_requests() returns integer language plpgsql security definer set search_path = public as $$
declare
  rr recurring_requests%rowtype; ov record; d date; new_id bigint; made integer := 0; ch jsonb;
  today date := (now() at time zone 'America/New_York')::date;
begin
  for rr in select * from recurring_requests where active loop
    foreach d in array array[today, today + 1] loop
      if recurring_occurs(rr, d) then
        select * into ov from recurring_overrides where recurring_id = rr.id and run_date = d;
        if coalesce(ov.skip, false) then continue; end if;
        ch := coalesce(ov.changes, '{}');
        insert into recurring_runs (recurring_id, run_date) values (rr.id, d) on conflict do nothing;
        if found then
          insert into requests (client_id, volunteer_id, pickup_driver_id, return_driver_id, bags, requested_for, notes, status, created_by, recurring_id)
          values (rr.client_id,
                  case when ch ? 'volunteer_id' then (ch->>'volunteer_id')::uuid else rr.volunteer_id end,
                  case when ch ? 'pickup_driver_id' then (ch->>'pickup_driver_id')::uuid else rr.pickup_driver_id end,
                  case when ch ? 'return_driver_id' then (ch->>'return_driver_id')::uuid else rr.return_driver_id end,
                  rr.bags, (d + rr.time_of_day) at time zone 'America/New_York', rr.notes, 'open', rr.created_by, rr.id)
          returning id into new_id;
          update recurring_runs set request_id = new_id where recurring_id = rr.id and run_date = d;
          made := made + 1;
        end if;
      end if;
    end loop;
  end loop;
  return made;
end;
$$;

-- 2026-10-13: note field for drivers
alter table drivers add column if not exists private_note text;

-- 2026-10-13: Suspended status; only editors delete people; deleting a person keeps history
alter table clients drop constraint clients_status_check;
alter table clients add constraint clients_status_check check (status in ('active','inactive','suspended'));
alter table volunteers drop constraint volunteers_status_check;
alter table volunteers add constraint volunteers_status_check check (status in ('active','inactive','temporary_inactive','suspended'));
alter table drivers drop constraint drivers_status_check;
alter table drivers add constraint drivers_status_check check (status in ('active','inactive','suspended'));
create policy clients_delete_editor on clients as restrictive for delete to authenticated using (is_editor());
create policy volunteers_delete_editor on volunteers as restrictive for delete to authenticated using (is_editor());
create policy drivers_delete_editor on drivers as restrictive for delete to authenticated using (is_editor());
-- requests.client_id / volunteer_id / pickup_driver_id / return_driver_id: on delete set null
-- recurring_requests.client_id: on delete cascade; its volunteer / driver ids: on delete set null

-- 2026-10-16: when each person was put on a request (set by the touch_request trigger)
alter table requests add column if not exists volunteer_assigned_at timestamptz;
alter table requests add column if not exists pickup_assigned_at timestamptz;
alter table requests add column if not exists return_assigned_at timestamptz;
create or replace function touch_request() returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  if new.status = 'completed' and (tg_op = 'INSERT' or old.status is distinct from 'completed') then new.completed_at := now();
  elsif new.status <> 'completed' then new.completed_at := null; end if;
  if new.volunteer_id is null then new.volunteer_assigned_at := null;
  elsif tg_op = 'INSERT' or new.volunteer_id is distinct from old.volunteer_id then new.volunteer_assigned_at := now(); end if;
  if new.pickup_driver_id is null then new.pickup_assigned_at := null;
  elsif tg_op = 'INSERT' or new.pickup_driver_id is distinct from old.pickup_driver_id then new.pickup_assigned_at := now(); end if;
  if new.return_driver_id is null then new.return_assigned_at := null;
  elsif tg_op = 'INSERT' or new.return_driver_id is distinct from old.return_driver_id then new.return_assigned_at := now(); end if;
  return new;
end;
$$;

-- 2026-10-16: "every N weeks" counts from the first chosen day on or after the start date
create or replace function recurring_occurs(rr recurring_requests, d date) returns boolean language plpgsql immutable as $$
declare n int; wk int; first_day date;
begin
  if d < rr.start_date or not (extract(dow from d)::int = any(rr.days)) then return false; end if;
  if rr.repeat = 'monthly' then
    n := (extract(day from d)::int - 1) / 7 + 1;
    return n = any(rr.month_weeks) or (5 = any(rr.month_weeks) and extract(month from d + 7) <> extract(month from d));
  end if;
  select rr.start_date + min((dd - extract(dow from rr.start_date)::int + 7) % 7) into first_day from unnest(rr.days) dd;
  wk := ((d - extract(dow from d)::int) - (first_day - extract(dow from first_day)::int)) / 7;
  return wk % rr.interval_weeks = 0;
end;
$$;

-- 2026-10-18: different people on each weekday of a recurring request
-- day_people = {"0": {"volunteer_id": "..."}, "3": {...}}; empty = the same people every day.
-- generate_recurring_requests() picks: one-time change for the date > that weekday's people > the usual people.
alter table recurring_requests add column if not exists day_people jsonb not null default '{}';

-- ============================================================
-- Recurring requests now appear at 7:00 AM (New York) on their own day,
-- instead of from the day before. Same function, only the dates changed:
--   if local time < 07:00 → create nothing; otherwise create only today's.
-- (applied as migration recurring_opens_7am_same_day)
-- ============================================================

-- ============================================================
-- Messages (migration messaging_tables): texting inside the app.
-- Nothing is actually sent until a texting company is connected (app_settings.sms_connected).
--   contacts       people to text who aren't drivers/volunteers/clients
--   contact_lists  saved groups; members = [{"kind":"driver","id":"..."}]
--   posts          one post of open calls sent to a group
--   messages       every text in/out; phone = last 10 digits; status not_sent/queued/sent/delivered/failed/received
--   post_numbers   a call's number for the day (1, 2, 3 …), unique per day
--   call_offers    a driver replying with a call's number; waiting/accepted/declined
--   app_settings.post_header / post_footer  first and last line of a post
-- All tables: row-level security, any known user (is_known_user()).
-- ============================================================

-- ============================================================
-- Test mode + incoming texts (migration messaging_receive_and_test_mode)
--   app_settings.sms_test: everything works as if connected, nothing leaves the app (messages.status = 'test')
--   receive_text(phone, body): saves an incoming text; a reply made only of call numbers ("2", "#3", "2 and 3",
--   "I'll take 4") creates a waiting call_offer for each open call, and an automatic answer for a taken or
--   unknown number. The texting company's incoming-text hook will call this same function.
-- ============================================================

-- ============================================================
-- Second volunteer on a call (migration second_volunteer)
alter table requests add column if not exists volunteer2_id uuid references volunteers(id) on delete set null;
alter table requests add column if not exists volunteer2_assigned_at timestamptz;
-- touch_request() also stamps volunteer2_assigned_at, the same way as the other people
-- ============================================================

-- ============================================================
-- Live updates (migration live_updates): open apps hear every change; row-level security still applies
alter publication supabase_realtime add table
  clients, volunteers, drivers, requests, recurring_requests, recurring_overrides, profiles, app_settings,
  contacts, contact_lists, messages, posts, post_numbers, call_offers;
-- ============================================================

-- ============================================================
-- receive_text() also understands "done" (migration receive_text_done):
--   "done", "delivered", "dropped off", "done 2" … from a driver moves their call on
--   (Posted · Pickup → Delivered, Posted · Return → Completed) and answers "Thank you! Marked as done."
--   With more than one call open and no number, it answers asking which one.
-- ============================================================

-- ============================================================
-- A text sent to a whole list carries the list's id, so the list has its own chat (migration messages_list_key)
alter table messages add column if not exists list_key text;
-- ============================================================

-- ============================================================
-- Automatic replies (migration auto_assign_replies)
--   drivers.needs_approval: an editor's setting; that driver's replies wait for a dispatcher to Accept
--   map_url(), render_template(), driver_message(): the database writes the same driver message as the app
--   receive_text(): a driver replying with an open call's number gets it right away (assigned, driver message sent,
--   anyone waiting told it was taken). Drivers needing approval and unknown numbers wait, unless another driver asks first.
-- ============================================================
