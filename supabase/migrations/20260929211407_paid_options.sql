-- Options payantes : kit identité express (15 000 F) et fichiers sources (5 000 F par visuel).
-- Prix modifiables dans le back-office (creative_types / settings).

-- Kit identité : un type de demande toujours payant (ni offert, ni dans le quota, ni bonus)
alter table public.creative_types add column paid_only boolean not null default false;
insert into public.creative_types (code, name, description, kind, delay_hours, price_fcfa, sort, paid_only) values
  ('identity_kit', 'Kit identité express', 'Logo, couleurs et polices pour démarrer, si vous n''avez pas encore de logo', 'static', 120, 15000, 10, true)
on conflict (code) do nothing;

-- Fichiers sources : achat par visuel, une fois le visuel prêt
insert into public.settings (key, value) values ('source_files_price_fcfa', '5000') on conflict (key) do nothing;
alter table public.requests add column source_files_paid boolean not null default false;

-- Notification équipe (WhatsApp activé) quand des sources sont payées
update public.settings set value = value || '{"staff_source_files_paid": true}' where key = 'whatsapp_auto';

create or replace function public.create_request(
  p_type_code text,
  p_title text,
  p_brief text,
  p_networks text[] default '{}',
  p_express boolean default false,
  p_brand_id uuid default null,
  p_plan_id uuid default null
)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_type public.creative_types;
  v_sub public.subscriptions;
  v_period public.usage_periods;
  v_brand uuid := p_brand_id;
  v_bonus integer;
  v_multiplier numeric := coalesce((public.setting('express_multiplier') #>> '{}')::numeric, 1.5);
  v_revisions integer := coalesce((public.setting('revisions_included') #>> '{}')::integer, 2);
  v_funding public.request_funding;
  v_amount integer := 0;
  v_status public.request_status;
  v_req public.requests;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501';
  end if;

  select * into v_type from public.creative_types where code = p_type_code and active;
  if not found then
    raise exception 'UNKNOWN_CREATIVE_TYPE' using errcode = 'P0001';
  end if;

  if v_brand is null then
    select active_brand_id into v_brand from public.profiles where id = v_uid;
  end if;
  if v_brand is null or not exists (select 1 from public.brands where id = v_brand and owner_id = v_uid) then
    raise exception 'BRAND_REQUIRED' using errcode = 'P0001',
      hint = 'Complétez votre profil de marque (logo, couleurs) avant de commander.';
  end if;
  if p_plan_id is not null and not exists (select 1 from public.plans where id = p_plan_id and owner_id = v_uid) then
    raise exception 'PLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_sub from public.subscriptions where user_id = v_uid for update;
  v_period := public.current_usage_period(v_uid);
  select bonus_static into v_bonus from public.profiles where id = v_uid for update;

  if v_type.paid_only then
    v_funding := 'paid';  -- ex. kit identité : jamais inclus dans l'offre ni le quota
  elsif not v_sub.free_offer_used and v_type.kind = 'static' then
    v_funding := 'free_offer';
    update public.subscriptions set free_offer_used = true where user_id = v_uid;
  elsif v_period.id is not null and v_type.kind = 'static'
        and v_period.static_used < v_period.static_allowance + v_period.carried_static then
    v_funding := 'quota';
    update public.usage_periods set static_used = static_used + 1 where id = v_period.id;
  elsif v_period.id is not null and v_type.kind = 'video'
        and v_period.video_used < v_period.video_allowance + v_period.carried_video then
    v_funding := 'quota';
    update public.usage_periods set video_used = video_used + 1 where id = v_period.id;
  elsif v_type.kind = 'static' and v_bonus > 0 then
    v_funding := 'bonus';
    update public.profiles set bonus_static = bonus_static - 1 where id = v_uid;
  else
    v_funding := 'paid';
  end if;

  if v_funding = 'paid' then
    v_amount := round(v_type.price_fcfa * (case when p_express then v_multiplier else 1 end));
  elsif p_express then
    v_amount := round(v_type.price_fcfa * (v_multiplier - 1));
  end if;
  v_status := case when v_amount > 0 then 'awaiting_payment' else 'received' end;

  insert into public.requests (
    owner_id, brand_id, plan_id, type_code, kind, title, brief, networks, express,
    status, funding, usage_period_id, amount_due_fcfa, revisions_included
  ) values (
    v_uid, v_brand, p_plan_id, v_type.code, v_type.kind, trim(p_title), trim(p_brief),
    coalesce(p_networks, '{}'), coalesce(p_express, false),
    v_status, v_funding, case when v_funding = 'quota' then v_period.id end, v_amount, v_revisions
  )
  returning * into v_req;

  return v_req;
end;
$$;

create or replace function public.create_payment(
  p_user uuid, p_purpose public.payment_purpose, p_tier text, p_request_id uuid, p_method text
)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_amount integer;
  v_req public.requests;
  v_pay public.payments;
begin
  if p_purpose = 'subscription' then
    select price_fcfa into v_amount from public.tiers where code = p_tier and code <> 'free';
    if v_amount is null then
      raise exception 'UNKNOWN_TIER' using errcode = 'P0001';
    end if;
  elsif p_purpose in ('creative_unit', 'express_fee', 'identity_kit') then
    select * into v_req from public.requests where id = p_request_id and owner_id = p_user;
    if not found then
      raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_req.status <> 'awaiting_payment' or v_req.amount_due_fcfa <= 0 then
      raise exception 'NOTHING_TO_PAY' using errcode = 'P0001';
    end if;
    v_amount := v_req.amount_due_fcfa;
    p_purpose := case
      when v_req.funding = 'paid' and v_req.type_code = 'identity_kit' then 'identity_kit'
      when v_req.funding = 'paid' then 'creative_unit'
      else 'express_fee' end;
  elsif p_purpose = 'source_files' then
    select * into v_req from public.requests where id = p_request_id and owner_id = p_user;
    if not found then
      raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_req.status not in ('to_validate', 'delivered') then
      raise exception 'NOT_DELIVERED_YET' using errcode = 'P0001',
        hint = 'Les fichiers sources se commandent une fois le visuel prêt.';
    end if;
    if v_req.source_files_paid then
      raise exception 'ALREADY_PAID' using errcode = 'P0001';
    end if;
    v_amount := coalesce((public.setting('source_files_price_fcfa') #>> '{}')::integer, 5000);
  else
    raise exception 'UNSUPPORTED_PURPOSE' using errcode = 'P0001';
  end if;

  insert into public.payments (user_id, purpose, tier, request_id, amount_fcfa, method)
  values (p_user, p_purpose, case when p_purpose = 'subscription' then p_tier end, p_request_id, v_amount, p_method)
  returning * into v_pay;
  return v_pay;
end;
$$;

create or replace function public.apply_payment_success(p_payment_id uuid, p_raw jsonb default null)
returns public.invoices
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
  v_inv public.invoices;
  v_prof public.profiles;
  v_label text;
  v_ref public.referrals;
  v_first boolean;
  v_req public.requests;
begin
  select * into v_pay from public.payments where id = p_payment_id for update;
  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_pay.status = 'succeeded' then
    select * into v_inv from public.invoices where payment_id = p_payment_id;
    return v_inv;
  end if;
  if v_pay.status not in ('pending', 'failed', 'canceled') then
    raise exception 'PAYMENT_NOT_PAYABLE' using errcode = 'P0001';
  end if;

  update public.payments
     set status = 'succeeded', paid_at = now(), failure_reason = null, raw = coalesce(p_raw, raw)
   where id = p_payment_id
  returning * into v_pay;

  if v_pay.purpose = 'subscription' then
    select not has_paid_once into v_first from public.subscriptions where user_id = v_pay.user_id;
    perform public.activate_subscription(v_pay.user_id, v_pay.tier);
    select 'Abonnement ' || name || ' · 1 mois' into v_label from public.tiers where code = v_pay.tier;

    if v_first then
      select * into v_ref from public.referrals where referee_id = v_pay.user_id and rewarded_at is null for update;
      if v_ref.id is not null then
        update public.referrals set rewarded_at = now() where id = v_ref.id;
        update public.profiles
           set bonus_static = bonus_static + coalesce((public.setting('referral_reward_static') #>> '{}')::integer, 1)
         where id = v_ref.referrer_id;
        perform public.notify(v_ref.referrer_id, 'referral_rewarded', 'Parrainage réussi',
          'Un de vos filleuls s''est abonné : un visuel vous est offert.', '{}');
      end if;
    end if;
  elsif v_pay.purpose = 'source_files' then
    update public.requests set source_files_paid = true where id = v_pay.request_id
    returning * into v_req;
    v_label := 'Fichiers sources · ' || coalesce(v_req.title, '') || ' (' || coalesce(v_req.ref, '') || ')';
    perform public.notify_staff('staff_source_files_paid', 'Fichiers sources payés · ' || coalesce(v_req.ref, ''),
      'Déposez les fichiers sources de « ' || coalesce(v_req.title, '') || ' ».', jsonb_build_object('request_id', v_req.id));
    if v_req.assignee_id is not null then
      perform public.notify(v_req.assignee_id, 'staff_source_files_paid', 'Fichiers sources payés · ' || coalesce(v_req.ref, ''),
        'Déposez les fichiers sources de « ' || coalesce(v_req.title, '') || ' ».', jsonb_build_object('request_id', v_req.id));
    end if;
  else
    update public.requests set status = 'received'
     where id = v_pay.request_id and status = 'awaiting_payment';
    select case v_pay.purpose when 'express_fee' then 'Supplément express · '
             when 'identity_kit' then 'Kit identité express · ' else 'Visuel · ' end
           || coalesce(r.title, '') || ' (' || coalesce(r.ref, '') || ')'
      into v_label from public.requests r where r.id = v_pay.request_id;
  end if;

  select * into v_prof from public.profiles where id = v_pay.user_id;
  insert into public.invoices (number, payment_id, user_id, label, amount_fcfa, customer)
  values (
    public.next_invoice_number(),
    v_pay.id, v_pay.user_id, coalesce(v_label, 'Start And Shift'), v_pay.amount_fcfa,
    jsonb_build_object(
      'name', v_prof.full_name, 'email', v_prof.email, 'phone', v_prof.phone,
      'brand', (select name from public.brands where id = v_prof.active_brand_id)
    )
  )
  returning * into v_inv;

  perform public.notify(v_pay.user_id, 'payment_succeeded', 'Paiement reçu',
    'Merci ! ' || to_char(v_pay.amount_fcfa, 'FM999G999G999') || ' F reçus. Votre facture ' || v_inv.number || ' est disponible.',
    jsonb_build_object('payment_id', v_pay.id, 'invoice_id', v_inv.id));
  return v_inv;
end;
$$;

-- Accès aux fichiers sources : équipe, ou client qui les a payés.
-- Les sources sont rangées sous <request_id>/sources/ (les livrables sous <request_id>/team/).
drop policy request_files_read on public.request_files;
create policy request_files_read on public.request_files for select to authenticated
  using (public.can_access_request(request_id) and (
    kind <> 'source' or public.is_staff()
    or exists (select 1 from public.requests r where r.id = request_id and r.source_files_paid)));

drop policy request_files_insert on public.request_files;
create policy request_files_insert on public.request_files for insert to authenticated
  with check (
    uploaded_by = (select auth.uid())
    and (
      (public.is_staff() and kind = 'deliverable')
      or (public.is_staff() and kind = 'source' and storage_path like request_id::text || '/sources/%')
      or (kind = 'brief_asset' and exists (
            select 1 from public.requests r
             where r.id = request_id and r.owner_id = (select auth.uid())
               and r.status in ('awaiting_payment', 'received', 'in_progress')))
    )
  );

drop policy request_files_obj_read on storage.objects;
create policy request_files_obj_read on storage.objects for select to authenticated
  using (bucket_id = 'request-files'
         and public.can_access_request(public.try_uuid((storage.foldername(name))[1]))
         and ((storage.foldername(name))[2] <> 'sources' or public.is_staff()
              or exists (select 1 from public.requests r
                          where r.id = public.try_uuid((storage.foldername(name))[1]) and r.source_files_paid)));

drop policy request_files_obj_insert on storage.objects;
create policy request_files_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'request-files' and (
    ((storage.foldername(name))[2] in ('team', 'sources') and public.is_staff())
    or ((storage.foldername(name))[2] = 'client' and exists (
          select 1 from public.requests r
           where r.id = public.try_uuid((storage.foldername(name))[1]) and r.owner_id = (select auth.uid())))
  ));
