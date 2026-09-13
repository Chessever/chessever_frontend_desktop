# Broadcast video embeds: compliance audit and rules

Audited 2026-09-11 against the providers' published terms. This file is the
contract for the Board pane's live-stream panel
(`lib/desktop/widgets/broadcast_video_panel.dart`), the site's in-board player
(`chessever_web_frontend/src/broadcast/components/VideoStreams.tsx`) and the
site's bare player page (`/embed/video/{scope}/{scopeId}/{streamId}`). Both
repos are public, so this audit is public too; it contains no credentials and
needs none, because embedding uses no API key.

## The model in one paragraph

ChessEver's editors find the public Twitch, YouTube and Kick streams that
cover an event and attach them to it in our Supabase broadcast settings; the
streamers are third parties who did not upload anything to us. The site
frames the provider's embeddable player on a chessever.com page. The
desktop app never loads a provider player itself: its WebView loads the
chessever.com player page, so Twitch's `parent` and YouTube's referrer are the
host that really serves the document. Nothing of ours is drawn in front of the
player, its own controls (fullscreen included) work as the provider built
them, playback stops when the player is not on the screen the user is
viewing, the panel is free, and the official source is always one click away.

## Sources

- YouTube API Services Terms of Service, Developer Policies (III.A, III.D,
  III.E, III.F, III.G, III.I), Required Minimum Functionality ("Embedded
  YouTube player"), Branding Guidelines.
- Twitch Developer Services Agreement, Schedule "Twitch APIs" (A. Data,
  C. Storage, D.1 Embeddable Experiences); dev.twitch.tv embed requirements
  and the video embed attribute table.
- Kick: "How to embed your KICK livestream" (help centre) and Kick Terms of
  Service.

## Clause-by-clause

Status: OK = implemented and verified in code; OPEN = required, not yet in
place, owner named; N/A = does not apply.

### YouTube

| Rule (source) | Status | How |
|---|---|---|
| Identify the API client through the HTTP Referer; desktop WebViews must set it (RMF) | OK | The WebView loads the chessever.com player page; the iframe's referrer is that real document. The app never sets a synthetic Referer. |
| Must not mask or misrepresent identity (III.D.1.a) | OK | Same as above: the embedding page is genuinely chessever.com. |
| Must not situate the player in a nested iframe lineage to circumvent policy or obfuscate the source (III.I.21) | OK | One page, one iframe. The WebView document is top-level; the player is its direct child frame. |
| Viewport at least 200×200 (RMF) | OK | Panel: below 200 px of rail width the external link replaces the player; height is clamped to at least 200. Site: `minWidth`/`minHeight` on the adapter. |
| Do not initiate autoplay until the player is visible and more than half visible (RMF) | OK | The panel renders (and loads) only for the foreground Board tab with the player expanded; hidden tabs unmount it. |
| Only one autoplaying player per page or screen (RMF) | OK | One panel per Board tab; only the foreground tab mounts it. A detached board window is a separate screen. |
| No overlays, frames or visual elements in front of any part of the player (RMF) | OK | Desktop: player first, toolbar under it; tooltips and popovers anchor downward over our notation panel. Site: hover list opens above the flag, overflow menu `side="top"`, chat launcher hidden on `/embed`. |
| No mouseovers or touch events on the player to initiate actions (RMF) | OK | Hover handlers exist only on the toolbar flags, not on the player. |
| Do not modify, build upon or block player functionality; no changes not described by the API docs (III.I.6, RMF) | OK | Documented player parameters only (`autoplay`, `mute`, `playsinline`); no scripts injected into provider frames. The player's fullscreen control is the provider's own: the site's iframe carries `allow="fullscreen"`, and the desktop WebView has the HTML Fullscreen API switched on (`WKPreferences.isElementFullscreenEnabled` through our patched `webview_all_wkwebview`; on by default in WebView2), which is a WebView capability, not a change to the player. WKWebView ships with it off, which hid YouTube's control and left Twitch's inert until 20.32.14. |
| Fullscreen presentation stays the player's, with nothing of ours in it (RMF overlays rule; III.I.6) | OK | macOS: WebKit presents the element in a full-screen window of its own; the app draws nothing there and does not intercept it. Windows: WebView2 sizes a full-screen element to the WebView's bounds only, so the panel listens to `ContainsFullScreenElementChanged` and, while it is set, mounts the same player in a window-filling overlay (bare `WebViewWidget` on black, one texture, no chrome) and takes the main window full screen; a detached board window only fills itself. The player's own exit (its button, Esc) clears the signal and restores the rail and the window. |
| No background player: content must not play from a player not displayed in the page, tab or screen the user is viewing (III.I.9) | OK | Playback stops 20 seconds after the tab leaves the foreground or the window is hidden or minimised (`liveGameStreamingLifecycleProvider`); the grace only lets a quick switch back re-attach the same player instead of loading it again. Element fullscreen does not trip this: on macOS the lifecycle follows `NSApplication.occlusionState`, and WebKit's full-screen window is one of the app's own, so the app stays `resumed`; on Windows the overlay lives in the same window. |
| Must not separate or promote audio/video components separately (III.I.7, III.I.8) | OK | Player shown whole; no audio-only mode. |
| Must not modify, interfere with, replace or block YouTube advertisements (III.I.5) | OK | No content blocking in the WebView; provider ad and measurement frames navigate freely (only Google's passive sign-in frame is cancelled, which carries no ad). |
| Must not charge users to watch in an embedded player or gate a video behind any action other than play (III.F.3.a, III.F.3.b) | OK, by reading | ChessEver Desktop is a paid product; the fee buys the analysis engine, databases, live boards and tools, and a stream is supplementary context inside them. YouTube's audit form lists subscription and freemium apps as valid models; the clause targets charging for the video itself. Conditions we hold: streams are never marketed, priced or gated as a paid benefit; the same streams play free on chessever.com and on YouTube; the player is unmodified with its controls, ads, branding and links intact; no background playback; "Open on YouTube" is always one click away. If YouTube ever reads it otherwise, the fallback is the link-out panel on `feat/streams-link-out-only`. |
| No incentives for engaging with YouTube (III.F.3.c) | OK | None. |
| Make clear YouTube is the source by displaying YouTube Brand Features; never obscure YouTube's attribution (III.F.2.a, III.F.2.c) | OK | The player's own branding is unobscured; the toolbar, menus and the "Open on YouTube" action name YouTube. |
| Must not sell ads or sponsorships on or within the player, nor on a page that contains only YouTube data (III.G.1.c, III.G.1.d) | OK | No advertising in the desktop app; the site runs no ad network. |
| Must not download, cache or store copies of audiovisual content (III.E.1.a) | OK | Streams play live in the provider's player; nothing is recorded. |
| Made for Kids: look up the status of every embedded video and turn tracking off for flagged videos (III.E.4.j) | OPEN, broadcasting API | The site and the embed page already switch to `youtube-nocookie.com` when `publication.madeForKids` is true (web PR "Disclose embedded players, honour Made for Kids"). The broadcasting API must populate the flag from `videos.list` `status.madeForKids` when it fetches a YouTube publication and refresh it with the publication. |
| Autoplay shares playback data on load; the API client may limit it with `autoplay=false` (III.E.4.i) | OK, disclosed | Game pages autoplay, as the site does; the privacy policy says so and the hide control stops it. |
| Privacy policy: prominently displayed, states use of YouTube API Services, links the Google Privacy Policy, explains data collected and shared, cookies, contact (III.A.2; ToS §7) | OPEN until deployed | Policy text in the web PR above; desktop Settings gains a "Privacy & terms" card linking the policy and the terms of use. |
| Industry-standard transport encryption (III.E.5.b) | OK | HTTPS everywhere; the embed page requires it. |
| YouTube name not used in our product name; logos unmodified (Branding Guidelines) | OK | We draw no YouTube logo of our own; "YouTube" appears only as a plain provider label. |
| Content licence: uploaders grant other users the right to access their content through YouTube's features such as embeds, and can switch embedding off per video (YouTube Terms of Service) | OK, with duties | Curated channels are third parties; we rely on that licence, so a video whose uploader disabled embedding simply shows YouTube's own "unavailable" card and must not be worked around, and a removal request from an uploader is honoured at once. |

### Twitch

| Rule (source) | Status | How |
|---|---|---|
| `parent` must name the domain(s) embedding the player; embedding domains use SSL (embed docs) | OK | `parent` is the host serving the chessever.com player page; the page is HTTPS. The earlier top-level load with an asserted `parent` was removed because it is both untrue and non-functional. |
| Use only Twitch's embeddable player for Twitch video (DSA D.1) | OK | `player.twitch.tv` iframe, nothing else. |
| Do not modify, replace, interfere with, limit, block, cover or obscure the player's functionality, including its ads, or the Twitch Marks (DSA D.1; embed docs "Twitch-approved player elements … not obscured") | OK | No overlays (see layout above); no blocking of the player's frames. The player's fullscreen control works (see the YouTube rows: the WebView's Fullscreen API is on, and the presentation is the player's own with nothing of ours in it). |
| Minimum 400×300 for video embeds (attribute table) | OK | Below 400 px of rail width the external link replaces the player; height is clamped to at least 300. Site: adapter `minWidth`/`minHeight`. |
| Autoplay where the embed is the focus; Twitch may disable it for hidden or obscured embeds (DSA D.1) | OK | The panel autoplays only as the visible focus of the game view and stops when hidden. The site's current rule starts Twitch muted until the viewer takes control; the embed page inherits it. |
| Not on sites that replicate Twitch without substantial additional content, nor targeting children under 13 (DSA D.1 prohibited uses) | OK | Live boards, engine and notation are the product; ChessEver is not directed at children. |
| Must not transmit embeds through advertising networks or services (DSA D.1) | OK | None. |
| Must not embed in exchange for compensation from a content provider on a site the provider does not own (DSA D.1) | OK, keep | Our editors pick the channels; no streamer pays us, we pay no streamer, and no channel is placed for a fee. Keep it that way: no paid placement of anyone's stream. |
| May charge for the service, but not fees specifically to watch the embeds (DSA D.1 permitted uses) | OK | ChessEver Desktop is a paid product that includes Twitch embeds, exactly the case this clause permits. Streams are not marketed as a paid feature and must not become one. |
| Advertising on the same site is allowed only beside substantial other content (DSA D.1) | N/A | No advertising. |
| Public, easily accessible privacy policy with data-protection disclosures; disclose tracking and offer an opt-out (DSA A) | OPEN until deployed | Same web PR; Settings link on desktop. Existing analytics disclosures already cover tracking. |
| Do not store copies of Twitch Content beyond a 24-hour cache; honour deletions and changes (DSA C) | OK, broadcasting API to keep | The desktop stores only the organiser's stream list it receives from ChessEver's API. The broadcasting API's publication observations for a Twitch channel (title, status, times) must keep refreshing and must not be retained as a permanent copy beyond the 24-hour window. |
| Twitch Marks only per the Trademark Guidelines (DSA 2.ii) | OK | "Twitch" appears as a plain provider label; no logo of ours. |
| Obtain the end user's authorisation before using their channel's content to market a commercial product; Twitch's embed permission is not a licence from the streamer (DSA D.1) | OK, with duties | We only display a streamer's public channel inside the event it covers, which is what Twitch's embed exists for; we never use a streamer's content in marketing, screenshots or the Pro pitch without their written consent. Because the streamers did not opt in, we honour any removal request at once (`info@chessever.com`), keep every provider link and attribution intact so the channel gets the viewers, and never autoplay a hidden embed (Twitch may treat that as inflating viewer counts). |

### Kick

| Rule (source) | Status | How |
|---|---|---|
| Embed via `player.kick.com/{username}` iframe with `autoplay`, `muted`, `allowfullscreen` parameters (help centre) | OK | Exactly those parameters; `allowfullscreen` left at its default, and the desktop WebView honours it (Fullscreen API on). |
| No scraping or automated access; no circumvention; no modification of the service (ToS) | OK | Player only; no API calls to Kick, no blocking. |
| Kick marks unmodified (ToS 2.2) | OK | Plain "Kick" label. |

## Rules for anyone touching the panel or the player page

1. Never load a provider player URL top-level in the WebView.
2. Never send a synthetic `Referer`, `Origin` or `parent` on the app's behalf.
3. Only streams the broadcast API resolves for the scope are embeddable; the
   embed page 404s for anything else and the panel then offers the external
   link, never a broken frame.
4. Nothing of ours in front of the player: the toolbar stays under it, and
   tooltips, popovers and menus anchor away from it. On the site, menus open
   above the toolbar and the chat launcher stays hidden on `/embed`.
5. Main-frame navigations away from the embed page are cancelled; only
   twitch.tv, youtube.com, youtu.be and kick.com destinations may open in
   the system browser, throttled to one launch per two seconds and no repeat
   of the same URL within fifteen. Sub-frames belong to the provider and are
   always allowed, except Google's passive sign-in frame
   (`accounts.google.com`, `youtube.com/signin_passive`), which reloads
   itself without end outside a signed-in browser profile and is cancelled.
   On macOS WebKit reports every frame's navigation to the delegate, so the
   `isMainFrame` check is what keeps sub-frames inside.
6. Honour the provider minimum player sizes (Twitch 400×300, YouTube and
   Kick 200×200); below the width, show the external link, never a cropped
   player.
7. Playback stops 20 seconds after the Board tab leaves the foreground or the
   window is hidden or minimised, and resumes on return. The grace exists so
   a quick switch re-attaches the same player rather than loading it again.
8. Never sell the panel: streams must not be marketed, priced or gated as a
   paid benefit, and no advertising may sit in or around it. The desktop app
   as a whole is paid; Twitch's agreement permits that explicitly, and the
   YouTube reading above depends on the stream staying supplementary to the
   product's own value. A "Pay to watch GM live streams" pitch, anywhere,
   breaks both.
9. The toolbar always offers "Open on <Provider>", so the official source is
   one click away whatever the embed does.
10. When the broadcasting API supplies `publication.madeForKids`, the site
    switches YouTube to `youtube-nocookie.com`; do not remove that path.
11. Fullscreen belongs to the player. The WebView's Fullscreen API stays on
    (`elementFullscreenEnabled: true` on macOS through the patched
    `third_party/webview_all_wkwebview`; WebView2's default on Windows) so
    the provider's own control works, and the app never adds a fullscreen
    control of its own, never intercepts the player's, and draws nothing in
    the full-screen presentation: on macOS that is WebKit's window, on
    Windows the panel's overlay holds the bare player and nothing else. A
    "fullscreen" of ours that stretches the player under our chrome would
    be an overlay in front of the player and is not allowed.

## Request discipline (what the desktop sends, and how often)

The providers must never be hammered. Every outbound request of the panel:

| Request | Target | Cadence |
|---|---|---|
| Stream list for the game's scope | `api.broadcast.chessever.com` (ours) | Every 30 s while the panel is on a foreground tab of a visible window; paused otherwise; one extra read when the window returns. Never touches a provider. |
| Embed page | `chessever.com/embed/video/…` (ours) | Once per selected stream. The 30 s poll never reloads it; a metadata refresh that leaves the stream unchanged is a no-op. |
| Provider player | Twitch / YouTube / Kick, from inside the embed page | Once per embed page load. Only the selected stream loads; nothing is prefetched. |
| Failed-frame retry | `chessever.com` only | At most three automatic retries (45 s, 90 s, 3 min), then manual. Fires only when our page delivered no frame, so a provider outage never triggers it. |
| Teardown and return | provider, via the page | A tab switch or hidden window blanks the player after 20 s; a return inside that window re-attaches the same player with no new request. |

Rules: never add a request to a provider host from the app itself; never
reload a player on a timer; never load more than the selected stream.

## Open items and owners

- Broadcasting API: populate `publication.madeForKids` from YouTube
  `videos.list` `status.madeForKids` on every YouTube publication fetch and
  refresh; keep Twitch publication observations within the 24-hour cache
  rule (YouTube III.E.4.j; Twitch DSA C).
- Site: merge and deploy the privacy-policy and Made-for-Kids PR and the
  `/embed/video` page PR (#375). Until the page is live the desktop panel
  shows "The player could not load here. Open <Provider>".
- Product: keep the panel ad-free and never priced or marketed as a
  feature; take no payment from anyone for placing a channel (Twitch DSA
  D.1). Should YouTube ever require it, `feat/streams-link-out-only` is the
  ready fallback that lists and links without a player.
- Editorial: because our editors choose third-party channels, a streamer can
  object. Remove a channel on request without argument, keep a note of who
  asked, and prefer a short courtesy message to a channel before featuring
  it. The site's privacy policy must describe the streams as selected by
  ChessEver, not by organisers.

## Open source

The desktop and web repositories are public (GPL-3.0 desktop). Embedding
needs no credentials, so nothing here requires a secret; the Made-for-Kids
lookup belongs on the broadcasting API, which already holds a server-side
YouTube key for publication metadata. `webview_all` (MIT) and its WebKit and
platform-interface packages (BSD-3-Clause, Flutter Authors) are compatible
with GPL-3.0 redistribution.
