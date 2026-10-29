import { AppleApi } from "./apple_api.ts";
import { Backend, hasAppleSubject, RevokeJob } from "./backend.ts";
import {
  AppleError,
  AppleVerifier,
  Binding,
  field,
  Json,
  object,
  secureEqual,
  sha256,
  TokenCipher,
} from "./security.ts";

export interface Dependencies {
  backend: Backend;
  apple: AppleApi;
  verifier: AppleVerifier;
  cipher: TokenCipher;
  audiences: string[];
  workerSecret: string;
  background?: (work: Promise<unknown>) => void;
}
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Cache-Control": "no-store",
};
function json(value: unknown, status = 200): Response {
  return Response.json(value, { status, headers: cors });
}
async function body(req: Request): Promise<Json> {
  if (
    !req.headers.get("content-type")?.toLowerCase().startsWith(
      "application/json",
    )
  ) throw new AppleError("invalid_request", 415);
  // Bounded streaming avoids reading an untrusted unlimited request first.
  const reader = req.body?.getReader();
  if (!reader) throw new AppleError("invalid_request");
  let text = "", length = 0;
  const decoder = new TextDecoder();
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      length += result.value.length;
      if (length > 65536) {
        await reader.cancel();
        throw new AppleError("request_too_large", 413);
      }
      text += decoder.decode(result.value, { stream: true });
    }
    return object(JSON.parse(text + decoder.decode()));
  } catch (error) {
    if (error instanceof AppleError) throw error;
    throw new AppleError("invalid_request");
  } finally {
    reader.releaseLock();
  }
}
function auth(req: Request): string {
  const value = req.headers.get("authorization") ?? "";
  if (!/^Bearer [^\s]+$/i.test(value)) {
    throw new AppleError("unauthorized", 401);
  }
  return value;
}
export async function drain(
  deps: Dependencies,
  userId: string | null = null,
): Promise<{ processed: number; pending: boolean }> {
  const jobs = await deps.backend.rpc("apple_claim_revoke_jobs", {
    p_user_id: userId,
    p_limit: 10,
  }) as RevokeJob[];
  if (!Array.isArray(jobs)) throw new AppleError("backend_unavailable", 503);
  const completed = await Promise.all(jobs.map(async (job) => {
    let pending = false;
    let success = false, errorCode: string | null = null;
    try {
      const tokens = await deps.cipher.open(
        job.encrypted_tokens,
        job,
        job.key_id,
      );
      await deps.apple.revoke(tokens, job.client_id);
      success = true;
    } catch (error) {
      // Enum only. Never stringify an exception carrying upstream data.
      const code = error instanceof AppleError ? error.code : "";
      errorCode =
        ["encryption_not_configured", "apple_not_configured"].includes(code)
          ? "configuration_missing"
          : code === "encrypted_token_invalid"
          ? "token_decryption_failed"
          : ["apple_revocation_failed", "upstream_unavailable"].includes(code)
          ? "apple_unavailable"
          : "request_failed";
      pending = true;
    }
    try {
      await deps.backend.rpc("apple_finish_revoke_job", {
        p_id: job.id,
        p_lease_token: job.lease_token,
        p_success: success,
        p_error_code: errorCode,
      });
    } catch {
      pending = true;
    } // Lease expiry replays safely, including Apple 200.
    return pending;
  }));
  return {
    processed: jobs.length,
    pending: completed.some(Boolean) || jobs.length === 10,
  };
}

async function register(req: Request, deps: Dependencies): Promise<Response> {
  const user = await deps.backend.user(auth(req)); // Always server-validated getUser.
  if (user.is_anonymous === true) throw new AppleError("unauthorized", 401);
  const input = await body(req);
  const nonce = field(input, "nonce", 256);
  if (nonce.length < 16) throw new AppleError("invalid_request");
  const claims = await deps.verifier.verify(
    field(input, "identity_token", 32768),
    deps.audiences,
  );
  if (!hasAppleSubject(user, claims.sub as string)) {
    throw new AppleError("apple_identity_mismatch", 403);
  }
  const nonceHash = await sha256(nonce);
  if (claims.nonce !== nonceHash) {
    throw new AppleError("apple_nonce_mismatch", 403);
  }
  const binding: Binding = {
    user_id: user.id,
    apple_sub: claims.sub as string,
    client_id: claims.aud as string,
  };
  await deps.cipher.assertReady(); // Misconfiguration must not consume the code.
  const tokens = await deps.apple.exchange(
    field(input, "authorization_code", 4096),
    binding.client_id,
  );
  const exchanged = await deps.verifier.verify(tokens.id_token, [
    binding.client_id,
  ]);
  if (exchanged.sub !== binding.apple_sub || exchanged.nonce !== nonceHash) {
    throw new AppleError("apple_identity_mismatch", 403);
  }
  const encrypted = await deps.cipher.seal(tokens, binding);
  // Recheck persisted identity inside SQL under the deletion lock. The app
  // never sends a user id and cannot select a different account to overwrite.
  let stored = false;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await deps.backend.rpc("apple_store_tokens", {
        p_user_id: user.id,
        p_apple_sub: binding.apple_sub,
        p_client_id: binding.client_id,
        p_encrypted_tokens: encrypted,
        p_key_id: deps.cipher.activeKeyId,
      });
      stored = true;
      break;
    } catch {
      /* Same ciphertext retries are idempotent; no consumed-code retry. */
    }
  }
  if (!stored) {
    // A lost acknowledgement may hide a committed write. Revoking here can
    // invalidate a returning user's existing Apple grant as well. Leave all
    // grants untouched; the client must not adopt its staged Supabase session.
    // Only durable account-deletion jobs authorize Apple token revocation.
    throw new AppleError("token_persistence_failed", 503);
  }
  return json({ stored: true });
}

