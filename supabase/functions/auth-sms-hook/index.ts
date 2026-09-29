// Edge Function "auth-sms-hook" — Hook "Send SMS" de Supabase Auth.
// Envoie le code de connexion par WhatsApp (par défaut) ou par SMS si l'utilisateur l'a demandé
// ("Pas WhatsApp ? Recevoir par SMS" → RPC set_otp_channel avant signInWithOtp).
// Si WhatsApp échoue (numéro sans WhatsApp), bascule automatique sur SMS.
import { Webhook } from "npm:standardwebhooks@1.1.1";
import { adminClient } from "../_shared/supabase.ts";
import { MessagingError, sendWhatsappOtp, smsProvider, whatsappConfigured } from "../_shared/messaging.ts";

const reply = (status: number, body: unknown = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  const secret = Deno.env.get("SEND_SMS_HOOK_SECRET");
  if (!secret) return reply(500, { error: { http_code: 500, message: "Hook non configuré" } });

  const payload = await req.text();
  let event: { user: { phone: string }; sms: { otp: string } };
  try {
    event = new Webhook(secret.replace("v1,whsec_", "")).verify(payload, Object.fromEntries(req.headers)) as typeof event;
  } catch {
    return reply(401, { error: { http_code: 401, message: "Signature invalide" } });
  }

  const phone = event.user.phone.replace(/\D/g, "");
  const code = event.sms.otp;
  const { data: pref } = await adminClient().from("otp_channel_prefs").select("channel").eq("phone", phone).maybeSingle();
  const wantSms = pref?.channel === "sms" || !whatsappConfigured();

  if (!wantSms) {
    try {
      await sendWhatsappOtp(phone, code);
      return reply(200);
    } catch (e) {
      console.warn("[auth-sms-hook] WhatsApp KO, bascule SMS", (e as MessagingError).message);
    }
  }
  try {
    await smsProvider().send(phone, `Start And Shift : votre code est ${code}. Il expire dans 10 minutes. Ne le partagez avec personne.`);
    return reply(200);
  } catch (e) {
    console.error("[auth-sms-hook] SMS KO", e);
    return reply(502, { error: { http_code: 502, message: "Impossible d'envoyer le code. Réessayez." } });
  }
});
