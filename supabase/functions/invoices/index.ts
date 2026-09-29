// Edge Function "invoices"
//   GET /invoices/:id/pdf → URL signée de la facture PDF (générée une fois, puis conservée)
import { HttpError, json, serve } from "../_shared/http.ts";
import { adminClient, requireUser, setting, userClient } from "../_shared/supabase.ts";
import { renderInvoicePdf } from "../_shared/pdf.ts";

const METHOD_LABEL: Record<string, string> = {
  flooz: "Flooz", moov_tg: "Flooz", tmoney: "T-Money", togocel: "T-Money", card: "Carte bancaire",
};

serve("invoices", async (req, path) => {
  await requireUser(req);
  const [id, action] = path;
  if (req.method !== "GET" || action !== "pdf" || !/^[0-9a-f-]{36}$/i.test(id ?? "")) throw new HttpError(404, "NOT_FOUND");

  // RLS : le client ne lit que ses factures, l'équipe les voit toutes
  const { data: inv } = await userClient(req).from("invoices")
    .select("id, number, user_id, label, amount_fcfa, customer, pdf_path, issued_at, payment_id").eq("id", id).maybeSingle();
  if (!inv) throw new HttpError(404, "INVOICE_NOT_FOUND", "Facture introuvable.");

  const db = adminClient();
  const { data: pay } = await db.from("payments").select("method, status").eq("id", inv.payment_id).single();
  const refunded = pay?.status === "refunded";
  const path_ = `${inv.user_id}/${inv.number}${refunded ? "-rembourse" : ""}.pdf`;

  if (inv.pdf_path !== path_) {
    const seller = await setting("seller", {
      name: "Start And Shift",
      address: "Lomé, Togo",
      legal: "",
    });
    const bytes = await renderInvoicePdf({
      number: inv.number,
      issued_at: inv.issued_at,
      label: inv.label,
      amount_fcfa: inv.amount_fcfa,
      method: METHOD_LABEL[pay?.method ?? ""] ?? pay?.method ?? null,
      customer: inv.customer ?? {},
      seller,
      refunded,
    });
    const up = await db.storage.from("invoices").upload(path_, bytes, { contentType: "application/pdf", upsert: true });
    if (up.error) throw up.error;
    await db.from("invoices").update({ pdf_path: path_ }).eq("id", inv.id);
  }

  const { data: signed, error } = await db.storage.from("invoices").createSignedUrl(path_, 3600, { download: `facture-${inv.number}.pdf` });
  if (error) throw error;
  return json({ url: signed.signedUrl, expires_in: 3600 });
});
