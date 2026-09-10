# Broadcast video embeds on desktop: compliance model

The Board pane's live-stream panel (`lib/desktop/widgets/broadcast_video_panel.dart`)
plays organiser-managed Twitch, YouTube and Kick streams. Each provider's embed
terms are written for web pages, so the desktop app never loads a provider
player directly. The WebView loads chessever.com's own document,
`/embed/video/{scope}/{scopeId}/{streamId}?autoplay=1`, and that page frames the
provider exactly as the site's in-board player does.

What this buys, per provider:

- **Twitch.** The embed's `parent` parameter must name the domain that embeds
  the player. On the embed page it is the host serving that page, so it is
  true. Loading `player.twitch.tv` top-level with `parent=chessever.com` is
  both false and non-functional: Twitch redirects to the channel page.
- **YouTube.** Embedded players must identify the API client through the HTTP
  referrer. Inside the embed page the referrer is the real chessever.com
  document; the app asserts nothing. The page has no overlays, autoplays only
  when visible, and shows one player at a time (YouTube's Required Minimum
  Functionality).
- **Kick.** No parent or referrer rule; the same page keeps it uniform.

Rules that follow from this, for anyone touching the panel:

1. Never load a provider player URL top-level in the WebView.
2. Never send a synthetic `Referer`, `Origin` or `parent` on the app's behalf.
3. Only streams the broadcast API resolves for the scope are embeddable; the
   embed page 404s for anything else, and the panel then offers the external
   link instead of a broken frame.
4. Main-frame navigations away from the embed page are cancelled; the rail
   stays on the document. Only provider destinations (twitch.tv, youtube.com,
   youtu.be, kick.com: channel pages, "Watch on Twitch", video titles) open in
   the system browser, throttled to one launch per two seconds and no repeat
   of the same URL within fifteen. Players load ad and bot-detection frames
   (Amazon ads, Kasada) that may try the top frame; those must never reach
   the user's browser. Sub-frame navigations belong to the provider and are
   always allowed, except YouTube's passive Google sign-in frame
   (`accounts.google.com`, `youtube.com/signin_passive`), which reloads
   itself without end outside a signed-in browser profile and is cancelled.
   On macOS WebKit reports every frame's navigation to the delegate, so the
   `isMainFrame` check is what keeps sub-frames inside.
6. The toolbar always offers "Open on <Provider>", so the official source is
   one click away whatever the embed does.
5. Honour the provider minimum player sizes (Twitch 400×300, YouTube and Kick
   200×200); below the width, show the external link, never a cropped player.

The embed page lives in `chessever_web_frontend`
(`src/app/embed/video/[scope]/[scopeId]/[streamId]/page.tsx`); the site's chat
launcher is hidden under `/embed`. A desktop build whose site does not yet
serve the route degrades to the external-link row.
