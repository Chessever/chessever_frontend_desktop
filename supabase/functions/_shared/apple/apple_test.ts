import { AppleApi } from "./apple_api.ts";
import { AppleUser, Backend, SupabaseBackend } from "./backend.ts";
import { Dependencies, drain, handler } from "./handlers.ts";
import {
  AppleError,
  AppleVerifier,
  bytes,
  encode64,
  Json,
  sha256,
  TokenCipher,
} from "./security.ts";

// All cryptographic keys and tokens below are generated in-memory for tests.
// No real Apple or Supabase endpoints, credentials, or accounts are used.
function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(JSON.stringify(actual) === JSON.stringify(expected), "values differ");
}
async function rejects(run: () => Promise<unknown>, code: string) {
  try {
    await run();
  } catch (error) {
    assert(error instanceof AppleError && error.code === code);
    return;
  }
  throw new Error("expected rejection");
}
const pair = await crypto.subtle.generateKey(
  {
    name: "RSASSA-PKCS1-v1_5",
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: "SHA-256",
  },
  true,
  ["sign", "verify"],
);
const jwk = {
  ...await crypto.subtle.exportKey("jwk", pair.publicKey),
  kid: "test-key",
  alg: "RS256",
  use: "sig",
};
const ecPair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);
const privatePem = `-----BEGIN PRIVATE KEY-----\n${
  btoa(
    String.fromCharCode(
      ...new Uint8Array(
        await crypto.subtle.exportKey("pkcs8", ecPair.privateKey),
      ),
    ),
  )
}\n-----END PRIVATE KEY-----`;
const now = Math.floor(Date.now() / 1000);
const nonce = "test-nonce-at-least-32-characters-long";
const baseClaims = {
  iss: "https://appleid.apple.com",
  aud: "test.native.app",
  sub: "test-apple-subject",
  iat: now,
  exp: now + 3600,
  nonce: await sha256(nonce),
};
async function token(overrides: Json = {}, header: Json = {}): Promise<string> {
  const unsigned = [
    encode64(
      bytes(JSON.stringify({ alg: "RS256", kid: "test-key", ...header })),
    ),
    encode64(bytes(JSON.stringify({ ...baseClaims, ...overrides }))),
  ].join(".");
  return `${unsigned}.${
    encode64(
      new Uint8Array(
        await crypto.subtle.sign(
          "RSASSA-PKCS1-v1_5",
          pair.privateKey,
          bytes(unsigned),
        ),
      ),
    )
  }`;
}
const idToken = await token();
const key = encode64(crypto.getRandomValues(new Uint8Array(32)));
const binding = {
  user_id: "test-user",
  apple_sub: baseClaims.sub,
  client_id: baseClaims.aud,
};
const storedTokens = {
  refresh_token: "test-refresh",
  access_token: "test-access",
  id_token: idToken,
};
const currentUser: AppleUser = {
  id: binding.user_id,
  identities: [{
    provider: "apple",
    identity_data: { sub: binding.apple_sub },
  }],
};

