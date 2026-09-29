// Edge Function "plans"
//   POST /plans/generate            génère un plan (sans compte possible) — renvoie un claim_token si anonyme
//   GET  /plans/:id                 lit un plan (propriétaire, équipe, ou jeton x-claim-token / ?token=)
//   POST /plans/:id/regenerate      nouvelle version du plan (quota Pro/Max ; illimité pour l'équipe)
//   GET  /plans/:id/pdf             URL signée du PDF (généré à la demande, mis en cache)
import { clientIp, HttpError, json, randomToken, readJson, serve, sha256Hex, fromPostgrestError } from "../_shared/http.ts";
import { adminClient, optionalUser, requireUser, roleOf, setting, userClient } from "../_shared/supabase.ts";
import { AnswersSchema, type Answers, type PlanContent } from "../_shared/plan-schema.ts";
import { generatePlan } from "../_shared/plan-generator.ts";
import { renderPlanPdf } from "../_shared/pdf.ts";

const PUBLIC_FIELDS = "id, owner_id, brand_id, parent_plan_id, answers, status, content, model, is_current, reviewed_at, created_at, updated_at, expires_at";

function parseAnswers(raw: unknown): Answers {
  const r = AnswersSchema.safeParse(raw);
  if (!r.success) {
    throw new HttpError(400, "INVALID_ANSWERS", r.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join(" ; "));
  }
  return r.data;
}

async function enforceBudget(ipHash: string, isStaff: boolean) {
  const db = adminClient();
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const [perIp, cap] = await Promise.all([
    setting<number>("plan_limit_per_ip_per_day", 3),
    setting<number>("plan_daily_cap", 40),
  ]);
  const { count: total } = await db.from("plan_generation_log").select("id", { count: "exact", head: true }).gte("created_at", since);
  if ((total ?? 0) >= cap) {
    throw new HttpError(503, "PLAN_DAILY_CAP", "Beaucoup de plans ont été préparés aujourd'hui. Revenez dans quelques heures.");
  }
  if (isStaff) return;
  const { count } = await db.from("plan_generation_log").select("id", { count: "exact", head: true })
    .eq("ip_hash", ipHash).gte("created_at", since);
  if ((count ?? 0) >= perIp) {
    throw new HttpError(429, "PLAN_RATE_LIMIT", "Vous avez déjà préparé plusieurs plans aujourd'hui. Réessayez demain.");
  }
}

// Crée la ligne, appelle l'IA, enregistre le résultat. Renvoie la ligne finale.
async function runGeneration(row: Record<string, unknown>, answers: Answers, ipHash: string, userId: string | null) {
  const db = adminClient();
  const { data: plan, error } = await db.from("plans").insert({ ...row, answers, status: "generating" }).select("id").single();
  if (error) throw error;
  await db.from("plan_generation_log").insert({ ip_hash: ipHash, user_id: userId, plan_id: plan.id });

  try {
    const result = await generatePlan(answers);
    const { data: done, error: e2 } = await db.from("plans").update({
      status: "ready",
      content: result.content,
      model: result.model,
      input_tokens: result.input_tokens,
      output_tokens: result.output_tokens,
    }).eq("id", plan.id).select(PUBLIC_FIELDS).single();
    if (e2) throw e2;
    return done;
  } catch (e) {
    await db.from("plans").update({ status: "failed", error: String((e as Error).message ?? e).slice(0, 500) }).eq("id", plan.id);
    throw e;
  }
}

async function loadPlan(req: Request, id: string) {
  const token = req.headers.get("x-claim-token") ?? new URL(req.url).searchParams.get("token");
  if (token) {
    const { data } = await adminClient().from("plans").select(`${PUBLIC_FIELDS}, claim_token_hash`).eq("id", id).maybeSingle();
    if (data && data.owner_id === null && data.claim_token_hash === (await sha256Hex(token))) {
      const { claim_token_hash: _drop, ...plan } = data;
      return plan;
    }
  }
  const user = await optionalUser(req);
  if (!user) throw new HttpError(404, "PLAN_NOT_FOUND", "Plan introuvable ou expiré.");
  const { data } = await userClient(req).from("plans").select(PUBLIC_FIELDS).eq("id", id).maybeSingle();
  if (!data) throw new HttpError(404, "PLAN_NOT_FOUND", "Plan introuvable.");
  return data;
}

