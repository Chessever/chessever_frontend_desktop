import { AppleApi } from "./apple_api.ts";
import { SupabaseBackend } from "./backend.ts";
import { Dependencies } from "./handlers.ts";
import { AppleError, AppleVerifier, TokenCipher } from "./security.ts";

let cached: Dependencies | undefined;
export function dependencies(): Dependencies {
  if (cached) return cached;
  const env = (name: string) => Deno.env.get(name) ?? "";
  const json = (name: string): Record<string, string> => {
    try {
      const value = JSON.parse(env(name) || "{}");
      if (
        !value || typeof value !== "object" || Array.isArray(value) ||
        Object.values(value).some((v) => typeof v !== "string")
      ) throw new Error();
      return value;
    } catch {
      throw new AppleError("apple_not_configured", 503);
    }
  };
  const audiences = env("APPLE_CLIENT_IDS").split(",").map((s) => s.trim())
    .filter(Boolean);
  const verifier = new AppleVerifier();
  cached = {
    audiences,
    verifier,
    apple: new AppleApi({
      audiences,
      teamId: env("APPLE_TEAM_ID"),
      keyId: env("APPLE_KEY_ID"),
      privateKey: env("APPLE_PRIVATE_KEY"),
      redirectUris: json("APPLE_REDIRECT_URIS"),
    }, verifier),
    cipher: new TokenCipher(
      json("APPLE_TOKEN_ENCRYPTION_KEYS"),
      env("APPLE_TOKEN_ACTIVE_KEY_ID"),
    ),
    backend: new SupabaseBackend(
      env("SUPABASE_URL"),
      env("SUPABASE_SERVICE_ROLE_KEY"),
      env("SUPABASE_ANON_KEY"),
    ),
    workerSecret: env("APPLE_REVOCATION_WORKER_SECRET"),
    background: (work) => {
      const runtime = globalThis as unknown as {
        EdgeRuntime?: { waitUntil: (work: Promise<unknown>) => void };
      };
      runtime.EdgeRuntime?.waitUntil(work);
    },
  };
  return cached;
}
