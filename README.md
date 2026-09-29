# Start And Shift — Backend

Backend de l'app Start And Shift : questionnaire → plan de com généré par IA → commande de visuels
produits par l'équipe → abonnements Gratuit / Pro / Max payés en Mobile Money.

Tout tourne sur **Supabase** (projet `start-and-shift`, réf. `umvoxhdicgmpqocvjjpn`, région Paris) :

| Brique | Rôle |
|---|---|
| **Postgres** (`supabase/migrations/`) | Données, règles métier (quotas, statuts, factures…) en fonctions SQL, sécurité ligne par ligne (RLS) |
| **Auth** | Connexion Google ou code WhatsApp (SMS en secours) |
| **Storage** | Logos et photos de marque, fichiers des demandes, PDF des plans et factures |
| **Edge Functions** (`supabase/functions/`) | IA (plan), paiement FedaPay, PDF, envoi WhatsApp, back-office, suppression de compte |
| **pg_cron** | Tâches automatiques : fin d'abonnement, rappels de renouvellement, purge, validation auto, nettoyage |
| **Realtime** | Suivi en direct des demandes, messages et notifications |

Guide d'intégration pour le front (web, Android, back-office) : **[docs/API.md](docs/API.md)**.

---

## Ce qui est fait

- **Questionnaire → plan** sans compte : plan généré par Claude Sonnet 5.5, conservé 7 jours sur un jeton
  (`claim_token`), rattaché au compte à la connexion. PDF « Stratégie de communication » aux couleurs de la marque.
- **Mode simulé** tant que la clé IA n'est pas configurée : plan d'exemple, aucun coût.
- **Garde-fous budget IA** : 40 plans/jour maximum pour toute l'app, 3 par appareil/réseau et par jour
  (modifiables dans les réglages), réponses isolées pour empêcher toute « injection » dans le prompt.
- **Connexion** : Google, ou code par WhatsApp avec bascule automatique en SMS (hook Supabase Auth).
- **Abonnements** Gratuit / Pro (9 900 F) / Max (24 900 F) : quotas mensuels, report des visuels non utilisés
  une seule fois, mises à jour du plan (1 en Pro, 3 en Max), multi-marques dès Pro, résiliation en 1 clic,
  rappel de renouvellement (pas de prélèvement automatique en Mobile Money), 3 jours de grâce.
- **Visuels** : 1 visuel offert, puis quota, visuel bonus de parrainage, ou paiement à l'unité (5 000 F statique,
  7 500 F carrousel, 10 000 F vidéo) ; express +50 % et délai divisé par 2 ; statuts Reçue → En création →
  À valider → Livrée ; 2 modifications incluses ; validation automatique après 5 jours ; accord portfolio.
- **Paiement FedaPay** (Flooz, T-Money, carte) : paiement poussé sur le téléphone ou page FedaPay, webhook signé
  et toujours revérifié auprès de FedaPay, montant contrôlé, idempotent. Remboursement enregistré par un admin
  (l'argent se renvoie depuis le tableau de bord FedaPay ; l'app repasse le client en Gratuit et marque la facture « Remboursée »).
