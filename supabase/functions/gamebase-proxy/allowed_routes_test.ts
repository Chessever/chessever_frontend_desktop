import { deepStrictEqual as assertEquals } from "node:assert/strict";
import {
  bearerNamesAccount,
  isAllowedGamebaseProxyRoute,
  matchGamebaseProxyRoute,
} from "./allowed_routes.ts";

Deno.test("allows reviewed memorial reads", () => {
  assertEquals(
    isAllowedGamebaseProxyRoute("GET", "/api/player/memorial"),
    true,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute(
      "GET",
      "/api/player/memorial/memorial%3Amemorial-e03cdf6af47b368c/games",
    ),
    true,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute(
      "GET",
      "/api/player/memorial/2000016/games",
    ),
    true,
  );
});

Deno.test("memorial permission remains read-only and single-player scoped", () => {
  assertEquals(
    isAllowedGamebaseProxyRoute(
      "POST",
      "/api/player/memorial/memorial%3Amemorial-e03cdf6af47b368c/games",
    ),
    false,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute(
      "GET",
      "/api/player/memorial/memorial%3Amemorial-e03cdf6af47b368c/games/delete",
    ),
    false,
  );
});

Deno.test("keeps existing regular-player routes available", () => {
  assertEquals(isAllowedGamebaseProxyRoute("GET", "/api/player/2000016"), true);
  assertEquals(
    isAllowedGamebaseProxyRoute("GET", "/api/player/2000016/games"),
    true,
  );
});

Deno.test("mobile proxy migration preserves its scoped reads and account avatar", () => {
  for (
    const path of [
      "/api/miniatures/stats",
      "/api/miniatures/players",
      "/api/event",
      "/api/player/memorial/memorial-id/stats",
      "/api/player/memorial/memorial-id/opening-tree",
      "/api/player/memorial/memorial-id/opening-tree/status",
    ]
  ) assertEquals(isAllowedGamebaseProxyRoute("GET", path), true, path);
  assertEquals(
    isAllowedGamebaseProxyRoute(
      "POST",
      "/api/player/memorial/memorial-id/opening-tree/build",
    ),
    true,
  );
  assertEquals(
    matchGamebaseProxyRoute("POST", "/api/collections/account/avatar")?.member,
    true,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute("POST", "/api/ingest/pgn-games"),
    false,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute("POST", "/api/studies/refresh"),
    false,
  );
});

Deno.test("allows player win-streak reads only", () => {
  assertEquals(isAllowedGamebaseProxyRoute("GET", "/api/streaks"), true);
  assertEquals(
    isAllowedGamebaseProxyRoute("GET", "/api/streaks/1503014"),
    true,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute("POST", "/api/streaks/ingest"),
    false,
  );
  assertEquals(
    isAllowedGamebaseProxyRoute("GET", "/api/streaks/ingest/x"),
    false,
  );
});

const FOLDER = "11111111-2222-4333-8444-555555555555";

Deno.test("book publishing: a member's own folder, as the member", () => {
  const book = `/api/library/folders/${FOLDER}/book`;
  for (const method of ["GET", "PUT", "DELETE"]) {
    assertEquals(matchGamebaseProxyRoute(method, book)?.member, true, method);
  }
  for (const image of ["cover", "author-photo"]) {
    assertEquals(
      matchGamebaseProxyRoute("POST", `${book}/${image}`)?.member,
      true,
    );
    assertEquals(
      matchGamebaseProxyRoute("DELETE", `${book}/${image}`)?.member,
      true,
    );
    // An image is uploaded or removed, never read or replaced in place.
    assertEquals(matchGamebaseProxyRoute("GET", `${book}/${image}`), null);
    assertEquals(matchGamebaseProxyRoute("PUT", `${book}/${image}`), null);
  }
  assertEquals(
    matchGamebaseProxyRoute("GET", "/api/library/authors")?.member,
    true,
  );
  // Reads stay anonymous behind the server key.
  assertEquals(
    matchGamebaseProxyRoute("GET", "/api/streaks")?.member,
    undefined,
  );
});

Deno.test("book publishing: nothing here approves, and nothing else opens", () => {
  const book = `/api/library/folders/${FOLDER}/book`;
  const refused: [string, string][] = [
    // Approval and every other staff decision live on the superadmin console.
    ["POST", "/api/superadmin/collections/c1/publish"],
    ["POST", "/api/superadmin/collections/c1/request-changes"],
    ["GET", "/api/superadmin/collections"],
    ["PATCH", "/api/admin/collections/c1"],
    ["POST", "/api/library/author"],
    ["POST", book],
    ["PATCH", book],
    ["GET", `${book}/publish`],
    ["PUT", "/api/library/folders/not-a-uuid/book"],
    ["PUT", `/api/library/folders/${FOLDER}/../${FOLDER}/book`],
    ["PUT", `/api/library/folders/${FOLDER}/book/`],
    ["DELETE", "/api/library/authors"],
    ["DELETE", "/api/game/1"],
    ["PUT", "/api/search/query"],
  ];
  for (const [method, path] of refused) {
    assertEquals(
      isAllowedGamebaseProxyRoute(method, path),
      false,
      `${method} ${path}`,
    );
  }
});

