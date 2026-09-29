# Guide d'intégration — API Start And Shift

Pour les développeurs de l'app web, de l'app Android et du back-office.
Le front parle au backend avec le client officiel **supabase-js** (ou `supabase-kt` sur Android).

```ts
import { createClient } from "@supabase/supabase-js";
export const supabase = createClient(
  "https://umvoxhdicgmpqocvjjpn.supabase.co",
  "sb_publishable_PvOkWBcvViE3sp96QNFDag_HJiYvGSM", // clé publique, peut être dans l'app
);
```

Trois façons d'appeler le backend :

| Quoi | Appel |
|---|---|
| Lire des données | `supabase.from("table").select(...)` — la sécurité (RLS) ne renvoie que ce que l'utilisateur a le droit de voir |
| Actions métier | `supabase.rpc("fonction", { ... })` |
| IA, paiement, PDF, compte | `supabase.functions.invoke("plans/generate", { body })` (Edge Functions) |

**Erreurs.** RPC : `error.message` commence par un code (`BRAND_REQUIRED`, `NO_REVISIONS_LEFT`…) et
`error.hint` contient, quand il existe, une phrase à afficher. Edge Functions : réponse
`{ "error": "CODE", "message": "phrase à afficher" }` avec le statut HTTP.

---

## 1. Questionnaire et plan (sans compte)

### Générer le plan
```ts
const { data, error } = await supabase.functions.invoke("plans/generate", { body: { answers } });
// data = { plan: {...}, claim_token: "..." }   (claim_token seulement si le visiteur n'est pas connecté)
```
Gardez `plan.id` et `claim_token` sur l'appareil (localStorage) : c'est la clé du plan pendant 7 jours
(`plan.expires_at`). Durée : **20 à 60 s** — prévoir l'écran de chargement en conséquence.

`answers` (les libellés affichés sont envoyés tels quels, le backend ne dépend pas des intitulés exacts) :

| Champ | Question | Type |
|---|---|---|
| `for_whom` | 1. Pour qui préparez-vous ce plan ? | texte |
| `business` | 2. Nom de l'activité et ce que vous vendez (le nom avant la 1re virgule sert de nom de marque) | texte, 2-200 |
| `domain` | 3. Domaine | texte |
| `customer_type` / `customer_zone` | 4. Particuliers/Entreprises/Les deux · Ma ville/Tout le pays/… | texte |
| `sales_channels` | 5. Où vendez-vous (multiple) | tableau de textes |
| `trigger` | 6. Ce qui pousse à agir | texte |
| `priority` | 7. Priorité 3 mois | texte |
| `budget` | 8. Budget mensuel (commencer par « Rien » = aucune dépense proposée) | texte |
| `time_per_week` | 9. Temps par semaine | texte |
| `blockers` | 10. Blocages (multiple) | tableau de textes |
| `differentiator` | 10 bis. Ce qui vous rend différent (facultatif) | texte ≤ 500 |
| `city`, `country` | facultatifs | texte |

Erreurs utiles : `INVALID_ANSWERS` (400), `PLAN_RATE_LIMIT` (429, 3 plans/jour par réseau),
`PLAN_DAILY_CAP` (503, plafond global), `AI_BUSY` / `AI_ERROR` → écran « Ça n'a pas fonctionné, vos réponses sont gardées ».

### Relire le plan / télécharger le PDF
```ts
// Sans compte : passer le jeton en en-tête
await supabase.functions.invoke(`plans/${planId}`, { method: "GET", headers: { "x-claim-token": claimToken } });
const { data } = await supabase.functions.invoke(`plans/${planId}/pdf`, { method: "GET", headers: { "x-claim-token": claimToken } });
window.location.href = data.url; // lien valable 1 h
```
Connecté : mêmes appels sans l'en-tête (ou `supabase.from("plans").select("*").eq("is_current", true)`).

Contenu du plan (`plan.content`) : `headline`, `summary`, `sections[6]` (`key`, `title`, `clair`, `points[]`,
`detail_pro`, `actions[]`) → vue « En clair » / « Détail pro » ; `weekly_plan[4]` ; `recommended_visuals[3]`
(`type_code`, `title`, `brief`, `why` → bouton « Commander ce visuel » pré-rempli) ; `kpis[3]` ; `next_step`.

### Rattacher le plan au compte (juste après la connexion)
```ts
await supabase.rpc("claim_plan", { p_plan_id: planId, p_claim_token: claimToken });
```
Crée automatiquement la première marque à partir des réponses. Puis effacez le jeton local.

### Mettre à jour le plan (Pro : 1/mois, Max : 3/mois)
```ts
await supabase.functions.invoke(`plans/${planId}/regenerate`, { body: { answers /* facultatif */ } });
```
`REGEN_QUOTA_EXCEEDED` (402) → proposer l'offre supérieure.

---

## 2. Connexion

