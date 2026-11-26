// Supabase Edge Function: imweb-poll. Deploy with verify_jwt = false (supabase/config.toml); the only accepted caller is
// pg_cron (supabase_cron_v11_1_imweb.sql) sending the shared secret header x-imweb-poll-secret.
import { createHandler, envFrom } from "./poller.ts";

const handle = createHandler(envFrom((k) => Deno.env.get(k)));
Deno.serve(async (req) => {
  try {
    return await handle(req);
  } catch {
    console.error("imweb-poll: unhandled");
    return new Response(JSON.stringify({ error: "internal_error" }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
