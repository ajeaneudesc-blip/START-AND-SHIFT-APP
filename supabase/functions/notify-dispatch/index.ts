// Edge Function "notify-dispatch" — appelée chaque minute par pg_cron (uniquement s'il y a des envois en attente).
// Envoie les notifications WhatsApp en file d'attente via un modèle Meta UTILITY.
import { json } from "../_shared/http.ts";
import { adminClient, setting } from "../_shared/supabase.ts";
import { MessagingError, sendWhatsappNotification, whatsappConfigured } from "../_shared/messaging.ts";

const BATCH = 50;
const MAX_ATTEMPTS = 3;

Deno.serve(async (req) => {
  const db = adminClient();
  const { data: allowed } = await db.rpc("verify_cron_secret", { p_secret: req.headers.get("x-cron-secret") ?? "" });
  if (!allowed) return json({ error: "FORBIDDEN" }, 403);

  const { data: pending } = await db.from("notifications")
    .select("id, user_id, title, body, whatsapp_attempts, profiles!inner(phone, whatsapp_notifications)")
    .eq("whatsapp_status", "pending").order("created_at").limit(BATCH);
  if (!pending?.length) return json({ sent: 0 });

  // WhatsApp pas encore configuré : on garde les messages in-app et on vide la file
  if (!whatsappConfigured()) {
    await db.from("notifications").update({ whatsapp_status: "skipped", whatsapp_error: "WHATSAPP_NOT_CONFIGURED" })
      .in("id", pending.map((n) => n.id));
    return json({ sent: 0, skipped: pending.length });
  }

  const template = await setting("whatsapp_template", { name: "sas_notification", language: "fr" });
  let sent = 0;
  for (const n of pending) {
    const profile = n.profiles as unknown as { phone: string | null; whatsapp_notifications: boolean };
    if (!profile?.phone || !profile.whatsapp_notifications) {
      await db.from("notifications").update({ whatsapp_status: "skipped" }).eq("id", n.id);
      continue;
    }
    try {
      await sendWhatsappNotification(profile.phone, n.title, n.body, template);
      await db.from("notifications").update({ whatsapp_status: "sent", whatsapp_attempts: n.whatsapp_attempts + 1, whatsapp_error: null }).eq("id", n.id);
      sent++;
    } catch (e) {
      const err = e as MessagingError;
      const attempts = n.whatsapp_attempts + 1;
      await db.from("notifications").update({
        whatsapp_status: err.permanent || attempts >= MAX_ATTEMPTS ? "failed" : "pending",
        whatsapp_attempts: attempts,
        whatsapp_error: err.message.slice(0, 300),
      }).eq("id", n.id);
    }
  }
  return json({ sent, total: pending.length });
});
