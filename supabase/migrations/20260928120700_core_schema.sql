-- Start And Shift — schéma principal
-- Conventions : montants en FCFA (XOF, entiers), dates en timestamptz (UTC = heure de Lomé).

create extension if not exists pgcrypto with schema extensions;

create type public.app_role as enum ('client', 'creative', 'admin');
create type public.creative_kind as enum ('static', 'video');
create type public.plan_status as enum ('generating', 'ready', 'failed');
create type public.request_status as enum (
  'awaiting_payment',
  'received',
  'in_progress',
  'to_validate',
  'delivered',
  'canceled'
);
create type public.request_funding as enum ('free_offer', 'quota', 'bonus', 'paid');
create type public.subscription_status as enum ('active', 'past_due');
create type public.payment_purpose as enum ('subscription', 'creative_unit', 'express_fee', 'source_files', 'identity_kit');
create type public.payment_status as enum ('pending', 'succeeded', 'failed', 'canceled', 'refunded');
create type public.whatsapp_status as enum ('skipped', 'pending', 'sent', 'failed');

create table public.tiers (
  code text primary key check (code in ('free', 'pro', 'max')),
  name text not null,
  price_fcfa integer not null check (price_fcfa >= 0),
  static_quota integer not null default 0 check (static_quota >= 0),
  video_quota integer not null default 0 check (video_quota >= 0),
  regen_quota integer not null default 0 check (regen_quota >= 0),
  multi_brand boolean not null default false,
  features text[] not null default '{}',
  sort integer not null default 0,
  updated_at timestamptz not null default now()
);

create table public.creative_types (
  code text primary key,
  name text not null,
  description text not null default '',
  kind public.creative_kind not null,
  delay_hours integer not null check (delay_hours > 0),
  price_fcfa integer not null check (price_fcfa >= 0),
  active boolean not null default true,
  sort integer not null default 0,
  updated_at timestamptz not null default now()
);

create table public.settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  email text,
  phone text,
  city text,
  role public.app_role not null default 'client',
  team_title text,
  is_available boolean not null default true,
  whatsapp_notifications boolean not null default true,
  referral_code text not null unique,
  referred_by uuid references public.profiles (id) on delete set null,
  bonus_static integer not null default 0 check (bonus_static >= 0),
  active_brand_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_role_idx on public.profiles (role) where role <> 'client';
create index profiles_phone_idx on public.profiles (phone);

create table public.brands (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  activity text,
  domain text,
  city text,
  colors text[] not null default '{}',
  logo_path text,
  photo_paths text[] not null default '{}',
  differentiator text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index brands_owner_idx on public.brands (owner_id);
alter table public.profiles
  add constraint profiles_active_brand_fk foreign key (active_brand_id) references public.brands (id) on delete set null;

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references public.profiles (id) on delete cascade,
  brand_id uuid references public.brands (id) on delete set null,
  parent_plan_id uuid references public.plans (id) on delete set null,
  claim_token_hash text,
  answers jsonb not null,
  status public.plan_status not null default 'generating',
  content jsonb,
  model text,
  input_tokens integer,
  output_tokens integer,
  error text,
  is_current boolean not null default true,
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles (id) on delete set null,
  review_note text,
  pdf_path text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index plans_owner_idx on public.plans (owner_id, created_at desc);
create index plans_expires_idx on public.plans (expires_at) where owner_id is null;

create table public.plan_generation_log (
  id bigint generated always as identity primary key,
  ip_hash text not null,
  user_id uuid,
  plan_id uuid,
  created_at timestamptz not null default now()
);
create index plan_generation_log_ip_idx on public.plan_generation_log (ip_hash, created_at desc);
create index plan_generation_log_created_idx on public.plan_generation_log (created_at desc);

create table public.subscriptions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  tier text not null default 'free' references public.tiers (code),
  status public.subscription_status not null default 'active',
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  free_offer_used boolean not null default false,
  reminder_sent_for timestamptz,
  has_paid_once boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.usage_periods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  tier text not null references public.tiers (code),
  period_start timestamptz not null,
  period_end timestamptz not null,
  static_allowance integer not null default 0,
  video_allowance integer not null default 0,
  carried_static integer not null default 0,
  carried_video integer not null default 0,
  static_used integer not null default 0,
  video_used integer not null default 0,
  regen_allowance integer not null default 0,
  regen_used integer not null default 0,
  created_at timestamptz not null default now(),
  check (period_end > period_start)
);
create index usage_periods_user_idx on public.usage_periods (user_id, period_end desc);

