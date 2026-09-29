-- Numérotation des factures sans trou : compteur par année verrouillé dans la transaction du paiement.
-- (Une séquence Postgres n'est pas transactionnelle : un paiement annulé laisserait un numéro manquant.)
create table public.invoice_counters (
  year integer primary key,
  last_number integer not null default 0
);
alter table public.invoice_counters enable row level security;

create or replace function public.next_invoice_number()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_year integer := extract(year from now() at time zone 'Africa/Lome')::integer;
  v_n integer;
begin
  insert into public.invoice_counters as c (year, last_number) values (v_year, 1)
  on conflict (year) do update set last_number = c.last_number + 1
  returning last_number into v_n;
  return 'SAS-' || v_year || '-' || lpad(v_n::text, 5, '0');
end;
$$;
revoke execute on function public.next_invoice_number() from public, anon, authenticated;

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

drop sequence if exists public.invoice_number_seq;
