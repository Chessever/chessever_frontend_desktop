// Keeps Supabase-hosted Apple OAuth (web, app.chessever.com and the website
// desktop builds) signed in, without anyone ever minting a key by hand.
//
// Apple only accepts a client secret that is an ES256 JWT expiring within six
// months, and Supabase stores that JWT as a static setting. When it expired on
// 2026-11-09 every web/desktop Apple sign-in failed with
// "Unable to exchange external code" (Apple: invalid_client). The underlying
// .p8 key never expires, so this worker re-signs a fresh JWT from it on a
// schedule, proves Apple accepts it, and only then writes it into the project's
// auth config through the Management API.
//
// Nothing secret is logged or returned: not the key, not the JWT, not the
// management token, not Apple's response body.
import { rotate, RotationConfig } from "./rotate.ts";

const env = (name: string) => Deno.env.get(name) ?? "";

function config(): RotationConfig {
  return {
    teamId: env("APPLE_TEAM_ID"),
    keyId: env("APPLE_KEY_ID"),
    privateKey: env("APPLE_PRIVATE_KEY"),
    clientId: env("APPLE_OAUTH_CLIENT_ID") || "com.chessever.web",
    projectRef: env("APPLE_OAUTH_PROJECT_REF") ||
      new URL(env("SUPABASE_URL")).hostname.split(".")[0],
    managementToken: env("SUPABASE_MANAGEMENT_TOKEN"),
  };
}

async function alert(text: string): Promise<void> {
  const token = env("TELEGRAM_BOT_TOKEN"), chat = env("TELEGRAM_CHAT_ID");
  if (!token || !chat) return;
  const thread = env("TELEGRAM_THREAD_ID");
  try {
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chat,
        ...(thread ? { message_thread_id: Number(thread) } : {}),
        text,
      }),
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    // Alerting is best effort; the failed run is still reported to the caller.
  }
}

async function authorized(request: Request): Promise<boolean> {
  const secret = env("APPLE_OAUTH_ROTATION_SECRET");
  if (secret.length < 32) return false;
  const given = (request.headers.get("Authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  );
  const [a, b] = await Promise.all(
    [given, secret].map(async (v) =>
      new Uint8Array(
        await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v)),
      )
    ),
  );
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method" }, 405);
  if (!(await authorized(request))) return json({ error: "unauthorized" }, 401);
  // An operator may pass a Management API token for one run (used for the
  // first rotation, before SUPABASE_MANAGEMENT_TOKEN is provisioned). It is
  // used for this request only and never stored or echoed.
  let override = "";
  try {
    const body = await request.json();
    if (body && typeof body.management_token === "string") {
      override = body.management_token;
    }
  } catch {
    // Empty or non-JSON body: use the configured token.
  }
  const settings = config();
  if (override) settings.managementToken = override;
  const result = await rotate(settings);
  if (!result.ok) {
    await alert(
      `Apple OAuth secret rotation FAILED (${result.error}). Web/desktop Apple sign-in breaks when the current secret expires. Check the apple-oauth-secret-rotate function.`,
    );
    return json({ rotated: false, error: result.error }, 502);
  }
  return json({ rotated: true, expires_at: result.expiresAt });
});
