import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
};

const DEFAULT_GAMEBASE_API_BASE = "https://service.chessever.com";
const UPSTREAM_TIMEOUT_MS = 80_000;

type AllowedRoute = {
  method: "GET" | "POST";
  pattern: RegExp;
};

const allowedRoutes: AllowedRoute[] = [
  { method: "GET", pattern: /^\/api\/player$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/(?:events|games|stats)$/ },

  { method: "POST", pattern: /^\/api\/player\/[^/]+\/opening-tree\/build$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/opening-tree\/status$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/opening-tree$/ },

  { method: "GET", pattern: /^\/api\/miniatures$/ },
  { method: "GET", pattern: /^\/api\/game\/[^/]+$/ },
  { method: "GET", pattern: /^\/api\/eval$/ },
  { method: "GET", pattern: /^\/api\/search$/ },
  { method: "GET", pattern: /^\/api\/search\/events$/ },
  { method: "GET", pattern: /^\/api\/search\/metadata$/ },
  { method: "POST", pattern: /^\/api\/search\/query$/ },
  { method: "GET", pattern: /^\/api\/game-position\/aggregates$/ },
  { method: "POST", pattern: /^\/api\/game-position\/aggregates\/query$/ },
  { method: "GET", pattern: /^\/api\/game-position\/games$/ },
  { method: "POST", pattern: /^\/api\/game-position\/games\/query$/ },
  { method: "GET", pattern: /^\/api\/game-position\/fen\/games$/ },
];

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

function isAllowed(method: string, path: string): method is "GET" | "POST" {
  return allowedRoutes.some((route) =>
    route.method === method && route.pattern.test(path)
  );
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

  if (req.method !== "GET" && req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const hasClientAuth =
    req.headers.has("authorization") || req.headers.has("apikey");
  if (!hasClientAuth) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const requestUrl = new URL(req.url);
  const apiPath = upstreamApiPath(requestUrl);
  if (!apiPath || !isAllowed(req.method, apiPath)) {
    return jsonResponse({ error: "route_not_allowed" }, 403);
  }

  const apiKey = Deno.env.get("GAMEBASE_API_KEY")?.trim();
  if (!apiKey) {
    return jsonResponse({ error: "gamebase_key_not_configured" }, 500);
  }

  const upstreamBase =
    Deno.env.get("GAMEBASE_API_BASE")?.trim() || DEFAULT_GAMEBASE_API_BASE;
  const upstreamUrl = new URL(
    `${upstreamBase.replace(/\/$/, "")}${apiPath}`,
  );
  requestUrl.searchParams.forEach((value, key) => {
    upstreamUrl.searchParams.append(key, value);
  });

  const headers = new Headers();
  headers.set("Accept", "application/json");
  headers.set("X-API-Key", apiKey);
  const contentType = req.headers.get("content-type");
  if (contentType) headers.set("Content-Type", contentType);

  let body: BodyInit | undefined;
  if (req.method === "POST") {
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
    return new Response(upstream.body, {
      status: upstream.status,
      headers: responseHeaders,
    });
  } catch {
    return jsonResponse({ error: "gamebase_upstream_unavailable" }, 502);
  }
});
