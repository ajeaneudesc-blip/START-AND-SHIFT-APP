revoke execute on function public.setting(text), public.generate_referral_code(), public.fr_datetime(timestamptz)
  from anon, authenticated;

insert into public.tiers (code, name, price_fcfa, static_quota, video_quota, regen_quota, multi_brand, sort, features) values
  ('free', 'Gratuit', 0, 0, 0, 0, false, 0, array[
    'Votre plan complet (En clair + Détail pro)',
    '1 visuel offert, téléchargement inclus',
    'Visuels supplémentaires à l''unité (dès 5 000 F)']),
  ('pro', 'Pro', 9900, 3, 0, 1, true, 1, array[
    '3 visuels par mois',
    '1 mise à jour de votre plan par mois',
    'Plusieurs marques (idéal community managers)',
    'Visuels non utilisés reportés au mois suivant']),
  ('max', 'Max', 24900, 5, 1, 3, true, 2, array[
    '6 visuels par mois : 5 visuels + 1 vidéo courte',
    '3 mises à jour de votre plan par mois',
    'Plusieurs marques',
    'Visuels non utilisés reportés au mois suivant'])
on conflict (code) do nothing;

insert into public.creative_types (code, name, description, kind, delay_hours, price_fcfa, sort) values
  ('post',     'Post ou statut', 'Un visuel pour WhatsApp, Facebook, Instagram ou TikTok', 'static', 24, 5000, 0),
  ('carousel', 'Carrousel',      'Plusieurs images à faire défiler (jusqu''à 5)',          'static', 48, 7500, 1),
  ('poster',   'Affiche',        'Affiche ou flyer, pour imprimer ou partager',             'static', 72, 5000, 2),
  ('video',    'Vidéo courte',   'Vidéo de 15 à 30 secondes, format vertical',              'video', 120, 10000, 3)
on conflict (code) do nothing;

insert into public.settings (key, value) values
  ('express_multiplier', '1.5'),
  ('revisions_included', '2'),
  ('revision_delay_hours', '24'),
  ('renewal_grace_days', '3'),
  ('auto_approve_days', '5'),
  ('referral_reward_static', '1'),
  ('anonymous_plan_ttl_days', '7'),
  ('plan_limit_per_ip_per_day', '5'),
  ('plan_daily_cap', '150'),
  ('plan_review_mode', '"instant"'),
  ('support_whatsapp', '"+22800000000"'),
  ('whatsapp_template', '{"name": "sas_notification", "language": "fr"}'),
  ('whatsapp_auto', '{
    "request_received": true, "request_in_progress": false, "request_to_validate": true,
    "request_delivered": true, "new_message": true, "renewal_reminder": true,
    "payment_succeeded": true, "payment_failed": true, "payment_refunded": true,
    "subscription_ended": true, "referral_rewarded": true,
    "staff_new_request": true, "staff_revision_requested": true, "request_assigned": true,
    "staff_new_message": false, "staff_request_validated": false, "staff_request_canceled": false
  }')
on conflict (key) do nothing;

alter table public.profiles add column avatar_path text;

create or replace function public.team_public()
returns table (id uuid, first_name text, team_title text, avatar_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select id, split_part(coalesce(full_name, ''), ' ', 1), team_title, avatar_path
    from public.profiles
   where role in ('creative', 'admin') and team_title is not null
   order by full_name;
$$;
grant execute on function public.team_public() to anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('brand-assets', 'brand-assets', false, 10485760, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml']),
  ('request-files', 'request-files', false, 104857600, null),
  ('plans', 'plans', false, 10485760, array['application/pdf']),
  ('invoices', 'invoices', false, 5242880, array['application/pdf']),
  ('public-assets', 'public-assets', true, 10485760, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml', 'video/mp4'])
on conflict (id) do nothing;

create or replace function public.try_uuid(p text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return p::uuid;
exception when others then
  return null;
end;
$$;
grant execute on function public.try_uuid(text) to authenticated;

create policy brand_assets_read on storage.objects for select to authenticated
  using (bucket_id = 'brand-assets' and (
    (storage.foldername(name))[1] = (select auth.uid())::text or public.is_staff()));
create policy brand_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'brand-assets' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy brand_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'brand-assets' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy brand_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'brand-assets' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy request_files_obj_read on storage.objects for select to authenticated
  using (bucket_id = 'request-files'
         and public.can_access_request(public.try_uuid((storage.foldername(name))[1])));
create policy request_files_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'request-files' and (
    ((storage.foldername(name))[2] = 'team' and public.is_staff())
    or ((storage.foldername(name))[2] = 'client' and exists (
          select 1 from public.requests r
           where r.id = public.try_uuid((storage.foldername(name))[1]) and r.owner_id = (select auth.uid())))
  ));
create policy request_files_obj_delete on storage.objects for delete to authenticated
  using (bucket_id = 'request-files' and owner_id = (select auth.uid())::text);

create policy public_assets_admin_write on storage.objects for insert to authenticated
  with check (bucket_id = 'public-assets' and public.is_admin());
create policy public_assets_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'public-assets' and public.is_admin());
create policy public_assets_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'public-assets' and public.is_admin());

create table public.portfolio_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid references public.requests (id) on delete set null,
  title text not null,
  domain text,
  before_path text,
  after_path text not null,
  published boolean not null default false,
  sort integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.portfolio_items enable row level security;
create policy portfolio_public_read on public.portfolio_items for select to anon, authenticated
  using (published or public.is_staff());
create policy portfolio_admin_insert on public.portfolio_items for insert to authenticated
  with check (public.is_admin());
create policy portfolio_admin_update on public.portfolio_items for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy portfolio_admin_delete on public.portfolio_items for delete to authenticated
  using (public.is_admin());

create or replace function public.guard_portfolio_consent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.request_id is not null and new.published and not exists (
    select 1 from public.requests where id = new.request_id and portfolio_allowed
  ) then
    raise exception 'PORTFOLIO_CONSENT_MISSING' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger portfolio_consent before insert or update on public.portfolio_items
  for each row execute function public.guard_portfolio_consent();

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

create or replace function public.verify_cron_secret(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from vault.decrypted_secrets
     where name = 'sas_cron_secret' and decrypted_secret = p_secret
  );
$$;
revoke execute on function public.verify_cron_secret(text) from public, anon, authenticated;

create or replace function public.job_dispatch_whatsapp()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from public.notifications where whatsapp_status = 'pending') then
    return null;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'sas_project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'sas_cron_secret';
  if v_url is null or v_secret is null then
    return null;
  end if;
  return net.http_post(
    url := v_url || '/functions/v1/notify-dispatch',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
end;
$$;
revoke execute on function public.job_dispatch_whatsapp() from public, anon, authenticated;

select cron.schedule('sas-expire-subscriptions', '*/30 * * * *', $$select public.job_expire_subscriptions()$$);
select cron.schedule('sas-renewal-reminders', '0 8 * * *', $$select public.job_renewal_reminders()$$);
select cron.schedule('sas-purge', '15 3 * * *', $$select public.job_purge_anonymous_plans()$$);
select cron.schedule('sas-auto-approve', '5 * * * *', $$select public.job_auto_approve()$$);
select cron.schedule('sas-whatsapp-dispatch', '* * * * *', $$select public.job_dispatch_whatsapp()$$);
