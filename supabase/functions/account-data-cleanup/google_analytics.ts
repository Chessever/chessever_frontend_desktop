import type { Dependencies, ErrorCode } from "./handler.ts";

// Current GA4 Admin API, not the sunset Universal Analytics v3 endpoint.
// The refresh grant is operator-owned and scoped to analytics.edit, with Editor
// access only to the configured properties. Never use an end-user OAuth token.
export async function eraseGoogleAnalyticsUser(
  userId: string,
  deps: Dependencies,
): Promise<ErrorCode | null> {
  const properties = deps.env("GOOGLE_ANALYTICS_PROPERTY_IDS")?.split(",").map((
    id,
  ) => id.trim());
  const client = deps.env("GOOGLE_ANALYTICS_OAUTH_CLIENT_ID");
  const secret = deps.env("GOOGLE_ANALYTICS_OAUTH_CLIENT_SECRET");
  const refresh = deps.env("GOOGLE_ANALYTICS_OAUTH_REFRESH_TOKEN");
  if (
    !properties?.length || properties.length > 10 ||
    properties.some((id) => !/^[0-9]+$/.test(id)) ||
    !client || !secret || !refresh
  ) return "configuration_missing";

  const grant = await deps.fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(8_000),
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: client,
      client_secret: secret,
      refresh_token: refresh,
      grant_type: "refresh_token",
    }).toString(),
  });
  if (!grant.ok) {
    return grant.status === 429
      ? "rate_limited"
      : grant.status < 500
      ? "configuration_missing"
      : "provider_unavailable";
  }
  const token = await grant.json();
  if (
    typeof token.access_token !== "string" || !token.access_token ||
    (typeof token.scope === "string" &&
      !token.scope.split(" ").includes(
        "https://www.googleapis.com/auth/analytics.edit",
      ))
  ) {
    return "configuration_missing";
  }
  const results = await Promise.all(
    [...new Set(properties)].map(async (property) => {
      const result = await deps.fetch(
        `https://analyticsadmin.googleapis.com/v1alpha/properties/${property}:submitUserDeletion`,
        {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(8_000),
          headers: {
            Authorization: `Bearer ${token.access_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ userId }),
        },
      );
      if (result.status === 429) return "rate_limited" as const;
      if (
        result.status === 401 || result.status === 403 || result.status === 404
      ) return "configuration_missing" as const;
      if (!result.ok) return "provider_unavailable" as const;
      const body = await result.json();
      return typeof body.deletionRequestTime === "string" &&
          Number.isFinite(Date.parse(body.deletionRequestTime))
        ? null
        : "provider_unavailable" as const;
    }),
  );
  return results.find((error) => error !== null) ?? null;
}
