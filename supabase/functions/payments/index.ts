// Edge Function "payments"
//   POST /payments/checkout   { purpose: "subscription", tier } | { purpose: "request", request_id }
//                             + { method?: "flooz" | "tmoney" | "card", phone? }
//        → { payment_id, mode: "push" }  (Mobile Money : confirmation sur le téléphone)
//        → { payment_id, mode: "redirect", checkout_url }  (page FedaPay : carte ou choix du moyen)
//   GET  /payments/:id        statut (resynchronisé auprès de FedaPay si en attente)
import { fromPostgrestError, HttpError, json, readJson, serve } from "../_shared/http.ts";
import { adminClient, requireUser, userClient } from "../_shared/supabase.ts";
import { createPaymentLink, createTransaction, fedapayConfigured, getTransaction, MOBILE_MODES, sendMobileMoney } from "../_shared/fedapay.ts";
import { reconcile } from "../_shared/payments.ts";

interface CheckoutBody {
  purpose: "subscription" | "request";
  tier?: "pro" | "max";
  request_id?: string;
  method?: "flooz" | "tmoney" | "card";
  phone?: string;
}

const mockPayments = () => Deno.env.get("PAYMENTS_MOCK") === "true" && Deno.env.get("FEDAPAY_ENV") !== "live";

serve("payments", async (req, path) => {
  const user = await requireUser(req);
  const db = adminClient();

  if (req.method === "POST" && path[0] === "checkout") {
    const body = await readJson<CheckoutBody>(req);
    if (body.purpose === "subscription" && !["pro", "max"].includes(body.tier ?? "")) {
      throw new HttpError(400, "INVALID_TIER", "Choisissez l'offre Pro ou Max.");
    }
    if (body.purpose === "request" && !body.request_id) throw new HttpError(400, "REQUEST_ID_REQUIRED");
    if (body.method && body.method !== "card" && !MOBILE_MODES[body.method]) throw new HttpError(400, "UNSUPPORTED_METHOD");

    const { data: payment, error } = await db.rpc("create_payment", {
      p_user: user.id,
      p_purpose: body.purpose === "subscription" ? "subscription" : "creative_unit",
      p_tier: body.purpose === "subscription" ? body.tier : null,
      p_request_id: body.purpose === "request" ? body.request_id : null,
      p_method: body.method ?? null,
    });
    if (error) throw fromPostgrestError(error);

    // Mode développement : paiement accepté immédiatement, sans prestataire
    if (!fedapayConfigured() && mockPayments()) {
      const { error: e } = await db.rpc("apply_payment_success", { p_payment_id: payment.id, p_raw: { mock: true } });
      if (e) throw e;
      return json({ payment_id: payment.id, mode: "mock", status: "succeeded" }, 201);
    }

    const { data: profile } = await db.from("profiles").select("full_name, email, phone").eq("id", user.id).single();
    const [firstname, ...rest] = (profile?.full_name ?? "").trim().split(/\s+/);
    let description = `Start And Shift · Offre ${body.tier === "max" ? "Max" : "Pro"} · 1 mois`;
    if (body.purpose === "request") {
      const { data: r } = await db.from("requests").select("ref, title").eq("id", payment.request_id).single();
      description = `Start And Shift · ${payment.purpose === "express_fee" ? "Express" : "Visuel"} ${r?.ref ?? ""} ${r?.title ?? ""}`.trim().slice(0, 200);
    }

    const txn = await createTransaction({
      amount: payment.amount_fcfa,
      description,
      callbackUrl: `${Deno.env.get("APP_URL") ?? "https://startandshift.com"}/paiement/retour?payment_id=${payment.id}`,
      paymentId: payment.id,
      customer: { firstname, lastname: rest.join(" "), email: profile?.email, phone: body.phone ?? profile?.phone },
    });
    await db.from("payments").update({ provider_txn_id: String(txn.id) }).eq("id", payment.id);
    const link = await createPaymentLink(txn.id);

    const phone = body.phone ?? profile?.phone;
    if (body.method && body.method !== "card" && phone) {
      try {
        await sendMobileMoney(link.token, body.method, phone);
        return json({ payment_id: payment.id, mode: "push", checkout_url: link.url }, 201);
      } catch (e) {
        // Paiement direct indisponible : on bascule sur la page FedaPay
        console.warn("[payments] push mobile money impossible, redirection", (e as Error).message);
      }
    }
    return json({ payment_id: payment.id, mode: "redirect", checkout_url: link.url }, 201);
  }

  const id = path[0];
  if (req.method === "GET" && id && /^[0-9a-f-]{36}$/i.test(id)) {
    const { data: payment } = await userClient(req).from("payments")
      .select("id, user_id, purpose, tier, request_id, amount_fcfa, status, method, provider_txn_id, failure_reason, paid_at, created_at")
      .eq("id", id).maybeSingle();
    if (!payment) throw new HttpError(404, "PAYMENT_NOT_FOUND");

    let status = payment.status;
    if (status === "pending" && payment.provider_txn_id && fedapayConfigured()) {
      status = await reconcile(payment, await getTransaction(payment.provider_txn_id)).catch((e) => {
        console.error("[payments] reconcile", e);
        return "pending";
      });
    }
    const { data: invoice } = await db.from("invoices").select("id, number").eq("payment_id", id).maybeSingle();
    const { provider_txn_id: _p, user_id: _u, ...rest } = payment;
    return json({ payment: { ...rest, status: status === "mismatch" ? "pending" : status }, invoice });
  }

  throw new HttpError(404, "NOT_FOUND");
});
