// Utilitaires HTTP communs aux Edge Functions : CORS, réponses JSON, erreurs typées.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") ?? "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-claim-token",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8", ...extra },
  });
}

// Erreurs Postgres levées par nos RPC : "CODE_METIER" (+ hint lisible) → réponse HTTP propre
export function fromPostgrestError(err: { message?: string; hint?: string | null; code?: string }): HttpError {
  const code = (err.message ?? "DB_ERROR").split(" ")[0];
  const status = err.code === "42501" ? 403 : err.code === "P0002" ? 404 : 400;
  return new HttpError(status, code, err.hint ?? err.message);
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, "INVALID_JSON", "Corps de requête JSON invalide.");
  }
}

export function clientIp(req: Request): string {
  return (
    req.headers.get("cf-connecting-ip") ??
      req.headers.get("x-forwarded-for")?.split(",")[0].trim() ??
      req.headers.get("x-real-ip") ??
      "unknown"
  );
}

export async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function randomToken(bytes = 24): string {
  const arr = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...arr)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

type Handler = (req: Request, path: string[]) => Promise<Response>;

// Enveloppe commune : CORS, routage par segments après le nom de la fonction, erreurs.
export function serve(name: string, handler: Handler) {
  Deno.serve(async (req) => {
    if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
    const url = new URL(req.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const idx = parts.indexOf(name);
    const path = idx >= 0 ? parts.slice(idx + 1) : parts;
    try {
      return await handler(req, path);
    } catch (e) {
      if (e instanceof HttpError) {
        return json({ error: e.code, message: e.message }, e.status);
      }
      console.error(`[${name}]`, e);
      return json({ error: "INTERNAL_ERROR", message: "Une erreur est survenue. Réessayez dans un instant." }, 500);
    }
  });
}
