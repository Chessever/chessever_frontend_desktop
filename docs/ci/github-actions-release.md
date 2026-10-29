# Desktop distribution through GitHub Actions

The production branch is `main`. Both release workflows are manually dispatched
and use the protected `release` environment. Only jobs running from `main` receive
signing or publishing credentials. The environment has no required reviewer, so a
dispatched run starts at once: dispatching it is the approval. Setup uses native background steps followed by
`wait-all`; no signing or publishing step runs in the background.

## Website downloads

Run **Desktop release** (`desktop-release.yml`) for any combination of:

| Target | Website installer | Updater platform |
| --- | --- | --- |
| macOS Apple Silicon | `Chessever.dmg` | `macos` |
| macOS Intel | `Chessever-intel.dmg` | `macos-x64` |
| Windows | `Chessever-Setup.exe` | `windows` |
| Linux | `Chessever.deb` | `linux` |

These editions retain Stripe billing and the existing updater. The GitHub jobs
reuse the Codemagic build, signing, notarization and R2 publishing scripts.
`ruby scripts/ci/check_codemagic_parity.rb` verifies all five historical recipes,
including the separate unsigned Flutter master build. `codemagic.yaml` remains a
behavior reference, rather than the service used to run releases.

Leave **Publish to R2** unchecked to build signed installers as seven-day GitHub
artifacts without changing website downloads or installed clients. Checking it is
the explicit manual action that publishes the direct-download release. macOS uses
Developer ID signing and Apple notarization, rather than App Review.

## Mac App Store

Run **Mac App Store review** (`desktop-app-store.yml`). It produces a universal
Apple Silicon + Intel `.pkg` for App Store Connect app `6824524785`, bundle
`com.chessever.desktop`. The dedicated build script sets both
`MAC_APP_STORE=true` and `CHESSEVER_APP_STORE=YES`, uses sandbox entitlements,
bundles signed universal engines, and uses Apple purchases. It does not invoke
the website updater or R2 publishing scripts.

The rejected selection at the start of the 2026-10-29 remediation was
22.15.1 (481); source was 22.17.35+525. Source changes are not evidence that the
selected binary contains the fixes. Read `pubspec.yaml` for the next candidate's
actual version/build and verify the selection again after preparation.

Keep the review corrections: guideline 5.2.5 means no Apple trademark
("Mac", "for Mac", "macOS") in
the app name, subtitle or screenshot captions. Guideline 4: sign-in never leaves
the app. The edition shows the native Sign in with Apple sheet, which requires
`com.apple.developer.applesignin` in `macos/Runner/AppStore.entitlements` and in
the store profile. Google opens in an `ASWebAuthenticationSession` sheet
(`DesktopWebAuthBridge.swift`) instead of the default browser.

Account deletion is available in Settings > Account for guests and permanent
accounts. The confirmation warns that deleting an account does not cancel Apple
billing and links to subscription management. Apple accounts without stored
revocation tokens receive manual Apple Account disconnection steps after the
ChessEver account is deleted, following Apple's TN3194 fallback. This flow does
not claim automatic Apple token revocation.
New Apple authorization capture, encrypted token storage, revocation outbox,
notification handling and credential checks also require configured server-side
keys, encryption keys and database migrations. Source implementation alone is
not endpoint readiness. The read-only health gates below must pass before a
candidate can be prepared for review.

Botvinnik asks for explicit, per-account AI-sharing permission before creating
a conversation or sending a message, including suggestions. The disclosure names
Cloudflare Workers AI and TinyFish and describes message/history/context sharing.
Settings > Botvinnik > AI data sharing can withdraw future sharing. The shared
Flutter flow also applies to app.chessever.com. Saved chats are not deleted by
withdrawing permission.

**Submit review** and **Prepare review only** default to checked. After the
read-only preflight passes, the workflow uploads once, waits for the exact source
version/build to become VALID, and prepares the preserved version slot with
`releaseType=MANUAL`. It selects that build, updates the reviewer instructions
from `scripts/ci/mac_app_store_review_notes.txt`, updates the English release
notes, and preserves existing review items. Missing subscription group, monthly
and annual metadata versions are attached to the same review draft, group first.
It does not replace the catalog or invent subscription metadata.

