// Edge Function "maintenance" — appelée chaque nuit par pg_cron (uniquement s'il y a des fichiers orphelins).
// Supprime du stockage les fichiers qui ne sont plus référencés (voir public.orphan_storage_paths).
import { json } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const CHUNK = 100;

Deno.serve(async (req) => {
  const db = adminClient();
  const { data: allowed } = await db.rpc("verify_cron_secret", { p_secret: req.headers.get("x-cron-secret") ?? "" });
  if (!allowed) return json({ error: "FORBIDDEN" }, 403);

  const { data: orphans, error } = await db.rpc("orphan_storage_paths", { p_limit: 1000 });
  if (error) {
    console.error("[maintenance]", error);
    return json({ error: "DB_ERROR" }, 500);
  }

  const byBucket = new Map<string, string[]>();
  for (const o of (orphans ?? []) as { bucket: string; path: string }[]) {
    byBucket.set(o.bucket, [...(byBucket.get(o.bucket) ?? []), o.path]);
  }

  const removed: Record<string, number> = {};
  for (const [bucket, paths] of byBucket) {
    removed[bucket] = 0;
    for (let i = 0; i < paths.length; i += CHUNK) {
      const { data, error: e } = await db.storage.from(bucket).remove(paths.slice(i, i + CHUNK));
      if (e) console.error("[maintenance]", bucket, e.message);
      removed[bucket] += data?.length ?? 0;
    }
  }
  return json({ removed });
});
