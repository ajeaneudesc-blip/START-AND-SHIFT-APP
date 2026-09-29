import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.117.2";
import { HttpError } from "./http.ts";

const url = () => Deno.env.get("SUPABASE_URL")!;

// Client service_role : contourne la RLS, réservé au code serveur.
export function adminClient(): SupabaseClient {
  return createClient(url(), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Client agissant au nom de l'utilisateur (RLS appliquée, auth.uid() renseigné dans les RPC).
export function userClient(req: Request): SupabaseClient {
  return createClient(url(), Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function bearer(req: Request): string | null {
  const h = req.headers.get("Authorization") ?? "";
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1] : null;
}

// Renvoie l'utilisateur connecté, ou null (les clés anon/publishable ne sont pas des sessions).
export async function optionalUser(req: Request): Promise<User | null> {
  const token = bearer(req);
  if (!token || token.startsWith("sb_")) return null;
  const { data, error } = await adminClient().auth.getUser(token);
  if (error || !data.user || data.user.is_anonymous) return null;
  return data.user;
}

export async function requireUser(req: Request): Promise<User> {
  const user = await optionalUser(req);
  if (!user) throw new HttpError(401, "AUTH_REQUIRED", "Connectez-vous pour continuer.");
  return user;
}

export async function roleOf(userId: string): Promise<"client" | "creative" | "admin"> {
  const { data } = await adminClient().from("profiles").select("role").eq("id", userId).single();
  return (data?.role ?? "client") as "client" | "creative" | "admin";
}

export async function setting<T>(key: string, fallback: T): Promise<T> {
  const { data } = await adminClient().from("settings").select("value").eq("key", key).maybeSingle();
  return (data?.value as T) ?? fallback;
}
