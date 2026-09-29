insert into public.settings (key, value) values
  ('seller', '{"name": "Start And Shift", "address": "Lomé, Togo", "legal": ""}')
on conflict (key) do nothing;

create or replace function public.plans_track_review()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.content is distinct from old.content and (select auth.uid()) is not null then
    new.reviewed_at := now();
    new.reviewed_by := (select auth.uid());
  end if;
  return new;
end;
$$;
revoke execute on function public.plans_track_review() from public, anon, authenticated;

create trigger plans_review before update of content on public.plans
  for each row execute function public.plans_track_review();

revoke update on public.plans from authenticated;
grant update (content, review_note, is_current) on public.plans to authenticated;
