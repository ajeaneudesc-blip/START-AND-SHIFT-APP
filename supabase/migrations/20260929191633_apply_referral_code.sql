-- Parrainage après coup : la connexion Google ne transmet pas de métadonnées à l'inscription,
-- le front appelle donc cette fonction juste après la première connexion (code mémorisé depuis ?parrain=XXXX).
-- Possible une seule fois, avant le premier abonnement payant.
create or replace function public.apply_referral_code(p_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_referrer uuid;
begin
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode = '42501';
  end if;
  select id into v_referrer from public.profiles where referral_code = upper(trim(coalesce(p_code, '')));
  if v_referrer is null or v_referrer = v_uid then
    raise exception 'INVALID_REFERRAL_CODE' using errcode = 'P0001', hint = 'Ce code de parrainage n''existe pas.';
  end if;
  if exists (select 1 from public.profiles where id = v_uid and referred_by is not null)
     or exists (select 1 from public.referrals where referee_id = v_uid) then
    return false;
  end if;
  if exists (select 1 from public.subscriptions where user_id = v_uid and has_paid_once) then
    raise exception 'REFERRAL_TOO_LATE' using errcode = 'P0001',
      hint = 'Le code de parrainage doit être saisi avant le premier abonnement.';
  end if;
  update public.profiles set referred_by = v_referrer where id = v_uid;
  insert into public.referrals (referrer_id, referee_id) values (v_referrer, v_uid);
  return true;
end;
$$;
revoke execute on function public.apply_referral_code(text) from public, anon;
grant execute on function public.apply_referral_code(text) to authenticated;
