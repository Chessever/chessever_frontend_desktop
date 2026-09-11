# Broadcast video on desktop: list and link, never embed

Decided 2026-09-11 after auditing YouTube's API Services policies, Twitch's
Developer Services Agreement and embed requirements, and Kick's terms.

## What the desktop app does

The Board pane's live-stream panel (`lib/desktop/widgets/broadcast_video_panel.dart`)
reads the organiser-managed stream list from ChessEver's broadcast API,
groups it by language exactly as the site does (flags, hover lists, remembered
language, per-tournament selection), and offers two actions for the selected
stream: "Open on Twitch / YouTube / Kick" (the provider's own page in the
system browser) and "Watch video with live boards" (chessever.com's free
watch page). No provider player is ever loaded inside the app.

## Why no player in the app

- ChessEver Desktop is premium-only: every screen sits behind a paid
  entitlement. YouTube's Developer Policies forbid charging users to watch
  content in an embedded YouTube player or gating a video behind any action
  other than pressing play (III.F.3.a, III.F.3.b). A YouTube player inside a
  paid app is at best a grey zone, and we do not ship grey zones.
- Twitch verifies the embedding web domain through the player's `parent`
  parameter and redirects a top-level load to twitch.tv; the only way to
  satisfy it from a native app is to frame one of our own web pages inside
  the app, which the product owner judged too close to a workaround.
- Linking out has no compliance surface at all: a link to a public Twitch,
  YouTube or Kick page uses none of their API services or embeds.

Listing streams is allowed by all three providers: the list is organiser
data from our own API, and the provider name appears only as a plain label.

## Rules

1. Never add a WebView, iframe or player for provider video to the desktop
   app. The site's own embeds (free pages, real chessever.com documents) are
   the only place streams play.
2. Never mark, price or market streams as a paid desktop feature. Twitch's
   agreement allows paid services that include its content only while the
   fee is not for the content itself (Schedule D.1); keeping streams out of
   the paywall pitch keeps that true, and the panel itself stays ad-free.
3. Keep the two actions: the provider page and the free site's watch page.
4. Provider names appear as plain labels. No provider logos of our own.

## History

- 20.32.4 (#227) framed provider players top-level in a WebView with an
  asserted `parent` and Referer. Non-compliant and non-functional for Twitch.
- 20.32.6 (#229) framed a chessever.com `/embed/video` page instead (web PR
  #375, never merged). Compliant on the mechanics, but see above.
- 20.32.9 (#232) linked out for YouTube only.
- 20.32.10: no embedded player on desktop; `webview_all` and the Linux
  WebKitGTK dependencies removed.
