import { assertEquals } from "jsr:@std/assert@1/equals";
import {
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

Deno.test("allows player win-streak reads only", () => {
  assertEquals(isAllowedGamebaseProxyRoute("GET", "/api/streaks"), true);
  assertEquals(isAllowedGamebaseProxyRoute("GET", "/api/streaks/1503014"), true);
  assertEquals(isAllowedGamebaseProxyRoute("POST", "/api/streaks/ingest"), false);
  assertEquals(isAllowedGamebaseProxyRoute("GET", "/api/streaks/ingest/x"), false);
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
    assertEquals(isAllowedGamebaseProxyRoute(method, path), false, `${method} ${path}`);
  }
});