Deno.test("collections: the catalog is the same for everyone", () => {
  const open = [
    "/api/collections/catalog/books",
    "/api/collections/catalog/authors",
    "/api/collections/for-event",
  ];
  for (const path of open) {
    const route = matchGamebaseProxyRoute("GET", path);
    assertEquals(route !== null, true, path);
    assertEquals(route?.viewer, undefined, path);
    assertEquals(route?.member, undefined, path);
  }
});

Deno.test("collections: a book, its games and its players carry the viewer", () => {
  for (
    const path of [
      "/api/collections/my-60-memorable-games",
      "/api/collections/my-60-memorable-games/games",
      "/api/collections/my-60-memorable-games/players",
    ]
  ) {
    const route = matchGamebaseProxyRoute("GET", path);
    assertEquals(route?.viewer, true, path);
    // Reading never needs an account.
    assertEquals(route?.member, undefined, path);
  }
});

Deno.test("collections: a view is anonymous, a star is the member's", () => {
  const view = matchGamebaseProxyRoute(
    "POST",
    "/api/collections/endgames/view",
  );
  assertEquals(view !== null, true);
  assertEquals(view?.member, undefined);
  assertEquals(
    matchGamebaseProxyRoute("PUT", "/api/collections/endgames/star")?.member,
    true,
  );
});

Deno.test("collections: nothing here writes a collection", () => {
  const refused: [string, string][] = [
    ["POST", "/api/collections"],
    ["PUT", "/api/collections/endgames"],
    ["DELETE", "/api/collections/endgames"],
    ["POST", "/api/collections/endgames/games"],
    ["DELETE", "/api/collections/endgames/star"],
    ["GET", "/api/collections/endgames/view"],
    ["GET", "/api/collections/endgames/star"],
    // Single-game PGN export is not something a reader's app asks for.
    ["GET", "/api/collections/endgames/games/g1/pgn"],
    ["GET", "/api/collections/endgames/games/"],
    ["GET", "/api/collections/"],
    ["GET", "/api/collections/a/b/c"],
    // A slug is letters, digits, dashes and underscores, nothing else.
    ["GET", "/api/collections/..%2Fadmin"],
    ["GET", "/api/collections/end%20games"],
    ["GET", "/api/collections/end.games/games"],
    ["GET", "/api/collections/-endgames"],
    ["POST", "/api/collections/end;games/view"],
    ["PUT", `/api/collections/${"a".repeat(161)}/star`],
  ];
  for (const [method, path] of refused) {
    assertEquals(
      isAllowedGamebaseProxyRoute(method, path),
      false,
      `${method} ${path}`,
    );
  }
});

function token(payload: Record<string, unknown>): string {
  const part = (value: unknown) =>
    btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_")
      .replace(/=+$/, "");
  return `Bearer ${part({ alg: "HS256", typ: "JWT" })}.${part(payload)}.sig`;
}

Deno.test("collections: only a token that names an account is the viewer", () => {
  assertEquals(
    bearerNamesAccount(token({ sub: "user-1", role: "authenticated" })),
    true,
  );
  // The app's public key: a role, nobody behind it.
  assertEquals(
    bearerNamesAccount(token({ role: "anon", iss: "supabase" })),
    false,
  );
  assertEquals(bearerNamesAccount(token({ sub: "" })), false);
  assertEquals(bearerNamesAccount(token({ sub: 7 })), false);
  assertEquals(bearerNamesAccount("Bearer not-a-token"), false);
  assertEquals(bearerNamesAccount("Bearer a.%%%.c"), false);
  assertEquals(bearerNamesAccount("Basic abc"), false);
  assertEquals(bearerNamesAccount(""), false);
});

Deno.test("mobile opening metadata stays anonymous and published games carry the viewer", () => {
  for (
    const path of [
      "/api/collections",
      "/api/collections/openings",
      "/api/collections/for-opening",
      "/api/collections/endgames/openings",
    ]
  ) {
    assertEquals(isAllowedGamebaseProxyRoute("GET", path), true, path);
    assertEquals(matchGamebaseProxyRoute("GET", path)?.viewer, undefined);
  }
  assertEquals(
    matchGamebaseProxyRoute("GET", "/api/collections/games")?.viewer,
    true,
  );
});

Deno.test("game analysis videos: reads open, submitting stays closed", () => {
  assertEquals(
    matchGamebaseProxyRoute("POST", "/api/collections/game-videos")?.viewer,
    true,
  );
  for (
    const [method, path] of [
      ["GET", "/api/collections/videos/mine"],
      ["PUT", "/api/collections/video-authors/follow"],
    ] as const
  ) {
    assertEquals(matchGamebaseProxyRoute(method, path)?.member, true, path);
  }
  // Closed until Gamebase enforces superadmins + collection owners on submit.
  for (
    const [method, path] of [
      ["POST", "/api/collections/videos"],
      ["POST", "/api/collections/videos/eligibility"],
      ["PUT", "/api/collections/videos/0b6c6c1e-2f4a-4b7e-9d1a-3c5e7f9a1b2c"],
      [
        "DELETE",
        "/api/collections/videos/0b6c6c1e-2f4a-4b7e-9d1a-3c5e7f9a1b2c",
      ],
      ["PATCH", "/api/superadmin/game-videos/x"],
      ["GET", "/api/superadmin/game-videos"],
    ] as const
  ) {
    assertEquals(isAllowedGamebaseProxyRoute(method, path), false, path);
  }
});
