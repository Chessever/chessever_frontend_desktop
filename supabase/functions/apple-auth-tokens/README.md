# Apple authorization lifecycle

Local implementation only. No Apple signing/encryption secrets were configured
when this work began. Deployment, scheduler setup, Apple portal registration,
and a test-account end-to-end check remain operator steps. Never use a real
account deletion to validate deployment.

The implementation follows [Apple TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)
and [signed account-change notifications](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts).
The only programmatic revocation is Apple's `/auth/revoke`, using a stored
refresh token. Old accounts with no saved token still delete, returning a manual
revocation flag. Direct users to [Apple's access-removal instructions](https://support.apple.com/en-us/102571).

## HTTP contracts

All endpoints accept POST JSON and return `Cache-Control: no-store`. No codes,
tokens, keys, Apple response bodies, or raw exceptions are logged or returned.
The gateway must set `verify_jwt=false`: the handlers perform authentication
themselves, and Apple's notification JWT is not a Supabase JWT.

Each endpoint also supports a public, side-effect-free `GET ?health=1`.
It returns exactly `{ready:true}` or HTTP 503 `{ready:false}`. Readiness imports
and signs with the configured P-256 server key, validates configured audience
IDs and every AES key (including the active key), requires a worker secret,
and calls service-only `apple_lifecycle_health(p_key_ids text[])`. The database
probe reads the private tables, verifies the canonical RPC/access contract,
and checks that every retained token/job's key ID is still configured. It never
leases jobs, writes tokens, changes accounts, exposes values, or contacts
Apple. This does not establish that Apple has enabled a particular key or
App ID in its portal; the operator must verify that capability separately.

| Endpoint | Authentication | Request | Success |
| --- | --- | --- | --- |
| `apple-auth-tokens` | Supabase bearer validated by `/auth/v1/user` | `{authorization_code,identity_token,nonce}`; nonce is the raw client nonce | `{stored:true}` only after durable storage |
| `delete-account` | Supabase bearer validated by `/auth/v1/user` | `{}` only; never a user ID | `{deleted:true,apple_manual_revoke_required:boolean,apple_revocation_pending:boolean,data_removal_pending:boolean}` |
| `apple-auth-revocations` | Dedicated `APPLE_REVOCATION_WORKER_SECRET` bearer | `{}` | `{processed:number,pending:boolean}` |
| `apple-auth-notifications` | Apple-signed RS256 payload, fixed Apple JWKS, issuer and configured audience | `{payload:"signed JWT"}` | `{accepted:true}` after durable notification handling |

Registration verifies the identity JWT's signature, issuer, expiration,
allowlisted audience, subject and SHA-256 nonce. It requires the same Apple
subject in the server-verified Supabase identity. It derives the client ID from
the signed audience, exchanges the one-use code with a server-generated ES256
client secret, and checks the returned ID token against that same subject,
audience and nonce. Neither email nor client-supplied account IDs authorize a
binding. The database repeats the identity check under the deletion lock.

Native auth stages its Supabase session in a temporary in-memory client.
The main application's auth stream sees the session only after `stored:true`.
Failures preserve a pre-existing app session and best-effort invalidate the
temporary Supabase session. Never fall back to successful native sign-in after
missing server configuration. Website/mobile OAuth mechanisms must arrange
provider-token capture on the server; they cannot invent the authorization code
after Supabase's hosted flow has already consumed it. Legacy fallback covers
accounts without captured provider tokens.

Registration storage failures return HTTP 503 after three idempotent retries
of the same ciphertext. They **never call Apple revocation**, including when
a database commit may have succeeded but its acknowledgement was lost. A new
native session is not adopted, and a returning user's prior Supabase session
and Apple grant remain intact. Previously saved credentials or an ambiguously
committed row remain available to the durable deletion flow. If nothing was
saved, the user retries sign-in with a fresh authorization code; legacy manual
revocation remains available for deletion without a saved token.

## Database contract

The separately reviewed migration owns `private.apple_tokens` (one row per
`user_id,client_id`) and `private.apple_revoke_jobs` (no auth user FK). No public,
anonymous, or authenticated role can read them. `encrypted_tokens` is an opaque
AES-256-GCM envelope `{v:1,iv,data}`. Its authenticated associated data binds
format version, key ID, user ID, Apple subject and client ID. The encrypted JSON
contains `refresh_token`, `access_token`, and `id_token` from Apple.

Service-role-only public RPCs:

* `apple_store_tokens(p_user_id uuid,p_apple_sub text,p_client_id text,p_encrypted_tokens text,p_key_id text)`.
* `apple_claim_revoke_jobs(p_user_id uuid DEFAULT NULL,p_limit integer DEFAULT 10)` returns canonical job rows with `lease_token`. Uses `FOR UPDATE SKIP LOCKED` with a two-minute lease.
* `apple_finish_revoke_job(p_id uuid,p_lease_token uuid,p_success boolean,p_error_code text)` removes only acknowledged successes, otherwise backs off for retry.
* `apple_process_notification(p_jti text,p_apple_sub text,p_event_type text,p_event_time bigint)` durably deduplicates notifications. `p_event_time` is Unix seconds. Official deletion event is `account-deleted`.
* `apple_lifecycle_health(p_key_ids text[])` is read-only and service-only; validates table/RPC access and encryption-key coverage for readiness.

`delete_user_account()` remains authenticated, takes no account argument,
derives `auth.uid()`, and returns JSONB `{deleted:true,apple_manual_revoke_required:boolean}`.
Its transaction queues encrypted credentials before deleting `auth.users`.
Missing legacy tokens do not block deletion. Native and website callers use
`delete-account` for an immediate best-effort drain and structured result.
Failures after the transaction commits never change `deleted:true` to a failed
deletion. A drain blocked by another worker conservatively reports pending.

Routine replacement of a saved token must not enqueue its old token for
revocation: revoking an old token can revoke the fresh authorization too.
The latest stored token handles deletion of that authorization.

## Server secrets and safe initial setup

Runtime supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY`. Do not export the service key into the client.

| Secret | Source |
| --- | --- |
| `APPLE_CLIENT_IDS` | Exact Apple-enabled bundle/Services IDs, comma-separated; use only verified configured audiences |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `APPLE_KEY_ID` | Key ID of the **Sign in with Apple** signing key |
| `APPLE_PRIVATE_KEY` | That key's PKCS#8 EC P-256 `.p8`, server only; literal `\n` or actual newlines supported |
| `APPLE_REDIRECT_URIS` | JSON mapping of web Services ID to exact original HTTPS redirect URI; `{}` for native only |
| `APPLE_TOKEN_ACTIVE_KEY_ID` | Active encryption key ID |
| `APPLE_TOKEN_ENCRYPTION_KEYS` | JSON object mapping key IDs to base64 32-byte random encryption keys |
| `APPLE_REVOCATION_WORKER_SECRET` | Independent random scheduler bearer secret |

An App Store Connect API key does **not** substitute for a Sign in with Apple
key. The key must have the SIWA capability for the configured primary App ID.
Its capability cannot be inferred from the `.p8` encoding alone. Confirm it in
the Apple Developer portal or the organization's authorized key inventory.
No configured credential is assumed or fabricated by this implementation.

For **initial setup only**, the local helper reads an existing confirmed SIWA
key and generates encryption/scheduler keys. It refuses source-tree key/output
paths and overwrites, validates P-256, writes mode 0600 and never prints values:

```sh
python3 supabase/functions/apple-auth-tokens/prepare_secrets.py \
  --key-file /secure/location/siwa.p8 \
  --output /secure/location/apple-server-secrets.env \
  --team-id YOURTEAMID --key-id YOURKEYID0 \
  --client-ids your.configured.bundle.id \
  --confirm-sign-in-with-apple-key
```

Replace IDs with the real configured values. Keep the env file in an access-
controlled location outside every source checkout. Do not paste it into chat,
terminal output, source, screenshots, Dart defines, Flutter assets or CI logs.
Never execute deployment commands with shell tracing enabled.

The operator's authorized deployment sequence is:

1. Review/apply the account deletion migration and its schema tests.
2. Upload server secrets with `supabase secrets set --project-ref PROJECT_REF --env-file /secure/location/apple-server-secrets.env`. This documented CLI path reads the file without putting secret values in command arguments.
3. Verify `supabase/config.toml` explicitly disables gateway JWT verification for the four functions above and `account-data-cleanup`. Deploy each reviewed function with `supabase functions deploy FUNCTION_NAME --project-ref PROJECT_REF`.
4. In Apple Developer, register the HTTPS `apple-auth-notifications` function URL as the server-to-server notification endpoint for the primary App ID.
5. Add a protected scheduler at least every minute to POST `{}` to `apple-auth-revocations` with its worker bearer. A single invocation leases up to 10 jobs; run additional bounded invocations for backlog. Store its bearer in a server secret store/Vault, never a public SQL migration. Also schedule the separately documented `account-data-cleanup` worker.
6. With dedicated test accounts, verify registration, restart, deletion and revoked credential state after deployment. Real token tests and deletion require explicit operator authorization.

Native attachment: add `DesktopAppleCredentialBridge.swift` to Runner Sources;
attach `DesktopAppleCredentialBridge.shared.attach(binaryMessenger: ...)` in
the main Flutter engine; after Supabase initialization call
`DesktopAppleCredentialLifecycle.instance.start()`. It observes native
revocation and checks credential state at launch, auth changes and resume.
Explicit `revoked`/`notFound` signs out only the same current account;
temporary errors, `transferred` and unknown states preserve the session.
Revocation checks also snapshot access/refresh-token generation. A delayed
verdict cannot clear preferences or sign out a newer authorization of the same
user/Apple subject. Supabase's JWT `session_id` distinguishes a new sign-in
from refresh-token rotation: rotation triggers one bounded fresh native-state
check instead of applying the old verdict. Tokens without `session_id` also
require fresh state after rotation. A switch to a different account still
permits cleanup of the revoked account's own keys while preserving the new
account's state.

## Retries, monitoring and key rotation

Never delete a failed outbox job to make the queue look healthy. Apple HTTP 200
also acknowledges an already-invalid token. Every non-200, timeout, missing
configuration/key, failed decryption or lost acknowledgement remains retriable.
Jobs keep working after account deletion. Poll private queue counts/oldest age
through server-only operational access; alert on sustained age, growing backlog,
configuration errors and token-decryption errors. Inspect error enums only.

The two-minute lease bounds worker ownership. An expired or lost completion is
replayed, and Apple revocation is idempotent. A scheduler outage leaves encrypted
jobs intact. A lost Apple signing key or encryption key requires operator repair.
Do not claim completed Apple revocation just because the account data is gone.

To rotate encryption, add the new base64 key beside **all** prior keys, change
`APPLE_TOKEN_ACTIVE_KEY_ID`, and deploy both atomically in secrets. Retain old
keys until no token or outbox row references their IDs, including delayed jobs.
Keep an encrypted backup in the authorized secrets manager. Do not rerun the
initial-setup helper over an existing live key configuration. Apple signing-key
rotation is independent; confirm the new key is SIWA-enabled before replacing
the server key/ID. None of these keys belongs in a client artifact.

Offline checks:

```sh
deno test supabase/functions/_shared/apple/apple_test.ts
deno check supabase/functions/apple-auth-tokens/index.ts supabase/functions/apple-auth-revocations/index.ts supabase/functions/apple-auth-notifications/index.ts supabase/functions/delete-account/index.ts
flutter test --no-pub --dart-define=MAC_APP_STORE=true test/desktop/desktop_apple_token_lifecycle_test.dart
```
