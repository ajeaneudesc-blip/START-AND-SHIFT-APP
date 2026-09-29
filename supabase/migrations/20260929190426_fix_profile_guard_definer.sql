-- Le garde-fou ne doit viser que les écritures directes du client (rôle "authenticated" via PostgREST).
-- Les fonctions SECURITY DEFINER (create_request qui consomme un visuel bonus, parrainage…) s'exécutent
-- sous le rôle propriétaire et doivent pouvoir modifier ces champs.
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
