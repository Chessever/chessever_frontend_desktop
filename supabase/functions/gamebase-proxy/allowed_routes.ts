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
  /**
   * The answer depends on who is asking: the caller's Supabase token is
   * forwarded upstream when they sent one (Gamebase judges their Premium
   * from it), a `Cache-Control: no-cache` re-check is passed along, and the
   * answer is never cached. Nobody has to be signed in.
   */
  viewer?: true;
};

// A folder id as the library stores it.
const FOLDER = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";

// A published collection's slug, or its id.
const COLLECTION = "[A-Za-z0-9][A-Za-z0-9_-]{0,159}";

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

  // Published collections, as readers browse them: only the routes the app
  // calls. Read-only apart from the two engagement counters. The catalog and
  // the books bound to an event are the same for everyone; they come first so
  // "catalog" and "for-event" are never read as a slug.
  { method: "GET", pattern: /^\/api\/collections\/catalog\/(?:books|authors)$/ },
  { method: "GET", pattern: /^\/api\/collections\/for-event$/ },
  // A collection, its games and its players: a Premium collection opens only
  // for an entitled account, so these carry the viewer.
  {
    method: "GET",
    pattern: new RegExp(`^/api/collections/${COLLECTION}$`),
    viewer: true,
  },
  {
    method: "GET",
    pattern: new RegExp(`^/api/collections/${COLLECTION}/(?:games|players)$`),
    viewer: true,
  },
  // A read is counted per anonymous reader id; a star belongs to an account.
  {
    method: "POST",
    pattern: new RegExp(`^/api/collections/${COLLECTION}/view$`),
  },
  {
    method: "PUT",
    pattern: new RegExp(`^/api/collections/${COLLECTION}/star$`),
    member: true,
  },
];

/**
 * Whether [authorization] is a bearer token that names an account.
 *
 * The app's public key is a token too, with a role and no subject. Sending
 * it upstream as "the viewer" would ask Gamebase to judge nobody, so a viewer
 * route forwards only a token that says who is asking. The function's own
 * verification has already checked the signature; this only reads the claim.
 */
export function bearerNamesAccount(authorization: string): boolean {
  const match = /^Bearer [\w-]+\.([\w-]+)\.[\w-]+$/.exec(authorization);
  if (!match) return false;
  try {
    const base64 = match[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
    const subject = JSON.parse(atob(padded))?.sub;
    return typeof subject === "string" && subject.length > 0;
  } catch {
    return false;
  }
}

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
