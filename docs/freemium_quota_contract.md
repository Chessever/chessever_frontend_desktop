# Freemium storage quota contract

Status: **proposed, not deployed.** The SQL lives in
`docs/freemium_quota_contract.sql`. The desktop client already speaks this
contract and falls back to a temporary client count while the function is
missing.

## What it does

| Quota kind         | Counted                                                      | Never counted                                                                 |
|--------------------|--------------------------------------------------------------|-------------------------------------------------------------------------------|
| `saved_games`      | `user_saved_analyses` rows in a folder the account owns       | rows in the Likes collection (`is_liked_games`), rows in books the account follows |
| `favorite_players` | `user_favorite_players` rows                                 | favourite events (unlimited)                                                  |
| `owned_databases`  | owned `user_folders` rows with `node_type = 'database'`      | `node_type = 'folder'`, the Likes collection, followed books, the synthetic TWIC book |

Limits are rows in `public.freemium_quota_limits` (10 / 3 / 3). No client
declares them.

Two server pieces:

1. `public.check_freemium_quota(p_kind text, p_additions integer) RETURNS jsonb`
   is a pre-flight read, granted to `authenticated`. It returns
   `{allowed, reason, used, limit, is_premium, kind, requested}` so the UI can say
   "10 of 10 saved games used". Possible reasons: `auth_required`, `invalid_kind`,
   `invalid_additions`, `premium`, `no_new_slot`, `within_limit`, `quota_exceeded`.
2. Statement-level `AFTER INSERT` / `AFTER UPDATE` triggers are the atomic
   authority. Each takes a per-account `pg_advisory_xact_lock`, recounts from
   committed state, and raises `P0001 freemium_quota_exceeded` (DETAIL carries
   the same jsonb) when a positive change leaves a free account over its limit.
   A second device racing for the last slot waits for the first commit and then
   loses.

Charging rules:

- An ordinary update (title, comments, tags, analysis state) is free and does
  not even take the lock.
- A move within counted storage is free.
- A move from Likes into a database is +1 and is charged.
- A node leaving the Likes flag, or turning from a folder into a database,
  is charged.
- Deletes have no trigger. Over-limit accounts keep read, edit, remove and
  export access to everything they have.

## Deployment order (backend owner)

1. **Stop the data loss first.** Remove the `EXPIRATION` calls to
   `trim_favorite_players_to_top_n` / `trim_saved_analyses_to_recent_n` from the
   RevenueCat webhook, and unschedule or delete the `trim-overlimit-free-users`
   admin function. Section 5 of the SQL redefines both functions as no-ops that
   return 0, which protects against any caller that is not redeployed. This part
   is independent of the rest and should ship even if the quota triggers wait.
2. Apply the SQL as one migration. It runs a one-time repair first: empty nodes
   created by desktop with the `folder_container` icon but stored as
   `node_type = 'database'` become folders. No row is deleted.
3. Verify, as an authenticated free test account:
   - `select public.check_freemium_quota('saved_games', 1);` returns the account's real usage
   - inserting past the limit fails with `freemium_quota_exceeded`
   - liking a game at the limit succeeds
   - editing a saved game while over the limit succeeds
4. Ship a desktop release. Once `check_freemium_quota` is live the client stops
   using the fallback on its own. The fallback can then be deleted (see below).

## Requirements and known interactions

- **Isolation:** relies on READ COMMITTED, which is PostgREST's default. Under
  REPEATABLE READ the recount after the lock would not see the competing commit.
- **Server contexts are exempt:** writes with `auth.uid() IS NULL` (service_role
  jobs, migrations) are not checked.
- **Legacy auto-heal:** `ensure_saved_analysis_database_folder` redirects a save
  aimed at a folder node into a new child database. For a free account already at
  its database limit, that save now fails instead of creating a fourth database.
  Only pre-split mobile builds can hit this path.
- **Net per statement:** one statement that moves a game into counted storage and
  another out of it nets to zero and is free.

## Client side (desktop)

- `lib/repository/freemium/freemium_quota_repository.dart` calls
  `check_freemium_quota` and maps a trigger rejection (`P0001`,
  `freemium_quota_exceeded`) to the same capacity result.
- **Temporary fallback:** only when PostgREST reports the function missing
  (`PGRST202`, or Postgres `42883` undefined_function), the repository counts with
  the same exclusions on the client.
  - Saved games and favourite players are enforced against the existing shared
    client constants.
  - Owned databases have no client constant, so the fallback reports usage and
    allows the create. The database cap starts being enforced when this contract
    deploys.
  - Any other error is `temporarilyUnavailable` (Retry), never a purchase prompt.
- Calls are serialized per process with a FIFO queue. Detached board windows run
  their own Riverpod container and queue; cross-process and cross-device races
  are the triggers' job.
