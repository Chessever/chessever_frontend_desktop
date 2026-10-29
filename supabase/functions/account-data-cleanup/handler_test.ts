import {
  type CleanupJob,
  createHandler,
  type Environment,
  type Fetcher,
  processJob,
} from "./handler.ts";

function assert(
  condition: unknown,
  description = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(description);
}
const user = "00000000-0000-4000-8000-000000000001";
const other = "00000000-0000-4000-8000-000000000002";
const job: CleanupJob = {
  id: "10000000-0000-4000-8000-000000000001",
  user_id: user,
  lease_token: "20000000-0000-4000-8000-000000000001",
  kind: "storage",
  payload: {
    bucket_id: "profile-avatars",
    path: `${user}/30000000-0000-4000-8000-000000000001.jpg`,
  },
};
const values: Record<string, string> = {
  SUPABASE_URL: "https://example.invalid",
  SUPABASE_SERVICE_ROLE_KEY: "synthetic-service",
  ACCOUNT_CLEANUP_CRON_SECRET: "synthetic-cron",
  ONESIGNAL_APP_ID: "40000000-0000-4000-8000-000000000001",
  ONESIGNAL_REST_API_KEY: "synthetic-onesignal",
  REVENUECAT_SECRET_API_KEY: "synthetic-revenuecat",
  REVENUECAT_STORE_AND_STRIPE_ONLY: "true",
};
const env: Environment = (name) => values[name];
const failFetch: Fetcher = () => {
  throw new Error("unexpected network");
};
const request = (
  token = "synthetic-service",
  body: object = { user_id: user },
) =>
  new Request("https://example.invalid/cleanup", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });

Deno.test("client JWT and absent authentication cannot claim jobs", async () => {
  const handle = createHandler({ env, fetch: failFetch });
  assert((await handle(request("synthetic-client-jwt"))).status === 401);
  assert(
    (await handle(
      new Request("https://example.invalid/cleanup", { method: "POST" }),
    )).status === 401,
  );
});

Deno.test("rejects malformed scope and excessive batches before network", async () => {
  const handle = createHandler({ env, fetch: failFetch });
  for (
    const body of [{ user_id: "../someone" }, { limit: 100 }, { limit: 0 }, {
      user_id: null,
    }, { arbitrary: true }]
  ) {
    assert((await handle(request("synthetic-service", body))).status === 400);
  }
  assert(
    (await handle(new Request("https://example.invalid/cleanup"))).status ===
      405,
  );
});

Deno.test("storage removes exactly one own avatar through the Storage API", async () => {
  let called = false;
  const result = await processJob(job, {
    env,
    fetch: (url, options) => {
      called = true;
      assert(
        String(url) ===
          "https://example.invalid/storage/v1/object/profile-avatars",
      );
      assert(options?.method === "DELETE");
      assert(options?.redirect === "error");
      assert(
        JSON.stringify(JSON.parse(String(options?.body))) ===
          JSON.stringify({ prefixes: [job.payload.path] }),
      );
      return new Response("[]");
    },
  });
  assert(called && result === null);
});

Deno.test("storage rejects another account, legal receipts, traversal and wildcard payloads", async () => {
  for (
    const payload of [
      {
        bucket_id: "profile-avatars",
        path: `${other}/30000000-0000-4000-8000-000000000001.jpg`,
      },
      {
        bucket_id: "payout-receipts",
        path: `${user}/30000000-0000-4000-8000-000000000001.jpg`,
      },
      { bucket_id: "profile-avatars", path: `${user}/../other.jpg` },
      { bucket_id: "profile-avatars", path: `${user}/%` },
      {
        bucket_id: "profile-avatars",
        path: `${user}/------------------------------------.jpg`,
      },
    ]
  ) {
    assert(
      await processJob({ ...job, payload }, { env, fetch: failFetch }) ===
        "invalid_payload",
    );
  }
});

Deno.test("OneSignal uses verified external_id delete and Key authorization", async () => {
  assert(
    await processJob({ ...job, kind: "onesignal" }, {
      env,
      fetch: (url, options) => {
        assert(
          String(url) ===
            `https://api.onesignal.com/apps/${values.ONESIGNAL_APP_ID}/users/by/external_id/${user}`,
        );
        assert(
          new Headers(options?.headers).get("Authorization") ===
            "Key synthetic-onesignal",
        );
        assert(options?.method === "DELETE");
        return new Response(null, { status: 202 });
      },
    }) === null,
  );
});

Deno.test("RevenueCat deletes only account UID, with no cancellation/refund request", async () => {
  assert(
    await processJob({ ...job, kind: "revenuecat" }, {
      env,
      fetch: (url, options) => {
        assert(
          String(url) === `https://api.revenuecat.com/v1/subscribers/${user}`,
        );
        assert(
          new Headers(options?.headers).get("Authorization") ===
            "Bearer synthetic-revenuecat",
        );
        assert(options?.method === "DELETE" && !options.body);
        return new Response(null, { status: 404 });
      },
    }) === null,
  );
});

