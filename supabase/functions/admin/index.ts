// Edge Function "admin" (réservée aux administrateurs)
//   POST /admin/invite  { email? | phone?, full_name, role: "creative" | "admin", team_title? }
//        Invite un membre de l'équipe (« Inviter un créatif » dans le back-office).
import { HttpError, json, readJson, serve } from "../_shared/http.ts";
import { adminClient, requireUser, roleOf } from "../_shared/supabase.ts";

interface InviteBody {
  email?: string;
  phone?: string;
  full_name: string;
  role: "creative" | "admin";
  team_title?: string;
}

serve("admin", async (req, path) => {
  const me = await requireUser(req);
  if ((await roleOf(me.id)) !== "admin") throw new HttpError(403, "FORBIDDEN");

  if (req.method === "POST" && path[0] === "invite") {
    const body = await readJson<InviteBody>(req);
    if (!["creative", "admin"].includes(body.role)) throw new HttpError(400, "INVALID_ROLE");
    if (!body.full_name?.trim()) throw new HttpError(400, "NAME_REQUIRED");
    const email = body.email?.trim().toLowerCase();
    const phone = body.phone?.replace(/\D/g, "");
    if (!email && !phone) throw new HttpError(400, "CONTACT_REQUIRED", "Indiquez un e-mail ou un numéro.");

    const db = adminClient();
    let q = db.from("profiles").select("id");
    q = email ? q.eq("email", email) : q.eq("phone", `+${phone}`);
    const { data: existing } = await q.maybeSingle();

    let userId = existing?.id as string | undefined;
    let invited = false;
    if (!userId) {
      const meta = { full_name: body.full_name.trim() };
      const res = email
        ? await db.auth.admin.inviteUserByEmail(email, { data: meta, redirectTo: Deno.env.get("BACKOFFICE_URL") })
        : await db.auth.admin.createUser({ phone, phone_confirm: true, user_metadata: meta });
      if (res.error || !res.data.user) throw new HttpError(400, "INVITE_FAILED", res.error?.message);
      userId = res.data.user.id;
      invited = true;
    }

    const { data: profile, error } = await db.from("profiles")
      .update({ role: body.role, team_title: body.team_title ?? null, full_name: body.full_name.trim() })
      .eq("id", userId).select("id, full_name, email, phone, role, team_title").single();
    if (error) throw error;
    return json({ profile, invited }, invited ? 201 : 200);
  }

  throw new HttpError(404, "NOT_FOUND");
});