A successful prepare-only result says `prepared_not_submitted`. Apple documents
the [first subscription submission through App Store Connect together with the
app binary](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review).
Complete that first submission in the App Store Connect UI after the signed
candidate smoke checks. A pending review is never cancelled implicitly. Resolve
an `UNRESOLVED_ISSUES` draft in App Store Connect before preparation; the script
will not mark a rejection resolved on the operator's behalf.

Unchecking **Prepare review only** requests final API submission, which requires
fresh evidence for the exact signed package and already-approved subscription
metadata. Without that evidence the lane stops. For the normal first-review
handoff, keep it checked and use the prepared draft plus the checklist below.
Approval always holds the app for a human to release in App Store Connect.
There is no publish-now command or automatic release option.

Uncheck **Submit review** only when an upload without changing the current review
is intended, for example while a previous version is already waiting for review.
The new build appears in App Store Connect/TestFlight after Apple processes it.
**Replace pending review** defaults to unchecked and must be explicitly selected
to cancel an earlier submission and submit its replacement. It still enforces
manual release. Advancing an editable rejected version preserves its slot and
does not cancel an active review. Never treat upload-only or prepare-only success
as a review submission.

### Read-only preflight and signed-candidate handoff

With App Store API credentials and `SUPABASE_URL` supplied privately, run:

```sh
python3 scripts/ci/mac_app_store_preflight.py --phase before-upload
```

