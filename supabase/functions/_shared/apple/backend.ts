import { AppleError, Binding, Json, object, timedFetch } from "./security.ts";

export interface AppleUser {
  id: string;
  is_anonymous?: boolean;
  identities?: {
    provider: string;
    id?: string;
    identity_data?: { sub?: string };
  }[];
}
export interface RevokeJob extends Binding {
  id: string;
  encrypted_tokens: string;
  key_id: string;
  lease_token: string;
}
export interface Backend {
  user(authorization: string): Promise<AppleUser>;
  rpc(name: string, args: Json, authorization?: string): Promise<unknown>;
  cleanup?(userId: string): Promise<void>;
}

export class SupabaseBackend implements Backend {
  constructor(
    private url: string,
    private serviceKey: string,
    private anonKey: string,
    private fetcher: typeof timedFetch = timedFetch,
  ) {}
  private async request(
    path: string,
    init: RequestInit,
    authorization?: string,
  ): Promise<unknown> {
    if (!this.url || !this.serviceKey) {
      throw new AppleError("backend_not_configured", 503);
    }
    const response = await this.fetcher(
      `${this.url.replace(/\/$/, "")}${path}`,
      {
        ...init,
        headers: {
          "Content-Type": "application/json",
          apikey: authorization
            ? this.anonKey || this.serviceKey
            : this.serviceKey,
          authorization: authorization ?? `Bearer ${this.serviceKey}`,
        },
      },
    );
    if (!response.ok) {
      // Never surface database or auth response bodies to callers/logs.
      if (
        path === "/auth/v1/user" &&
        (response.status === 401 || response.status === 403)
      ) throw new AppleError("unauthorized", 401);
      throw new AppleError("backend_unavailable", 503);
    }
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }
  async user(authorization: string): Promise<AppleUser> {
    if (!/^Bearer [^\s]+$/i.test(authorization)) {
      throw new AppleError("unauthorized", 401);
    }
    const value = object(
      await this.request("/auth/v1/user", { method: "GET" }, authorization),
    );
    if (typeof value.id !== "string") {
      throw new AppleError("unauthorized", 401);
    }
    return value as unknown as AppleUser;
  }
  rpc(name: string, args: Json, authorization?: string): Promise<unknown> {
    return this.request(`/rest/v1/rpc/${name}`, {
      method: "POST",
      body: JSON.stringify(args),
    }, authorization);
  }
  async cleanup(userId: string): Promise<void> {
    await this.request("/functions/v1/account-data-cleanup", {
      method: "POST",
      body: JSON.stringify({ user_id: userId }),
    });
  }
}

export function hasAppleSubject(user: AppleUser, sub: string): boolean {
  return user.identities?.some((identity) =>
    identity.provider === "apple" &&
    (identity.identity_data?.sub ?? identity.id) === sub
  ) ?? false;
}