serve("plans", async (req, path) => {
  const ipHash = await sha256Hex(`${Deno.env.get("IP_HASH_SALT") ?? "sas"}:${clientIp(req)}`);

  // POST /plans/generate
  if (req.method === "POST" && path[0] === "generate") {
    const body = await readJson<{ answers: unknown }>(req);
    const answers = parseAnswers(body.answers);
    const user = await optionalUser(req);
    const staff = user ? (await roleOf(user.id)) !== "client" : false;
    await enforceBudget(ipHash, staff);

    const claimToken = randomToken();
    const ttlDays = await setting<number>("anonymous_plan_ttl_days", 7);
    const plan = await runGeneration({
      claim_token_hash: await sha256Hex(claimToken),
      expires_at: new Date(Date.now() + ttlDays * 86400_000).toISOString(),
    }, answers, ipHash, user?.id ?? null);

    if (user) {
      // Connecté : rattachement immédiat (crée la marque si besoin)
      const { data, error } = await userClient(req).rpc("claim_plan", { p_plan_id: plan.id, p_claim_token: claimToken });
      if (error) throw fromPostgrestError(error);
      return json({ plan: { ...plan, ...pick(data) } }, 201);
    }
    return json({ plan, claim_token: claimToken }, 201);
  }

  const id = path[0];
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) throw new HttpError(404, "NOT_FOUND");

  // GET /plans/:id
  if (req.method === "GET" && path.length === 1) {
    return json({ plan: await loadPlan(req, id) });
  }

  // POST /plans/:id/regenerate
  if (req.method === "POST" && path[1] === "regenerate") {
    const user = await requireUser(req);
    const body = await readJson<{ answers?: unknown }>(req).catch(() => ({} as { answers?: unknown }));
    const { data: current } = await userClient(req).from("plans").select("id, owner_id, brand_id, answers").eq("id", id).maybeSingle();
    if (!current || !current.owner_id) throw new HttpError(404, "PLAN_NOT_FOUND", "Plan introuvable.");

    const staff = (await roleOf(user.id)) !== "client";
    const isOwner = current.owner_id === user.id;
    if (!isOwner && !staff) throw new HttpError(403, "FORBIDDEN");
    if (isOwner && !staff) {
      const { data: ok, error } = await userClient(req).rpc("consume_plan_regeneration");
      if (error) throw fromPostgrestError(error);
      if (!ok) {
        throw new HttpError(402, "REGEN_QUOTA_EXCEEDED", "Vous avez utilisé vos mises à jour du mois. Passez à l'offre supérieure pour en obtenir plus.");
      }
    }
    const answers = parseAnswers(body.answers ?? current.answers);
    await enforceBudget(ipHash, true); // plafond global uniquement : la régénération est déjà limitée par le quota

    let plan;
    try {
      plan = await runGeneration({
        owner_id: current.owner_id,
        brand_id: current.brand_id,
        parent_plan_id: current.id,
        is_current: false,
      }, answers, ipHash, user.id);
    } catch (e) {
      if (isOwner && !staff) await userClient(req).rpc("refund_plan_regeneration");
      throw e;
    }
    const db = adminClient();
    await db.from("plans").update({ is_current: false }).eq("owner_id", current.owner_id).eq("brand_id", current.brand_id).eq("is_current", true);
    await db.from("plans").update({ is_current: true }).eq("id", plan.id);
    return json({ plan: { ...plan, is_current: true } }, 201);
  }

  // GET /plans/:id/pdf
  if (req.method === "GET" && path[1] === "pdf") {
    const plan = await loadPlan(req, id);
    if (plan.status !== "ready" || !plan.content) throw new HttpError(409, "PLAN_NOT_READY", "Le plan n'est pas encore prêt.");
    const db = adminClient();
    // Version = empreinte du contenu : une correction par l'équipe produit un nouveau PDF
    const version = (await sha256Hex(JSON.stringify(plan.content))).slice(0, 16);
    const pdfPath = `${id}/${version}.pdf`;

    const { data: existing } = await db.from("plans").select("pdf_path").eq("id", id).single();
    if (existing?.pdf_path !== pdfPath) {
      const answers = plan.answers as Answers;
      const bytes = await renderPlanPdf(plan.content as PlanContent, {
        business: answers.business?.split(",")[0]?.trim() || "Votre activité",
        date: new Date(plan.updated_at as string),
      });
      const up = await db.storage.from("plans").upload(pdfPath, bytes, { contentType: "application/pdf", upsert: true });
      if (up.error) throw up.error;
      if (existing?.pdf_path) await db.storage.from("plans").remove([existing.pdf_path]);
      await db.from("plans").update({ pdf_path: pdfPath }).eq("id", id);
    }
    const filename = `plan-${(plan.answers as Answers).business?.split(",")[0]?.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-") || "start-and-shift"}.pdf`;
    const { data: signed, error } = await db.storage.from("plans").createSignedUrl(pdfPath, 3600, { download: filename });
    if (error) throw error;
    return json({ url: signed.signedUrl, expires_in: 3600 });
  }

  throw new HttpError(404, "NOT_FOUND");
});

function pick(row: unknown): Record<string, unknown> {
  const r = (row ?? {}) as Record<string, unknown>;
  return { owner_id: r.owner_id, brand_id: r.brand_id, is_current: r.is_current, expires_at: r.expires_at };
}
