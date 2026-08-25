import { assertEquals } from "jsr:@std/assert@1/equals";
import { isAllowedGamebaseProxyRoute } from "./allowed_routes.ts";

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
