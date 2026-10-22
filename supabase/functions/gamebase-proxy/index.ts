import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  bearerNamesAccount,
  matchGamebaseProxyRoute,
} from "./allowed_routes.ts";
import { hasProjectClientKey, upstreamHeaders } from "./request_headers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, if-none-match, cache-control, pragma, x-rewarded-session",
  "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
  "Access-Control-Expose-Headers":
    "X-Game-Count, X-PGN-Cache, X-PGN-Snapshot, X-PGN-Filter-Version, X-PGN-Warm-Job, Retry-After, ETag, Content-Disposition",
};

const DEFAULT_GAMEBASE_API_BASE = "https://service.chessever.com";
const UPSTREAM_TIMEOUT_MS = 240_000;

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

async function fetchWithTimeout(
  input: string,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (!["GET", "POST", "PUT", "DELETE"].includes(req.method)) {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const publicKey = (Deno.env.get("GAMEBASE_CLIENT_ANON_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY") ?? "").trim();
  if (!hasProjectClientKey(req.headers, publicKey)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const requestUrl = new URL(req.url);
  const apiPath = upstreamApiPath(requestUrl);
  const route = apiPath ? matchGamebaseProxyRoute(req.method, apiPath) : null;
  if (!apiPath || !route) {
    return jsonResponse({ error: "route_not_allowed" }, 403);
  }

  // Gamebase verifies the account token and its permissions. Gateway JWT
  // verification stays off because it rejects the project's legacy anon key.
  const authorization = req.headers.get("authorization") ?? "";
  if (route.member && !bearerNamesAccount(authorization)) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const apiKey = Deno.env.get("GAMEBASE_API_KEY")?.trim();
  if (!apiKey) {
    return jsonResponse({ error: "gamebase_key_not_configured" }, 500);
  }

  const upstreamBase = Deno.env.get("GAMEBASE_API_BASE")?.trim() ||
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

  try {
    const upstream = await fetchWithTimeout(
      upstreamUrl.toString(),
      { method: req.method, headers, body },
      UPSTREAM_TIMEOUT_MS,
    );
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
    if (pgnFilterVersion) responseHeaders.set("X-PGN-Filter-Version", pgnFilterVersion);
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
  } catch {
    return jsonResponse({ error: "gamebase_upstream_unavailable" }, 502);
  }
});
