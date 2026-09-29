-- Garde-fous budget IA (Claude Sonnet 5.5 ≈ 0,07 $ par plan) : 40 plans/jour max ≈ 3 $/jour au pire.
-- Modifiables par un admin dans les réglages du back-office.
update public.settings set value = '40' where key = 'plan_daily_cap';
update public.settings set value = '3' where key = 'plan_limit_per_ip_per_day';
