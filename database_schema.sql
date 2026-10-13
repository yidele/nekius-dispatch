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
