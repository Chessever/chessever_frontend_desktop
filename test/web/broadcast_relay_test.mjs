// Run: node --test test/web/broadcast_relay_test.mjs
// Exercises the shipped worker's /_broadcast/ relay with a stubbed fetch.
import assert from 'node:assert/strict';
import test from 'node:test';

const worker = (await import('../../web_worker/index.js')).default;
const env = { ASSETS: { fetch: async () => new Response('asset') } };
const ctx = { waitUntil() {} };

function stubFetch(response) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return typeof response === 'function' ? response() : response;
  };
  return calls;
}

const get = (path, init) =>
  worker.fetch(new Request(`https://app.chessever.com${path}`, init), env, ctx);

test('relays a tour stream list to the broadcast API', async () => {
  const calls = stubFetch(new Response('{"streams":[]}', {
    headers: { 'Content-Type': 'application/json', 'Set-Cookie': 'a=b' },
  }));
  const res = await get('/_broadcast/api/broadcast/abc123/video-streams', {
    headers: { Cookie: 'sb-session=secret', Authorization: 'Bearer x' },
  });
  assert.equal(res.status, 200);
  assert.equal(await res.text(), '{"streams":[]}');
  assert.equal(res.headers.get('Set-Cookie'), null);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url,
    'https://api.broadcast.chessever.com/api/broadcast/abc123/video-streams');
  assert.deepEqual(calls[0].init.headers, { Accept: 'application/json' });
});

test('relays a round stream list', async () => {
  const calls = stubFetch(new Response('{}', { status: 404 }));
  const res = await get('/_broadcast/api/broadcast/round/R-1_x/video-streams');
  assert.equal(res.status, 404);
  assert.equal(calls[0].url,
    'https://api.broadcast.chessever.com/api/broadcast/round/R-1_x/video-streams');
});

test('refuses anything but the read-only stream list', async () => {
  const calls = stubFetch(new Response('{}'));
  for (const path of [
    '/_broadcast/api/broadcast/abc/games',
    '/_broadcast/api/broadcast/abc/video-streams?x=1',
    '/_broadcast/api/broadcast/a%2F..%2Fadmin/video-streams',
    '/_broadcast/api/admin/abc/video-streams',
    '/_broadcast/https://evil.example/video-streams',
  ]) {
    assert.equal((await get(path)).status, 404, path);
  }
  const post = await get('/_broadcast/api/broadcast/abc/video-streams',
    { method: 'POST', body: '{}' });
  assert.equal(post.status, 405);
  assert.equal(calls.length, 0);
});

test('does not follow upstream redirects', async () => {
  stubFetch(new Response(null, {
    status: 302, headers: { Location: 'https://evil.example/' },
  }));
  const res = await get('/_broadcast/api/broadcast/abc/video-streams');
  assert.equal(res.status, 502);
});
