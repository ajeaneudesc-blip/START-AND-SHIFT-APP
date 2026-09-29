-- Nettoyage du stockage : fichiers qui ne sont plus référencés par aucune ligne
-- (PDF des plans anonymes purgés, anciennes versions de factures, fichiers de comptes supprimés…).
-- Supabase interdit la suppression directe dans storage.objects : la fonction "maintenance"
-- récupère la liste ci-dessous et supprime via l'API Storage.
-- Délai de 24 h : laisse le temps au client d'enregistrer la ligne qui référence un fichier qu'il vient d'envoyer.

create or replace function public.orphan_storage_paths(p_limit integer default 500)
returns table (bucket text, path text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.bucket_id, o.name
    from storage.objects o
   where o.created_at < now() - interval '24 hours'
     and (
       (o.bucket_id = 'plans' and not exists (select 1 from public.plans p where p.pdf_path = o.name))
       or (o.bucket_id = 'invoices' and not exists (select 1 from public.invoices i where i.pdf_path = o.name))
       or (o.bucket_id = 'request-files' and not exists (select 1 from public.request_files f where f.storage_path = o.name))
       or (o.bucket_id = 'brand-assets' and not exists (
             select 1 from public.brands b where b.logo_path = o.name or o.name = any (b.photo_paths)))
     )
   order by o.created_at
   limit greatest(p_limit, 1);
$$;
revoke execute on function public.orphan_storage_paths(integer) from public, anon, authenticated;

create or replace function public.job_storage_cleanup()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from public.orphan_storage_paths(1)) then
    return null;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'sas_project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'sas_cron_secret';
  if v_url is null or v_secret is null then
    return null;
  end if;
  return net.http_post(
    url := v_url || '/functions/v1/maintenance',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
end;
$$;
revoke execute on function public.job_storage_cleanup() from public, anon, authenticated;

select cron.schedule('sas-storage-cleanup', '45 3 * * *', $$select public.job_storage_cleanup()$$);
