// Run: node --test test/web/web_mount_worker_test.mjs
// chessever.com/webapp/<path> must answer what app.chessever.com/<path> answers.
import assert from 'node:assert/strict';
import test from 'node:test';

const worker = (await import('../../web_worker/index.js')).default;
const ctx = { waitUntil() {} };

// Node has no HTMLRewriter; this stand-in applies the same `base` handler to
// the one <base> tag index.html carries. Its transform streams the rewrite.
globalThis.HTMLRewriter = class {
  on(selector, handler) {
    assert.equal(selector, 'base');
    this.handler = handler;
    return this;
  }
  transform(response) {
    const rewrite = async (html) => html.replace(/<base href="[^"]*">/, () => {
      let href;
      this.handler.element({ setAttribute: (_, value) => { href = value; } });
      return `<base href="${href}">`;
    });
    const source = response.clone();
    const body = new ReadableStream({
      async start(controller) {
        controller.enqueue(new TextEncoder().encode(await rewrite(await source.text())));
        controller.close();
      },
    });
    return new Response(body, response);
  }
};

function assets(respond) {
  const seen = [];
  return {
    seen,
    env: { ASSETS: { fetch: async (request) => {
      const path = new URL(request.url ?? request).pathname;
      seen.push(path);
      return respond(path);
    } } },
  };
}

const page = () => new Response('<html><head><base href="/"></head></html>',
  { headers: { 'Content-Type': 'text/html; charset=utf-8', ETag: '"x"' } });

test('strips the mount before the asset lookup', async () => {
  const { seen, env } = assets(() => new Response('wasm',
    { headers: { 'Content-Type': 'application/wasm' } }));
  const res = await worker.fetch(
    new Request('https://chessever.com/webapp/main.dart.wasm'), env, ctx);
  assert.deepEqual(seen, ['/main.dart.wasm']);
  assert.equal(await res.text(), 'wasm');
  assert.equal(res.headers.get('Document-Isolation-Policy'),
    'isolate-and-credentialless');
});

for (const path of ['/webapp', '/webapp/', '/webapp/broadcast/some-event/abc']) {
  test(`serves index.html under the mount for ${path}`, async () => {
    const { seen, env } = assets(page);
    const res = await worker.fetch(
      new Request(`https://chessever.com${path}`), env, ctx);
    assert.equal(seen[0], path.slice('/webapp'.length) || '/');
    assert.match(await res.text(), /<base href="\/webapp\/">/);
    assert.equal(res.headers.get('Document-Isolation-Policy'),
      'isolate-and-credentialless');
  });
}

test('app.chessever.com keeps its root base', async () => {
  const { seen, env } = assets(page);
  const res = await worker.fetch(
    new Request('https://app.chessever.com/app/likes'), env, ctx);
  assert.deepEqual(seen, ['/app/likes']);
  assert.match(await res.text(), /<base href="\/">/);
});

test('keeps asset redirects inside the mount', async () => {
  const { env } = assets(() => new Response(null,
    { status: 307, headers: { Location: '/' } }));
  const res = await worker.fetch(
    new Request('https://chessever.com/webapp/index.html'), env, ctx);
  assert.equal(res.headers.get('Location'), '/webapp/');
});

test('refuses chessever.com paths outside the mount', async () => {
  const { seen, env } = assets(page);
  // The phone app's /app links are never this Worker's business.
  for (const path of ['/', '/app', '/app/feed', '/webapps', '/broadcast']) {
    const res = await worker.fetch(
      new Request(`https://chessever.com${path}`), env, ctx);
    assert.equal(res.status, 404);
  }
  assert.deepEqual(seen, []);
});

test('routes the relays under the mount', async () => {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return new Response('{}', { headers: { 'Content-Type': 'application/json' } });
  };
  const { env } = assets(page);
  const res = await worker.fetch(new Request(
    'https://chessever.com/webapp/_broadcast/api/broadcast/abc123/video-streams'),
    env, ctx);
  assert.equal(res.status, 200);
  assert.deepEqual(calls,
    ['https://api.broadcast.chessever.com/api/broadcast/abc123/video-streams']);
});