async function fixture(
  options: {
    claims?: Json;
    exchangeClaims?: Json;
    revokeStatus?: number;
    user?: AppleUser;
    cipher?: TokenCipher;
    rpc?: Backend["rpc"];
  } = {},
) {
  const calls: { name: string; args: Json; authorization?: string }[] = [];
  const appleCalls: { url: string; form: URLSearchParams }[] = [];
  const verifier = new AppleVerifier((url) => {
    equal(url, "https://appleid.apple.com/auth/keys");
    return Promise.resolve(Response.json({ keys: [jwk] }));
  });
  const apple = new AppleApi(
    {
      audiences: [baseClaims.aud],
      teamId: "TESTTEAM00",
      keyId: "TESTKEY000",
      privateKey: privatePem,
      redirectUris: {},
    },
    verifier,
    async (url, init) => {
      const form = new URLSearchParams(init?.body as URLSearchParams);
      appleCalls.push({ url, form });
      if (url.endsWith("/token")) {
        return Response.json({
          ...storedTokens,
          id_token: options.exchangeClaims
            ? await token(options.exchangeClaims)
            : idToken,
        });
      }
      if (url.endsWith("/revoke")) {
        return new Response(null, {
          status: options.revokeStatus ?? 200,
        });
      }
      throw new Error("unexpected URL");
    },
  );
  const backend: Backend = {
    user(authorization) {
      if (authorization !== "Bearer test-session") {
        return Promise.reject(new AppleError("unauthorized", 401));
      }
      return Promise.resolve(options.user ?? currentUser);
    },
    rpc(name, args, authorization) {
      calls.push({ name, args, authorization });
      return options.rpc
        ? options.rpc(name, args, authorization)
        : Promise.resolve(name === "apple_claim_revoke_jobs" ? [] : null);
    },
  };
  const deps: Dependencies = {
    backend,
    apple,
    verifier,
    cipher: options.cipher ?? new TokenCipher({ test: key }, "test"),
    audiences: [baseClaims.aud],
    workerSecret: "test-worker-secret",
  };
  const registerBody = {
    authorization_code: "test-authorization-code",
    identity_token: options.claims ? await token(options.claims) : idToken,
    nonce,
  };
  return { deps, calls, appleCalls, registerBody };
}
function request(
  body: unknown,
  authorization = "Bearer test-session",
  method = "POST",
) {
  return new Request("https://example.invalid/functions/v1/test", {
    method,
    headers: { "Content-Type": "application/json", authorization },
    ...(method === "POST" ? { body: JSON.stringify(body) } : {}),
  });
}

