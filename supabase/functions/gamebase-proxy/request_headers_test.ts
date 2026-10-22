import { hasProjectClientKey, upstreamHeaders } from "./request_headers.ts";

function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) {
    throw new Error(`Expected ${expected}; got ${actual}`);
  }
}
const userToken = `Bearer e30.${
  btoa(JSON.stringify({ sub: "account-a" })).replaceAll("=", "")
}.signature`;

Deno.test("public project key is required, rather than mere header presence", () => {
  equal(
    hasProjectClientKey(
      new Headers({ authorization: "Bearer arbitrary" }),
      "public",
    ),
    false,
  );
  equal(
    hasProjectClientKey(new Headers({ apikey: "other-project" }), "public"),
    false,
  );
  equal(hasProjectClientKey(new Headers({ apikey: "public" }), "public"), true);
  equal(
    hasProjectClientKey(
      new Headers({ authorization: "Bearer public" }),
      "public",
    ),
    true,
  );
  equal(hasProjectClientKey(new Headers({ apikey: "" }), ""), false);
});

Deno.test("caller cannot choose the upstream credential or leak other headers", () => {
  const headers = upstreamHeaders(
    new Headers({
      apikey: "public",
      "X-API-Key": "caller-key",
      cookie: "private-cookie",
    }),
    { method: "GET", pattern: /./ },
    "server-only-key",
  );
  equal(headers.get("X-API-Key"), "server-only-key");
  equal(headers.get("apikey"), null);
  equal(headers.get("cookie"), null);
});

Deno.test("rewarded session and its account bearer travel together", () => {
  const headers = upstreamHeaders(
    new Headers({
      authorization: userToken,
      "x-rewarded-session": "reward-ticket",
    }),
    { method: "GET", pattern: /./ },
    "server-only-key",
  );
  equal(headers.get("x-rewarded-session"), "reward-ticket");
  equal(headers.get("authorization"), userToken);
  const anonymous = upstreamHeaders(
    new Headers({
      authorization: "Bearer public",
      "x-rewarded-session": "reward-ticket",
    }),
    { method: "GET", pattern: /./ },
    "server-only-key",
  );
  equal(anonymous.get("x-rewarded-session"), null);
});

Deno.test("viewer cache recheck and member identity are preserved", () => {
  const headers = upstreamHeaders(
    new Headers({
      authorization: userToken,
      "cache-control": "no-cache",
    }),
    { method: "GET", pattern: /./, viewer: true },
    "server-only-key",
  );
  equal(headers.get("authorization"), userToken);
  equal(headers.get("cache-control"), "no-cache");
  equal(headers.get("pragma"), "no-cache");
});
