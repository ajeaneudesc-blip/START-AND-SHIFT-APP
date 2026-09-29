-- Suppression de compte (exigée par Google Play pour l'app Android) :
-- les données personnelles partent avec le compte (profil, marques, plans, demandes, messages…),
-- mais paiements et factures sont conservés pour la comptabilité, détachés du compte.
-- La facture garde sa copie figée des coordonnées client (colonne customer), comme l'exige la loi.

alter table public.payments alter column user_id drop not null;
alter table public.payments drop constraint payments_user_id_fkey;
alter table public.payments add constraint payments_user_id_fkey
  foreign key (user_id) references public.profiles (id) on delete set null;

alter table public.invoices alter column user_id drop not null;
alter table public.invoices drop constraint invoices_user_id_fkey;
alter table public.invoices add constraint invoices_user_id_fkey
  foreign key (user_id) references public.profiles (id) on delete set null;