Deno.test("missing provider configuration and unimplemented integrations remain pending", async () => {
  assert(
    await processJob({ ...job, kind: "onesignal" }, {
      env: () => undefined,
      fetch: failFetch,
    }) === "configuration_missing",
  );
  assert(
    await processJob({ ...job, kind: "revenuecat" }, {
      env: () => undefined,
      fetch: failFetch,
    }) === "configuration_missing",
  );
  assert(
    await processJob({ ...job, kind: "revenuecat" }, {
      env: (name) =>
        name === "REVENUECAT_STORE_AND_STRIPE_ONLY" ? undefined : env(name),
      fetch: failFetch,
    }) === "configuration_missing",
  );
  assert(
    await processJob({ ...job, kind: "gamebase" }, {
      env,
      fetch: failFetch,
    }) === "configuration_missing",
  );
  assert(
    await processJob({ ...job, kind: "appsflyer" }, {
      env,
      fetch: failFetch,
    }) === "integration_required",
  );
});

Deno.test("Gamebase erasure binds trusted project and queued UID, not job payload", async () => {
  const gamebaseEnv: Environment = (name) =>
    ({
      GAMEBASE_ACCOUNT_ERASURE_SECRET: "synthetic-erasure-secret",
      GAMEBASE_AUTH_PROJECT: "abcdefghijklmnopqrst",
    } as Record<string, string>)[name];
  assert(
    await processJob({
      ...job,
      kind: "gamebase",
      payload: { auth_project: "another-project", user_id: other },
    }, {
      env: gamebaseEnv,
      fetch: (url, options) => {
        assert(
          url === "https://service.chessever.com/api/internal/account-erasure",
        );
        assert(options?.method === "POST" && options.redirect === "error");
        assert(
          new Headers(options.headers).get("Authorization") ===
            "Bearer synthetic-erasure-secret",
        );
        const body = JSON.parse(String(options.body));
        assert(
          body.user_id === user && body.auth_project === "abcdefghijklmnopqrst",
        );
        return Response.json({ erased: true });
      },
    }) === null,
  );
});

Deno.test("Gamebase 202, 404 and malformed success retain the job for retry", async () => {
  const gamebaseEnv: Environment = (name) =>
    name === "GAMEBASE_AUTH_PROJECT"
      ? "abcdefghijklmnopqrst"
      : name === "GAMEBASE_ACCOUNT_ERASURE_SECRET"
      ? "synthetic-erasure-secret"
      : undefined;
  for (
    const result of [
      Response.json({ erased: false, pending: true }, { status: 202 }),
      new Response(null, { status: 404 }),
      Response.json({}),
    ]
  ) {
    assert(
      await processJob({ ...job, kind: "gamebase" }, {
        env: gamebaseEnv,
        fetch: () => result,
      }) === "provider_unavailable",
    );
  }
});

Deno.test("GA4 uses server refresh grant then userId deletion on configured properties", async () => {
  const gaEnv: Environment = (name) =>
    ({
      GOOGLE_ANALYTICS_PROPERTY_IDS: "12345,67890",
      GOOGLE_ANALYTICS_OAUTH_CLIENT_ID: "synthetic-oauth-client",
      GOOGLE_ANALYTICS_OAUTH_CLIENT_SECRET: "synthetic-oauth-secret",
      GOOGLE_ANALYTICS_OAUTH_REFRESH_TOKEN: "synthetic-refresh",
    } as Record<string, string>)[name];
  const properties = new Set<string>();
  const error = await processJob({ ...job, kind: "ga4" }, {
    env: gaEnv,
    fetch: (url, options) => {
      assert(options?.method === "POST" && options.redirect === "error");
      if (url === "https://oauth2.googleapis.com/token") {
        const body = new URLSearchParams(String(options.body));
        assert(body.get("grant_type") === "refresh_token");
        assert(body.get("refresh_token") === "synthetic-refresh");
        return Response.json({
          access_token: "synthetic-access",
          scope: "https://www.googleapis.com/auth/analytics.edit",
        });
      }
      assert(
        url.startsWith(
          "https://analyticsadmin.googleapis.com/v1alpha/properties/",
        ),
      );
      assert(url.endsWith(":submitUserDeletion"));
      assert(JSON.parse(String(options.body)).userId === user);
      assert(
        new Headers(options.headers).get("Authorization") ===
          "Bearer synthetic-access",
      );
      properties.add(url);
      return Response.json({ deletionRequestTime: "2026-10-29T10:00:00Z" });
    },
  });
  assert(error === null && properties.size === 2);
});

