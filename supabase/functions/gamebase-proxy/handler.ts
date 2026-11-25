import {
  bearerNamesAccount,
  matchGamebaseProxyRoute,
} from "./allowed_routes.ts";
import { hasProjectClientKey, upstreamHeaders } from "./request_headers.ts";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, if-none-match, cache-control, pragma, x-rewarded-session",
  "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
  // Retry-After paces the clients' polling. Cache diagnostics that would tell
  // one reader what others looked at (X-Prediction-Cache) stay unexposed.
  "Access-Control-Expose-Headers":
    "X-Game-Count, X-PGN-Cache, X-PGN-Snapshot, X-PGN-Filter-Version, X-PGN-Warm-Job, Retry-After, ETag, Content-Disposition",
};

// Every authenticated browser request is preflighted. Letting the browser
// reuse a preflight for ten minutes saves one round trip per poll.
export const preflightHeaders = {
  ...corsHeaders,
  "Access-Control-Max-Age": "600",
};

const DEFAULT_GAMEBASE_API_BASE = "https://service.chessever.com";
const UPSTREAM_TIMEOUT_MS = 240_000;

export type GamebaseProxyDeps = {
  env: (name: string) => string | undefined;
  fetch: (input: string, init: RequestInit) => Promise<Response>;
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function upstreamApiPath(reqUrl: URL): string | null {
  const apiIndex = reqUrl.pathname.indexOf("/api/");
  if (apiIndex < 0) return null;
  return reqUrl.pathname.substring(apiIndex);
}

/**
 * Aborts the upstream request when the caller hangs up before its answer has
 * been relayed in full. A board that moves on during a long poll then stops
 * the service's work for the old position. Best effort: whether the runtime
 * reports a hang-up depends on the platform. Some runtimes also signal abort
 * after a response completes normally; by then the upstream body has been
 * read to its end and the abort changes nothing, so the body is relayed as
 * the runtime streams it, with no per-chunk step in between.
 */
function followCallerHangUp(caller: AbortSignal, upstream: AbortController) {
  if (caller.aborted) {
    upstream.abort();
    return;
  }
  caller.addEventListener("abort", () => upstream.abort(), { once: true });
}

export function createGamebaseProxyHandler(
  deps: GamebaseProxyDeps,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: preflightHeaders });
    }

    if (!["GET", "POST", "PUT", "DELETE"].includes(req.method)) {
      return jsonResponse({ error: "method_not_allowed" }, 405);
    }

    const publicKey = (deps.env("GAMEBASE_CLIENT_ANON_KEY") ??
      deps.env("SUPABASE_ANON_KEY") ?? "").trim();
    const publishableKeys = (deps.env("GAMEBASE_CLIENT_PUBLISHABLE_KEYS") ?? "")
      .split(",")
      .map((key) => key.trim())
      .filter((key) => key.startsWith("sb_publishable_"));
    if (!hasProjectClientKey(req.headers, publicKey, ...publishableKeys)) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    const requestUrl = new URL(req.url);
    const apiPath = upstreamApiPath(requestUrl);
    const route = apiPath ? matchGamebaseProxyRoute(req.method, apiPath) : null;
    if (!apiPath || !route) {
      return jsonResponse({ error: "route_not_allowed" }, 403);
    }

    // Gamebase verifies the account token and its permissions. Gateway JWT
    // verification stays off to accept both project key formats.
    const authorization = req.headers.get("authorization") ?? "";
    if (route.member && !bearerNamesAccount(authorization)) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    const apiKey = deps.env("GAMEBASE_API_KEY")?.trim();
    if (!apiKey) {
      return jsonResponse({ error: "gamebase_key_not_configured" }, 500);
    }

    const upstreamBase = deps.env("GAMEBASE_API_BASE")?.trim() ||
      DEFAULT_GAMEBASE_API_BASE;
    const upstreamUrl = new URL(
      `${upstreamBase.replace(/\/$/, "")}${apiPath}`,
    );
    requestUrl.searchParams.forEach((value, key) => {
      upstreamUrl.searchParams.append(key, value);
    });

    const headers = upstreamHeaders(req.headers, route, apiKey);

    let body: BodyInit | undefined;
    if (req.method === "POST" || req.method === "PUT") {
      body = await req.text();
    }

    const controller = new AbortController();
    followCallerHangUp(req.signal, controller);
    const timeout = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
    let upstream: Response;
    try {
      upstream = await deps.fetch(upstreamUrl.toString(), {
        method: req.method,
        headers,
        body,
        signal: controller.signal,
      });
    } catch {
      return jsonResponse({ error: "gamebase_upstream_unavailable" }, 502);
    } finally {
      clearTimeout(timeout);
    }

    const responseHeaders = new Headers(corsHeaders);
    const upstreamContentType = upstream.headers.get("content-type");
    responseHeaders.set(
      "Content-Type",
      upstreamContentType ?? "application/json",
    );
    const contentEncoding = upstream.headers.get("content-encoding");
    if (contentEncoding) {
      responseHeaders.set("Content-Encoding", contentEncoding);
    }
    const vary = upstream.headers.get("vary");
    if (vary) responseHeaders.set("Vary", vary);
    const gameCount = upstream.headers.get("x-game-count");
    if (gameCount) responseHeaders.set("X-Game-Count", gameCount);
    const pgnCache = upstream.headers.get("x-pgn-cache");
    if (pgnCache) responseHeaders.set("X-PGN-Cache", pgnCache);
    const pgnSnapshot = upstream.headers.get("x-pgn-snapshot");
    if (pgnSnapshot) responseHeaders.set("X-PGN-Snapshot", pgnSnapshot);
    const pgnFilterVersion = upstream.headers.get("x-pgn-filter-version");
    if (pgnFilterVersion) {
      responseHeaders.set("X-PGN-Filter-Version", pgnFilterVersion);
    }
    const pgnWarmJob = upstream.headers.get("x-pgn-warm-job");
    if (pgnWarmJob) responseHeaders.set("X-PGN-Warm-Job", pgnWarmJob);
    const retryAfter = upstream.headers.get("retry-after");
    if (retryAfter) responseHeaders.set("Retry-After", retryAfter);
    const etag = upstream.headers.get("etag");
    if (etag) responseHeaders.set("ETag", etag);
    const disposition = upstream.headers.get("content-disposition");
    if (disposition) responseHeaders.set("Content-Disposition", disposition);
    // One member's publication, or one viewer's access, is never another's
    // cached answer.
    if (route.member || route.viewer) {
      responseHeaders.set("Cache-Control", "private, no-store");
      responseHeaders.set("Vary", "Authorization");
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders,
    });
  };
}
