// Run: node --test test/web/analytics_bootstrap_test.mjs
// Executes the actual shipped inline script. No Google requests or test hits.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const html = readFileSync(new URL('../../web/index.html', import.meta.url), 'utf8');
const blocks = [...html.matchAll(/<script id="chessever-web-analytics">([\s\S]*?)<\/script>/g)];
assert.equal(blocks.length, 1);
const source = blocks[0][1];
const id = 'G-06TRX0SNEF';
const page = {
  page_location: 'https://app.chessever.com/',
  page_referrer: '',
  page_title: 'ChessEver Web App',
};
function boot(url = 'https://app.chessever.com/', options = {}) {
  const location = new URL(url);
  const scripts = [];
  const window = { ...options.window };
  const navigator = { ...options.navigator };
  const document = {
    title: 'PRIVATE PLAYER NAME / Personal database',
    referrer: 'https://example.org/private-person?token=PRIVATE_TOKEN#PRIVATE_HASH',
    createElement: (name) => { assert.equal(name, 'script'); return {}; },
    head: { appendChild: (script) => scripts.push(script) },
  };
  const context = vm.createContext({ window, location, navigator, document });
  vm.runInContext(source, context);
  const commands = () => JSON.parse(JSON.stringify((window.dataLayer || []).map(x => Array.from(x))));
  return { location, scripts, window, commands, rerun: () => vm.runInContext(source, context) };
}

test('one async loader, one explicit page view, exact new stream only', () => {
  const b = boot();
  assert.deepEqual(b.scripts, [{ async: true, referrerPolicy: 'no-referrer',
    src: 'https://www.googletagmanager.com/gtag/js?id=' + id }]);
  const c = b.commands();
  assert.deepEqual(c.map(x => x[0]), ['consent', 'set', 'js', 'config', 'event']);
  assert.equal(c[3][1], id);
  assert.equal(c[3][2].send_page_view, false);
  assert.deepEqual(c[4], ['event', 'page_view', { send_to: id, ...page }]);
  b.rerun();
  assert.equal(b.scripts.length, 1);
  assert.equal(b.commands().length, 5);
});

test('fixed fields cannot leak arrival path, dynamic title, or referrer', () => {
  const b = boot('https://app.chessever.com/player/private-person/123456789');
  const c = b.commands();
  for (const command of [c[1], c[3], c[4]]) {
    for (const [key, value] of Object.entries(page)) assert.equal(command.at(-1)[key], value);
  }
  const payload = JSON.stringify(c);
  for (const sensitive of ['private-person', '123456789', 'PRIVATE', 'Personal database']) {
    assert.equal(payload.includes(sensitive), false);
  }
  assert.equal(b.location.pathname, '/player/private-person/123456789');
});

for (const suffix of [
  '?code=OAUTH_SECRET&state=PRIVATE_STATE',
  '#access_token=ACCESS_SECRET&refresh_token=REFRESH_SECRET',
  '?error_description=private%40example.org',
  '/auth/callback?token_hash=TOKEN_SECRET&type=recovery',
  '/analysis?fen=PRIVATE_FEN&pgn=PRIVATE_PGN',
  '?utm_source=PRIVATE_CAMPAIGN',
  '#/player/private-person',
]) {
  test('no third-party script or command on data-bearing arrival ' + suffix.split(/[=?#]/)[0], () => {
    const url = 'https://app.chessever.com/' + suffix;
    const b = boot(url);
    assert.equal(b.scripts.length, 0);
    assert.deepEqual(b.commands(), []);
    assert.equal(b.location.href, new URL(url).href, 'auth URL must remain untouched');
  });
}

for (const url of ['http://localhost:8080/', 'https://preview.example.org/',
  'http://app.chessever.com/', 'https://app.chessever.com.evil.example/']) {
  test('nonproduction origin disabled: ' + url, () => {
    const b = boot(url);
    assert.equal(b.scripts.length, 0);
    assert.deepEqual(b.commands(), []);
  });
}

for (const options of [
  { navigator: { globalPrivacyControl: true } },
  { navigator: { doNotTrack: '1' } },
  { window: { doNotTrack: '1' } },
  { window: { ['ga-disable-' + id]: true } },
]) {
  test('privacy opt-out prevents even loading Google: ' + JSON.stringify(options), () => {
    const b = boot(undefined, options);
    assert.equal(b.scripts.length, 0);
    assert.deepEqual(b.commands(), []);
  });
}

test('ads denied first; no fabricated analytics consent or identity/event bridge', () => {
  const c = boot().commands();
  assert.deepEqual(c[0], ['consent', 'default', {
    ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied',
  }]);
  const settings = c[1][1];
  assert.equal(settings.allow_google_signals, false);
  assert.equal(settings.allow_ad_personalization_signals, false);
  assert.equal(settings.ads_data_redaction, true);
  assert.equal(settings.url_passthrough, false);
  assert.equal(settings.ignore_referrer, true);
  for (const key of ['id', 'source', 'medium', 'name', 'term', 'content']) {
    assert.equal(settings['campaign_' + key], '');
  }
  assert.equal(c[3][2].cookie_domain, 'app.chessever.com');
  assert.equal(c[3][2].cookie_prefix, 'ce_web');
  assert.equal(c[3][2].cookie_flags, 'SameSite=Lax;Secure');
  assert.deepEqual(c.filter(x => x[0] === 'event').map(x => x[1]), ['page_view']);
  for (const forbidden of ['user_id', 'user_properties', 'email', 'pgn', 'fen', 'analytics_storage']) {
    assert.equal(JSON.stringify(c).includes('"' + forbidden + '"'), false);
  }
  // No SPA/history observers, account storage, global gtag bridge or native calls.
  assert.doesNotMatch(source, /addEventListener|pushState|replaceState|localStorage|sessionStorage|window\.gtag|AnalyticsService\./);
});

test('stream prerequisites are documented, not simulated as a client setting', () => {
  const doc = readFileSync(new URL('../../docs/web_analytics.md', import.meta.url), 'utf8');
  for (const flag of ['streamEnabled', 'scrollsEnabled', 'outboundClicksEnabled',
    'siteSearchEnabled', 'videoEngagementEnabled', 'fileDownloadsEnabled',
    'pageChangesEnabled', 'formInteractionsEnabled']) {
    assert.ok(doc.includes('`' + flag + ': false`'));
  }
});