Deno.test("verify accepts a signed Apple token and caches only the fixed JWKS origin", async () => {
  let calls = 0;
  const verifier = new AppleVerifier(() => {
    calls++;
    return Promise.resolve(Response.json({ keys: [jwk] }));
  });
  equal((await verifier.verify(idToken, [baseClaims.aud])).sub, baseClaims.sub);
  await verifier.verify(idToken, [baseClaims.aud]);
  equal(calls, 1);
});
Deno.test("verify rejects changed payload, wrong issuer/audience/expiry/algorithm/future issuance", async () => {
  const { deps } = await fixture();
  const parts = idToken.split(".");
  parts[1] = encode64(
    bytes(JSON.stringify({ ...baseClaims, sub: "attacker" })),
  );
  await rejects(
    () => deps.verifier.verify(parts.join("."), [baseClaims.aud]),
    "invalid_apple_token",
  );
  for (
    const claims of [
      { iss: "https://attacker.invalid" },
      { aud: "another.app" },
      { exp: now - 1 },
      { iat: now + 3600 },
      { exp: "later" },
      { sub: "" },
    ]
  ) {
    const invalid = await token(claims);
    await rejects(
      () => deps.verifier.verify(invalid, [baseClaims.aud]),
      "invalid_apple_token",
    );
  }
  const none = await token({}, { alg: "none" });
  await rejects(
    () => deps.verifier.verify(none, [baseClaims.aud]),
    "invalid_apple_token",
  );
});
Deno.test("unknown signing key does not cause unbounded JWKS refreshes", async () => {
  let calls = 0;
  const verifier = new AppleVerifier(() => {
    calls++;
    return Promise.resolve(Response.json({ keys: [jwk] }));
  });
  const bad = await token({}, { kid: "unknown" });
  for (let i = 0; i < 3; i++) {
    await rejects(
      () => verifier.verify(bad, [baseClaims.aud]),
      "invalid_apple_token",
    );
  }
  equal(calls, 1);
});
Deno.test("AES-GCM binds ciphertext to user, Apple subject, client, key version and detects tampering", async () => {
  const cipher = new TokenCipher({
    old: key,
    current: encode64(crypto.getRandomValues(new Uint8Array(32))),
  }, "old");
  const sealed = await cipher.seal(storedTokens, binding);
  assert(!sealed.includes(storedTokens.refresh_token));
  equal(await cipher.open(sealed, binding, "old"), storedTokens);
  for (
    const changed of [{ ...binding, user_id: "other" }, {
      ...binding,
      apple_sub: "other",
    }, { ...binding, client_id: "other" }]
  ) {
    await rejects(
      () => cipher.open(sealed, changed, "old"),
      "encrypted_token_invalid",
    );
  }
  await rejects(
    () => cipher.open(sealed, binding, "current"),
    "encrypted_token_invalid",
  );
  await rejects(
    () => cipher.open(sealed, binding, "missing"),
    "encryption_not_configured",
  );
  const envelope = JSON.parse(sealed);
  envelope.data = `${envelope.data[0] === "a" ? "b" : "a"}${
    envelope.data.slice(1)
  }`;
  await rejects(
    () => cipher.open(JSON.stringify(envelope), binding, "old"),
    "encrypted_token_invalid",
  );
});
Deno.test("native registration binds nonce and both Apple identity tokens to getUser identity", async () => {
  const f = await fixture();
  const result = await handler("register", () => f.deps)(
    request(f.registerBody),
  );
  equal(result.status, 200);
  equal(await result.json(), { stored: true });
  equal(f.calls[0].name, "apple_store_tokens");
  equal(f.calls[0].args.p_user_id, binding.user_id);
  equal(f.calls[0].args.p_apple_sub, binding.apple_sub);
  const sealed = f.calls[0].args.p_encrypted_tokens as string;
  equal(await f.deps.cipher.open(sealed, binding, "test"), storedTokens);
  const exchange = f.appleCalls[0];
  equal(exchange.url, "https://appleid.apple.com/auth/token");
  equal(exchange.form.get("client_id"), baseClaims.aud);
  equal(exchange.form.get("grant_type"), "authorization_code");
  assert(!exchange.form.has("redirect_uri"));
  const secret = exchange.form.get("client_secret")!.split(".");
  const claims = JSON.parse(
    atob(secret[1].replaceAll("-", "+").replaceAll("_", "/")),
  );
  equal(claims.sub, baseClaims.aud);
  equal(claims.aud, "https://appleid.apple.com");
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      ecPair.publicKey,
      Uint8Array.from(
        atob(secret[2].replaceAll("-", "+").replaceAll("_", "/")),
        (c) => c.charCodeAt(0),
      ),
      bytes(secret.slice(0, 2).join(".")),
    ),
  );
});
Deno.test("registration rejects absent auth, unauthenticated bearer and Apple account substitution before exchange", async () => {
  const f = await fixture();
  for (const auth of ["", "Bearer invalid"]) {
    equal(
      (await handler("register", () => f.deps)(request(f.registerBody, auth)))
        .status,
      401,
    );
  }
  const other = await fixture({
    user: {
      id: "attacker",
      identities: [{ provider: "apple", identity_data: { sub: "other" } }],
    },
  });
  equal(
    (await handler("register", () => other.deps)(request(other.registerBody)))
      .status,
    403,
  );
  equal(other.appleCalls.length, 0);
  equal(other.calls.length, 0);
});
Deno.test("registration rejects nonce mismatch and wrong-sub/wrong-nonce exchanged token", async () => {
  const f = await fixture();
  equal(
    (await handler("register", () => f.deps)(
      request({ ...f.registerBody, nonce: "wrong-nonce-long-enough-for-test" }),
    )).status,
    403,
  );
  equal(f.appleCalls.length, 0);
  for (
    const claims of [{ sub: "different-sub" }, { nonce: "different-nonce" }]
  ) {
    const other = await fixture({ exchangeClaims: claims });
    equal(
      (await handler("register", () => other.deps)(request(other.registerBody)))
        .status,
      403,
    );
    equal(other.calls.length, 0);
  }
});
Deno.test("missing encryption configuration fails before consuming one-use code", async () => {
  const f = await fixture({ cipher: new TokenCipher({}, "") });
  const result = await handler("register", () => f.deps)(
    request(f.registerBody),
  );
  equal(result.status, 503);
  equal(f.appleCalls.length, 0);
});
Deno.test("persistence failure retries identical ciphertext and never reports stored success", async () => {
  const f = await fixture({
    rpc: () => Promise.reject(new Error("must not expose private response")),
  });
  const result = await handler("register", () => f.deps)(
    request(f.registerBody),
  );
  equal(result.status, 503);
  equal(await result.json(), { error: "token_persistence_failed" });
  equal(f.calls.length, 3);
  equal(f.calls[0].args.p_encrypted_tokens, f.calls[2].args.p_encrypted_tokens);
  equal(f.appleCalls.length, 1);
  equal(f.appleCalls[0].url, "https://appleid.apple.com/auth/token");
});

