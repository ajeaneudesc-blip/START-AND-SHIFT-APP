import { adminClient } from "./supabase.ts";
import type { FedaTransaction } from "./fedapay.ts";

export interface PaymentRow {
  id: string;
  user_id: string;
  status: string;
  amount_fcfa: number;
  provider_txn_id: string | null;
}

// Applique le statut FedaPay (déjà revérifié auprès de l'API) à notre paiement. Idempotent.
export async function reconcile(payment: PaymentRow, txn: FedaTransaction): Promise<string> {
  const db = adminClient();
  const raw = { fedapay_id: txn.id, reference: txn.reference, status: txn.status, mode: txn.mode ?? null };

  if (txn.status === "approved" || txn.status === "transferred") {
    if (Number(txn.amount) !== payment.amount_fcfa) {
      console.error("[payments] montant incohérent", payment.id, txn.amount, payment.amount_fcfa);
      await db.from("payments").update({ failure_reason: "AMOUNT_MISMATCH", raw }).eq("id", payment.id);
      return "mismatch";
    }
    if (txn.mode) await db.from("payments").update({ method: txn.mode }).eq("id", payment.id);
    const { error } = await db.rpc("apply_payment_success", { p_payment_id: payment.id, p_raw: raw });
    if (error) throw error;
    return "succeeded";
  }
  if (txn.status === "declined" || txn.status === "canceled") {
    const { error } = await db.rpc("apply_payment_failure", {
      p_payment_id: payment.id,
      p_status: txn.status === "declined" ? "failed" : "canceled",
      p_reason: txn.status,
      p_raw: raw,
    });
    if (error) throw error;
    return txn.status === "declined" ? "failed" : "canceled";
  }
  return "pending";
}
