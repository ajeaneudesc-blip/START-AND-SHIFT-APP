// Edge Function "fedapay-webhook" — URL à déclarer dans le tableau de bord FedaPay (Webhooks).
// La signature est vérifiée, puis le statut est TOUJOURS revérifié auprès de l'API FedaPay :
// le contenu du webhook n'est jamais cru sur parole.
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { getTransaction, verifyWebhookSignature } from "../_shared/fedapay.ts";
import { reconcile } from "../_shared/payments.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const payload = await req.text();
  const secret = Deno.env.get("FEDAPAY_WEBHOOK_SECRET");
  if (!secret) {
    console.error("[fedapay-webhook] FEDAPAY_WEBHOOK_SECRET manquant");
    return json({ error: "NOT_CONFIGURED" }, 503);
  }
  const header = req.headers.get("x-fedapay-signature");
  if (!(await verifyWebhookSignature(payload, header, secret))) {
    return json({ error: "INVALID_SIGNATURE" }, 401);
  }

  let event: { name?: string; entity?: { id?: number; custom_metadata?: { payment_id?: string } } };
  try {
    event = JSON.parse(payload);
  } catch {
    return json({ error: "INVALID_JSON" }, 400);
  }
  const txnId = event.entity?.id;
  if (!event.name?.startsWith("transaction.") || !txnId) return json({ ignored: true });

  const db = adminClient();
  let { data: payment } = await db.from("payments").select("id, user_id, status, amount_fcfa, provider_txn_id")
    .eq("provider_txn_id", String(txnId)).maybeSingle();
  if (!payment && event.entity?.custom_metadata?.payment_id) {
    ({ data: payment } = await db.from("payments").select("id, user_id, status, amount_fcfa, provider_txn_id")
      .eq("id", event.entity.custom_metadata.payment_id).is("provider_txn_id", null).maybeSingle());
  }
  if (!payment) {
    console.warn("[fedapay-webhook] transaction inconnue", txnId);
    return json({ ignored: true });
  }

  try {
    const txn = await getTransaction(txnId);
    const status = await reconcile(payment, txn);
    return json({ ok: true, status });
  } catch (e) {
    console.error("[fedapay-webhook]", e);
    return json({ error: "RETRY" }, 500); // FedaPay renverra l'événement
  }
});
