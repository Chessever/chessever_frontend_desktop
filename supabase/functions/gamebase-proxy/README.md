# gamebase-proxy

Supabase Edge Function proxy for Chessever Gamebase API requests.

The Flutter desktop release path calls this function instead of compiling the
upstream Gamebase API key into the app. The function forwards only an allowlist
of Gamebase routes and injects `GAMEBASE_API_KEY` server-side.

## Required Secret

Set the upstream key as a Supabase function secret:

```bash
supabase secrets set --env-file /path/to/gamebase-secret.env
```

The env file must contain:

```text
GAMEBASE_API_KEY=...
```

Do not pass `GAMEBASE_API_KEY` to Flutter release builds.

## Deploy

```bash
supabase functions deploy gamebase-proxy --use-api
```

JWT verification stays enabled. Clients call the function with the app's
Supabase anon/user token headers.