```ts
// Google
await supabase.auth.signInWithOAuth({ provider: "google", options: { redirectTo: location.origin + "/mon-espace" } });

// Code WhatsApp (par défaut) — numéro au format international
await supabase.auth.signInWithOtp({ phone: "+22890123456" });
await supabase.auth.verifyOtp({ phone: "+22890123456", token: "123456", type: "sms" });

// « Pas WhatsApp ? Recevoir par SMS » : à appeler AVANT signInWithOtp
await supabase.rpc("set_otp_channel", { p_phone: "+22890123456", p_channel: "sms" });
```
Parrainage (lien `?parrain=XXXX`) : mémorisez le code, puis juste après la première connexion (Google ou téléphone) :
`rpc("apply_referral_code", { p_code })` → `true` (appliqué) / `false` (déjà parrainé) ; erreurs
`INVALID_REFERRAL_CODE`, `REFERRAL_TOO_LATE` (après le premier abonnement). Avec le téléphone, on peut aussi passer
`options: { data: { referral_code } }` à `signInWithOtp`.
Changer de numéro plus tard : `supabase.auth.updateUser({ phone })` puis `verifyOtp({ type: "phone_change" })`.

---

## 3. Mon espace

| Donnée | Appel |
|---|---|
| Profil | `from("profiles").select("*").single()` — modifiable : `full_name`, `city`, `whatsapp_notifications`, `active_brand_id`, `avatar_path` |
| Droits du mois | `rpc("my_entitlements")` → `tier`, `tier_name`, `status` (`active`/`past_due`), `current_period_end`, `cancel_at_period_end`, `free_offer_available`, `static_remaining`, `video_remaining`, `regen_remaining`, `bonus_static`, `multi_brand` |
| Plan actuel | `from("plans").select("*").eq("is_current", true)` |
| Mes visuels | `from("requests").select("*, request_files(*)").order("created_at", { ascending: false })` |
| Notifications | `from("notifications").select("*").order("created_at", { ascending: false })` ; lu : `.update({ read_at: new Date().toISOString() })` |
| Parrainage | `profiles.referral_code` ; filleuls : `from("referrals").select("*")` |
| Factures | `from("invoices").select("*")` ; PDF : `functions.invoke("invoices/<id>/pdf", { method: "GET" })` → `{ url }` |

**Temps réel** (suivi de demande sans recharger) :
```ts
supabase.channel("moi").on("postgres_changes",
  { event: "*", schema: "public", table: "requests" }, handler).subscribe();
// tables diffusées : requests, request_messages, notifications
```

---

## 4. Profil de marque

```ts
await supabase.from("brands").insert({ owner_id: user.id, name, activity, domain, city, colors: ["#095CFF"] });
// Logo / photos : bucket "brand-assets", chemin "<user.id>/<nom>"
await supabase.storage.from("brand-assets").upload(`${user.id}/logo.png`, file);
await supabase.from("brands").update({ logo_path: `${user.id}/logo.png`, photo_paths: [...] }).eq("id", brandId);
```
2e marque en Gratuit → `MULTI_BRAND_REQUIRES_PRO`. Marque active : `profiles.active_brand_id`.

---

## 5. Commander un visuel

Types et prix : `from("creative_types").select("*").eq("active", true).order("sort")`
(`post` 5 000 F · 24 h, `carousel` 7 500 F · 48 h, `poster` 5 000 F · 72 h, `video` 10 000 F · 5 j).

```ts
const { data: req, error } = await supabase.rpc("create_request", {
  p_type_code: "post", p_title: "Promo de la Tabaski", p_brief: "Décrivez ce que vous voulez…",
  p_networks: ["whatsapp", "facebook"], p_express: false,
  p_brand_id: null /* marque active */, p_plan_id: planId /* facultatif */,
});
```
Le backend choisit le financement dans cet ordre : visuel offert (1re fois) → quota du mois → visuel bonus →
paiement. Réponse : `req.status` = `received` (rien à payer) ou `awaiting_payment` avec `req.amount_due_fcfa`
→ aller au paiement (section 6, `purpose: "request"`). Express : +50 % (supplément seul si le visuel est inclus).
`BRAND_REQUIRED` → ouvrir le profil de marque.

**Pièces jointes du client** : bucket `request-files`, chemin `<request.id>/client/<fichier>`, puis
`from("request_files").insert({ request_id, uploaded_by: user.id, kind: "brief_asset", storage_path, file_name, mime_type, size_bytes })`.

**Suivi** : statuts `awaiting_payment` → `received` (Reçue) → `in_progress` (En création) → `to_validate`
(À valider) → `delivered` (Livrée) ; `canceled`. Échéance : `due_at`.

**Messages** : `from("request_messages").insert({ request_id, author_id: user.id, body })` ;
lecture : `from("request_messages").select("*").eq("request_id", id).order("created_at")`
(`kind` : `message`, `revision`, `system`).

**Livrables** : `request_files` avec `kind = "deliverable"` ; téléchargement :
`storage.from("request-files").createSignedUrl(storage_path, 3600, { download: true })`.

