<!-- Moved verbatim from AGENTS.md Part II (formerly AGENTS.md) on 2026-10-12 so it is read on demand, not
     loaded into every agent session. Still binding; edit it here. -->

## 6. Auth (the second-hardest)

- Google: ditch `google_sign_in`. Use OAuth 2.0 desktop flow:
  1. Start `HttpServer.bind('127.0.0.1', 0)` to get a free port.
  2. Open browser to `https://accounts.google.com/o/oauth2/v2/auth?...&redirect_uri=http://127.0.0.1:<port>`.
  3. Capture the auth code from the loopback request, exchange via Supabase or directly with Google's token endpoint, then sign into Supabase with the resulting ID token.
- Apple: keep `sign_in_with_apple` only on macOS. On Windows, hide the button.
- Test signed-in state survives a restart on both OSes.