for (const mode of ["store-failed", "commit-acknowledgement-lost"]) {
  Deno.test(`returning user's grant survives ${mode}; durable deletion can still revoke`, async () => {
    const cipher = new TokenCipher({ test: key }, "test");
    const previous = {
      ...storedTokens,
      refresh_token: "test-existing-grant-refresh",
    };
    const originalCiphertext = await cipher.seal(previous, binding);
    let persisted = originalCiphertext;
    const f = await fixture({
      cipher,
      rpc: (name, args) => {
        if (name === "apple_store_tokens") {
          if (mode === "commit-acknowledgement-lost") {
            persisted = args.p_encrypted_tokens as string;
          }
          return Promise.reject(
            new Error("private persistence transport failure"),
          );
        }
        if (name === "apple_claim_revoke_jobs") {
          return Promise.resolve([{
            ...binding,
            id: "test-deletion-job",
            lease_token: "test-lease",
            key_id: "test",
            encrypted_tokens: persisted,
          }]);
        }
        if (name === "apple_finish_revoke_job") {
          equal(args.p_success, true);
          return Promise.resolve(null);
        }
        return Promise.reject(new Error("unexpected RPC"));
      },
    });
    const response = await handler("register", () => f.deps)(
      request(f.registerBody),
    );
    equal(response.status, 503);
    equal(await response.json(), { error: "token_persistence_failed" });
    equal(f.calls.length, 3);
    equal(f.appleCalls.map((call) => call.url), [
      "https://appleid.apple.com/auth/token",
    ]);
    equal(
      f.calls[0].args.p_encrypted_tokens,
      f.calls[2].args.p_encrypted_tokens,
    );
    const retained = await cipher.open(persisted, binding, "test");
    equal(retained, mode === "store-failed" ? previous : storedTokens);
    if (mode === "store-failed") equal(persisted, originalCiphertext);

    // A later account deletion owns revocation, whether the last registration
    // committed or the previously saved refresh token was retained.
    equal(await drain(f.deps, binding.user_id), {
      processed: 1,
      pending: false,
    });
    equal(f.appleCalls[1].url, "https://appleid.apple.com/auth/revoke");
    equal(f.appleCalls[1].form.get("token"), retained.refresh_token);
    equal(f.calls.at(-1)?.name, "apple_finish_revoke_job");
  });
}
Deno.test("Supabase getUser is server verified and service-only RPC credentials are separate", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const backend = new SupabaseBackend(
    "https://example.invalid",
    "test-service",
    "test-anon",
    (url, init = {}) => {
      calls.push({ url, init });
      return Promise.resolve(
        url.endsWith("/user")
          ? Response.json({ ...currentUser, is_anonymous: false })
          : Response.json(null),
      );
    },
  );
  await backend.user("Bearer test-session");
  await backend.rpc("apple_store_tokens", {});
  equal(calls[0].url, "https://example.invalid/auth/v1/user");
  equal(
    new Headers(calls[0].init.headers).get("authorization"),
    "Bearer test-session",
  );
  equal(
    new Headers(calls[1].init.headers).get("authorization"),
    "Bearer test-service",
  );
  const invalid = new SupabaseBackend(
    "https://example.invalid",
    "test-service",
    "test-anon",
    () => Promise.resolve(new Response("private error", { status: 401 })),
  );
  await rejects(() => invalid.user("Bearer expired"), "unauthorized");
});
Deno.test("delete invokes authority as caller and drains only captured authenticated user; failures remain pending", async () => {
  const f = await fixture({
    rpc: (name) =>
      name === "delete_user_account"
        ? Promise.resolve({
          deleted: true,
          apple_manual_revoke_required: false,
        })
        : Promise.reject(new Error("offline")),
  });
  const result = await handler("delete", () => f.deps)(request({}));
  equal(result.status, 200);
  const reply = await result.json();
  equal(reply.deleted, true);
  equal(reply.apple_revocation_pending, true);
  equal(reply.data_removal_pending, true);
  equal(f.calls[0], {
    name: "delete_user_account",
    args: {},
    authorization: "Bearer test-session",
  });
  equal(f.calls[1].args.p_user_id, binding.user_id);
  const attacker = await handler("delete", () => f.deps)(
    request({ user_id: "victim" }),
  );
  equal(attacker.status, 400);
});
Deno.test("legacy missing-token deletion succeeds with manual fallback", async () => {
  const f = await fixture({
    rpc: (name) =>
      Promise.resolve(
        name === "delete_user_account"
          ? { deleted: true, apple_manual_revoke_required: true }
          : name === "account_cleanup_pending"
          ? false
          : [],
      ),
  });
  const result = await handler("delete", () => f.deps)(request({}));
  equal(await result.json(), {
    deleted: true,
    apple_manual_revoke_required: true,
    apple_revocation_pending: false,
    data_removal_pending: false,
  });
});

