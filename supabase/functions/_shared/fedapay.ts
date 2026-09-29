// Client FedaPay minimal (API REST v1). Flooz, T-Money et carte bancaire.
// Doc : https://docs.fedapay.com — SDK de référence : github.com/fedapay/fedapay-php
import { HttpError } from "./http.ts";

export type FedaStatus = "pending" | "approved" | "declined" | "canceled" | "refunded" | "transferred" | string;

export interface FedaTransaction {
  id: number;
  reference?: string;
  amount: number;
  status: FedaStatus;
  mode?: string | null;
  custom_metadata?: Record<string, unknown> | null;
}

function baseUrl(): string {
  return Deno.env.get("FEDAPAY_ENV") === "live" ? "https://api.fedapay.com/v1" : "https://sandbox-api.fedapay.com/v1";
}

export function fedapayConfigured(): boolean {
  return Boolean(Deno.env.get("FEDAPAY_SECRET_KEY"));
}

async function call<T>(method: string, path: string, body?: unknown): Promise<T> {
  const key = Deno.env.get("FEDAPAY_SECRET_KEY");
  if (!key) throw new HttpError(503, "PAYMENT_UNAVAILABLE", "Le paiement n'est pas encore activé.");
  const res = await fetch(`${baseUrl()}${path}`, {
    method,
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", Accept: "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: Record<string, unknown> = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch { /* réponse non JSON */ }
  if (!res.ok) {
    console.error("[fedapay]", method, path, res.status, text.slice(0, 500));
    throw new HttpError(502, "PAYMENT_PROVIDER_ERROR", "Le service de paiement ne répond pas. Réessayez.");
  }
  return data as T;
}

// L'API enveloppe les objets sous une clé "v1/transaction" : on la retire si présente.
function unwrap(data: Record<string, unknown>, key: string): Record<string, unknown> {
  return (data[`v1/${key}`] as Record<string, unknown>) ?? (data[key] as Record<string, unknown>) ?? data;
}

// Numéro togolais "+228 90 12 34 56" → { number: "90123456", country: "tg" }
export function splitPhone(phone: string | null | undefined): { number: string; country: string } | undefined {
  const digits = (phone ?? "").replace(/\D/g, "");
  if (!digits) return undefined;
  const prefixes: Record<string, string> = { "228": "tg", "229": "bj", "225": "ci", "221": "sn", "226": "bf", "223": "ml", "227": "ne" };
  for (const [p, c] of Object.entries(prefixes)) {
    if (digits.startsWith(p) && digits.length > p.length + 6) return { number: digits.slice(p.length), country: c };
  }
  return { number: digits, country: "tg" };
}

export async function createTransaction(input: {
  amount: number;
  description: string;
  callbackUrl: string;
  paymentId: string;
  customer: { firstname?: string; lastname?: string; email?: string | null; phone?: string | null };
}): Promise<FedaTransaction> {
  const phone = splitPhone(input.customer.phone);
  const data = await call<Record<string, unknown>>("POST", "/transactions", {
    description: input.description,
    amount: input.amount,
    currency: { iso: "XOF" },
    callback_url: input.callbackUrl,
    custom_metadata: { payment_id: input.paymentId },
    customer: {
      firstname: input.customer.firstname || "Client",
      lastname: input.customer.lastname || "Start And Shift",
      ...(input.customer.email ? { email: input.customer.email } : {}),
      ...(phone ? { phone_number: phone } : {}),
    },
  });
  return unwrap(data, "transaction") as unknown as FedaTransaction;
}

export async function createPaymentLink(transactionId: number): Promise<{ token: string; url: string }> {
  const data = await call<{ token: string; url: string }>("POST", `/transactions/${transactionId}/token`);
  return { token: data.token, url: data.url };
}

// Paiement direct sans redirection : le client reçoit la demande de validation sur son téléphone.
// Modes Togo : Flooz (Moov Africa) = "moov_tg", T-Money (Togocel) = "togocel". Surchargeables par variable d'env.
export const MOBILE_MODES: Record<string, string> = {
  flooz: Deno.env.get("FEDAPAY_MODE_FLOOZ") ?? "moov_tg",
  tmoney: Deno.env.get("FEDAPAY_MODE_TMONEY") ?? "togocel",
};

export async function sendMobileMoney(token: string, method: string, phone: string): Promise<void> {
  const mode = MOBILE_MODES[method];
  if (!mode) throw new HttpError(400, "UNSUPPORTED_METHOD", "Moyen de paiement non pris en charge.");
  const p = splitPhone(phone);
  await call("POST", `/${mode}`, { token, ...(p ? { phone_number: p } : {}) });
}

export async function getTransaction(transactionId: number | string): Promise<FedaTransaction> {
  const data = await call<Record<string, unknown>>("GET", `/transactions/${transactionId}`);
  return unwrap(data, "transaction") as unknown as FedaTransaction;
}

// Vérifie l'en-tête X-FEDAPAY-SIGNATURE : "t=<timestamp>,s=<hmac_sha256_hex(secret, `${t}.${payload}`)>"
export async function verifyWebhookSignature(payload: string, header: string | null, secret: string, toleranceSec = 300): Promise<boolean> {
  if (!header) return false;
  let timestamp = "";
  const signatures: string[] = [];
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2).map((s) => s?.trim());
    if (k === "t") timestamp = v ?? "";
    if (k === "s" && v) signatures.push(v);
  }
  if (!/^\d+$/.test(timestamp) || signatures.length === 0) return false;
  if (toleranceSec > 0 && Math.abs(Date.now() / 1000 - Number(timestamp)) > toleranceSec) return false;

  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${payload}`)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return signatures.some((s) => timingSafeEqual(s, expected));
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
