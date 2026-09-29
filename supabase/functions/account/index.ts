// Edge Function "account"
//   POST /account/delete   supprime le compte connecté et ses données personnelles.
//        Paiements et factures sont conservés (obligation comptable), détachés du compte.
//        Les fichiers stockés sont effacés par la maintenance nocturne.
import { HttpError, json, serve } from "../_shared/http.ts";
import { adminClient, requireUser, roleOf } from "../_shared/supabase.ts";

serve("account", async (req, path) => {
  if (req.method !== "POST" || path[0] !== "delete") throw new HttpError(404, "NOT_FOUND");
  const user = await requireUser(req);
  const db = adminClient();

  // Un membre de l'équipe doit d'abord être retiré de l'équipe par un admin
  if ((await roleOf(user.id)) !== "client") {
    throw new HttpError(409, "TEAM_ACCOUNT", "Ce compte fait partie de l'équipe. Demandez à un administrateur de vous retirer de l'équipe.");
  }

  // Un paiement en cours pourrait encore être validé : on attend qu'il aboutisse ou expire
  const since = new Date(Date.now() - 3600 * 1000).toISOString();
  const { count } = await db.from("payments").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).eq("status", "pending").gte("created_at", since);
  if ((count ?? 0) > 0) {
    throw new HttpError(409, "PAYMENT_PENDING", "Un paiement est en cours. Réessayez dans une heure.");
  }

  const { error } = await db.auth.admin.deleteUser(user.id);
  if (error) {
    console.error("[account] deleteUser", error.message);
    throw new HttpError(500, "DELETE_FAILED", "La suppression n'a pas abouti. Réessayez ou écrivez-nous sur WhatsApp.");
  }
  return json({ deleted: true });
});