Deno.test("authenticated guests may delete but may not register Apple tokens", async () => {
  const f = await fixture({
    user: { id: "test-guest", is_anonymous: true, identities: [] },
    rpc: (name) =>
      Promise.resolve(
        name === "delete_user_account"
          ? { deleted: true, apple_manual_revoke_required: false }
          : name === "account_cleanup_pending"
          ? false
          : [],
      ),
  });
  equal((await handler("delete", () => f.deps)(request({}))).status, 200);
  equal(
    (await handler("register", () => f.deps)(request(f.registerBody))).status,
    401,
  );
  equal(f.appleCalls.length, 0);
  const backend = new SupabaseBackend(
    "https://example.invalid",
    "test-service",
    "test-anon",
    () =>
      Promise.resolve(Response.json({ id: "test-guest", is_anonymous: true })),
  );
  equal((await backend.user("Bearer test-guest-session")).id, "test-guest");
});

Deno.test("an exchange without a refresh token never reports persistent revocation support", async () => {
  const api = new AppleApi(
    {
      audiences: [baseClaims.aud],
      teamId: "test-team",
      keyId: "test-signing-key",
      privateKey: privatePem,
      redirectUris: {},
    },
    undefined,
    () =>
      Promise.resolve(
        Response.json({ access_token: "test-access", id_token: idToken }),
      ),
  );
  await rejects(
    () => api.exchange("test-code", baseClaims.aud),
    "invalid_request",
  );
});
Deno.test("revocation failure, lost keys, and lease completion failure never drop a job", async () => {
  for (
    const mode of ["revoke-fails", "key-lost", "complete-fails", "success"]
  ) {
    const cipher = new TokenCipher({ test: key }, "test");
    const job = {
      ...binding,
      id: "test-job",
      key_id: "test",
      lease_token: "test-lease",
      encrypted_tokens: await cipher.seal(storedTokens, binding),
    };
    const f = await fixture({
      revokeStatus: mode === "revoke-fails" ? 400 : 200,
      cipher: mode === "key-lost" ? new TokenCipher({}, "new") : cipher,
      rpc: (name) =>
        name === "apple_claim_revoke_jobs"
          ? Promise.resolve([job])
          : mode === "complete-fails"
          ? Promise.reject(new Error("offline"))
          : Promise.resolve(null),
    });
    const result = await drain(f.deps, binding.user_id);
    equal(result.pending, mode !== "success");
    const finish = f.calls.find((c) => c.name === "apple_finish_revoke_job")!;
    equal(finish.args.p_id, "test-job");
    equal(finish.args.p_lease_token, "test-lease");
    equal(
      finish.args.p_success,
      mode === "success" || mode === "complete-fails",
    );
  }
});
Deno.test("worker refuses user sessions and missing worker configuration", async () => {
  const f = await fixture();
  equal((await handler("worker", () => f.deps)(request({}))).status, 401);
  equal(f.calls.length, 0);
  equal(
    (await handler("worker", () => f.deps)(
      request({}, "Bearer test-worker-secret"),
    )).status,
    200,
  );
  f.deps.workerSecret = "";
  equal(
    (await handler("worker", () => f.deps)(
      request({}, "Bearer test-worker-secret"),
    )).status,
    401,
  );
});
Deno.test("signed consent revocation and account-deleted events reach deduplicating SQL only after verification", async () => {
  for (const type of ["consent-revoked", "account-deleted"]) {
    const f = await fixture();
    const event = { type, sub: baseClaims.sub, event_time: now };
    const payload = await token({
      exp: undefined,
      sub: undefined,
      jti: "test-event",
      events: type === "consent-revoked" ? JSON.stringify(event) : event,
    });
    const result = await handler("notification", () => f.deps)(
      request({ payload }, ""),
    );
    equal(result.status, 200);
    equal(f.calls[0], {
      name: "apple_process_notification",
      args: {
        p_jti: "test-event",
        p_apple_sub: baseClaims.sub,
        p_event_type: type,
        p_event_time: now,
      },
    });
    const wrong = await token({
      aud: "wrong-client",
      jti: "test-event",
      events: event,
    });
    equal(
      (await handler("notification", () => f.deps)(
        request({ payload: wrong }, ""),
      )).status,
      401,
    );
    equal(f.calls.length, 1);
  }
});
Deno.test("notification rejects missing event id, future event timestamp and unsupported event type", async () => {
  const f = await fixture();
  for (
    const claims of [
      {
        events: {
          type: "consent-revoked",
          sub: baseClaims.sub,
          event_time: now,
        },
      },
      {
        jti: "test-event",
        events: {
          type: "consent-revoked",
          sub: baseClaims.sub,
          event_time: now + 3600,
        },
      },
      {
        jti: "test-event",
        events: {
          type: "account-delete",
          sub: baseClaims.sub,
          event_time: now,
        },
      },
    ]
  ) {
    equal(
      (await handler("notification", () => f.deps)(
        request({ payload: await token(claims) }, ""),
      )).status,
      400,
    );
  }
  equal(f.calls.length, 0);
});
Deno.test("protocol rejects oversized JSON, wrong methods, malformed JSON without leaking bodies", async () => {
  const f = await fixture();
  equal(
    (await handler("register", () => f.deps)(
      request({}, "Bearer test-session", "GET"),
    )).status,
    405,
  );
  equal(
    (await handler("register", () => f.deps)(
      request({ code: "a".repeat(66000) }),
    )).status,
    413,
  );
  const invalid = new Request("https://example.invalid", {
    method: "POST",
    headers: {
      authorization: "Bearer test-session",
      "content-type": "application/json",
    },
    body: "private invalid body",
  });
  const reply = await handler("register", () => f.deps)(invalid);
  equal(reply.status, 400);
  equal(await reply.json(), { error: "invalid_request" });
});

