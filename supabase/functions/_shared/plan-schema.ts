import { z } from "npm:zod@4.6.5";

// Réponses du questionnaire (10 écrans). Les libellés affichés sont envoyés tels quels :
// le front reste libre de reformuler les options sans casser le backend.
const short = (max: number) => z.string().trim().max(max);

export const AnswersSchema = z.object({
  for_whom: short(60),                       // Q1 Mon activité / L'activité d'un client
  business: short(200).min(2),               // Q2 nom + ce qu'on vend
  domain: short(60),                         // Q3
  customer_type: short(60),                  // Q4a Particuliers / Entreprises / Les deux
  customer_zone: short(60),                  // Q4b Ma ville / Tout le pays / ...
  sales_channels: z.array(short(60)).max(10), // Q5 (multiple)
  trigger: short(120),                       // Q6
  priority: short(120),                      // Q7
  budget: short(60),                         // Q8
  time_per_week: short(60),                  // Q9
  blockers: z.array(short(120)).max(10),     // Q10 (multiple)
  differentiator: short(500).optional(),     // Q10 bis (facultatif)
  city: short(60).optional(),
  country: short(60).optional(),
});
export type Answers = z.infer<typeof AnswersSchema>;

// Plan généré. Pas de contraintes min/max : non prises en charge par les sorties structurées.
const Section = z.object({
  key: z.enum(["situation", "clients", "message", "canaux", "contenus", "budget"]),
  title: z.string().describe("Titre court et concret, sans jargon"),
  clair: z.string().describe("En clair : 2 ou 3 phrases simples, tutoiement interdit, vouvoiement"),
  points: z.array(z.string()).describe("3 à 5 points clés, une phrase courte chacun"),
  detail_pro: z.string().describe("Détail pro : 2 à 4 paragraphes argumentés, vocabulaire marketing autorisé"),
  actions: z.array(z.string()).describe("2 à 4 actions concrètes à faire cette semaine"),
});

const Post = z.object({
  day: z.string().describe("Jour de la semaine, ex. Mardi"),
  channel: z.string().describe("Canal parmi ceux utilisés par le client"),
  format: z.string().describe("Statut, post, carrousel, vidéo courte, live…"),
  idea: z.string().describe("Idée de publication précise, prête à produire"),
});

export const PlanSchema = z.object({
  headline: z.string().describe("Le conseil n°1 en une phrase motivante (max 12 mots)"),
  summary: z.string().describe("Résumé du plan en 3 phrases simples"),
  sections: z.array(Section).describe("Exactement 6 sections, dans l'ordre des clés"),
  weekly_plan: z.array(z.object({
    week: z.number().int(),
    focus: z.string().describe("Objectif de la semaine en une phrase"),
    posts: z.array(Post).describe("3 à 5 publications"),
  })).describe("4 semaines"),
  recommended_visuals: z.array(z.object({
    type_code: z.enum(["post", "carousel", "poster", "video"]),
    title: z.string(),
    brief: z.string().describe("Ce que le visuel doit montrer et dire, 2-3 phrases, prêt à commander"),
    why: z.string().describe("Pourquoi ce visuel aide à atteindre la priorité, 1 phrase"),
  })).describe("3 visuels à commander en priorité"),
  kpis: z.array(z.object({
    name: z.string(),
    target: z.string().describe("Objectif réaliste et vérifiable, sans chiffre inventé sur le marché"),
    how_to_measure: z.string(),
  })).describe("3 indicateurs simples à suivre"),
  next_step: z.string().describe("Première action à faire aujourd'hui, 1 phrase"),
});
export type PlanContent = z.infer<typeof PlanSchema>;