async function removeAccount(
  req: Request,
  deps: Dependencies,
): Promise<Response> {
  const authorization = auth(req);
  const user = await deps.backend.user(authorization);
  const input = await body(req);
  if (Object.keys(input).length) throw new AppleError("invalid_request");
  const result = object(
    await deps.backend.rpc("delete_user_account", {}, authorization),
  );
  if (
    result.deleted !== true ||
    typeof result.apple_manual_revoke_required !== "boolean"
  ) throw new AppleError("deletion_unconfirmed", 503);
  // Deletion has committed. A drain failure must never turn it into a failed
  // deletion in the UI. The outbox remains authoritative after user removal.
  const appleMayBePending = !result.apple_manual_revoke_required &&
    (user.identities?.some((i) => i.provider === "apple") ?? false);
  const work = Promise.all([
    (async () => {
      try {
        const drained = await drain(deps, user.id);
        return drained.pending ||
          (drained.processed === 0 && appleMayBePending);
      } catch {
        return appleMayBePending;
      }
    })(),
    (async () => {
      try {
        await deps.backend.cleanup?.(user.id);
      } catch { /* Durable cleanup queue owns retries. */ }
      try {
        return await deps.backend.rpc("account_cleanup_pending", {
          p_user_id: user.id,
        }) !== false;
      } catch {
        return true;
      }
    })(),
  ]);
  // A provider outage after commit must not leave the user waiting until a
  // gateway timeout hides successful deletion. Durable jobs own all retries.
  try {
    deps.background?.(work);
  } catch { /* Durable queues survive runtime shutdown. */ }
  let deadline: ReturnType<typeof setTimeout> | undefined;
  const status = await Promise.race([
    work,
    new Promise<boolean[]>((resolve) => {
      deadline = setTimeout(() => resolve([appleMayBePending, true]), 8000);
    }),
  ]).finally(() => clearTimeout(deadline));
  return json({
    ...result,
    apple_revocation_pending: status[0],
    data_removal_pending: status[1],
  });
}

async function notification(
  req: Request,
  deps: Dependencies,
): Promise<Response> {
  const input = await body(req);
  const claims = await deps.verifier.verify(
    field(input, "payload", 32768),
    deps.audiences,
    true,
  );
  const jti = field(claims, "jti", 256);
  let event: Json;
  try {
    event = object(
      typeof claims.events === "string"
        ? JSON.parse(claims.events)
        : claims.events,
    );
  } catch {
    throw new AppleError("invalid_apple_notification", 400);
  }
  const type = field(event, "type", 64), sub = field(event, "sub", 256);
  if (
    !["email-enabled", "email-disabled", "consent-revoked", "account-deleted"]
      .includes(type) ||
    typeof event.event_time !== "number" ||
    !Number.isSafeInteger(event.event_time) || event.event_time <= 0 ||
    event.event_time > Date.now() / 1000 + 60
  ) throw new AppleError("invalid_apple_notification");
  await deps.backend.rpc("apple_process_notification", {
    p_jti: jti,
    p_apple_sub: sub,
    p_event_type: type,
    p_event_time: event.event_time,
  });
  return json({ accepted: true });
}

export type Endpoint = "register" | "delete" | "worker" | "notification";
export function handler(
  endpoint: Endpoint,
  dependencies: () => Dependencies,
): (req: Request) => Promise<Response> {
  return async (req) => {
    if (
      req.method === "GET" &&
      new URL(req.url).searchParams.get("health") === "1"
    ) {
      try {
        const deps = dependencies();
        if (!deps.audiences.length || deps.workerSecret.length < 32) {
          throw new Error();
        }
        await deps.apple.assertReady();
        const keyIds = await deps.cipher.assertAllReady();
        const ready = await deps.backend.rpc("apple_lifecycle_health", {
          p_key_ids: keyIds,
        });
        return json({ ready: ready === true }, ready === true ? 200 : 503);
      } catch {
        return json({ ready: false }, 503);
      }
    }
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (req.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }
    try {
      const deps = dependencies();
      if (endpoint === "register") return await register(req, deps);
      if (endpoint === "delete") return await removeAccount(req, deps);
      if (endpoint === "notification") return await notification(req, deps);
      if (
        !deps.workerSecret ||
        !await secureEqual(auth(req), `Bearer ${deps.workerSecret}`)
      ) throw new AppleError("unauthorized", 401);
      return json(await drain(deps));
    } catch (error) {
      return json({
        error: error instanceof AppleError ? error.code : "service_unavailable",
      }, error instanceof AppleError ? error.status : 503);
    }
  };
}