Deno.test("all four public health endpoints validate config and read-only schema without Apple or account mutations", async () => {
  for (
    const endpoint of ["register", "delete", "worker", "notification"] as const
  ) {
    const f = await fixture({
      rpc: (name) => Promise.resolve(name === "apple_lifecycle_health"),
    });
    f.deps.workerSecret = "test-worker-secret-that-is-at-least-32-characters";
    const result = await handler(endpoint, () => f.deps)(
      new Request("https://example.invalid/functions/v1/test?health=1"),
    );
    equal(result.status, 200);
    equal(await result.json(), { ready: true });
    equal(f.calls, [{
      name: "apple_lifecycle_health",
      args: { p_key_ids: ["test"] },
    }]);
    equal(f.appleCalls.length, 0);
  }
});

Deno.test("health fails closed on missing config, malformed signing/encryption keys, or inaccessible/incomplete schema", async () => {
  const health = new Request("https://example.invalid/test?health=1");
  for (
    const mode of [
      "secret",
      "audience",
      "cipher",
      "signer",
      "schema",
      "rpc-failure",
      "parse",
    ]
  ) {
    const f = await fixture({
      cipher: mode === "cipher"
        ? new TokenCipher({ test: "wrong-length" }, "test")
        : undefined,
      rpc: () =>
        mode === "rpc-failure"
          ? Promise.reject(new Error("private backend content"))
          : Promise.resolve(mode !== "schema"),
    });
    f.deps.workerSecret = mode === "secret"
      ? ""
      : "test-worker-secret-that-is-at-least-32-characters";
    if (mode === "audience") f.deps.audiences = [];
    if (mode === "signer") {
      f.deps.apple = new AppleApi({
        audiences: [baseClaims.aud],
        teamId: "TESTTEAM00",
        keyId: "TESTKEY000",
        privateKey: "not-a-key",
        redirectUris: {},
      });
    }
    const result = await handler("register", () => {
      if (mode === "parse") throw new Error("private config content");
      return f.deps;
    })(health);
    equal(result.status, 503);
    equal(await result.json(), { ready: false });
    equal(f.appleCalls.length, 0);
  }
});
