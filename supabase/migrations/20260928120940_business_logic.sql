create or replace function public.notify(
  p_user uuid, p_type text, p_title text, p_body text, p_data jsonb default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_wa public.whatsapp_status := 'skipped';
  v_auto jsonb := coalesce(public.setting('whatsapp_auto'), '{}');
begin
  if exists (
    select 1 from public.profiles
     where id = p_user and whatsapp_notifications and phone is not null
  ) and coalesce((v_auto ->> p_type)::boolean, false) then
    v_wa := 'pending';
  end if;

  insert into public.notifications (user_id, type, title, body, data, whatsapp_status)
  values (p_user, p_type, p_title, p_body, coalesce(p_data, '{}'), v_wa)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.notify_staff(p_type text, p_title text, p_body text, p_data jsonb default '{}')
returns void
language sql
security definer
set search_path = ''
as $$
  select public.notify(id, p_type, p_title, p_body, p_data)
    from public.profiles where role = 'admin';
$$;

create or replace function public.fr_datetime(p_ts timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select to_char(p_ts at time zone 'Africa/Lome', 'DD/MM à HH24"h"MI');
$$;

create or replace function public.current_usage_period(p_user uuid)
returns public.usage_periods
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.usage_periods
   where user_id = p_user and period_start <= now() and period_end > now()
   order by period_start desc
   limit 1;
$$;

create or replace function public.entitlements_for(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_sub public.subscriptions;
  v_tier public.tiers;
  v_period public.usage_periods;
  v_bonus integer;
begin
  select * into v_sub from public.subscriptions where user_id = p_user;
  if not found then
    return null;
  end if;
  select * into v_tier from public.tiers where code = v_sub.tier;
  v_period := public.current_usage_period(p_user);
  select bonus_static into v_bonus from public.profiles where id = p_user;

  return jsonb_build_object(
    'tier', v_sub.tier,
    'tier_name', v_tier.name,
    'status', v_sub.status,
    'current_period_start', v_sub.current_period_start,
    'current_period_end', v_sub.current_period_end,
    'cancel_at_period_end', v_sub.cancel_at_period_end,
    'multi_brand', v_tier.multi_brand,
    'free_offer_available', not v_sub.free_offer_used,
    'bonus_static', coalesce(v_bonus, 0),
    'static_remaining', case when v_period.id is null then 0
      else v_period.static_allowance + v_period.carried_static - v_period.static_used end,
    'video_remaining', case when v_period.id is null then 0
      else v_period.video_allowance + v_period.carried_video - v_period.video_used end,
    'regen_remaining', case when v_period.id is null then 0
      else v_period.regen_allowance - v_period.regen_used end,
    'carried_static', coalesce(v_period.carried_static, 0),
    'carried_video', coalesce(v_period.carried_video, 0)
  );
end;
$$;

create or replace function public.my_entitlements()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.entitlements_for((select auth.uid()));
$$;

create or replace function public.consume_plan_regeneration()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period public.usage_periods;
begin
  v_period := public.current_usage_period((select auth.uid()));
  if v_period.id is null or v_period.regen_used >= v_period.regen_allowance then
    return false;
  end if;
  update public.usage_periods set regen_used = regen_used + 1 where id = v_period.id;
  return true;
end;
$$;

create or replace function public.refund_plan_regeneration()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_period public.usage_periods;
begin
  v_period := public.current_usage_period((select auth.uid()));
  if v_period.id is not null and v_period.regen_used > 0 then
    update public.usage_periods set regen_used = regen_used - 1 where id = v_period.id;
  end if;
end;
$$;

create or replace function public.claim_plan(p_plan_id uuid, p_claim_token text)
returns public.plans
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_plan public.plans;
  v_brand uuid;
  v_business text;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501';
  end if;

  select * into v_plan from public.plans where id = p_plan_id for update;
  if not found then
    raise exception 'PLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_plan.owner_id = v_uid then
    return v_plan;
  end if;
  if v_plan.owner_id is not null
     or v_plan.claim_token_hash is distinct from encode(extensions.digest(p_claim_token, 'sha256'), 'hex') then
    raise exception 'INVALID_CLAIM_TOKEN' using errcode = '42501';
  end if;

  select active_brand_id into v_brand from public.profiles where id = v_uid;
  if v_brand is null then
    select id into v_brand from public.brands where owner_id = v_uid order by created_at limit 1;
  end if;
  if v_brand is null then
    v_business := nullif(trim(v_plan.answers ->> 'business'), '');
    insert into public.brands (owner_id, name, activity, domain, city, differentiator)
    values (
      v_uid,
      left(coalesce(split_part(v_business, ',', 1), 'Ma marque'), 120),
      v_business,
      v_plan.answers ->> 'domain',
      v_plan.answers ->> 'city',
      v_plan.answers ->> 'differentiator'
    )
    returning id into v_brand;
  end if;

  update public.plans set is_current = false
   where owner_id = v_uid and brand_id = v_brand and is_current;

  update public.plans
     set owner_id = v_uid, brand_id = v_brand, claim_token_hash = null, expires_at = null, is_current = true
   where id = p_plan_id
  returning * into v_plan;

  return v_plan;
end;
$$;

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

  if not v_sub.free_offer_used and v_type.kind = 'static' then
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

create or replace function public.release_request_funding(p_req public.requests)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  case p_req.funding
    when 'free_offer' then
      update public.subscriptions set free_offer_used = false where user_id = p_req.owner_id;
    when 'quota' then
      if p_req.kind = 'static' then
        update public.usage_periods set static_used = greatest(static_used - 1, 0) where id = p_req.usage_period_id;
      else
        update public.usage_periods set video_used = greatest(video_used - 1, 0) where id = p_req.usage_period_id;
      end if;
    when 'bonus' then
      update public.profiles set bonus_static = bonus_static + 1 where id = p_req.owner_id;
    else
      null;
  end case;
end;
$$;

create or replace function public.cancel_request(p_request_id uuid)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
begin
  select * into v_req from public.requests where id = p_request_id for update;
  if not found or (v_req.owner_id <> (select auth.uid()) and not public.is_staff()) then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status not in ('awaiting_payment', 'received') then
    raise exception 'REQUEST_ALREADY_STARTED' using errcode = 'P0001';
  end if;
  if v_req.status = 'received' and v_req.funding = 'paid' and not public.is_staff() then
    raise exception 'PAID_REQUEST_CONTACT_SUPPORT' using errcode = 'P0001';
  end if;

  perform public.release_request_funding(v_req);
  update public.requests set status = 'canceled' where id = p_request_id returning * into v_req;
  update public.payments set status = 'canceled'
   where request_id = p_request_id and status = 'pending';
  return v_req;
end;
$$;

create or replace function public.request_revision(p_request_id uuid, p_message text)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_req public.requests;
  v_hours integer := coalesce((public.setting('revision_delay_hours') #>> '{}')::integer, 24);
begin
  select * into v_req from public.requests where id = p_request_id for update;
  if not found or v_req.owner_id <> v_uid then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status not in ('to_validate', 'delivered') then
    raise exception 'NOTHING_TO_REVISE' using errcode = 'P0001';
  end if;
  if v_req.revisions_used >= v_req.revisions_included then
    raise exception 'NO_REVISIONS_LEFT' using errcode = 'P0001',
      hint = 'Les modifications incluses sont épuisées. Un changement de concept devient une nouvelle demande.';
  end if;
  if coalesce(trim(p_message), '') = '' then
    raise exception 'MESSAGE_REQUIRED' using errcode = 'P0001';
  end if;

  insert into public.request_messages (request_id, author_id, kind, body)
  values (p_request_id, v_uid, 'revision', trim(p_message));

  update public.requests
     set status = 'in_progress',
         revisions_used = revisions_used + 1,
         due_at = now() + make_interval(hours => v_hours),
         delivered_at = null
   where id = p_request_id
  returning * into v_req;
  return v_req;
end;
$$;

create or replace function public.approve_request(p_request_id uuid, p_portfolio_allowed boolean default false)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
begin
  select * into v_req from public.requests where id = p_request_id for update;
  if not found or v_req.owner_id <> (select auth.uid()) then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status = 'delivered' then
    update public.requests set portfolio_allowed = coalesce(p_portfolio_allowed, false)
     where id = p_request_id returning * into v_req;
    return v_req;
  end if;
  if v_req.status <> 'to_validate' then
    raise exception 'NOT_READY_FOR_VALIDATION' using errcode = 'P0001';
  end if;
  update public.requests
     set status = 'delivered', portfolio_allowed = coalesce(p_portfolio_allowed, false)
   where id = p_request_id
  returning * into v_req;
  return v_req;
end;
$$;

create or replace function public.staff_set_request_status(p_request_id uuid, p_status public.request_status)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
begin
  if not public.is_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.requests set status = p_status,
         assignee_id = coalesce(assignee_id, case when p_status = 'in_progress' then (select auth.uid()) end)
   where id = p_request_id
  returning * into v_req;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v_req;
end;
$$;

create or replace function public.assign_request(p_request_id uuid, p_assignee uuid)
returns public.requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
begin
  if not public.is_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_assignee is not null and public.current_role_of(p_assignee) not in ('creative', 'admin') then
    raise exception 'ASSIGNEE_NOT_IN_TEAM' using errcode = 'P0001';
  end if;
  update public.requests set assignee_id = p_assignee where id = p_request_id returning * into v_req;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_assignee is not null and p_assignee <> (select auth.uid()) then
    perform public.notify(p_assignee, 'request_assigned', 'Nouvelle demande pour vous',
      v_req.title || ' · ' || v_req.ref, jsonb_build_object('request_id', v_req.id));
  end if;
  return v_req;
end;
$$;

create or replace function public.requests_before_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_delay integer;
  v_ok boolean;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  if tg_op = 'UPDATE' then
    v_ok := case old.status
      when 'awaiting_payment' then new.status in ('received', 'canceled')
      when 'received'         then new.status in ('in_progress', 'canceled')
      when 'in_progress'      then new.status in ('to_validate', 'received')
      when 'to_validate'      then new.status in ('delivered', 'in_progress')
      when 'delivered'        then new.status in ('in_progress')
      else false
    end;
    if not v_ok then
      raise exception 'INVALID_STATUS_TRANSITION % -> %', old.status, new.status using errcode = 'P0001';
    end if;
  end if;

  if new.status = 'to_validate' and not exists (
    select 1 from public.request_files where request_id = new.id and kind = 'deliverable'
  ) then
    raise exception 'DELIVERABLE_REQUIRED' using errcode = 'P0001',
      hint = 'Déposez au moins un fichier livrable avant d''envoyer au client.';
  end if;

  if new.status = 'received' and new.received_at is null then
    select delay_hours into v_delay from public.creative_types where code = new.type_code;
    new.received_at := now();
    new.due_at := now() + make_interval(hours => case when new.express then ceil(v_delay / 2.0)::int else v_delay end);
  end if;
  if new.status = 'delivered' then
    new.delivered_at := now();
  end if;
  return new;
end;
$$;

create trigger requests_status_guard
  before insert or update of status on public.requests
  for each row execute function public.requests_before_status();

create or replace function public.requests_after_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_data jsonb := jsonb_build_object('request_id', new.id, 'ref', new.ref, 'status', new.status);
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;

  case new.status
    when 'received' then
      perform public.notify(new.owner_id, 'request_received', 'Demande reçue',
        'Nous avons bien reçu « ' || new.title || ' ». Livraison prévue le ' || public.fr_datetime(new.due_at) || '.', v_data);
      perform public.notify_staff('staff_new_request', 'Nouvelle demande ' || new.ref,
        new.title || (case when new.express then ' · EXPRESS' else '' end), v_data);
    when 'in_progress' then
      perform public.notify(new.owner_id, 'request_in_progress', 'Votre visuel est en création',
        '« ' || new.title || ' » est entre les mains de l''équipe.', v_data);
    when 'to_validate' then
      perform public.notify(new.owner_id, 'request_to_validate', 'Votre visuel est prêt',
        'Regardez « ' || new.title || ' » et validez-le, ou demandez une modification.', v_data);
    when 'delivered' then
      perform public.notify(new.owner_id, 'request_delivered', 'Visuel livré',
        '« ' || new.title || ' » est prêt à publier. Téléchargez-le depuis Mon espace.', v_data);
      if new.assignee_id is not null then
        perform public.notify(new.assignee_id, 'staff_request_validated', 'Visuel validé par le client',
          new.title || ' · ' || new.ref, v_data);
      end if;
    when 'canceled' then
      if tg_op = 'UPDATE' and old.status <> 'awaiting_payment' then
        perform public.notify_staff('staff_request_canceled', 'Demande annulée ' || new.ref, new.title, v_data);
      end if;
    else
      null;
  end case;

  if tg_op = 'UPDATE' and new.status = 'in_progress' and old.status in ('to_validate', 'delivered') then
    if new.assignee_id is not null then
      perform public.notify(new.assignee_id, 'staff_revision_requested', 'Modification demandée',
        new.title || ' · ' || new.ref || ' · à livrer avant le ' || public.fr_datetime(new.due_at), v_data);
    else
      perform public.notify_staff('staff_revision_requested', 'Modification demandée', new.title || ' · ' || new.ref, v_data);
    end if;
  end if;
  return null;
end;
$$;

create trigger requests_status_notify
  after insert or update of status on public.requests
  for each row execute function public.requests_after_status();

create or replace function public.request_messages_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.requests;
  v_data jsonb;
begin
  if new.kind <> 'message' then
    return null;
  end if;
  select * into v_req from public.requests where id = new.request_id;
  v_data := jsonb_build_object('request_id', v_req.id, 'ref', v_req.ref, 'message_id', new.id);

  if new.author_id = v_req.owner_id then
    if v_req.assignee_id is not null then
      perform public.notify(v_req.assignee_id, 'staff_new_message', 'Message client · ' || v_req.ref, left(new.body, 200), v_data);
    else
      perform public.notify_staff('staff_new_message', 'Message client · ' || v_req.ref, left(new.body, 200), v_data);
    end if;
  else
    perform public.notify(v_req.owner_id, 'new_message', 'Nouveau message de l''équipe', left(new.body, 200), v_data);
  end if;
  return null;
end;
$$;

create trigger request_messages_notify
  after insert on public.request_messages
  for each row execute function public.request_messages_after_insert();

create or replace function public.activate_subscription(p_user uuid, p_tier text)
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.subscriptions;
  v_tier public.tiers;
  v_prev public.usage_periods;
  v_start timestamptz;
  v_end timestamptz;
  v_carry_s integer := 0;
  v_carry_v integer := 0;
  v_grace interval := make_interval(days => coalesce((public.setting('renewal_grace_days') #>> '{}')::integer, 3));
begin
  select * into v_tier from public.tiers where code = p_tier and code <> 'free';
  if not found then
    raise exception 'UNKNOWN_TIER' using errcode = 'P0001';
  end if;
  select * into v_sub from public.subscriptions where user_id = p_user for update;

  if v_sub.tier = p_tier and v_sub.current_period_end is not null and v_sub.current_period_end > now() then
    v_start := v_sub.current_period_end;
  else
    v_start := now();
  end if;
  v_end := v_start + interval '1 month';

  select * into v_prev from public.usage_periods
   where user_id = p_user and period_end > v_start - v_grace and period_start < v_start
   order by period_end desc limit 1;
  if v_prev.id is not null then
    v_carry_s := greatest(v_prev.static_allowance - greatest(v_prev.static_used - v_prev.carried_static, 0), 0);
    v_carry_v := greatest(v_prev.video_allowance - greatest(v_prev.video_used - v_prev.carried_video, 0), 0);
    if v_start = now() then
      update public.usage_periods set period_end = greatest(v_start, period_start + interval '1 second')
       where id = v_prev.id and period_end > v_start;
    end if;
  end if;

  insert into public.usage_periods (
    user_id, tier, period_start, period_end,
    static_allowance, video_allowance, carried_static, carried_video, regen_allowance
  ) values (
    p_user, p_tier, v_start, v_end,
    v_tier.static_quota, v_tier.video_quota, v_carry_s, v_carry_v, v_tier.regen_quota
  );

  update public.subscriptions
     set tier = p_tier,
         status = 'active',
         current_period_start = case when v_start = now() then v_start else coalesce(current_period_start, v_start) end,
         current_period_end = v_end,
         cancel_at_period_end = false,
         has_paid_once = true
   where user_id = p_user
  returning * into v_sub;

  return v_sub;
end;
$$;

create or replace function public.cancel_subscription()
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.subscriptions;
begin
  update public.subscriptions set cancel_at_period_end = true
   where user_id = (select auth.uid()) and tier <> 'free'
  returning * into v_sub;
  if not found then
    raise exception 'NO_PAID_SUBSCRIPTION' using errcode = 'P0001';
  end if;
  return v_sub;
end;
$$;

create or replace function public.resume_subscription()
returns public.subscriptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sub public.subscriptions;
begin
  update public.subscriptions set cancel_at_period_end = false
   where user_id = (select auth.uid()) and tier <> 'free' and current_period_end > now()
  returning * into v_sub;
  if not found then
    raise exception 'NO_ACTIVE_SUBSCRIPTION' using errcode = 'P0001';
  end if;
  return v_sub;
end;
$$;

create or replace function public.downgrade_to_free(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.usage_periods set period_end = greatest(now(), period_start + interval '1 second')
   where user_id = p_user and period_end > now();
  update public.subscriptions
     set tier = 'free', status = 'active', current_period_start = null, current_period_end = null,
         cancel_at_period_end = false
   where user_id = p_user;
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
  elsif p_purpose in ('creative_unit', 'express_fee') then
    select * into v_req from public.requests where id = p_request_id and owner_id = p_user;
    if not found then
      raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_req.status <> 'awaiting_payment' or v_req.amount_due_fcfa <= 0 then
      raise exception 'NOTHING_TO_PAY' using errcode = 'P0001';
    end if;
    v_amount := v_req.amount_due_fcfa;
    p_purpose := case when v_req.funding = 'paid' then 'creative_unit' else 'express_fee' end;
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
  else
    update public.requests set status = 'received'
     where id = v_pay.request_id and status = 'awaiting_payment';
    select case v_pay.purpose when 'express_fee' then 'Supplément express · ' else 'Visuel · ' end
           || coalesce(r.title, '') || ' (' || coalesce(r.ref, '') || ')'
      into v_label from public.requests r where r.id = v_pay.request_id;
  end if;

  select * into v_prof from public.profiles where id = v_pay.user_id;
  insert into public.invoices (number, payment_id, user_id, label, amount_fcfa, customer)
  values (
    'SAS-' || to_char(now() at time zone 'Africa/Lome', 'YYYY') || '-' || lpad(nextval('public.invoice_number_seq')::text, 5, '0'),
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

create or replace function public.apply_payment_failure(p_payment_id uuid, p_status public.payment_status, p_reason text default null, p_raw jsonb default null)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
begin
  if p_status not in ('failed', 'canceled') then
    raise exception 'INVALID_FAILURE_STATUS' using errcode = 'P0001';
  end if;
  update public.payments
     set status = p_status, failure_reason = p_reason, raw = coalesce(p_raw, raw)
   where id = p_payment_id and status = 'pending'
  returning * into v_pay;
  if found then
    perform public.notify(v_pay.user_id, 'payment_failed', 'Paiement non abouti',
      'Le paiement de ' || to_char(v_pay.amount_fcfa, 'FM999G999G999') || ' F n''a pas abouti. Vous pouvez réessayer en un tap.',
      jsonb_build_object('payment_id', v_pay.id));
  end if;
  return v_pay;
end;
$$;

create or replace function public.admin_refund_payment(p_payment_id uuid, p_reason text default null)
returns public.payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pay public.payments;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.payments
     set status = 'refunded', refunded_at = now(), failure_reason = p_reason
   where id = p_payment_id and status = 'succeeded'
  returning * into v_pay;
  if not found then
    raise exception 'PAYMENT_NOT_REFUNDABLE' using errcode = 'P0001';
  end if;
  if v_pay.purpose = 'subscription' then
    perform public.downgrade_to_free(v_pay.user_id);
  end if;
  perform public.notify(v_pay.user_id, 'payment_refunded', 'Remboursement effectué',
    to_char(v_pay.amount_fcfa, 'FM999G999G999') || ' F vous ont été remboursés.', jsonb_build_object('payment_id', v_pay.id));
  return v_pay;
end;
$$;

create or replace function public.admin_set_role(p_user uuid, p_role public.app_role, p_team_title text default null)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prof public.profiles;
begin
  if not public.is_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_user = (select auth.uid()) and p_role <> 'admin' then
    raise exception 'CANNOT_DEMOTE_SELF' using errcode = 'P0001';
  end if;
  update public.profiles set role = p_role, team_title = coalesce(p_team_title, team_title)
   where id = p_user returning * into v_prof;
  return v_prof;
end;
$$;

create or replace function public.admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month timestamptz := date_trunc('month', now() at time zone 'Africa/Lome') at time zone 'Africa/Lome';
begin
  if not public.is_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'requests_by_status', (select coalesce(jsonb_object_agg(status, n), '{}') from (
        select status, count(*) n from public.requests group by status) s),
    'requests_late', (select count(*) from public.requests
        where status in ('received', 'in_progress') and due_at < now()),
    'requests_due_today', (select count(*) from public.requests
        where status in ('received', 'in_progress') and due_at < now() + interval '24 hours'),
    'subscribers_by_tier', (select coalesce(jsonb_object_agg(tier, n), '{}') from (
        select tier, count(*) n from public.subscriptions group by tier) s),
    'mrr_fcfa', (select coalesce(sum(t.price_fcfa), 0) from public.subscriptions s
        join public.tiers t on t.code = s.tier where s.tier <> 'free' and s.status = 'active'),
    'revenue_month_fcfa', (select coalesce(sum(amount_fcfa), 0) from public.payments
        where status = 'succeeded' and paid_at >= v_month),
    'plans_month', (select count(*) from public.plans where created_at >= v_month and status = 'ready'),
    'new_clients_month', (select count(*) from public.profiles where role = 'client' and created_at >= v_month),
    'conversion_rate', (select case when count(*) = 0 then 0
        else round(100.0 * count(*) filter (where s.has_paid_once) / count(*), 1) end
        from public.profiles p join public.subscriptions s on s.user_id = p.id where p.role = 'client'),
    'team_load', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', p.id, 'name', p.full_name, 'title', p.team_title, 'available', p.is_available,
          'open', (select count(*) from public.requests r where r.assignee_id = p.id
                    and r.status in ('received', 'in_progress', 'to_validate')),
          'delivered_month', (select count(*) from public.requests r where r.assignee_id = p.id
                    and r.status = 'delivered' and r.delivered_at >= v_month)
        ) order by p.full_name), '[]')
        from public.profiles p where p.role in ('creative', 'admin'))
  );
end;
$$;

create or replace view public.admin_requests
with (security_invoker = true) as
select r.*,
       ct.name as type_name,
       b.name as brand_name, b.domain as brand_domain, b.colors as brand_colors, b.logo_path as brand_logo_path,
       p.full_name as client_name, p.phone as client_phone, p.city as client_city,
       s.tier as client_tier,
       a.full_name as assignee_name,
       (r.due_at < now() and r.status in ('received', 'in_progress')) as is_late
  from public.requests r
  join public.creative_types ct on ct.code = r.type_code
  join public.profiles p on p.id = r.owner_id
  left join public.subscriptions s on s.user_id = r.owner_id
  left join public.brands b on b.id = r.brand_id
  left join public.profiles a on a.id = r.assignee_id;

create or replace view public.admin_clients
with (security_invoker = true) as
select p.id, p.full_name, p.email, p.phone, p.city, p.created_at,
       s.tier, s.status as subscription_status, s.current_period_end, s.has_paid_once,
       b.id as brand_id, b.name as brand_name, b.domain as brand_domain, b.colors as brand_colors, b.logo_path as brand_logo_path,
       (select count(*) from public.requests r where r.owner_id = p.id) as requests_count,
       (select count(*) from public.plans pl where pl.owner_id = p.id and pl.status = 'ready') as plans_count
  from public.profiles p
  join public.subscriptions s on s.user_id = p.id
  left join public.brands b on b.id = p.active_brand_id
 where p.role = 'client';

create or replace function public.set_otp_channel(p_phone text, p_channel text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
begin
  if length(v_phone) < 8 or length(v_phone) > 15 or p_channel not in ('whatsapp', 'sms') then
    raise exception 'INVALID_INPUT' using errcode = '22023';
  end if;
  insert into public.otp_channel_prefs (phone, channel) values (v_phone, p_channel)
  on conflict (phone) do update set channel = excluded.channel, updated_at = now();
end;
$$;

create or replace function public.job_expire_subscriptions()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_grace interval := make_interval(days => coalesce((public.setting('renewal_grace_days') #>> '{}')::integer, 3));
  v_sub record;
  v_n integer := 0;
begin
  for v_sub in
    select * from public.subscriptions
     where tier <> 'free' and current_period_end <= now()
     for update skip locked
  loop
    if v_sub.cancel_at_period_end or v_sub.current_period_end + v_grace <= now() then
      perform public.downgrade_to_free(v_sub.user_id);
      perform public.notify(v_sub.user_id, 'subscription_ended', 'Votre offre est terminée',
        'Vous êtes repassé à l''offre Gratuit. Votre plan reste accessible. Réabonnez-vous en un tap quand vous voulez.', '{}');
    elsif v_sub.status = 'active' then
      update public.subscriptions set status = 'past_due' where user_id = v_sub.user_id;
      perform public.notify(v_sub.user_id, 'renewal_reminder', 'Votre offre est arrivée à échéance',
        'Renouvelez en un tap pour garder vos visuels du mois et le report de ceux non utilisés.', '{}');
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function public.job_renewal_reminders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer := 0;
  v_sub record;
begin
  for v_sub in
    select s.*, t.name as tier_name, t.price_fcfa from public.subscriptions s join public.tiers t on t.code = s.tier
     where s.tier <> 'free' and not s.cancel_at_period_end and s.status = 'active'
       and s.current_period_end between now() and now() + interval '3 days'
       and s.reminder_sent_for is distinct from s.current_period_end
  loop
    update public.subscriptions set reminder_sent_for = v_sub.current_period_end where user_id = v_sub.user_id;
    perform public.notify(v_sub.user_id, 'renewal_reminder', 'Votre offre ' || v_sub.tier_name || ' se renouvelle bientôt',
      'Elle se termine le ' || public.fr_datetime(v_sub.current_period_end) || '. Renouvelez en un tap ('
        || to_char(v_sub.price_fcfa, 'FM999G999') || ' F) avec Flooz, T-Money ou carte.',
      jsonb_build_object('tier', v_sub.tier));
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function public.job_purge_anonymous_plans()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  delete from public.plans where owner_id is null and expires_at < now();
  get diagnostics v_n = row_count;
  delete from public.plan_generation_log where created_at < now() - interval '30 days';
  delete from public.otp_channel_prefs where updated_at < now() - interval '1 day';
  update public.requests set status = 'canceled'
   where status = 'awaiting_payment' and created_at < now() - interval '7 days';
  return v_n;
end;
$$;

create or replace function public.job_auto_approve()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_days integer := coalesce((public.setting('auto_approve_days') #>> '{}')::integer, 5);
  v_n integer;
begin
  update public.requests set status = 'delivered'
   where status = 'to_validate' and updated_at < now() - make_interval(days => v_days);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.requests_release_on_cancel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'canceled' and old.status = 'awaiting_payment' and (select auth.uid()) is null then
    perform public.release_request_funding(new);
  end if;
  return null;
end;
$$;

create trigger requests_release_on_cancel
  after update of status on public.requests
  for each row execute function public.requests_release_on_cancel();

revoke execute on all functions in schema public from public, anon;

grant execute on function
  public.is_staff(), public.is_admin(), public.can_access_request(uuid), public.current_role_of(uuid),
  public.my_entitlements(), public.consume_plan_regeneration(), public.refund_plan_regeneration(),
  public.claim_plan(uuid, text),
  public.create_request(text, text, text, text[], boolean, uuid, uuid),
  public.cancel_request(uuid), public.request_revision(uuid, text), public.approve_request(uuid, boolean),
  public.staff_set_request_status(uuid, public.request_status), public.assign_request(uuid, uuid),
  public.cancel_subscription(), public.resume_subscription(),
  public.admin_refund_payment(uuid, text), public.admin_set_role(uuid, public.app_role, text),
  public.admin_dashboard()
to authenticated;

grant execute on function public.set_otp_channel(text, text) to anon, authenticated;

revoke execute on function
  public.notify(uuid, text, text, text, jsonb), public.notify_staff(text, text, text, jsonb),
  public.entitlements_for(uuid), public.current_usage_period(uuid),
  public.activate_subscription(uuid, text), public.downgrade_to_free(uuid),
  public.create_payment(uuid, public.payment_purpose, text, uuid, text),
  public.apply_payment_success(uuid, jsonb), public.apply_payment_failure(uuid, public.payment_status, text, jsonb),
  public.release_request_funding(public.requests),
  public.job_expire_subscriptions(), public.job_renewal_reminders(), public.job_purge_anonymous_plans(), public.job_auto_approve()
from authenticated;
