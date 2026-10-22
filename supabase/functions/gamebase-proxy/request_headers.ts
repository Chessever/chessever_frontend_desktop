import { type AllowedRoute, bearerNamesAccount } from "./allowed_routes.ts";

// This is a public project identifier, not the upstream service credential.
// Account authorization is enforced by Gamebase for member/viewer operations.
export function hasProjectClientKey(
  headers: Headers,
  publicKey: string,
): boolean {
  return publicKey.length > 0 &&
    (headers.get("apikey") === publicKey ||
      headers.get("authorization") === `Bearer ${publicKey}`);
}

export function upstreamHeaders(
  incoming: Headers,
  route: AllowedRoute,
  serverKey: string,
): Headers {
  const headers = new Headers({
    Accept: incoming.get("accept") ?? "application/json",
    "X-API-Key": serverKey,
  });
  for (const name of ["if-none-match", "content-type"]) {
    const value = incoming.get(name);
    if (value) headers.set(name, value);
  }
  const authorization = incoming.get("authorization") ?? "";
  if (route.member || (route.viewer && bearerNamesAccount(authorization))) {
    headers.set("Authorization", authorization);
  }
  // Rewarded access is bound to this account and session by the upstream
  // service. Preserve both values; neither can substitute for the server key.
  const rewarded = incoming.get("x-rewarded-session");
  if (rewarded && bearerNamesAccount(authorization)) {
    headers.set("x-rewarded-session", rewarded);
    headers.set("Authorization", authorization);
  }
  if (
    route.viewer && /\bno-cache\b/i.test(incoming.get("cache-control") ?? "")
  ) {
    headers.set("Cache-Control", "no-cache");
    headers.set("Pragma", "no-cache");
  }
  return headers;
}
