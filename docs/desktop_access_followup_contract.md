# Desktop access follow-up contract

## User-directed policy

- Play is Premium. Free accounts can discover its locked entry; starting a single game, a seeded Play-from-here game, a rematch, or a new/continued engine tournament requires admission.
- A running Play session remains mounted on membership changes. Existing tournament results/runs remain available for stopping and recovery. No existing PGN is deleted or rewritten by the gate.
- Each account receives one free **successfully delivered** game report, not one per day or per widget session. Further new reports require verified Premium. Premium reports are unrestricted by the client allowance.
- Hide/show, re-entry and cache eviction do not charge an already admitted report again. A previously unadmitted cache hit is admitted explicitly when requested, rather than silently granting access because background work happened to exist.
- Failed/cancelled generation does not record a free success. Requests are serialized per account within the process, and successful admission persistence is awaited before the next request may proceed.
- The three-player favorite limit is a **player** allowance. Favorite events remain unlimited. An authoritative quota denial must open the Desktop paywall; unknown/loading/error outcomes show retry behavior, not a fabricated Premium denial.

## Favorite activation repair

Favorites and Countrymen player lists previously reached the legacy standings notifier. It optimistically appended a player, caught the underlying limit exception, reverted state, and returned without presenting a dialog. The observed fourth add was rejected rather than saved, but the user received no paywall.

Desktop Favorites/Countrymen hearts and context menus, Rankings, full player profiles and performance-card favorites now use one awaited Desktop action. It checks the current account generation, uses the existing quota repository, serializes admission through mutation, avoids an optimistic insert, and presents a limit rejection at either preflight or write boundary. Removals spend no slot. Compact hover cards have no separate favorite mutation; their name/avatar activation retains the full-card route.

## Report enforcement boundary — not account-global security yet

The available `claim_game_analysis_report(p_fingerprint)` contract is a daily, claim-before-generation API. It cannot honestly implement a lifetime **successful-delivery** allowance: it also spends a daily claim on failed/cancelled attempts. This follow-up does not call that incompatible daily RPC for the lifetime path and does not invent or deploy a replacement RPC.

The implemented fallback is an account-prefixed durable preference ledger on the local app database, separate from evictable/logout-cleared report cache. It survives ordinary restarts and sign-out/cache clearing on that installation. Per-fingerprint admission and the first-free-success marker preserve reopen behavior. Production generation uses account-generation and current-document ownership checks; raw debug flags do not grant Premium.

**This is client UX enforcement, not secure account-global authorization.** Another device, a separate process racing the same installation, an app-data reset/reinstall, or a modified client can bypass a local-only ledger. A supported backend transaction must reserve/complete/release one lifetime allowance for the account, idempotently bind successful deliveries, and expose authoritative usage across devices before claiming secure account-global enforcement. No production schema, subscription, billing or backend change is included here.

The pre-existing storage-quota fallback likewise still needs the server quota transaction/triggers for cross-device atomicity. The integration's documented destructive expiry cleanup and guest-account merge dependencies remain external release blockers.

## Verification scope

Regression sources cover the three-to-four favorite boundary, deferred count, count failure, mutation rejection, account changes, report success/cancellation/failure, cached admission, repeated opens, queued requests and account generation changes. Repository instructions permit analysis only: these test sources are **not reported as executed or passing**.

The existing Countrymen USA date-discovery statement timeout is separate. The failing `get_distinct_dates_for_country` request is unchanged by this follow-up; there is no database/index/timeout fix here.