- **Factures PDF** numérotées **sans trou** (`SAS-2026-00001`, remise à zéro chaque année).
- **Notifications** dans l'app + WhatsApp (modèle Meta), réglables par type dans le back-office.
- **Parrainage** : code personnel, 1 visuel offert au parrain quand le filleul prend son premier abonnement.
- **Back-office** : tableau de bord (revenu du mois, MRR, retards, charge de l'équipe, conversion), assignation,
  dépôt des livrables, relecture/correction des plans, invitation de créatifs, réglages (tarifs, délais, WhatsApp).
- **Suppression de compte** (exigée par Google Play) : données personnelles effacées, factures conservées.
- **Nettoyage nocturne** des fichiers qui ne servent plus.

### Corrections faites lors de la reprise (29/09/2026)

1. Le visuel bonus de parrainage ne pouvait jamais être utilisé (blocage `FORBIDDEN_FIELD`).
2. Les numéros de facture pouvaient avoir des trous (séquence non transactionnelle) → compteur annuel sans trou.
3. Un client pouvait modifier l'e-mail/téléphone de son profil et se faire promouvoir « créatif » lors d'une
   invitation, ou détourner des notifications → ces champs ne changent plus que via une vérification Auth.
4. Les PDF des plans anonymes expirés restaient stockés indéfiniment → nettoyage nocturne.
5. Supprimer un compte aurait effacé ses factures → elles sont conservées, détachées du compte.
6. Le parrainage ne marchait pas pour les inscriptions Google → fonction `apply_referral_code`.
7. IA : passage à **Claude Sonnet 5.5**, effort `low`, délais compatibles avec la limite de 150 s des Edge Functions.

Tous les parcours ont été testés de bout en bout en base (transactions annulées) et les fonctions déployées
ont été appelées en conditions réelles.

---

## Ce que vous devez faire

Rien n'est payant tant que les étapes 1 et 2 ne sont pas faites : l'app tourne en mode simulé.

### 1. Clé IA (Anthropic) — ~15 min
1. Créez un compte sur <https://console.anthropic.com>, ajoutez un moyen de paiement et **une limite de dépense
   mensuelle** (Settings → Limits), par exemple 20 $.
2. Créez une clé API.
3. Supabase → *Project Settings → Edge Functions → Secrets* → ajoutez `ANTHROPIC_API_KEY`.

Coût estimé : **~0,03 à 0,07 $ par plan** (≈ 20 à 45 F). Plafond actuel : 40 plans/jour.

### 2. FedaPay — ~1 h + validation du compte
1. Créez un compte sur <https://fedapay.com>, commencez en **sandbox**.
2. Secrets Supabase : `FEDAPAY_SECRET_KEY` (clé secrète sandbox), `FEDAPAY_ENV=sandbox`.
3. Tableau de bord FedaPay → *Webhooks* → URL :
   `https://umvoxhdicgmpqocvjjpn.supabase.co/functions/v1/fedapay-webhook`
   (événements `transaction.*`), puis copiez la clé de signature dans `FEDAPAY_WEBHOOK_SECRET`.
4. Après vos tests, passez le compte en *live* (pièces de l'entreprise demandées par FedaPay) et remplacez
   les clés + `FEDAPAY_ENV=live`.

### 3. WhatsApp Cloud API (Meta) — ~2 h + validation Meta (1 à 3 jours)
1. <https://business.facebook.com> : compte Business Manager vérifié, puis <https://developers.facebook.com> →
   app « Business » → produit **WhatsApp**, avec un numéro dédié (pas votre WhatsApp personnel).
2. Créez 2 modèles de message (langue *French*) :
   - `sas_code_connexion` — catégorie **Authentication**, bouton « Copier le code ».
   - `sas_notification` — catégorie **Utility**, texte : `{{1}}` puis `{{2}}` (titre puis message).
3. Créez un **utilisateur système** avec un jeton permanent (permission `whatsapp_business_messaging`).
4. Secrets Supabase : `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`.

Coût : les codes de connexion et notifications sont facturés par Meta à l'unité (quelques francs chacun).

### 4. Connexion (Supabase Auth) — ~30 min
Supabase → *Authentication* :
- **Sign In / Providers → Phone** : activer. **Auth Hooks → Send SMS hook** : type HTTPS, URL
  `https://umvoxhdicgmpqocvjjpn.supabase.co/functions/v1/auth-sms-hook`, générez le secret et copiez-le dans le
  secret `SEND_SMS_HOOK_SECRET`. Longueur du code : 6 chiffres, expiration : 600 s.
- **Providers → Google** : créez un identifiant OAuth sur <https://console.cloud.google.com> (type *Application Web*,
  URI de redirection indiquée par Supabase) et collez Client ID / Secret.
- **URL Configuration** : *Site URL* = adresse de l'app web ; ajoutez les URL de redirection (web + schéma de l'app Android).

### 5. Réglages de l'entreprise
- Autres secrets : `APP_ENV=production`, `APP_URL`, `BACKOFFICE_URL`, `ALLOWED_ORIGIN`, `IP_HASH_SALT`
  (modèle complet : [supabase/functions/.env.example](supabase/functions/.env.example)).
- Dans les réglages (table `settings`, ou back-office) : **`support_whatsapp`** (actuellement `+22800000000`)
  et **`seller`** (raison sociale, adresse, RCCM/NIF à imprimer sur les factures) dès que l'entité juridique est choisie.

### 6. Premier administrateur
Connectez-vous une première fois à l'app, puis dans Supabase → *SQL Editor* :
```sql
update public.profiles set role = 'admin', team_title = 'Directeur créatif'
 where email = 'votre@email.com';  -- ou : where phone = '+228XXXXXXXX'
```
Les créatifs suivants s'invitent depuis le back-office.

### 7. Plus tard
- Fournisseur **SMS** de secours (codes de connexion hors WhatsApp) : à brancher dans
  `supabase/functions/_shared/messaging.ts` (Africa's Talking, opérateur local…). En attendant, sans WhatsApp,
  le code est écrit dans les logs (refusé si `APP_ENV=production`).

---

## Points à trancher (le code suit l'hypothèse indiquée)

| Sujet | Hypothèse actuelle |
|---|---|
| Abonné Pro/Max qui a épuisé son quota | **Décidé (29/09/2026)** : il peut payer un visuel à l'unité, au tarif normal (5 000 F statique, 10 000 F vidéo) |
| Relecture des plans avant envoi | Le client voit son plan tout de suite (écran de chargement 10-20 s) ; l'équipe peut le corriger ensuite, le PDF se met à jour |
| Kit identité express, fichiers sources | Prévus dans le modèle de données, pas encore vendus (prix à définir) |
| Durée d'une génération | 20 à 60 s selon la longueur du plan : l'écran de chargement doit le tolérer |

---

## Développement

```bash
# Outils : Supabase CLI (https://supabase.com/docs/guides/cli) et Deno 2
supabase link --project-ref umvoxhdicgmpqocvjjpn
supabase db push                         # applique les migrations
supabase functions deploy                # déploie toutes les fonctions
deno check supabase/functions/*/index.ts # vérification des types
```

Les migrations et les fonctions de ce dépôt sont identiques à ce qui est déployé.
