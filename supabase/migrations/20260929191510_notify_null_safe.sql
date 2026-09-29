-- Depuis la suppression de compte, un paiement peut ne plus avoir d'utilisateur (user_id null) :
-- rembourser ce paiement ne doit pas échouer sur la notification.
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
  if p_user is null then
    return null;
  end if;
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
