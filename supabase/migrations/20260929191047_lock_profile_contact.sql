-- E-mail et téléphone du profil = coordonnées vérifiées par Supabase Auth (synchronisées par
-- handle_user_contact_update). Un client ne peut plus les modifier directement : sinon il pourrait
-- se faire passer pour un futur membre d'équipe (admin/invite retrouve les comptes par ces champs)
-- ou détourner les notifications WhatsApp vers le numéro d'un tiers.
-- Pour changer de numéro : supabase.auth.updateUser({ phone }) puis vérification du code.
create or replace function public.guard_profile_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') and (select auth.uid()) is not null and not public.is_admin() then
    if new.role is distinct from old.role
       or new.referral_code is distinct from old.referral_code
       or new.referred_by is distinct from old.referred_by
       or new.bonus_static is distinct from old.bonus_static
       or new.team_title is distinct from old.team_title
       or new.email is distinct from old.email
       or new.phone is distinct from old.phone then
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
