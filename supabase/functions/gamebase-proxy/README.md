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

## Member routes

Most routes are anonymous reads behind the server key. The book-publishing
routes (`/api/library/authors`, `/api/library/folders/{id}/book`, its `cover`
and `author-photo`) act for one signed-in member: the function forwards the
caller's own Supabase bearer upstream, Gamebase verifies it and checks that the
folder is theirs, and the answer is `private, no-store`.

None of these routes can publish. Gamebase keeps every submission a private
draft until a ChessEver superadmin approves it from chessever.com/account; the
superadmin console is not reachable through this function.

## Viewer routes

Published collections are read through `/api/collections/...`. The catalog,
the author list, the event bindings and the opening index are anonymous reads
like the rest. A collection itself, its games and its players are *viewer*
routes: a Premium collection opens only for an entitled account, so the
function forwards the caller's bearer when there is one, passes a
`Cache-Control: no-cache` re-check along (sent right after a purchase), and
answers `private, no-store`. Counting a read (`POST .../view`) is anonymous;
starring (`PUT .../star`) is a member route.

No route here writes a collection: publishing is the member routes above, and
approval is the superadmin console.

A function deployed before these routes existed answers `route_not_allowed`
(or `method_not_allowed` for PUT and DELETE). The desktop app reads that as
"publishing is not available here yet" and still lets a folder be deleted.
