# Browser-app Google Analytics

`web/index.html` owns a browser-only GA4 bootstrap for **G-06TRX0SNEF**.
It does not initialize Firebase or connect the native AnalyticsService.

## Intentionally minimal coverage

- One explicit `page_view` per eligible full page load, not per Flutter tab or
  history transition. Initial automatic page views are disabled.
- Location is always `https://app.chessever.com/`, referrer always empty, title
  always `ChessEver Web App`. No route, slug, game/player ID, chess content,
  account identifier, search, campaign, query or fragment is provided.
- Arrival URLs containing **any query or fragment** skip analytics entirely,
  including OAuth/recovery callbacks and campaign links. Nothing rewrites the
  browser URL, so the existing auth flow still receives its original values.
  Collection does not start later on that same skipped document.
- Production HTTPS origin only. Preview/localhost never load Google. GPC,
  Do Not Track and the stream's `ga-disable-G-06TRX0SNEF` opt-out prevent loading.
- One async loader even if the bootstrap is evaluated twice. Its script request
  has `referrerPolicy=no-referrer`. No listener reads forms, clicks, titles,
  history changes, account storage or custom app events.
- Google signals and advertising personalization disabled; advertising storage,
  ad user data and ad personalization consent default denied. Campaign fields
  are empty and URL passthrough is disabled. Analytics cookies are host-scoped
  with an app-only prefix, not shared with the main website.

## Consent precedent and limits

Read-only inspection found no browser-app analytics consent UI or GA bootstrap
in this source base. The sibling website's inspected `src/app/layout.tsx` at
`a78381b32e1ca6d396cb0694e1d90fefde368172` loads its own GA tag unconditionally,
without an analytics-consent gate. This patch preserves that basic-analytics
precedent, does **not** fabricate a grant or create a new consent policy/UI, and
adds privacy opt-outs and denied advertising consent. The two streams remain
separate. Whether an explicit analytics opt-in is required is an owner/legal
policy decision before release, not resolved by the website precedent.

GA still uses its standard anonymous client/session identifiers and analytics
cookies and may generate standard session/engagement events. This is not
cookieless or anonymous-to-Google telemetry. Google's infrastructure receives
network metadata such as IP address and user agent. No claim that this hides
all personal data from Google is intended. Fixed page fields minimize app
content disclosure, not general browser metadata.

## Required GA4 stream configuration, separate from this patch

The parent operator reports PATCH plus exact GET verification for the **new app
stream only** (`properties/495088649/dataStreams/16274291859`):

- `streamEnabled: false`
- `scrollsEnabled: false`
- `outboundClicksEnabled: false`
- `siteSearchEnabled: false`
- `videoEngagementEnabled: false`
- `fileDownloadsEnabled: false`
- `pageChangesEnabled: false`
- `formInteractionsEnabled: false`

These are enhancedMeasurementSettings. Do not confuse `streamEnabled` here
with disabling the data stream itself: explicit page views remain intentional.
The local code cannot enforce these administrative settings. Verify them again
before any future release and do not enable enhanced measurement without a new
privacy review. Automatic page/history/form/search tracking could read raw URLs
or app content regardless of our explicit page-view payload. No other stream
settings are changed by this patch or its tests.

## Verification and release gaps

Run `node --test test/web/analytics_bootstrap_test.mjs`. These tests execute the
actual inline shipped script in Node VM with instrumented browser APIs and
assert the queued commands/loader, opt-outs, origins, duplicate evaluation and
sensitive-arrival suppression. They make zero Google requests or analytics hits.
They do not substitute for the Google runtime, the Flutter app, real browser
headers/cookies, GA ingestion, or consent/legal approval. GA DebugView/Realtime
and real browser network checks require a separately authorized release or
controlled test plan; do not create production test hits from this suite.

The owner authorized this browser-only integration for release as
`22.23.3+559`. Use `scripts/build_web.sh` from the exact pushed source, then
`scripts/deploy_web.sh`, and verify the active Worker and version assets.
Release authorization is not certification of consent/legal compliance.
Billing/auth behavior and native analytics remain unchanged. Deployment and
browser/GA ingestion acceptance require actual release readbacks, not this file.
