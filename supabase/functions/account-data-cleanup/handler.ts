// Provider contracts and remaining integrations: ../../ACCOUNT_DELETION.md.
// Never log requests, identifiers, upstream bodies, headers, or exception text.
import { eraseGoogleAnalyticsUser } from "./google_analytics.ts";
export type CleanupJob = {
  id: string;
  user_id: string;
  kind: string;
  payload: Record<string, unknown>;
  lease_token: string;
};
export type ErrorCode =
  | "configuration_missing"
  | "provider_unavailable"
  | "rate_limited"
  | "invalid_payload"
  | "integration_required"
  | "request_failed";
export type Environment = (name: string) => string | undefined;
// A synchronous response is also useful for deterministic, network-free tests.
export type Fetcher = (
  url: string,
  options?: RequestInit,
) => Promise<Response> | Response;
export type Dependencies = { env: Environment; fetch: Fetcher };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const timeout = () => AbortSignal.timeout(8_000);

function equalSecret(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let difference = left.length ^ right.length;
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function response(body: object, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

async function ensureDeleted(
  url: string,
  headers: Record<string, string>,
  deps: Dependencies,
  body?: object,
): Promise<ErrorCode | null> {
  const result = await deps.fetch(url, {
    method: "DELETE",
    headers,
    signal: timeout(),
    redirect: "error",
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  // Documented provider idempotence: an already absent profile/object is removed.
  if (result.ok || result.status === 404) return null;
  if (result.status === 429) return "rate_limited";
  if (result.status === 401 || result.status === 403) {
    return "configuration_missing";
  }
  return "provider_unavailable";
}

export async function processJob(
  job: CleanupJob,
  deps: Dependencies,
): Promise<ErrorCode | null> {
  if (
    !uuid.test(job.user_id) || !uuid.test(job.id) || !uuid.test(job.lease_token)
  ) return "invalid_payload";
  if (job.kind === "ga4") {
    return await eraseGoogleAnalyticsUser(job.user_id, deps);
  }
  if (job.kind === "gamebase") {
    const secret = deps.env("GAMEBASE_ACCOUNT_ERASURE_SECRET");
    const project = deps.env("GAMEBASE_AUTH_PROJECT");
    const endpoint = deps.env("GAMEBASE_ACCOUNT_ERASURE_URL") ??
      "https://service.chessever.com/api/internal/account-erasure";
    if (!secret || !project || !/^[a-z0-9]{20}$/.test(project)) {
      return "configuration_missing";
    }
    const url = new URL(endpoint);
    if (
      url.protocol !== "https:" || url.username || url.password || url.search ||
      url.hash ||
      url.pathname !== "/api/internal/account-erasure"
    ) return "configuration_missing";
    const result = await deps.fetch(endpoint, {
      method: "POST",
      redirect: "error",
      signal: timeout(),
      headers: {
        Authorization: `Bearer ${secret}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ auth_project: project, user_id: job.user_id }),
    });
    if (result.status === 429) return "rate_limited";
    if (result.status === 401 || result.status === 403) {
      return "configuration_missing";
    }
    if (result.status !== 200) return "provider_unavailable";
    const body = await result.json();
    return body?.erased === true ? null : "provider_unavailable";
  }
  if (job.kind === "storage") {
    const { bucket_id: bucket, path } = job.payload;
    // No arbitrary bucket, URL, wildcard, prefix, traversal, or another user's file.
    if (
      bucket !== "profile-avatars" || typeof path !== "string" ||
      !new RegExp(`^${job.user_id}/[0-9a-f-]{36}\\.jpg$`, "i").test(path) ||
      !uuid.test(path.split("/")[1].slice(0, -4))
    ) return "invalid_payload";
    const base = deps.env("SUPABASE_URL");
    const key = deps.env("SUPABASE_SERVICE_ROLE_KEY");
    if (!base || !key) return "configuration_missing";
    return await ensureDeleted(
      `${base.replace(/\/$/, "")}/storage/v1/object/profile-avatars`,
      {
        Authorization: `Bearer ${key}`,
        apikey: key,
        "Content-Type": "application/json",
      },
      deps,
      { prefixes: [path] },
    );
  }
  if (job.kind === "onesignal") {
    const app = deps.env("ONESIGNAL_APP_ID");
    const key = deps.env("ONESIGNAL_REST_API_KEY");
    if (!app || !key) return "configuration_missing";
    if (!uuid.test(app)) return "configuration_missing";
    return await ensureDeleted(
      `https://api.onesignal.com/apps/${app}/users/by/external_id/${job.user_id}`,
      {
        Authorization: `Key ${key}`,
        "Content-Type": "application/json",
      },
      deps,
    );
  }
  if (job.kind === "revenuecat") {
    const key = deps.env("REVENUECAT_SECRET_API_KEY");
    if (!key || deps.env("REVENUECAT_STORE_AND_STRIPE_ONLY") !== "true") {
      return "configuration_missing";
    }
    // Deleting the account's customer profile does not cancel store billing.
    // Never call refund/cancellation/Stripe customer endpoints here. RevenueCat
    // Billing subscriptions DO auto-cancel on customer deletion, so the operator
    // must explicitly attest this project uses only stores/Stripe, not RC Billing.
    return await ensureDeleted(
      `https://api.revenuecat.com/v1/subscribers/${job.user_id}`,
      {
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
      },
      deps,
    );
  }
  // AppsFlyer erasure needs app/identity mapping and processor completion evidence.
  // Preserve this work for the operator SOP; do not fake successful erasure.
  return "integration_required";
}

export function createHandler(
  deps: Dependencies,
): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method !== "POST") {
      return response({ error: "method_not_allowed" }, 405);
    }
    const serviceKey = deps.env("SUPABASE_SERVICE_ROLE_KEY");
    const cronSecret = deps.env("ACCOUNT_CLEANUP_CRON_SECRET");
    const authorization =
      request.headers.get("Authorization")?.match(/^Bearer (\S+)$/)?.[1] ?? "";
    if (
      !authorization ||
      !((serviceKey && equalSecret(authorization, serviceKey)) ||
        (cronSecret && equalSecret(authorization, cronSecret)))
    ) return response({ error: "unauthorized" }, 401);
    const base = deps.env("SUPABASE_URL");
    if (!base || !serviceKey) {
      return response({ error: "configuration_missing" }, 503);
    }
    try {
      if (Number(request.headers.get("content-length")) > 1024) {
        return response({ error: "invalid_request" }, 400);
      }
      const raw = await request.text();
      if (new TextEncoder().encode(raw).length > 1024) {
        return response({ error: "invalid_request" }, 400);
      }
      const body = raw ? JSON.parse(raw) : {};
      if (
        !body || typeof body !== "object" || Array.isArray(body) ||
        Object.keys(body).some((key) => !["user_id", "limit"].includes(key)) ||
        (body.user_id !== undefined &&
          (typeof body.user_id !== "string" || !uuid.test(body.user_id))) ||
        (body.limit !== undefined &&
          (!Number.isInteger(body.limit) || body.limit < 1 || body.limit > 10))
      ) {
        return response({ error: "invalid_request" }, 400);
      }
      const rpc = async (name: string, payload: object) => {
        const result = await deps.fetch(
          `${base.replace(/\/$/, "")}/rest/v1/rpc/${name}`,
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${serviceKey}`,
              apikey: serviceKey,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(payload),
            signal: timeout(),
            redirect: "error",
          },
        );
        if (!result.ok) throw new Error("rpc_failed");
        const text = await result.text();
        return text ? JSON.parse(text) : null;
      };
      // Up to ten parallel 8s jobs fit inside the 2min lease and function budget.
      const jobs: CleanupJob[] = await rpc("account_claim_cleanup_jobs", {
        p_user_id: body.user_id ?? null,
        p_limit: body.limit ?? 10,
      });
      if (!Array.isArray(jobs) || jobs.length > 10) {
        throw new Error("invalid_jobs");
      }
      let completed = 0;
      await Promise.all(jobs.map(async (job) => {
        let error: ErrorCode | null;
        try {
          error = await processJob(job, deps);
        } catch {
          error = "request_failed";
        }
        await rpc("account_finish_cleanup_job", {
          p_id: job.id,
          p_lease_token: job.lease_token,
          p_success: error === null,
          p_error_code: error,
        });
        if (error === null) completed++;
      }));
      const pending = body.user_id
        ? await rpc("account_cleanup_pending", { p_user_id: body.user_id })
        : undefined;
      return response({
        processed: jobs.length,
        completed,
        ...(pending !== undefined ? { data_removal_pending: pending } : {}),
      });
    } catch {
      // Failed acknowledgement leaves the lease/job intact for the next cron run.
      return response({
        error: "cleanup_unavailable",
        data_removal_pending: true,
      }, 503);
    }
  };
}