Deno.test("GA4 missing configuration and insufficient OAuth scope stay pending", async () => {
  assert(
    await processJob({ ...job, kind: "ga4" }, {
      env: () => undefined,
      fetch: failFetch,
    }) === "configuration_missing",
  );
  const gaEnv: Environment = (name) =>
    name === "GOOGLE_ANALYTICS_PROPERTY_IDS" ? "12345" : "synthetic-value";
  assert(
    await processJob({ ...job, kind: "ga4" }, {
      env: gaEnv,
      fetch: () =>
        Response.json({
          access_token: "synthetic-access",
          scope: "unrelated.scope",
        }),
    }) === "configuration_missing",
  );
});

Deno.test("GA4 never treats unknown property or malformed deletion acceptance as success", async () => {
  const gaEnv: Environment = (name) =>
    name === "GOOGLE_ANALYTICS_PROPERTY_IDS" ? "12345" : "synthetic-value";
  for (
    const [result, expected] of [[
      new Response(null, { status: 404 }),
      "configuration_missing",
    ], [Response.json({}), "provider_unavailable"]] as const
  ) {
    assert(
      await processJob({ ...job, kind: "ga4" }, {
        env: gaEnv,
        fetch: (url) =>
          url.includes("oauth2")
            ? Response.json({ access_token: "synthetic-access" })
            : result,
      }) === expected,
    );
  }
});

Deno.test("upstream 429/503 and permission failures produce fixed codes", async () => {
  for (
    const [status, expected] of [[429, "rate_limited"], [
      503,
      "provider_unavailable",
    ], [403, "configuration_missing"]] as const
  ) {
    assert(
      await processJob({ ...job, kind: "revenuecat" }, {
        env,
        fetch: () =>
          new Response("private upstream text must not be retained", {
            status,
          }),
      }) === expected,
    );
  }
});

Deno.test("drain scopes claims, propagates unguessable lease and reports pending", async () => {
  const calls: string[] = [];
  const handle = createHandler({
    env,
    fetch: (url, options) => {
      const path = new URL(String(url)).pathname;
      calls.push(path);
      const body = options?.body ? JSON.parse(String(options.body)) : {};
      if (path.endsWith("/account_claim_cleanup_jobs")) {
        assert(body.p_user_id === user && body.p_limit === 10);
        return Response.json([job]);
      }
      if (path.endsWith("/account_finish_cleanup_job")) {
        assert(body.p_id === job.id && body.p_lease_token === job.lease_token);
        assert(body.p_success === true && body.p_error_code === null);
        return Response.json(null);
      }
      if (path.endsWith("/account_cleanup_pending")) return Response.json(true);
      if (path === "/storage/v1/object/profile-avatars") {
        return Response.json([]);
      }
      throw new Error("unexpected request");
    },
  });
  const result = await handle(request());
  assert(result.status === 200);
  const body = await result.json();
  assert(body.completed === 1 && body.data_removal_pending === true);
  assert(calls.length === 4);
});

Deno.test("provider exception is sanitized and failed job is acknowledged for retry", async () => {
  let ack = false;
  const handle = createHandler({
    env,
    fetch: (url, options) => {
      const path = new URL(String(url)).pathname;
      if (path.endsWith("/account_claim_cleanup_jobs")) {
        return Response.json([job]);
      }
      if (path.endsWith("/account_finish_cleanup_job")) {
        const body = JSON.parse(String(options?.body));
        ack = body.p_success === false &&
          body.p_error_code === "request_failed";
        return Response.json(null);
      }
      if (path.endsWith("/account_cleanup_pending")) return Response.json(true);
      throw new Error("sensitive synthetic failure details");
    },
  });
  const result = await handle(request());
  assert(result.status === 200 && ack);
  assert(!(await result.text()).includes("sensitive"));
});

Deno.test("failed lease acknowledgment reports pending and never claims success", async () => {
  const handle = createHandler({
    env,
    fetch: (url) => {
      const path = new URL(String(url)).pathname;
      if (path.endsWith("/account_claim_cleanup_jobs")) {
        return Response.json([job]);
      }
      if (path.endsWith("/account_finish_cleanup_job")) {
        return new Response("private internal error", { status: 500 });
      }
      return Response.json([]);
    },
  });
  const result = await handle(request());
  assert(result.status === 503);
  const text = await result.text();
  assert(
    text.includes('"data_removal_pending":true') && !text.includes("private"),
  );
});

Deno.test("cron secret can drain due work without a caller-supplied identity", async () => {
  const handle = createHandler({
    env,
    fetch: (_url, options) => {
      assert(JSON.parse(String(options?.body)).p_user_id === null);
      return Response.json([]);
    },
  });
  const result = await handle(request("synthetic-cron", {}));
  assert(result.status === 200 && (await result.json()).processed === 0);
});
