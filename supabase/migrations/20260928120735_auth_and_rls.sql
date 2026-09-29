create or replace function public.current_role_of(p_user uuid)
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.profiles where id = p_user;
$$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role in ('creative', 'admin')
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

create or replace function public.can_access_request(p_request uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_staff() or exists (
    select 1 from public.requests where id = p_request and owner_id = (select auth.uid())
  );
$$;

create or replace function public.setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select value from public.settings where key = p_key;
$$;

create or replace function public.generate_referral_code()
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_code text;
begin
  loop
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
      into v_code
      from generate_series(1, 6);
    exit when not exists (select 1 from public.profiles where referral_code = v_code);
  end loop;
  return v_code;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}');
  v_referrer uuid;
begin
  if v_meta ? 'referral_code' then
    select id into v_referrer
      from public.profiles
      where referral_code = upper(trim(v_meta ->> 'referral_code'));
  end if;

  insert into public.profiles (id, full_name, email, phone, referral_code, referred_by)
  values (
    new.id,
    coalesce(v_meta ->> 'full_name', v_meta ->> 'name'),
    new.email,
    case when coalesce(new.phone, '') = '' then null else '+' || ltrim(new.phone, '+') end,
    public.generate_referral_code(),
    v_referrer
  );

  insert into public.subscriptions (user_id, tier) values (new.id, 'free');

  if v_referrer is not null then
    insert into public.referrals (referrer_id, referee_id) values (v_referrer, new.id);
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_user_contact_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles
     set email = new.email,
         phone = case when coalesce(new.phone, '') = '' then phone else '+' || ltrim(new.phone, '+') end
   where id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_contact_updated
  after update of email, phone on auth.users
  for each row execute function public.handle_user_contact_update();

create or replace function public.guard_profile_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is not null and not public.is_admin() then
    if new.role is distinct from old.role
       or new.referral_code is distinct from old.referral_code
       or new.referred_by is distinct from old.referred_by
       or new.bonus_static is distinct from old.bonus_static
       or new.team_title is distinct from old.team_title then
      raise exception 'FORBIDDEN_FIELD' using errcode = '42501';
    end if;
  end if;
  if new.active_brand_id is not null and not exists (
    select 1 from public.brands where id = new.active_brand_id and owner_id = new.id
  ) then
    raise exception 'BRAND_NOT_OWNED' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

create or replace function public.guard_brand_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_multi boolean;
begin
  select t.multi_brand into v_multi
    from public.subscriptions s join public.tiers t on t.code = s.tier
   where s.user_id = new.owner_id;

  if not coalesce(v_multi, false)
     and exists (select 1 from public.brands where owner_id = new.owner_id) then
    raise exception 'MULTI_BRAND_REQUIRES_PRO' using errcode = 'P0001',
      hint = 'Passez à l''offre Pro pour gérer plusieurs marques.';
  end if;
  return new;
end;
$$;

create trigger brands_limit before insert on public.brands
  for each row execute function public.guard_brand_limit();

create or replace function public.set_first_brand_active()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles set active_brand_id = new.id
   where id = new.owner_id and active_brand_id is null;
  return new;
end;
$$;

create trigger brands_first_active after insert on public.brands
  for each row execute function public.set_first_brand_active();

alter table public.tiers enable row level security;
alter table public.creative_types enable row level security;
alter table public.settings enable row level security;
alter table public.profiles enable row level security;
alter table public.brands enable row level security;
alter table public.plans enable row level security;
alter table public.plan_generation_log enable row level security;
alter table public.subscriptions enable row level security;
alter table public.usage_periods enable row level security;
alter table public.requests enable row level security;
alter table public.request_files enable row level security;
alter table public.request_messages enable row level security;
alter table public.payments enable row level security;
alter table public.invoices enable row level security;
alter table public.notifications enable row level security;
alter table public.referrals enable row level security;
alter table public.otp_channel_prefs enable row level security;

create policy tiers_read on public.tiers for select to anon, authenticated using (true);
create policy tiers_admin on public.tiers for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy types_read on public.creative_types for select to anon, authenticated using (true);
create policy types_admin_insert on public.creative_types for insert to authenticated
  with check (public.is_admin());
create policy types_admin_update on public.creative_types for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy settings_staff_read on public.settings for select to authenticated using (public.is_staff());
create policy settings_admin_write on public.settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy settings_admin_insert on public.settings for insert to authenticated
  with check (public.is_admin());

create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_staff());
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = (select auth.uid()) or public.is_admin())
  with check (id = (select auth.uid()) or public.is_admin());

create policy brands_read on public.brands for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_staff());
create policy brands_insert on public.brands for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy brands_update on public.brands for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy brands_delete on public.brands for delete to authenticated
  using (owner_id = (select auth.uid()));

create policy plans_read on public.plans for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_staff());
create policy plans_staff_update on public.plans for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

create policy subscriptions_read on public.subscriptions for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff());
create policy usage_read on public.usage_periods for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff());

create policy requests_read on public.requests for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_staff());
create policy requests_staff_update on public.requests for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

create policy request_files_read on public.request_files for select to authenticated
  using (public.can_access_request(request_id));
create policy request_files_insert on public.request_files for insert to authenticated
  with check (
    uploaded_by = (select auth.uid())
    and (
      (public.is_staff() and kind in ('deliverable', 'source'))
      or (kind = 'brief_asset' and exists (
            select 1 from public.requests r
             where r.id = request_id and r.owner_id = (select auth.uid())
               and r.status in ('awaiting_payment', 'received', 'in_progress')))
    )
  );
create policy request_files_delete on public.request_files for delete to authenticated
  using (uploaded_by = (select auth.uid()) or public.is_admin());

create policy request_messages_read on public.request_messages for select to authenticated
  using (public.can_access_request(request_id));
create policy request_messages_insert on public.request_messages for insert to authenticated
  with check (
    author_id = (select auth.uid()) and kind = 'message'
    and public.can_access_request(request_id)
  );

create policy payments_read on public.payments for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff());
create policy invoices_read on public.invoices for select to authenticated
  using (user_id = (select auth.uid()) or public.is_staff());

create policy notifications_read on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_mark_read on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy referrals_read on public.referrals for select to authenticated
  using (referrer_id = (select auth.uid()) or referee_id = (select auth.uid()) or public.is_staff());

revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;
