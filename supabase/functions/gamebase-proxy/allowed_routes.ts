type AllowedRoute = {
  method: "GET" | "POST";
  pattern: RegExp;
};

const allowedRoutes: AllowedRoute[] = [
  { method: "GET", pattern: /^\/api\/player\/memorial$/ },
  {
    method: "GET",
    pattern: /^\/api\/player\/memorial\/[^/]+\/games$/,
  },

  { method: "GET", pattern: /^\/api\/player$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/(?:events|games|stats)$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/games\.pgn$/ },
  { method: "GET", pattern: /^\/api\/player\/fide\/[^/]+\/games\.pgn$/ },
  {
    method: "GET",
    pattern: /^\/api\/player\/(?:lichess|chesscom)\/[^/]+\/games\.pgn$/,
  },

  { method: "POST", pattern: /^\/api\/player\/[^/]+\/opening-tree\/build$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/opening-tree\/status$/ },
  { method: "GET", pattern: /^\/api\/player\/[^/]+\/opening-tree$/ },

  { method: "GET", pattern: /^\/api\/miniatures$/ },
  { method: "GET", pattern: /^\/api\/game\/[^/]+$/ },
  { method: "GET", pattern: /^\/api\/eval$/ },
  { method: "GET", pattern: /^\/api\/search$/ },
  { method: "GET", pattern: /^\/api\/search\/events$/ },
  { method: "GET", pattern: /^\/api\/search\/metadata$/ },
  { method: "POST", pattern: /^\/api\/search\/query$/ },
  { method: "GET", pattern: /^\/api\/game-position\/aggregates$/ },
  { method: "POST", pattern: /^\/api\/game-position\/aggregates\/query$/ },
  { method: "GET", pattern: /^\/api\/game-position\/games$/ },
  { method: "POST", pattern: /^\/api\/game-position\/games\/query$/ },
  { method: "GET", pattern: /^\/api\/game-position\/fen\/games$/ },
];

export function isAllowedGamebaseProxyRoute(
  method: string,
  path: string,
): method is "GET" | "POST" {
  return allowedRoutes.some((route) =>
    route.method === method && route.pattern.test(path)
  );
}
