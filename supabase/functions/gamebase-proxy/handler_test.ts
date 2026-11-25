import { createGamebaseProxyHandler } from "./handler.ts";

function equal(actual: unknown, expected: unknown) {
  if (actual !== expected) {
    throw new Error(`Expected ${expected}; got ${actual}`);
  }
}

const env: Record<string, string> = {
  GAMEBASE_CLIENT_ANON_KEY: "public",
  GAMEBASE_API_KEY: "server",
  GAMEBASE_API_BASE: "https://upstream.test",
};

const userToken = `Bearer e30.${
  btoa(JSON.stringify({ sub: "account-a" })).replaceAll("=", "")
}.signature`;

type Upstream = (input: string, init: RequestInit) => Promise<Response>;

function proxy(upstream: Upstream) {
  return createGamebaseProxyHandler({
    env: (name) => env[name],
    fetch: upstream,
  });
}

function nextMove(signal?: AbortSignal): Request {
  return new Request(
    "https://edge.test/functions/v1/gamebase-proxy/api/next-move",
    {
      method: "POST",
      headers: {
        apikey: "public",
        authorization: userToken,
        "content-type": "application/json",
      },
      body: JSON.stringify({ version: 2, session: "panel-0001", moves: [] }),
      signal,
    },
  );
}

/** An upstream that answers only when told to, and records its signal. */
function heldUpstream() {
  let signal: AbortSignal | undefined;
  let called!: () => void;
  const reached = new Promise<void>((resolve) => called = resolve);
  const upstream: Upstream = (_input, init) => {
    signal = init.signal ?? undefined;
    called();
    return new Promise<Response>((_resolve, reject) => {
      signal?.addEventListener(
        "abort",
        () => reject(new DOMException("aborted", "AbortError")),
      );
    });
  };
  return { upstream, reached, signal: () => signal };
}

Deno.test("preflights may be reused for ten minutes", async () => {
  const response = await proxy(() => {
    throw new Error("a preflight never reaches the service");
  })(
    new Request(
      "https://edge.test/functions/v1/gamebase-proxy/api/next-move",
      { method: "OPTIONS" },
    ),
  );
  equal(response.status, 204);
  equal(response.headers.get("access-control-max-age"), "600");
  const exposed = response.headers.get("access-control-expose-headers") ?? "";
  equal(/\bRetry-After\b/i.test(exposed), true);
  equal(/X-Prediction-Cache/i.test(exposed), false);
});

Deno.test("next move relays Retry-After and keeps cache hits private", async () => {
  const response = await proxy(() =>
    Promise.resolve(
      new Response(JSON.stringify({ status: "pending", reason: "queued" }), {
        status: 202,
        headers: {
          "content-type": "application/json",
          "retry-after": "1",
          "x-prediction-cache": "hit",
        },
      }),
    )
  )(nextMove());
  equal(response.status, 202);
  equal(response.headers.get("retry-after"), "1");
  equal(response.headers.has("x-prediction-cache"), false);
  equal(response.headers.has("access-control-max-age"), false);
  equal(response.headers.get("cache-control"), "private, no-store");
  equal((await response.json()).reason, "queued");
});

Deno.test("a caller hanging up during a long poll aborts the upstream request", async () => {
  const held = heldUpstream();
  const caller = new AbortController();
  const answer = proxy(held.upstream)(nextMove(caller.signal));
  await held.reached;
  equal(held.signal()?.aborted, false);

  caller.abort();
  const response = await answer;
  equal(held.signal()?.aborted, true);
  equal(response.status, 502);
});

Deno.test("a caller hanging up mid-body aborts the upstream request", async () => {
  let signal: AbortSignal | undefined;
  const caller = new AbortController();
  const response = await proxy((_input, init) => {
    signal = init.signal ?? undefined;
    return Promise.resolve(
      new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("{"));
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );
  })(nextMove(caller.signal));
  const reader = response.body!.getReader();
  await reader.read();

  caller.abort();
  equal(signal?.aborted, true);
  await reader.cancel();
});

Deno.test("an answer is relayed as the upstream body, with no step in between", async () => {
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('{"stage":"final"}'));
      controller.close();
    },
  });
  const response = await proxy(() =>
    Promise.resolve(
      new Response(body, {
        status: 200,
        headers: { "content-type": "application/json" },
      }),
    )
  )(nextMove());
  equal(response.body, body);
  equal((await response.json()).stage, "final");
});

Deno.test("an empty answer is relayed empty", async () => {
  const response = await proxy(() =>
    Promise.resolve(new Response(null, { status: 204 }))
  )(nextMove());
  equal(response.status, 204);
  equal(response.body, null);
});
