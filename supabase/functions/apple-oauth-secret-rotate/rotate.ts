export interface RotationConfig {
  teamId: string;
  keyId: string;
  privateKey: string;
  /** The Services ID Supabase sends to Apple: the first entry of
   * `external_apple_client_id`. */
  clientId: string;
  projectRef: string;
  managementToken: string;
}

export type RotationResult =
  | { ok: true; expiresAt: string }
  | { ok: false; error: string };

/** Apple rejects secrets that live longer than 15777000 s (six months). 150
 * days leaves a month of slack, and a weekly run renews long before that. */
export const SECRET_LIFETIME_SECONDS = 150 * 24 * 60 * 60;

const encoder = new TextEncoder();
function base64url(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/,
    "",
  );
}

export async function signClientSecret(
  config: Pick<RotationConfig, "teamId" | "keyId" | "privateKey" | "clientId">,
  now = Math.floor(Date.now() / 1000),
): Promise<{ jwt: string; exp: number }> {
  const pem = config.privateKey.replaceAll("\\n", "\n").replace(
    /-----[^-]+-----|\s/g,
    "",
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const exp = now + SECRET_LIFETIME_SECONDS;
  const message = [
    { alg: "ES256", kid: config.keyId },
    {
      iss: config.teamId,
      iat: now,
      exp,
      aud: "https://appleid.apple.com",
      sub: config.clientId,
    },
  ].map((part) => base64url(encoder.encode(JSON.stringify(part)))).join(".");
  // WebCrypto returns the raw r||s signature JWS ES256 expects.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(message),
  );
  return { jwt: `${message}.${base64url(new Uint8Array(signature))}`, exp };
}

/** Asks Apple to redeem a deliberately bogus code. Apple checks the client
 * first: `invalid_client` means the secret is rejected, `invalid_grant` means
 * the secret is good and only the (fake) code failed. */
export async function appleAcceptsSecret(
  clientId: string,
  secret: string,
  fetcher: typeof fetch = fetch,
): Promise<boolean> {
  const response = await fetcher("https://appleid.apple.com/auth/token", {
    method: "POST",
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: secret,
      code: "chessever-secret-probe",
      grant_type: "authorization_code",
    }),
    signal: AbortSignal.timeout(12000),
  });
  let error = "";
  try {
    error = String((await response.json())?.error ?? "");
  } catch {
    // Not JSON: treat as not proven.
  }
  return error === "invalid_grant";
}

export async function rotate(
  config: RotationConfig,
  fetcher: typeof fetch = fetch,
  now?: number,
): Promise<RotationResult> {
  if (
    !config.teamId || !config.keyId || !config.privateKey ||
    !config.clientId || !config.projectRef || !config.managementToken
  ) return { ok: false, error: "not_configured" };

  let signed: { jwt: string; exp: number };
  try {
    signed = await signClientSecret(config, now);
  } catch {
    return { ok: false, error: "key_unusable" };
  }

  try {
    if (!(await appleAcceptsSecret(config.clientId, signed.jwt, fetcher))) {
      return { ok: false, error: "apple_rejected_secret" };
    }
  } catch {
    return { ok: false, error: "apple_unreachable" };
  }

  try {
    const response = await fetcher(
      `https://api.supabase.com/v1/projects/${config.projectRef}/config/auth`,
      {
        method: "PATCH",
        headers: {
          Authorization: `Bearer ${config.managementToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ external_apple_secret: signed.jwt }),
        signal: AbortSignal.timeout(15000),
      },
    );
    if (!response.ok) {
      return { ok: false, error: `supabase_config_${response.status}` };
    }
  } catch {
    return { ok: false, error: "supabase_unreachable" };
  }

  return { ok: true, expiresAt: new Date(signed.exp * 1000).toISOString() };
}
