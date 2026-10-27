// app.chessever.com: the Flutter web build is served straight from static
// assets; this script only runs for /_img (run_worker_first in
// wrangler.web.jsonc).
//
// Flutter's web renderer decodes images from fetched bytes, so an image host
// that sends no CORS headers cannot be drawn. index.html rewrites requests for
// the hosts below to this same-origin relay. Only these hosts are relayed, so
// the route is not an open proxy.
const RELAY_HOSTS = new Set(['image.lichess1.org', 'marketing.chess.com']);
const ONE_DAY = 86400;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/_img') return relayImage(request, url, ctx);
    return env.ASSETS.fetch(request);
  },
};

async function relayImage(request, url, ctx) {
  if (request.method !== 'GET') return new Response(null, { status: 405 });

  let target;
  try {
    target = new URL(url.searchParams.get('u') ?? '');
  } catch {
    return new Response('Bad image URL', { status: 400 });
  }
  if (target.protocol !== 'https:' || !RELAY_HOSTS.has(target.hostname)) {
    return new Response('Image host not allowed', { status: 403 });
  }

  const cache = caches.default;
  const cacheKey = new Request(url.toString());
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const upstream = await fetch(target.toString(), {
    headers: { Accept: 'image/*' },
    cf: { cacheEverything: true, cacheTtl: ONE_DAY },
  });
  const type = upstream.headers.get('Content-Type') ?? '';
  if (!upstream.ok) return new Response(null, { status: upstream.status });
  if (!type.startsWith('image/')) return new Response(null, { status: 415 });

  const response = new Response(upstream.body, {
    headers: {
      'Content-Type': type,
      'Cache-Control': `public, max-age=${ONE_DAY}`,
      'X-Content-Type-Options': 'nosniff',
    },
  });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}
