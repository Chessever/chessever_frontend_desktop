import { handleSignInPreview } from './signin_preview.js';

// app.chessever.com: the Flutter web build is served straight from static
// assets; this script only runs for /_img, /_broadcast/, the sign-in preview
// API and /webapp (run_worker_first in wrangler.web.jsonc).
//
// The same build is also served at chessever.com/webapp/. The chessever.com
// Worker (chessever_web_frontend cloudflare-worker.ts) forwards /webapp and
// /webapp/* here through its WEB_APP service binding with the original URL.
// serveMounted strips the prefix, answers exactly as app.chessever.com would,
// and rewrites index.html's <base href> to /webapp/ so the page and the app
// (lib/web/web_mount.dart) load and address everything under the mount.
//
// Flutter's web renderer decodes images from fetched bytes, so an image host
// that sends no CORS headers cannot be drawn. index.html rewrites requests for
// the hosts below to this same-origin relay. Only these hosts are relayed,
// including after a redirect, so the route is not an open proxy.
//
// The list covers every tours.image host that sends no
// Access-Control-Allow-Origin (hosts that do are fetched directly). Keep it in
// sync with relayHosts in web/index.html.
const RELAY_HOSTS = new Set([
  'image.lichess.org',
  'image.lichess1.org',
  'chessever.com',
  'www.chessever.com',
  'marketing.chess.com',
  'saintlouischessclub.org',
  'aicf.in',
  'ruchess.ru',
  'www.pucharpolskiamatorow.pl',
]);
// Shared hosts where only one bucket is relayed.
const RELAY_PREFIXES = [
  { host: 'storage.googleapis.com', path: '/cdn.chessmanager.com/' },
];
// image.lichess1.org now answers every request with a 301 to the same path on
// image.lichess.org; going there directly saves a round trip per image.
const HOST_ALIASES = { 'image.lichess1.org': 'image.lichess.org' };
// Event and player images are replaced under a new URL rather than edited in
// place (Lichess signs each one), so the edge and the browser keep them a week.
const CACHE_SECONDS = 7 * 86400;

// Keep configuration private: workerd validates named exports as entrypoints.
const MOUNT_HOST = 'chessever.com';
const MOUNT = '/webapp';

// web/_headers is not applied to responses this script returns, including
// assets it fetches through env.ASSETS, so the same policy is set here.
// See web/_headers for why the page needs it.
const ASSET_HEADERS = {
  'Document-Isolation-Policy': 'isolate-and-credentialless',
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.hostname === MOUNT_HOST) {
      return serveMounted(request, url, env, ctx);
    }
    return route(request, url, env, ctx);
  },
};

function route(request, url, env, ctx) {
  if (url.pathname.startsWith('/api/signin-preview/')) {
    return handleSignInPreview(request, env, ctx);
  }
  if (url.pathname === '/_img') return relayImage(request, url, ctx);
  if (url.pathname.startsWith(BROADCAST_RELAY_PREFIX)) {
    return relayBroadcastStreams(request, url);
  }
  return serveAsset(request, env);
}

async function serveAsset(request, env) {
  const asset = await env.ASSETS.fetch(request);
  const response = new Response(asset.body, asset);
  for (const [name, value] of Object.entries(ASSET_HEADERS)) {
    response.headers.set(name, value);
  }
  return response;
}

// chessever.com/webapp/<path> answers what app.chessever.com/<path> answers.
async function serveMounted(request, url, env, ctx) {
  if (url.pathname !== MOUNT && !url.pathname.startsWith(`${MOUNT}/`)) {
    return new Response('Not found', { status: 404 });
  }
  const inner = new URL(url);
  inner.pathname = url.pathname.slice(MOUNT.length) || '/';
  const response = await route(new Request(inner, request), inner, env, ctx);

  // Asset handling may redirect (e.g. /index.html to /); keep it mounted.
  const location = response.headers.get('Location');
  if (location?.startsWith('/') && !location.startsWith('//')) {
    const mounted = new Response(response.body, response);
    mounted.headers.set('Location', `${MOUNT}${location}`);
    return mounted;
  }
  if (!response.headers.get('Content-Type')?.startsWith('text/html')) {
    return response;
  }
  return new HTMLRewriter()
    .on('base', {
      element(base) {
        base.setAttribute('href', `${MOUNT}/`);
      },
    })
    .transform(response);
}

const MAX_REDIRECTS = 3;

// Only https on the default port, an allowlisted host, and no credentials.
function allowedTarget(target) {
  return target.protocol === 'https:' && target.port === '' &&
    target.username === '' && target.password === '' &&
    (RELAY_HOSTS.has(target.hostname) ||
      RELAY_PREFIXES.some((p) =>
        target.hostname === p.host && target.pathname.startsWith(p.path)));
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
  const alias = HOST_ALIASES[target.hostname];
  if (alias) target.hostname = alias;

  const cache = caches.default;
  // Keyed by the canonical target, so both Lichess hostnames share entries.
  const cacheKey = new Request(
    `${url.origin}/_img?u=${encodeURIComponent(target.href)}`);
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
      cf: { cacheEverything: true, cacheTtl: CACHE_SECONDS },
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
      'Cache-Control': `public, max-age=${CACHE_SECONDS}`,
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

// The Board pane's live-stream panel reads the editor-curated stream list
// from the public broadcast API. That API only sends CORS headers to
// chessever.com, so the web build reads it through this origin instead
// (broadcastApiWebRelayPath in lib/desktop/services/broadcast_video_streams.dart).
// Only the read-only video-streams endpoint is relayed, GET only, with no
// cookies or credentials forwarded, so the route is not an open proxy.
const BROADCAST_RELAY_PREFIX = '/_broadcast/';
const BROADCAST_API_ORIGIN = 'https://api.broadcast.chessever.com';
// /_broadcast/api/broadcast/<tourId>/video-streams
// /_broadcast/api/broadcast/round/<roundId>/video-streams
const BROADCAST_STREAMS_PATH =
  /^\/_broadcast(\/api\/broadcast\/(?:round\/)?[A-Za-z0-9_-]{1,64}\/video-streams)$/;

async function relayBroadcastStreams(request, url) {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  const match = BROADCAST_STREAMS_PATH.exec(url.pathname);
  if (!match || url.search !== '') {
    return new Response('Not found', { status: 404 });
  }
  let upstream;
  try {
    upstream = await fetch(`${BROADCAST_API_ORIGIN}${match[1]}`, {
      method: request.method,
      redirect: 'manual',
      headers: { Accept: 'application/json' },
    });
  } catch {
    return new Response(null, { status: 502 });
  }
  if (upstream.status >= 300 && upstream.status < 400) {
    return new Response(null, { status: 502 });
  }
  const headers = {
    'Content-Type': upstream.headers.get('Content-Type') ?? 'application/json',
    'X-Content-Type-Options': 'nosniff',
  };
  const cacheControl = upstream.headers.get('Cache-Control');
  if (cacheControl) headers['Cache-Control'] = cacheControl;
  return new Response(upstream.body, { status: upstream.status, headers });
}
