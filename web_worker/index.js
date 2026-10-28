// app.chessever.com: the Flutter web build is served straight from static
// assets; this script only runs for /_img (run_worker_first in
// wrangler.web.jsonc).
//
// Flutter's web renderer decodes images from fetched bytes, so an image host
// that sends no CORS headers cannot be drawn. index.html rewrites requests for
// the hosts below to this same-origin relay. Only these hosts are relayed,
// including after a redirect, so the route is not an open proxy.
const RELAY_HOSTS = new Set([
  'image.lichess1.org',
  'marketing.chess.com',
  'saintlouischessclub.org',
  'aicf.in',
]);
const ONE_DAY = 86400;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/_img') return relayImage(request, url, ctx);
    return env.ASSETS.fetch(request);
  },
};

const MAX_REDIRECTS = 3;

// Only https on the default port, an allowlisted host, and no credentials.
function allowedTarget(target) {
  return target.protocol === 'https:' && target.port === '' &&
    target.username === '' && target.password === '' &&
    RELAY_HOSTS.has(target.hostname);
}

async function relayImage(request, url, ctx) {
  if (request.method !== 'GET') return new Response(null, { status: 405 });

  let target;
  try {
    target = new URL(url.searchParams.get('u') ?? '');
  } catch {
    return new Response('Bad image URL', { status: 400 });
  }
  if (!allowedTarget(target)) {
    return new Response('Image host not allowed', { status: 403 });
  }

  const cache = caches.default;
  const cacheKey = new Request(url.toString());
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  // Redirects are followed by hand so every hop must pass the same allowlist;
  // an open redirect on a relayed host cannot point the relay elsewhere.
  let upstream;
  for (let hop = 0; ; hop++) {
    upstream = await fetch(target.toString(), {
      redirect: 'manual',
      // Some hosts' bot protection refuses a request with no User-Agent.
      headers: {
        Accept: 'image/*',
        'User-Agent': 'Mozilla/5.0 (compatible; ChessEverImageRelay/1.0; +https://chessever.com)',
      },
      cf: { cacheEverything: true, cacheTtl: ONE_DAY },
    });
    if (upstream.status < 300 || upstream.status >= 400) break;
    const location = upstream.headers.get('Location');
    if (!location || hop >= MAX_REDIRECTS) {
      return new Response(null, { status: 502 });
    }
    try {
      target = new URL(location, target);
    } catch {
      return new Response(null, { status: 502 });
    }
    if (!allowedTarget(target)) {
      return new Response('Image host not allowed', { status: 403 });
    }
  }
  const type = upstream.headers.get('Content-Type') ?? '';
  if (!upstream.ok) return new Response(null, { status: upstream.status });
  if (!type.startsWith('image/')) return new Response(null, { status: 415 });

  const response = new Response(upstream.body, {
    headers: {
      'Content-Type': type,
      'Cache-Control': `public, max-age=${ONE_DAY}`,
      'X-Content-Type-Options': 'nosniff',
      // The app reads these bytes through fetch, which this header does not
      // affect. It stops an SVG opened directly at /_img from running script
      // in the app's origin, where the Supabase session lives.
      'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; sandbox",
    },
  });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}
