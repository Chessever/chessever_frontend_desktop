import {
  AppleError,
  AppleVerifier,
  bytes,
  encode64,
  field,
  object,
  StoredTokens,
  timedFetch,
} from "./security.ts";

export interface AppleConfig {
  audiences: string[];
  teamId: string;
  keyId: string;
  privateKey: string;
  redirectUris: Record<string, string>;
}

export class AppleApi {
  constructor(
    private config: AppleConfig,
    public verifier = new AppleVerifier(),
    private fetcher: typeof timedFetch = timedFetch,
  ) {}
  async assertReady(): Promise<void> {
    const clients = this.config.audiences;
    if (
      !clients.length || clients.length > 32 ||
      new Set(clients).size !== clients.length ||
      clients.some((client) =>
        !/^[A-Za-z0-9.-]+$/.test(client) || !client.includes(".")
      ) ||
      !/^[A-Z0-9]{10}$/.test(this.config.teamId) ||
      !/^[A-Z0-9]{10}$/.test(this.config.keyId)
    ) {
      throw new AppleError("apple_not_configured", 503);
    }
    for (const [client, uri] of Object.entries(this.config.redirectUris)) {
      const url = new URL(uri);
      if (
        !clients.includes(client) || url.protocol !== "https:" || url.hash ||
        url.username || url.password || !url.hostname.includes(".") ||
        /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname)
      ) throw new AppleError("apple_not_configured", 503);
    }
    // Imports the real server P-256 key and signs a short-lived client secret
    // for every configured audience. No request is made to Apple's token API.
    await Promise.all(clients.map((client) => this.clientSecret(client)));
  }
  async clientSecret(clientId: string): Promise<string> {
    if (
      !this.config.audiences.includes(clientId) || !this.config.teamId ||
      !this.config.keyId || !this.config.privateKey
    ) throw new AppleError("apple_not_configured", 503);
    try {
      const pem = this.config.privateKey.replaceAll("\\n", "\n").replace(
        /-----[^-]+-----|\s/g,
        "",
      );
      const raw = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
      const key = await crypto.subtle.importKey(
        "pkcs8",
        raw,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["sign"],
      );
      const now = Math.floor(Date.now() / 1000);
      const message = [
        encode64(
          bytes(JSON.stringify({ alg: "ES256", kid: this.config.keyId })),
        ),
        encode64(
          bytes(
            JSON.stringify({
              iss: this.config.teamId,
              iat: now,
              exp: now + 300,
              aud: "https://appleid.apple.com",
              sub: clientId,
            }),
          ),
        ),
      ].join(".");
      const signature = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" },
        key,
        bytes(message),
      );
      return `${message}.${encode64(new Uint8Array(signature))}`;
    } catch {
      throw new AppleError("apple_not_configured", 503);
    }
  }
  async exchange(code: string, clientId: string): Promise<StoredTokens> {
    const form = new URLSearchParams({
      client_id: clientId,
      client_secret: await this.clientSecret(clientId),
      code,
      grant_type: "authorization_code",
    });
    const redirectUri = this.config.redirectUris[clientId];
    if (redirectUri) form.set("redirect_uri", redirectUri);
    const response = await this.fetcher(
      "https://appleid.apple.com/auth/token",
      { method: "POST", body: form },
    );
    if (!response.ok) {
      throw new AppleError(
        response.status >= 500 || response.status === 429
          ? "apple_unavailable"
          : "apple_exchange_failed",
        response.status >= 500 || response.status === 429 ? 503 : 400,
      );
    }
    const result = object(await response.json());
    return {
      refresh_token: field(result, "refresh_token"),
      access_token: field(result, "access_token"),
      id_token: field(result, "id_token", 32768),
    };
  }
  async revoke(tokens: StoredTokens, clientId: string): Promise<void> {
    const response = await this.fetcher(
      "https://appleid.apple.com/auth/revoke",
      {
        method: "POST",
        body: new URLSearchParams({
          client_id: clientId,
          client_secret: await this.clientSecret(clientId),
          token: tokens.refresh_token,
          token_type_hint: "refresh_token",
        }),
      },
    );
    // Apple returns 200 for already-invalid tokens too. Never infer success
    // from invalid_client / invalid_grant: retain the job for operator repair.
    if (!response.ok) throw new AppleError("apple_revocation_failed", 503);
  }
}