| Action client | Appel |
|---|---|
| Valider (+ accord portfolio) | `rpc("approve_request", { p_request_id, p_portfolio_allowed: true })` |
| Demander une modification (2 incluses) | `rpc("request_revision", { p_request_id, p_message })` — `NO_REVISIONS_LEFT` |
| Annuler (avant démarrage) | `rpc("cancel_request", { p_request_id })` — le quota ou le visuel offert est rendu |

Sans action du client, un visuel « À valider » passe « Livré » au bout de 5 jours.

---

## 6. Paiement (FedaPay : Flooz, T-Money, carte)

Offres : `from("tiers").select("*").order("sort")` (visible sans compte → page Tarifs).

```ts
const { data } = await supabase.functions.invoke("payments/checkout", {
  body: { purpose: "subscription", tier: "pro", method: "flooz", phone: "+22890123456" },
  // ou { purpose: "request", request_id, method: "tmoney" | "card" }
});
```
Réponses :
- `mode: "push"` → « Confirmez sur votre téléphone » (le client tape son code secret Flooz/T-Money) ;
- `mode: "redirect"` → ouvrir `data.checkout_url` (carte, ou si le paiement direct est indisponible) ;
  retour sur `{APP_URL}/paiement/retour?payment_id=…`.

Puis interroger toutes les 3-5 s (2 minutes max) :
```ts
const { data } = await supabase.functions.invoke(`payments/${data.payment_id}`, { method: "GET" });
// data.payment.status : pending | succeeded | failed | canceled ; data.invoice = { id, number } si payé
```
`failed` → écran « Le paiement n'est pas passé » (l'offre actuelle reste active).
Renouvellement : même appel avec le même `tier` (les jours restants sont conservés).
Résilier / reprendre : `rpc("cancel_subscription")` / `rpc("resume_subscription")`.

---

## 7. Compte

```ts
await supabase.functions.invoke("account/delete", { method: "POST" });  // puis supabase.auth.signOut()
```
Efface le compte et les données personnelles ; les factures sont conservées (obligation comptable).
`PAYMENT_PENDING` (409) si un paiement est en cours.

---

## 8. Pages publiques

| Donnée | Appel |
|---|---|
| Tarifs | `from("tiers").select("*")` (`features[]` = liste à puces) |
| Types de visuels | `from("creative_types").select("*")` |
| Portfolio avant/après | `from("portfolio_items").select("*").eq("published", true).order("sort")` ; images dans le bucket public `public-assets` |
| Équipe (prénom, rôle, photo) | `rpc("team_public")` |

---

## 9. Back-office (rôles `creative` et `admin`)

La même RLS donne à l'équipe la vue sur toutes les demandes, marques, plans, paiements.

| Écran | Appel |
|---|---|
| Tableau de bord | `rpc("admin_dashboard")` → `requests_by_status`, `requests_late`, `requests_due_today`, `subscribers_by_tier`, `mrr_fcfa`, `revenue_month_fcfa`, `plans_month`, `new_clients_month`, `conversion_rate`, `team_load[]` |
| Demandes | `from("requests").select("*, brands(*), profiles!requests_owner_id_fkey(full_name, phone)")` |
| Changer le statut | `rpc("staff_set_request_status", { p_request_id, p_status: "in_progress" \| "to_validate" \| ... })` — `to_validate` exige un livrable (`DELIVERABLE_REQUIRED`) |
| Assigner | `rpc("assign_request", { p_request_id, p_assignee })` |
| Déposer un livrable | upload `request-files` → `<request_id>/team/<fichier>` puis insert `request_files` (`kind: "deliverable"` ou `"source"`, `format_label: "Story 1080×1920"`) |
| Répondre au client | insert `request_messages` (le client est notifié, WhatsApp compris) |
| Plans | `from("plans").select("*")` ; corriger : `.update({ content, review_note })` (le PDF se régénère) |
| Clients / paiements | `from("profiles")`, `from("subscriptions")`, `from("payments")`, `from("invoices")` |
| Rembourser (admin) | rembourser d'abord dans FedaPay, puis `rpc("admin_refund_payment", { p_payment_id, p_reason })` |
| Équipe (admin) | `functions.invoke("admin/invite", { body: { email \| phone, full_name, role: "creative", team_title } })` ; `rpc("admin_set_role", { p_user, p_role, p_team_title })` |
| Réglages (admin) | `from("tiers").update(...)`, `from("creative_types").update(...)`, `from("settings").update({ value })` — clés : `express_multiplier`, `revisions_included`, `auto_approve_days`, `renewal_grace_days`, `referral_reward_static`, `plan_daily_cap`, `plan_limit_per_ip_per_day`, `support_whatsapp`, `seller`, `whatsapp_auto` (types de notification envoyés sur WhatsApp) |
| Portfolio (admin) | `from("portfolio_items").insert(...)` — publication refusée sans accord du client (`PORTFOLIO_CONSENT_MISSING`) |
