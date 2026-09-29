// Envoi de messages : WhatsApp Cloud API (Meta) + SMS derrière une interface interchangeable.

const GRAPH = "https://graph.facebook.com/v21.0";

export class MessagingError extends Error {
  constructor(public channel: "whatsapp" | "sms", message: string, public permanent = false) {
    super(message);
  }
}

export function whatsappConfigured(): boolean {
  return Boolean(Deno.env.get("WHATSAPP_TOKEN") && Deno.env.get("WHATSAPP_PHONE_NUMBER_ID"));
}

const digits = (phone: string) => phone.replace(/\D/g, "");

async function graphSend(body: Record<string, unknown>): Promise<void> {
  const res = await fetch(`${GRAPH}/${Deno.env.get("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("WHATSAPP_TOKEN")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", ...body }),
  });
  if (!res.ok) {
    const text = await res.text();
    // 131026 : numéro sans WhatsApp / non joignable → inutile de réessayer
    const permanent = /131026|131030|"code":\s*100\b/.test(text);
    throw new MessagingError("whatsapp", `HTTP ${res.status}: ${text.slice(0, 300)}`, permanent);
  }
}

// Code de connexion : modèle d'authentification Meta (catégorie AUTHENTICATION, bouton "copier le code").
export async function sendWhatsappOtp(phone: string, code: string): Promise<void> {
  if (!whatsappConfigured()) throw new MessagingError("whatsapp", "WhatsApp non configuré");
  await graphSend({
    to: digits(phone),
    type: "template",
    template: {
      name: Deno.env.get("WHATSAPP_OTP_TEMPLATE") ?? "sas_code_connexion",
      language: { code: Deno.env.get("WHATSAPP_TEMPLATE_LANG") ?? "fr" },
      components: [
        { type: "body", parameters: [{ type: "text", text: code }] },
        { type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: code }] },
      ],
    },
  });
}

// Notification : modèle UTILITY générique à 2 variables ({{1}} titre, {{2}} message).
export async function sendWhatsappNotification(
  phone: string,
  title: string,
  body: string,
  template: { name: string; language: string },
): Promise<void> {
  if (!whatsappConfigured()) throw new MessagingError("whatsapp", "WhatsApp non configuré");
  const clip = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1)}…` : s).replace(/[\n\t]+/g, " ").replace(/ {4,}/g, "   ");
  await graphSend({
    to: digits(phone),
    type: "template",
    template: {
      name: template.name,
      language: { code: template.language },
      components: [{ type: "body", parameters: [{ type: "text", text: clip(title, 60) }, { type: "text", text: clip(body, 900) }] }],
    },
  });
}

// ---------------------------------------------------------------------------
// SMS : fournisseur à brancher plus tard (Africa's Talking, Twilio, opérateur local…).
// En attendant, le "mock" écrit le code dans les logs de la fonction (développement uniquement).
// ---------------------------------------------------------------------------
export interface SmsProvider {
  send(phone: string, text: string): Promise<void>;
}

class MockSms implements SmsProvider {
  async send(phone: string, text: string) {
    if (Deno.env.get("APP_ENV") === "production") {
      throw new MessagingError("sms", "Aucun fournisseur SMS configuré (SMS_PROVIDER)", true);
    }
    console.log(`[sms:mock] → +${digits(phone)} : ${text}`);
  }
}

export function smsProvider(): SmsProvider {
  switch (Deno.env.get("SMS_PROVIDER") ?? "mock") {
    // case "africastalking": return new AfricasTalkingSms();
    default:
      return new MockSms();
  }
}
