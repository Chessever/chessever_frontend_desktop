export type GamebaseProxyMethod = "GET" | "POST" | "PUT" | "DELETE";

export type AllowedRoute = {
  method: GamebaseProxyMethod;
  pattern: RegExp;
  /**
   * The route acts for the signed-in member: their own Supabase token is
   * forwarded upstream (Gamebase verifies it and checks the folder is
   * theirs), and the answer is never cached.
   */
  member?: true;
};

// A folder id as the library stores it.
const FOLDER = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";

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
  // Player win streaks (read-only leaderboard + per-player detail).
  { method: "GET", pattern: /^\/api\/streaks$/ },
  { method: "GET", pattern: /^\/api\/streaks\/[^/]+$/ },
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

  // Publishing a library folder as a collection. Gamebase keeps every
  // submission a private draft until a ChessEver superadmin approves it; no
  // route here can publish.
  { method: "GET", pattern: /^\/api\/library\/authors$/, member: true },
  ...(["GET", "PUT", "DELETE"] as const).map((method): AllowedRoute => ({
    method,
    pattern: new RegExp(`^/api/library/folders/${FOLDER}/book$`),
    member: true,
  })),
  ...(["POST", "DELETE"] as const).map((method): AllowedRoute => ({
    method,
    pattern: new RegExp(
      `^/api/library/folders/${FOLDER}/book/(?:cover|author-photo)$`,
    ),
    member: true,
  })),
];

const METHODS: readonly string[] = ["GET", "POST", "PUT", "DELETE"];

/** The allowlisted route a request matches, or null. */
export function matchGamebaseProxyRoute(
  method: string,
  path: string,
): AllowedRoute | null {
  if (!METHODS.includes(method)) return null;
  return allowedRoutes.find((route) =>
    route.method === method && route.pattern.test(path)
  ) ?? null;
}

export function isAllowedGamebaseProxyRoute(
  method: string,
  path: string,
): method is GamebaseProxyMethod {
  return matchGamebaseProxyRoute(method, path) !== null;
}