This makes GET requests only. It reads the expected version/build from source,
reports the actual selected build, checks the MANUAL hold, the current listing
name/subtitle, every current privacy-policy localization, review contact/demo
completeness, canonical review notes, subscription metadata versions, completed
subscription review screenshots and review-item relationships. A stale selected
build or notes are reported as false but can be repaired during preparation;
missing privacy/contact/catalog/server readiness stops preparation. The privacy
URL must be `https://chessever.com/privacy-policy`, not the old Google Sites URL.
It checks the saved URL, not the accuracy of the served policy text. The saved
contact/demo data and full API responses never appear in the report.
The catalog/review resource names and request bodies were independently checked
against Apple's downloaded OpenAPI 4.5.1 archive. Exact operation IDs, source
hashes, payloads and the remaining authenticated GET probe are recorded in
[the public API verification below](#public-apple-catalog-and-review-api-verification). Fixture tests alone are
not evidence that an endpoint exists or is accessible to this production app.

Each of `apple-auth-tokens`, `apple-auth-revocations`,
`apple-auth-notifications`, and `delete-account` must accept
`GET <SUPABASE_URL>/functions/v1/<function>?health=1` without a user credential.
The contract is HTTP 200 JSON `{"ready": true}` only after configuration and
schema readiness checks. A missing route, redirect, 401, 405, liveness-only
response, or `ready: false` is a blocker. Health must not exchange/revoke a
token, process a notification, delete an account, or drain the outbox, and must
not disclose key values. Server configuration belongs in the server secret
store. Do not pass those keys to this script or to the client build.

The ready gate also requires a private evidence JSON file, based on
[`mac-app-store-review-evidence.example.json`](mac-app-store-review-evidence.example.json).
Set `MAC_APP_STORE_REVIEW_EVIDENCE` to its local path and run against the exact
tested, signed installer, without rebuilding it:

```sh
python3 scripts/ci/mac_app_store_preflight.py --phase ready --package /path/to/tested-candidate.pkg
```

Evidence must match source version/build, `git rev-parse HEAD`, the shipped-source
fingerprint (including uncommitted/new files), and the package SHA-256. The test
time must be within 48 hours and every smoke item needs `passed: true` plus a
proof reference. Generate the current fingerprint with
`PYTHONPATH=scripts/ci python3 -c 'from mac_app_store_release_gates import source_fingerprint; print(source_fingerprint())'`.
Use `shasum -a 256` on the same `.pkg` that was installed/tested. Keep evidence
outside the repository and out of build assets. Do not include account passwords,
Apple tokens, receipts, private keys or unredacted service logs. These checks
validate an operator's evidence attestation; they cannot perform or independently
verify a sandbox purchase. Reports therefore keep `sandboxPurchaseVerified=false`.

The gate also requires these four operational evidence keys in `checks`, each
with `passed: true` and a nonempty private proof reference. Missing keys, false
values and empty references fail closed. The public audit reports each key as a
separate boolean alongside `review_smoke_evidence`, so app-flow checks cannot
hide unfinished operational work.

| Evidence key | Required operator proof |
| --- | --- |
| `appPrivacyInventory` | Reconcile all 14 currently declared App Privacy labels, including Device ID and tracking answers, against the actual shipped MAS SDK/data inventory and privacy policy. Document every correction or justified retention. |
| `subscriptionServerNotifications` | Verify both production and sandbox App Store Server Notifications configuration for RevenueCat, and evidence that each environment delivers and handles the expected event. A blank or unverified URL fails. This billing configuration is separate from the Sign in with Apple account-notification handler. The parent reported the live configuration blank; this remains a blocker until verified. |
| `deletionOperations` | Assign owners and references for outstanding GA/AppsFlyer deletion cases, verify required configuration, and document external-cleanup queue monitoring, age/error alerts, retry ownership and escalation. Preserve an accurate account of pending or `integration_required` work. |
| `aiReportOperations` | Assign report-review responsibility and a timely review target/coverage process, and verify that a sample report reaches that review process. A functioning report button alone is insufficient. |

These attestations do not create signed-candidate evidence. Until the real
candidate is signed, installed and tested, keep candidate verification and
purchase/restore evidence false. The example intentionally leaves every new
operational key false and every proof reference blank. No evidence for these
manual operations was fabricated by the local tooling changes.

After the first subscription metadata is approved, an operator may invoke
`scripts/ci/app_store_review.py` on that same package with `--platform MAC_OS
--release-type MANUAL --notes scripts/ci/mac_app_store_release_notes.txt` and the
private evidence path in the environment. This reuses an existing VALID build
and never releases it. A newly built package or changed shipped source requires
new evidence. The default CI preparation run does not fabricate evidence or
claim a purchase/restore test.

Final operator checklist and proof required before submitting the draft:

- [ ] Confirm the source version/build and fingerprint, signed `.pkg` SHA-256,
  universal architectures, App Store edition flags, signature chain, sandbox,
  Apple sign-in and file-access entitlements. Capture signing/entitlement output
  with `pkgutil --check-signature` and `codesign` against the installed candidate.
- [ ] Install that candidate and record a cold-launch smoke result. Confirm
  native Apple authorization, cancellation and restored credential behavior;
  Google must stay in `ASWebAuthenticationSession`, return through its temporary
  loopback callback and close correctly on completion/cancellation.
- [ ] Show guest deletion and permanent-account deletion controls, confirmation,
  Apple billing warning and subscription-management link. Use isolated approved
  test fixtures for destructive verification; never delete a real account as a
  preflight probe. Capture server token-storage/revocation/outbox and notification
  fixture test proof without token values. Verify legacy Apple fallback wording.
- [ ] Record AI permission grant/deny/withdraw behavior and the safety/reporting
  behavior of the configured production chat service with an approved test case.
  Reassess questionnaire answers from actual content safeguards; AI presence
  alone is not an automatic failure of the current 4+ age rating.
- [ ] Load localized monthly and annual prices and billed periods. Record a
  successful sandbox purchase for each plan, cancellation/error behavior, restore
  after relaunch/sign-in, and the resulting Premium access. Include proof from
  the tested signed candidate, not a Dart unit test or an API/catalog response.
  No sandbox purchase/restore is recorded as verified by these script changes.
- [ ] Confirm the Apple capture/revocation/notification/deletion health checks
  are positive, required encryption/signing secrets are configured server-side,
  migrations are applied, and the retry worker is scheduled. An HTTP 200 alone
  does not prove valid notification routing or Apple credential exchange.
- [ ] Open the saved privacy URL and inspect the served data/AI-sharing policy.
  Match App Privacy disclosures to actual collection, including bundled SDKs.
  Inspect the packaged privacy manifests/report. Apple's
  [privacy-manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
  requires data-collection information on all platforms but lists required-reason
  API declarations for iOS/iPadOS/tvOS/visionOS/watchOS. Do not block this macOS
  submission solely on an iOS-only required-reason rule. Still review Apple's
  [listed SDK manifest/signature requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
  and all actual upload diagnostics; this is not a blanket SDK exemption.
- [ ] Re-read the review notes against the tested candidate. Explain both
  network-server entitlement uses: Google callback on ephemeral IPv4 loopback
  and release-mode document handoff on loopback port 47683. Do not describe it
  as an externally reachable server or as required by native Apple sign-in.
- [ ] Confirm the selected candidate is the source build, not rejected 481, and
  that the draft retains the app plus all required group/monthly/annual review
  items. Confirm MANUAL release, then submit the first-subscription draft in App
  Store Connect and capture its actual review state. A release remains a later
  separate human action; no public download/update is changed by this handoff.
- [ ] Keep the current five screenshots and corrected ChessEver name unless a
  candidate-specific visual review finds a real mismatch. The five uploaded
  screenshots were visually confirmed correct during remediation; the audit
  cannot re-verify their pixels or independently prove those review assertions.

The production store provisioning profile is `WR4MCF5FY6`. Renew it when needed;
do not substitute the direct-download profile. Store certificates are separate
from Developer ID certificates. The protected environment contains:

- `MAC_APP_STORE_APPLICATION_P12_B64`
- `MAC_APP_STORE_INSTALLER_P12_B64`
- `MAC_APP_STORE_P12_PASSWORD`
- `APP_STORE_CONNECT_KEY_IDENTIFIER`, `APP_STORE_CONNECT_ISSUER_ID`,
  `APP_STORE_CONNECT_PRIVATE_KEY`

Only client-safe settings are written to the allowlisted temporary Dart config.
Signing material lives in an ephemeral runner keychain, is removed in `always()`
cleanup, and is never included in the installer artifact. Actions use full commit
pins, checkout does not persist credentials, and the GitHub token is read-only.
No pull-request or push event can invoke either production release workflow.

The Codemagic CLI tools are pinned open-source utilities running on GitHub
runners. Their use does not invoke the hosted Codemagic build service.

Every job has a time limit, so a stalled build fails instead of running for
three hours. The limits sit above the slowest successful release (23 October
2026), where macOS Intel took 63 minutes and the R2 publish steps took 23-30
minutes:

| Job | Job limit | Build step limit |
|---|---|---|
| macOS (Apple Silicon, Intel) | 90 min | 75 min (build, notarize and publish) |
| Windows | 75 min | 30 min |
| Linux | 60 min | 20 min |
| Mac App Store | 75 min | 45 min, then 30 min for upload and review |
| macOS on Flutter master | 60 min | 40 min |

Revisit the limits when release durations change. The review script waits at
most 10 minutes for Apple to process a build. Apple processing is external: a
timeout is a failed run, not proof of submission. A retry reuses a build that
was already uploaded.

### Public Apple catalog and review API verification

Verified on 2026-10-29 by downloading Apple's public OpenAPI archive directly
from the link in its [API documentation](https://developer.apple.com/documentation/appstoreconnectapi).
This establishes the published API contract. No authenticated production GET,
review write, upload, or subscription transaction was performed for this check.
The parent operator separately reported a successful read-only live probe on
2026-10-29: the expected production app/bundle and ChessEver name, one group,
the expected monthly/annual parent subscriptions in `READY_TO_SUBMIT`, and one
resource from the group's `/versions` endpoint. This is operator-provided live
evidence; the public-spec verifier itself makes no authenticated requests.

| Evidence | Value |
| --- | --- |
| Official archive | [Apple OpenAPI ZIP](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip) |
| API version in archive | `4.5.1` |
| HTTP Last-Modified | `Tue, 06 Oct 2026 17:01:38 GMT` |
| Archive SHA-256 | `7b826ae9ca3e45b0e7df2643cbb811c9930632640944db11a8af4586fab9db46` |
| Extracted file | `openapi.oas.json` |
| JSON SHA-256 | `7518d3a94a8bd701ac25c1c601b95b8f53aad92091affb15a2a9d331713dac1a` |

Run `python3 scripts/ci/verify_apple_asc_contract.py` to download and verify the
current official archive again. To validate a separately downloaded copy, pass
`--spec /path/to/openapi.oas.json`. The checker validates the operations, response
schemas, sparse fields, linkage types, required request members, and state and
revision types used by this preflight. It reports the downloaded content hash.
It also checks the remaining audit GET parameters and validates the preparation
PATCH/POST payload shapes and MANUAL hold against their published request
schemas without executing them. Its source identity is read dynamically from
`pubspec.yaml`; the working source at this follow-up is `22.17.36+526`.
It is an explicit public-document verification tool; regular offline CI tests
and release preparation do not gain a dependency on this download being online.
To exercise the contract regression tests against that same real download, run
`APPLE_ASC_SPEC_PATH=/path/to/openapi.oas.json python3 -m unittest discover -s scripts/ci -p 'test_*.py'`.
Without the file those particular tests explicitly skip rather than replacing
the official schema with fixture data.

The following resources and relationships are public, not private web-client
endpoints. Apple introduced them in its
[API 4.4.1 release](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-4-1-release-notes),
and they remain in the downloaded 4.5.1 specification.

| Request | OpenAPI operationId | Response/resource contract |
| --- | --- | --- |
| `GET /v1/subscriptionGroups/{id}/versions` | `subscriptionGroups_versions_getToManyRelated` | `SubscriptionGroupVersionsResponse.data[]` contains `SubscriptionGroupVersion`, with `type=subscriptionGroupVersions` |
| `GET /v1/subscriptions/{id}/versions` | `subscriptions_versions_getToManyRelated` | `SubscriptionVersionsResponse.data[]` contains `SubscriptionVersion`, with `type=subscriptionVersions` |
| `POST /v1/reviewSubmissionItems` | `reviewSubmissionItems_createInstance` | Body is `ReviewSubmissionItemCreateRequest` |
| `GET /v1/reviewSubmissions/{id}/items` | `reviewSubmissions_items_getToManyRelated` | Supports both subscription version relationships in `fields[reviewSubmissionItems]` |

Use the subscription group ID returned by
`GET /v1/apps/{appId}/subscriptionGroups`; use subscription IDs from
`GET /v1/subscriptionGroups/{groupId}/subscriptions`. These are distinct from
the metadata version IDs returned by the `/versions` collections. Review items
reference the metadata version IDs, not the parent product/group IDs.

The group-version GET accepts
`fields[subscriptionGroupVersions]=version,state&limit=200`; the subscription
GET accepts `fields[subscriptionVersions]=version,state&limit=200`. The URL query
must be encoded normally. Each resource's `attributes.version` is an integer,
and `attributes.state` is an enum that includes `ACCEPTED` and `APPROVED` as
passed-review states. Both collections are paginated through `links.next`.
The preflight stops on pagination instead of silently ignoring later rows.

The corrected catalog chooses the highest numeric metadata revision, so an old
rejected revision does not compete with a newer draft or approved revision.
It accepts both passed-review states. An empty version collection means metadata
must first be prepared in App Store Connect; it is not evidence that the route
does not exist. Unexpected response types or duplicate current revisions stop
with an inspection error rather than inventing a review relationship.

The actual create-item body for a subscription group is:

```json
{
  "data": {
    "type": "reviewSubmissionItems",
    "relationships": {
      "reviewSubmission": {
        "data": { "type": "reviewSubmissions", "id": "EXISTING_DRAFT_ID" }
      },
      "subscriptionGroupVersion": {
        "data": { "type": "subscriptionGroupVersions", "id": "GROUP_METADATA_VERSION_ID" }
      }
    }
  }
}
```

For a monthly or annual item, replace `subscriptionGroupVersion` with
`subscriptionVersion`, its linkage type with `subscriptionVersions`, and its ID
with that plan's metadata version ID. The create schema requires `data.type`,
`data.relationships`, and `relationships.reviewSubmission`; every linkage
contains string `id` and its exact resource `type`. Each item carries one target.
Apple's [submission guide](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review)
shows these contracts and explicitly keeps the first-subscription submission
with the app binary in the App Store Connect UI. Existing review items remain
attached; the preparation path never removes them.

Before using the prepared draft in production, complete the plan-version and
review-item GETs and run the full read-only audit with the existing ASC API key.
Report HTTP status, returned resource types and counts only. Do not print the
JWT, issuer/key credentials, complete responses or private review data. An ASC
API key is a separate credential from the Sign in with Apple signing key.
401/403 indicates authorization failure, while a 404 needs inspection of both
the public path and resource ownership. Successful access to the group version
collection does not establish readiness of its metadata, the full review draft,
server endpoints, or the signed candidate's purchase/restore behavior.

If a live audit reports no draft while App Store Connect shows active review
items, stop preparation. A missing parsed app linkage must not trigger creation
of a competing draft. The preflight now checks unfiltered submissions before
treating platform-filtered absence as an empty review history, and blocks any
unclassified active submission. The parent subsequently confirmed the production
cause with GETs: the Mac-filtered submission is `UNRESOLVED_ISSUES` and has four
items (three `READY_FOR_REVIEW`, one `REJECTED`), but sparse item responses have
unexpanded relationships. Valid sparse-field names do not force relationship
`data` into the response.

`review_items()` now requests exactly
`include=appStoreVersion,subscriptionVersion,subscriptionGroupVersion`, the
combination confirmed by the parent's live GET. It sends no broad sparse-field
list or extra query options on that request. The published schema lists more
include values, but the live all-16-fields/all-16-includes combination returned
HTTP 400; schema validation alone does not establish that every combination is
accepted by the production service. Individual other types have not been shown
unsupported by that error. The parser may recognize the wider whitelist when
typed linkages are already present, but it does not request bulk expansion or
silently retry it. Each non-removed item must carry a recognized
typed target ID. Empty or links-only relationships after the included GET stop
preparation; they never mean there is no draft. Retention verification checks
both original item IDs and target references. Regression cases reproduce the
reported four-item sparse shape with anonymized identifiers and verify that,
after an operator resolves the submission, preparation retains all four items
without creating a new draft or duplicating the metadata items. The production
expanded GET and resulting full audit must still be verified by the parent;
offline cases do not replace that check. `UNRESOLVED_ISSUES` itself remains an
operator-resolution blocker, even when all four attachments are correctly found.
The parent then supplied an included-GET safe projection, confirming one app,
one group-metadata version and two subscription-metadata versions with typed
target IDs and null unused relationships. The derived regression fixture is
[`mac_app_store_review_item_shape.json`](../../scripts/ci/fixtures/mac_app_store_review_item_shape.json).
It replaces real IDs and explicitly records restoration of the standard JSON:API
envelopes around the flattened projection; it is not presented as an untouched
HTTP recording. Capture-based parsing and full offline audit replay both pass,
including true app/metadata attachment flags and preservation of all four item
IDs. Before any live mutation, the parent must still rerun the full GET-only
audit with the corrected included query and observe those two true flags in its
live report. The unresolved-issues state remains a separate blocker.

The parent can collect states and linkage IDs only with its existing credential
context using `python3 scripts/ci/mac_app_store_preflight.py --diagnose-review-links`.
For an API object already held in memory, call
`diagnose_review_links(api)` from the same module. This compares platform-filtered
and unfiltered submissions, `appStoreVersionForReview`, sparse item references,
and exactly `include=appStoreVersion,subscriptionVersion,subscriptionGroupVersion`.
It emits no review notes,
contact fields, tokens, URLs or credentials.
Use this actual field-presence evidence for the parser regression fixture before
changing the production association logic. The diagnostic itself performs GETs
only; no item is resolved, removed, submitted or created.

Do not substitute an invented aggregate group state: `SubscriptionGroup` has
`referenceName` plus relationships, while the parent `Subscription.state` has a
different lifecycle (for example `READY_TO_SUBMIT`). The metadata versions are
the public reviewable resources confirmed above. If a production probe reveals
a compatibility issue, preserve the existing draft and record the response code
for an explicit compatibility decision; do not catch every API error and report
the catalog ready.
