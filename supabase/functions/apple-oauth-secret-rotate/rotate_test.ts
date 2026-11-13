import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  rotate,
  RotationConfig,
  SECRET_LIFETIME_SECONDS,
  signClientSecret,
} from "./rotate.ts";

async function testConfig(): Promise<
  { config: RotationConfig; publicKey: CryptoKey }
> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  const body = btoa(String.fromCharCode(...pkcs8));
  return {
    publicKey: pair.publicKey,
    config: {
      teamId: "TEAMID1234",
      keyId: "KEYID12345",
      // Same shape a secret store hands over: literal \n separators.
      privateKey:
        `-----BEGIN PRIVATE KEY-----\\n${body}\\n-----END PRIVATE KEY-----`,
      clientId: "com.chessever.web",
      projectRef: "projectref",
      managementToken: "management-token",
    },
  };
}

const decode = (part: string) =>
  JSON.parse(atob(part.replaceAll("-", "+").replaceAll("_", "/")));

Deno.test("signs an ES256 client secret Apple will parse", async () => {
  const { config, publicKey } = await testConfig();
  const { jwt, exp } = await signClientSecret(config, 1_000_000);
  const [header, payload, signature] = jwt.split(".");
  assertEquals(decode(header), { alg: "ES256", kid: "KEYID12345" });
  assertEquals(decode(payload), {
    iss: "TEAMID1234",
    iat: 1_000_000,
    exp: 1_000_000 + SECRET_LIFETIME_SECONDS,
    aud: "https://appleid.apple.com",
    sub: "com.chessever.web",
  });
  assertEquals(exp, 1_000_000 + SECRET_LIFETIME_SECONDS);
  assert(SECRET_LIFETIME_SECONDS < 15_777_000, "Apple caps at six months");
  const raw = Uint8Array.from(
    atob(signature.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      raw,
      new TextEncoder().encode(`${header}.${payload}`),
    ),
  );
});

function fakeFetch(appleError: string, patchStatus = 200) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fetcher = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.startsWith("https://appleid.apple.com")) {
      return Promise.resolve(
        new Response(JSON.stringify({ error: appleError }), { status: 400 }),
      );
    }
    return Promise.resolve(new Response("{}", { status: patchStatus }));
  }) as typeof fetch;
  return { calls, fetcher };
}

Deno.test("writes the secret only after Apple accepts it", async () => {
  const { config } = await testConfig();
  const { calls, fetcher } = fakeFetch("invalid_grant");
  const result = await rotate(config, fetcher, 1_000_000);
  assert(result.ok);
  assertEquals(calls.length, 2);
  assertEquals(
    calls[1].url,
    "https://api.supabase.com/v1/projects/projectref/config/auth",
  );
  assertEquals(calls[1].init?.method, "PATCH");
  const body = JSON.parse(String(calls[1].init?.body));
  assertEquals(Object.keys(body), ["external_apple_secret"]);
});

Deno.test("never overwrites the live secret with one Apple rejects", async () => {
  const { config } = await testConfig();
  const { calls, fetcher } = fakeFetch("invalid_client");
  const result = await rotate(config, fetcher);
  assertEquals(result, { ok: false, error: "apple_rejected_secret" });
  assertEquals(calls.length, 1);
});

Deno.test("reports a failed config write", async () => {
  const { config } = await testConfig();
  const { fetcher } = fakeFetch("invalid_grant", 401);
  assertEquals(await rotate(config, fetcher), {
    ok: false,
    error: "supabase_config_401",
  });
});

Deno.test("refuses to run half-configured", async () => {
  const { config } = await testConfig();
  const { calls, fetcher } = fakeFetch("invalid_grant");
  assertEquals(await rotate({ ...config, managementToken: "" }, fetcher), {
    ok: false,
    error: "not_configured",
  });
  assertEquals(calls.length, 0);
});