create sequence public.request_ref_seq start 1001;

create table public.requests (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique default ('SAS-' || nextval('public.request_ref_seq')),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  brand_id uuid references public.brands (id) on delete set null,
  plan_id uuid references public.plans (id) on delete set null,
  type_code text not null references public.creative_types (code),
  kind public.creative_kind not null,
  title text not null check (char_length(title) between 1 and 140),
  brief text not null check (char_length(brief) between 1 and 4000),
  networks text[] not null default '{}',
  express boolean not null default false,
  status public.request_status not null,
  funding public.request_funding not null,
  usage_period_id uuid references public.usage_periods (id) on delete set null,
  amount_due_fcfa integer not null default 0,
  assignee_id uuid references public.profiles (id) on delete set null,
  revisions_included integer not null default 2,
  revisions_used integer not null default 0,
  portfolio_allowed boolean not null default false,
  received_at timestamptz,
  due_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index requests_owner_idx on public.requests (owner_id, created_at desc);
create index requests_status_idx on public.requests (status, due_at);
create index requests_assignee_idx on public.requests (assignee_id) where status in ('received', 'in_progress', 'to_validate');

create table public.request_files (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests (id) on delete cascade,
  uploaded_by uuid references public.profiles (id) on delete set null,
  kind text not null check (kind in ('brief_asset', 'deliverable', 'source')),
  storage_path text not null unique,
  file_name text not null,
  mime_type text,
  size_bytes bigint,
  format_label text,
  version integer not null default 1,
  created_at timestamptz not null default now()
);
create index request_files_request_idx on public.request_files (request_id, created_at);

create table public.request_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests (id) on delete cascade,
  author_id uuid references public.profiles (id) on delete set null,
  kind text not null default 'message' check (kind in ('message', 'revision', 'system')),
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index request_messages_request_idx on public.request_messages (request_id, created_at);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  purpose public.payment_purpose not null,
  tier text references public.tiers (code),
  request_id uuid references public.requests (id) on delete set null,
  amount_fcfa integer not null check (amount_fcfa > 0),
  currency text not null default 'XOF',
  provider text not null default 'fedapay',
  provider_txn_id text unique,
  method text,
  status public.payment_status not null default 'pending',
  failure_reason text,
  paid_at timestamptz,
  refunded_at timestamptz,
  raw jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((purpose = 'subscription') = (tier is not null))
);
create index payments_user_idx on public.payments (user_id, created_at desc);
create index payments_status_idx on public.payments (status, created_at desc);

create sequence public.invoice_number_seq start 1;

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  number text not null unique,
  payment_id uuid not null unique references public.payments (id) on delete restrict,
  user_id uuid not null references public.profiles (id) on delete cascade,
  label text not null,
  amount_fcfa integer not null,
  customer jsonb not null default '{}',
  pdf_path text,
  issued_at timestamptz not null default now()
);
create index invoices_user_idx on public.invoices (user_id, issued_at desc);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  type text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}',
  read_at timestamptz,
  whatsapp_status public.whatsapp_status not null default 'skipped',
  whatsapp_attempts integer not null default 0,
  whatsapp_error text,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_whatsapp_idx on public.notifications (created_at) where whatsapp_status = 'pending';

create table public.referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references public.profiles (id) on delete cascade,
  referee_id uuid not null unique references public.profiles (id) on delete cascade,
  rewarded_at timestamptz,
  created_at timestamptz not null default now(),
  check (referrer_id <> referee_id)
);
create index referrals_referrer_idx on public.referrals (referrer_id);

create table public.otp_channel_prefs (
  phone text primary key,
  channel text not null check (channel in ('whatsapp', 'sms')),
  updated_at timestamptz not null default now()
);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['tiers','creative_types','settings','profiles','brands','plans','subscriptions','requests','payments']
  loop
    execute format('create trigger %I_touch before update on public.%I for each row execute function public.touch_updated_at()', t, t);
  end loop;
end $$;
