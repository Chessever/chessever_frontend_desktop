// No token, authorization code, Apple response body, or key is ever logged.
export class AppleError extends Error {
  constructor(public code: string, public status = 400) {
    super(code);
  }
}

export type Json = Record<string, unknown>;
const encoder = new TextEncoder();
export const bytes = (value: string) => encoder.encode(value);
export function encode64(data: Uint8Array): string {
  return btoa(String.fromCharCode(...data)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replace(/=+$/, "");
}
export function decode64(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[\w+/=-]+$/.test(value)) throw new AppleError("invalid_encoding");
  return Uint8Array.from(
    atob(value.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
}
export function object(value: unknown): Json {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new AppleError("invalid_request");
  }
  return value as Json;
}
export function field(value: Json, name: string, max = 16384): string {
  const result = value[name];
  if (typeof result !== "string" || !result || result.length > max) {
    throw new AppleError("invalid_request");
  }
  return result;
}
export async function sha256(value: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes(value));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
export async function secureEqual(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  let result = a.length ^ b.length;
  for (let i = 0; i < x.length; i++) {
    result |= x.charCodeAt(i) ^ y.charCodeAt(i);
  }
  return result === 0;
}

export async function timedFetch(
  url: string,
  init: RequestInit = {},
): Promise<Response> {
  try {
    return await fetch(url, {
      ...init,
      redirect: "error",
      signal: AbortSignal.timeout(12000),
    });
  } catch {
    throw new AppleError("upstream_unavailable", 503);
  }
}

type Jwk = JsonWebKey & { kid?: string; use?: string; alg?: string };
export class AppleVerifier {
  private cached?: { keys: Jwk[]; until: number };
  private refreshing?: Promise<Jwk[]>;
  private lastFetch = 0;
  constructor(
    private fetcher: typeof timedFetch = timedFetch,
    private now = () => Date.now(),
  ) {}
  private async keys(refresh: boolean): Promise<Jwk[]> {
    if (this.cached && this.cached.until > this.now() && !refresh) {
      return this.cached.keys;
    }
    if (refresh && this.cached && this.now() - this.lastFetch < 30000) {
      return this.cached.keys;
    }
    if (!this.refreshing) {
      this.refreshing = (async () => {
        const response = await this.fetcher(
          "https://appleid.apple.com/auth/keys",
        );
        if (!response.ok) throw new AppleError("apple_keys_unavailable", 503);
        const body = object(await response.json());
        if (!Array.isArray(body.keys)) {
          throw new AppleError("apple_keys_unavailable", 503);
        }
        const keys = body.keys as Jwk[];
        this.lastFetch = this.now();
        this.cached = { keys, until: this.now() + 3600000 };
        return keys;
      })().finally(() => {
        this.refreshing = undefined;
      });
    }
    return await this.refreshing;
  }
  async verify(
    token: string,
    audiences: string[],
    notification = false,
  ): Promise<Json> {
    if (token.length > 32768) throw new AppleError("invalid_apple_token", 401);
    const parts = token.split(".");
    if (parts.length !== 3) throw new AppleError("invalid_apple_token", 401);
    let header: Json, payload: Json, signature: Uint8Array<ArrayBuffer>;
    try {
      header = object(JSON.parse(new TextDecoder().decode(decode64(parts[0]))));
      payload = object(
        JSON.parse(new TextDecoder().decode(decode64(parts[1]))),
      );
      signature = decode64(parts[2]);
    } catch {
      throw new AppleError("invalid_apple_token", 401);
    }
    if (
      header.alg !== "RS256" || typeof header.kid !== "string" ||
      header.crit !== undefined
    ) throw new AppleError("invalid_apple_token", 401);
    let key = (await this.keys(false)).find((k) => k.kid === header.kid);
    if (!key) key = (await this.keys(true)).find((k) => k.kid === header.kid);
    if (!key || key.kty !== "RSA" || key.alg !== "RS256" || key.use !== "sig") {
      throw new AppleError("invalid_apple_token", 401);
    }
    const imported = await crypto.subtle.importKey(
      "jwk",
      key,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      imported,
      signature,
      bytes(parts.slice(0, 2).join(".")),
    );
    const seconds = Math.floor(this.now() / 1000);
    if (
      !valid || payload.iss !== "https://appleid.apple.com" ||
      typeof payload.aud !== "string" || !audiences.includes(payload.aud) ||
      typeof payload.iat !== "number" || !Number.isSafeInteger(payload.iat) ||
      payload.iat > seconds + 60 ||
      (payload.exp !== undefined &&
        (typeof payload.exp !== "number" || payload.exp <= seconds)) ||
      (!notification &&
        (typeof payload.exp !== "number" || typeof payload.sub !== "string" ||
          !payload.sub)) ||
      (payload.nbf !== undefined &&
        (typeof payload.nbf !== "number" || payload.nbf > seconds + 60))
    ) throw new AppleError("invalid_apple_token", 401);
    return payload;
  }
}

export interface Binding {
  user_id: string;
  apple_sub: string;
  client_id: string;
}
export interface StoredTokens {
  refresh_token: string;
  access_token: string;
  id_token: string;
}
export class TokenCipher {
  constructor(
    private keys: Record<string, string>,
    public activeKeyId: string,
  ) {}
  async assertReady(): Promise<void> {
    await this.key(this.activeKeyId);
  }
  async assertAllReady(): Promise<string[]> {
    const ids = Object.keys(this.keys);
    if (
      !this.activeKeyId || !ids.includes(this.activeKeyId) || !ids.length ||
      ids.length > 32 || ids.some((id) => !id || id.length > 128)
    ) {
      throw new AppleError("encryption_not_configured", 503);
    }
    await Promise.all(ids.map((id) => this.key(id)));
    return ids;
  }
  private async key(id: string): Promise<CryptoKey> {
    try {
      const value = decode64(this.keys[id] ?? "");
      if (value.length !== 32) throw new Error();
      return await crypto.subtle.importKey("raw", value, "AES-GCM", false, [
        "encrypt",
        "decrypt",
      ]);
    } catch {
      throw new AppleError("encryption_not_configured", 503);
    }
  }
  private aad(binding: Binding, keyId: string): Uint8Array<ArrayBuffer> {
    return bytes(
      JSON.stringify([
        1,
        keyId,
        binding.user_id,
        binding.apple_sub,
        binding.client_id,
      ]),
    );
  }
  async seal(tokens: StoredTokens, binding: Binding): Promise<string> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const data = await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: this.aad(binding, this.activeKeyId),
      },
      await this.key(this.activeKeyId),
      bytes(JSON.stringify(tokens)),
    );
    return JSON.stringify({
      v: 1,
      iv: encode64(iv),
      data: encode64(new Uint8Array(data)),
    });
  }
  async open(
    value: string,
    binding: Binding,
    keyId: string,
  ): Promise<StoredTokens> {
    try {
      const envelope = object(JSON.parse(value));
      if (envelope.v !== 1) throw new Error();
      const plain = await crypto.subtle.decrypt(
        {
          name: "AES-GCM",
          iv: decode64(field(envelope, "iv", 32)),
          additionalData: this.aad(binding, keyId),
        },
        await this.key(keyId),
        decode64(field(envelope, "data", 65536)),
      );
      const result = object(JSON.parse(new TextDecoder().decode(plain)));
      return {
        refresh_token: field(result, "refresh_token"),
        access_token: field(result, "access_token"),
        id_token: field(result, "id_token", 32768),
      };
    } catch (error) {
      if (
        error instanceof AppleError &&
        error.code === "encryption_not_configured"
      ) throw error;
      throw new AppleError("encrypted_token_invalid", 503);
    }
  }
}
