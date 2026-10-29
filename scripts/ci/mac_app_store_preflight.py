"""Read-only store audit and explicit preparation of a preserved review draft.

Only audit() is used by the standalone CLI; it never calls request() or the
publisher. Output contains check names/booleans, never review contacts, tokens,
demo credentials, URLs, notes, or publisher resource summaries.
"""
import argparse
import json
from pathlib import Path
import re
import time

from app_store_review import (AppleAPI, EDITABLE, REVIEWED, TARGETS, ReviewError,
                              attached_build, find_build, prepare_version,
                              publish, state, version_number, versions, wait_build)
from mac_app_store_release_gates import OPERATIONAL_CHECKS, endpoint_readiness, review_evidence

APP, BUNDLE, _ = TARGETS['MAC_OS']
ROOT = Path(__file__).resolve().parents[2]
REVIEW_NOTES = Path(__file__).with_name('mac_app_store_review_notes.txt')
PRIVACY_URL = 'https://chessever.com/privacy-policy'
ACTIVE_SUBMISSIONS = {'READY_FOR_REVIEW', 'UNRESOLVED_ISSUES', 'WAITING_FOR_REVIEW',
                      'IN_REVIEW', 'CANCELING', 'COMPLETING'}
EDITABLE_ITEMS = {'PREPARE_FOR_SUBMISSION', 'READY_FOR_REVIEW', 'DEVELOPER_REJECTED',
                  'REJECTED'}
PASSED_METADATA_STATES = {'ACCEPTED', 'APPROVED'}
ITEM_RELATIONSHIPS = (
    'appStoreVersion', 'appCustomProductPageVersion', 'appStoreVersionExperiment',
    'appStoreVersionExperimentV2', 'appEvent', 'appAssetLibraryImage',
    'appAssetLibraryVideo', 'backgroundAssetVersion', 'gameCenterAchievementVersion',
    'gameCenterActivityVersion', 'gameCenterChallengeVersion',
    'gameCenterLeaderboardSetVersion', 'gameCenterLeaderboardVersion',
    'inAppPurchaseVersion', 'subscriptionVersion', 'subscriptionGroupVersion',
)
ITEM_RESOURCE_TYPES = {kind: kind + 's' for kind in ITEM_RELATIONSHIPS}
ITEM_RESOURCE_TYPES['appStoreVersionExperimentV2'] = 'appStoreVersionExperiments'
# Live GET verified this exact combination. Apple's published include enum is
# broader, but requesting every member together returned HTTP 400 in production.
REVIEW_ITEM_INCLUDES = ('appStoreVersion', 'subscriptionVersion', 'subscriptionGroupVersion')


def source_version(path=ROOT / 'pubspec.yaml'):
    match = re.search(r'^version:\s*(\d+(?:\.\d+){0,2})\+(\d+)\s*$',
                      path.read_text(), re.MULTILINE)
    if not match:
        raise ReviewError('Source version/build is missing or invalid.')
    return match.groups()


def listing(api, path, **query):
    response = api.get(path, **{'limit': 200, **query})
    return collection_rows(response)


def collection_rows(response):
    if response.get('links', {}).get('next'):
        # Fail closed rather than dropping a subscription or following a URL
        # returned in resource metadata with an Authorization header.
        raise ReviewError('Store audit requires inspection of a paginated resource.')
    if not isinstance(response.get('data'), list):
        raise ReviewError('Unexpected store audit collection.')
    return response['data']


def ref(row, relationship):
    return row.get('relationships', {}).get(relationship, {}).get('data') or {}


def item_refs(items):
    references = set()
    for item in items:
        if item.get('attributes', {}).get('state') == 'REMOVED':
            continue
        expanded = False
        for kind in ITEM_RELATIONSHIPS:
            data = ref(item, kind)
            if not data:
                continue
            if (not isinstance(data, dict) or data.get('type') != ITEM_RESOURCE_TYPES[kind]
                    or not isinstance(data.get('id'), str) or not data['id']):
                raise ReviewError('Unexpected review-item linkage contract; preparation stopped.')
            references.add((kind, data['id']))
            expanded = True
        if not expanded:
            # JSON:API sparse fields can return relationships={} or links only.
            # That is unknown attachment state, never evidence of an empty draft.
            raise ReviewError('Review-item references were not expanded despite include; '
                              'preparation stopped without creating or removing a draft.')
    return references


def review_items(api, identifier):
    response = api.get(f'/v1/reviewSubmissions/{identifier}/items', **{
        'include': ','.join(REVIEW_ITEM_INCLUDES),
    })
    return collection_rows(response)


def diagnose_review_links(api):
    """GET-only field-presence evidence, without notes, contacts or credentials.

    Compare the exact existing query with an unfiltered/included query before
    deciding which response shape the production parser must support.
    """
    app_versions = versions(api, APP, 'MAC_OS')
    query = {
        'limit': 200,
        'fields[reviewSubmissions]': 'platform,state,items,appStoreVersionForReview',
        'include': 'appStoreVersionForReview',
        'fields[appStoreVersions]': 'versionString,platform',
    }
    filtered = api.get(f'/v1/apps/{APP}/reviewSubmissions', **{
        **query, 'filter[platform]': 'MAC_OS'})
    unfiltered = api.get(f'/v1/apps/{APP}/reviewSubmissions', **query)

    def linkage(data):
        if isinstance(data, dict):
            return {key: data[key] for key in ('type', 'id') if key in data}
        if isinstance(data, list):
            return [linkage(row) for row in data]
        return None

    def item_summary(row):
        relationships = row.get('relationships', {})
        return {'id': row.get('id'), 'state': row.get('attributes', {}).get('state'),
                'relationships': {
                    kind: {'dataPresent': 'data' in relationships[kind],
                           'data': linkage(relationships[kind].get('data'))}
                    for kind in ITEM_RELATIONSHIPS if kind in relationships}}

    summaries = []
    for row in unfiltered.get('data', []):
        if row.get('attributes', {}).get('state') not in ACTIVE_SUBMISSIONS:
            continue
        identifier = row['id']
        sparse = api.get(f'/v1/reviewSubmissions/{identifier}/items', **{
            'limit': 200, 'fields[reviewSubmissionItems]': 'state,' + ','.join(ITEM_RELATIONSHIPS)})
        included = api.get(f'/v1/reviewSubmissions/{identifier}/items', **{
            'include': ','.join(REVIEW_ITEM_INCLUDES),
        })
        relationships = row.get('relationships', {})
        summaries.append({
            'id': identifier, 'state': row.get('attributes', {}).get('state'),
            'platform': row.get('attributes', {}).get('platform'),
            'appStoreVersionForReview': linkage(ref(row, 'appStoreVersionForReview')),
            'submissionItemIds': linkage(relationships.get('items', {}).get('data')),
            'sparseItems': [item_summary(item) for item in sparse.get('data', [])],
            'includedItems': [item_summary(item) for item in included.get('data', [])],
            'itemsHaveNextPage': bool(sparse.get('links', {}).get('next') or
                                      included.get('links', {}).get('next')),
        })
    return {
        'appVersions': [{'id': row['id'], 'version': row['attributes']['versionString'],
                         'state': state(row)} for row in app_versions],
        'filteredSubmissionIds': [row['id'] for row in filtered.get('data', [])],
        'unfilteredSubmissionIds': [row['id'] for row in unfiltered.get('data', [])],
        'submissionsHaveNextPage': bool(filtered.get('links', {}).get('next') or
                                       unfiltered.get('links', {}).get('next')),
        'activeSubmissions': summaries,
    }


def product_version(api, path):
    kind = 'subscriptionGroupVersions' if 'subscriptionGroups/' in path else 'subscriptionVersions'
    rows = listing(api, path, **{f'fields[{kind}]': 'version,state'})
    if not rows:
        raise ReviewError('Prepare subscription/group metadata versions in App Store Connect first.')
    for row in rows:
        attrs = row.get('attributes', {})
        revision = attrs.get('version')
        if (row.get('type') != kind or not isinstance(row.get('id'), str) or not row['id']
                or type(revision) is not int or attrs.get('state') not in EDITABLE_ITEMS |
                PASSED_METADATA_STATES | {'WAITING_FOR_REVIEW', 'IN_REVIEW', 'REPLACED_WITH_NEW_VERSION'}):
            raise ReviewError('Unexpected subscription metadata version contract; inspect the public API response.')
    # Version collections contain review history. Old rejected revisions must
    # not compete with the current draft or block a later approved revision.
    latest = max(row['attributes']['version'] for row in rows)
    current = [row for row in rows if row['attributes']['version'] == latest]
    if len(current) != 1:
        raise ReviewError('Ambiguous current subscription metadata version requires inspection.')
    current = current[0]
    if current['attributes']['state'] in PASSED_METADATA_STATES:
        return None, True
    if current['attributes']['state'] == 'REPLACED_WITH_NEW_VERSION':
        raise ReviewError('The current subscription metadata version was superseded; inspect the catalog.')
    return current, False


def catalog(api):
    groups = listing(api, f'/v1/apps/{APP}/subscriptionGroups')
    # This app has one Premium group with one monthly and one annual plan.
    # A future second group must be deliberately configured, never guessed.
    if len(groups) != 1:
        raise ReviewError('Expected one Premium subscription group; inspect the catalog.')
    group = groups[0]
    plans = listing(api, f'/v1/subscriptionGroups/{group["id"]}/subscriptions', **{
        'fields[subscriptions]': 'subscriptionPeriod,state,productId',
    })
    required = []
    metadata, approved = product_version(api, f'/v1/subscriptionGroups/{group["id"]}/versions')
    if not approved:
        required.append(('subscriptionGroupVersion', metadata))
    all_approved = approved
    for period in ('ONE_MONTH', 'ONE_YEAR'):
        matches = [row for row in plans if row['attributes'].get('subscriptionPeriod') == period]
        if len(matches) != 1:
            raise ReviewError('Expected one monthly and one annual subscription; inspect the catalog.')
        plan = matches[0]
        if not plan['attributes'].get('productId'):
            raise ReviewError('Subscription product identity is missing.')
        screenshot = api.get(f'/v1/subscriptions/{plan["id"]}/appStoreReviewScreenshot')['data']
        if not screenshot or screenshot.get('attributes', {}).get(
                'assetDeliveryState', {}).get('state') != 'COMPLETE':
            raise ReviewError('A subscription review screenshot is missing or unfinished.')
        metadata, approved = product_version(api, f'/v1/subscriptions/{plan["id"]}/versions')
        all_approved = all_approved and approved
        if not approved:
            required.append(('subscriptionVersion', metadata))
    return required, all_approved


def audit(api, version, number, notes=None, package=None):
    """Return private preparation context plus a deliberately public report."""
    version_number(version)
    if not re.fullmatch(r'\d+', number):
        raise ReviewError('Unexpected build number.')
    notes = REVIEW_NOTES.read_text().strip() if notes is None else notes.strip()
    if not notes:
        raise ReviewError('Reviewer notes template is empty.')
    app = api.get(f'/v1/apps/{APP}', **{'fields[apps]': 'bundleId'})['data']
    if app['id'] != APP or app['attributes']['bundleId'] != BUNDLE:
        raise ReviewError('Unexpected production App Store application.')
    rows = versions(api, APP, 'MAC_OS')
    outstanding = [row for row in rows if state(row) in EDITABLE | REVIEWED |
                   {'WAITING_FOR_EXPORT_COMPLIANCE'}]
    if len(outstanding) != 1:
        raise ReviewError('Expected one unreleased store version to preserve.')
    target = outstanding[0]
    identifier = target['id']
    checks = {}
    checks['source_not_older_than_store'] = (
        version_number(version) >= version_number(target['attributes']['versionString']))
    checks['manual_release_hold'] = target['attributes'].get('releaseType') == 'MANUAL'
    checks['version_matches_source'] = target['attributes']['versionString'] == version
    selected = api.get(f'/v1/appStoreVersions/{identifier}/build')['data']
    selected_number = (selected or {}).get('attributes', {}).get('version')
    if selected_number is not None and not re.fullmatch(r'\d+', selected_number):
        raise ReviewError('Unexpected selected build number.')
    checks['source_build_not_older_than_selected'] = (
        selected_number is None or int(number) >= int(selected_number))
    build = find_build(api, APP, 'MAC_OS', version, number)
    checks['candidate_build_valid'] = bool(build and not build['attributes'].get('expired')
                                          and build['attributes']['processingState'] == 'VALID')
    checks['selected_build_matches_source'] = bool(build and attached_build(target) == build['id'])
    detail = api.get(f'/v1/appStoreVersions/{identifier}/appStoreReviewDetail')['data']
    attrs = (detail or {}).get('attributes', {})
    checks['review_contact_complete'] = all(attrs.get(key) for key in (
        'contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone'))
    checks['review_demo_complete'] = not attrs.get('demoAccountRequired') or bool(
        attrs.get('demoAccountName') and attrs.get('demoAccountPassword'))
    checks['review_notes_current'] = (attrs.get('notes') or '').strip() == notes
    infos = listing(api, f'/v1/apps/{APP}/appInfos')
    editable_infos = [row for row in infos if state(row) in EDITABLE]
    if len(editable_infos) == 1:
        info = editable_infos[0]
    elif len(infos) == 1:
        info = infos[0]
    else:
        raise ReviewError('Cannot unambiguously identify the current app information.')
    locales = listing(api, f'/v1/appInfos/{info["id"]}/appInfoLocalizations')
    checks['privacy_url_current'] = bool(locales) and all(
        row['attributes'].get('privacyPolicyUrl') == PRIVACY_URL for row in locales)
    checks['listing_name_compliant'] = bool(locales) and all(
        row['attributes'].get('name') and not re.search(
            r'\bmac(?:os)?\b|\bapple\b',
            row['attributes']['name'] + ' ' + (row['attributes'].get('subtitle') or ''),
            re.IGNORECASE) for row in locales)
    localizations = listing(api, f'/v1/appStoreVersions/{identifier}/appStoreVersionLocalizations')
    checks['release_notes_locale_present'] = any(
        row['attributes'].get('locale') == 'en-US' for row in localizations)
    required, all_approved = catalog(api)
    drafts = listing(api, f'/v1/apps/{APP}/reviewSubmissions', **{'filter[platform]': 'MAC_OS'})
    candidates = []
    unmatched_active = []
    for draft in drafts:
        if draft['attributes']['state'] in ACTIVE_SUBMISSIONS:
            items = review_items(api, draft['id'])
            if ('appStoreVersion', identifier) in item_refs(items):
                candidates.append((draft, items))
            else:
                unmatched_active.append(draft)
    if len(candidates) > 1:
        raise ReviewError('Multiple submissions contain the store version; inspect them first.')
    if not candidates:
        # Platform is optional at submission creation. A platform-filtered
        # empty result is not proof that no active draft exists.
        unfiltered = listing(api, f'/v1/apps/{APP}/reviewSubmissions')
        active_unclassified = [row for row in unfiltered
                               if row.get('attributes', {}).get('state') in ACTIVE_SUBMISSIONS
                               and row.get('attributes', {}).get('platform') in (None, 'MAC_OS')]
        if unmatched_active or active_unclassified:
            raise ReviewError('An active review submission has no parsed target app linkage. '
                              'Run the GET-only review-link diagnostic; a new draft must not be created.')
    draft, items = candidates[0] if candidates else (None, [])
    checks['review_draft_contains_app'] = draft is not None
    checks['review_submission_state_actionable'] = not draft or draft['attributes']['state'] in {
        'READY_FOR_REVIEW', 'WAITING_FOR_REVIEW', 'IN_REVIEW'}
    required_refs = {(kind, row['id']) for kind, row in required}
    checks['subscription_review_items_attached'] = required_refs <= item_refs(items)
    checks.update(endpoint_readiness())
    checks.update(review_evidence(version, number, package))
    report = {'platform': 'MAC_OS', 'sourceVersion': version, 'sourceBuild': number,
              'selectedBuild': selected_number,
              'selectedVersion': target['attributes']['versionString'],
              'selectedState': state(target),
              'checks': checks, 'allSubscriptionMetadataApproved': all_approved,
              'sandboxPurchaseVerified': False}
    return dict(report=report, target=target, build=build, detail=detail, draft=draft,
                items=items, required=required, localizations=localizations)


PREPARABLE = {'version_matches_source', 'candidate_build_valid',
              'selected_build_matches_source', 'review_notes_current',
              'review_draft_contains_app', 'subscription_review_items_attached',
              'fresh_signed_candidate_evidence', 'purchase_restore_evidence', 'review_smoke_evidence'} | set(OPERATIONAL_CHECKS)
EVIDENCE_CHECKS = {'fresh_signed_candidate_evidence', 'purchase_restore_evidence', 'review_smoke_evidence'} | set(OPERATIONAL_CHECKS)


def require_checks(snapshot, before_upload=False, prepare_only=False):
    failures = [key for key, passed in snapshot['report']['checks'].items()
                if not passed and not (before_upload and key in PREPARABLE)
                and not (prepare_only and key in EVIDENCE_CHECKS)]
    if failures:
        raise ReviewError('Store preflight failed: ' + ', '.join(failures))


def prepare(api, snapshot, version, build, notes, release_notes):
    """Prepare only an editable slot. Preserve all existing review items."""
    target = snapshot['target']
    if state(target) not in EDITABLE:
        raise ReviewError('Store version must be editable before preparing its review.')
    if not snapshot['detail']:
        raise ReviewError('Prepare private review contact details in App Store Connect first.')
    draft = snapshot['draft']
    if draft and draft['attributes']['state'] != 'READY_FOR_REVIEW':
        raise ReviewError('Resolve the rejected submission in App Store Connect before preparing it.')
    existing = item_refs(snapshot['items'])
    missing = [(kind, row) for kind, row in snapshot['required'] if (kind, row['id']) not in existing]
    if any(row['attributes']['state'] not in EDITABLE_ITEMS for _, row in missing):
        raise ReviewError('Unattached subscription metadata is already under review; inspect it first.')
    identifier = target['id']
    api.request('PATCH', f'/v1/appStoreVersions/{identifier}', {'data': {
        'type': 'appStoreVersions', 'id': identifier,
        'attributes': {'versionString': version, 'releaseType': 'MANUAL'},
        'relationships': {'build': {'data': {'type': 'builds', 'id': build['id']}}},
    }})
    detail = snapshot['detail']['id']
    api.request('PATCH', f'/v1/appStoreReviewDetails/{detail}', {'data': {
        'type': 'appStoreReviewDetails', 'id': detail, 'attributes': {'notes': notes.strip()},
    }})
    for locale in snapshot['localizations']:
        if locale['attributes']['locale'] == 'en-US':
            api.request('PATCH', f'/v1/appStoreVersionLocalizations/{locale["id"]}', {'data': {
                'type': 'appStoreVersionLocalizations', 'id': locale['id'],
                'attributes': {'whatsNew': release_notes.read_text().strip()},
            }})
    if not draft:
        draft = api.request('POST', '/v1/reviewSubmissions', {'data': {
            'type': 'reviewSubmissions', 'attributes': {'platform': 'MAC_OS'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}},
        }})['data']
    required = [('appStoreVersion', {'id': identifier, 'type': 'appStoreVersions'})]
    # The group must precede the monthly and annual versions for first review.
    required += [(kind, row) for kind, row in snapshot['required']]
    for kind, row in required:
        if (kind, row['id']) not in existing:
            api.request('POST', '/v1/reviewSubmissionItems', {'data': {
                'type': 'reviewSubmissionItems', 'relationships': {
                    'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': draft['id']}},
                    kind: {'data': {'type': row['type'], 'id': row['id']}},
                },
            }})


def submit_mac(api, package, version, number, release_notes, replace=False,
               prepare_only=False, publisher=publish, sleep=time.sleep):
    notes = REVIEW_NOTES.read_text().strip()
    before = audit(api, version, number, notes, package)
    require_checks(before, before_upload=True)
    if not prepare_only:
        missing_evidence = [key for key in sorted(EVIDENCE_CHECKS)
                            if not before['report']['checks'].get(key)]
        if missing_evidence:
            raise ReviewError('Store preflight failed: ' + ', '.join(missing_evidence))
    target = before['target']
    if state(target) in REVIEWED and before['report']['checks']['selected_build_matches_source']:
        require_checks(before, prepare_only=prepare_only)
        print(json.dumps({**before['report'], 'result': 'already_in_review'}))
        return
    if state(target) not in EDITABLE and not replace:
        raise ReviewError('An unreleased version exists; explicit replacement is required.')
    if not before['build']:
        publisher(['publish', '--path', str(package)])
    build = wait_build(api, APP, 'MAC_OS', version, number, sleep)
    prepare_version(api, APP, 'MAC_OS', version, build, replace, sleep)
    current = audit(api, version, number, notes, package)
    prepare(api, current, version, build, notes, release_notes)
    ready = audit(api, version, number, notes, package)
    require_checks(ready, prepare_only=prepare_only)
    # Confirm that preparation never removed a previously attached item.
    if not item_refs(before['items']) <= item_refs(ready['items']):
        raise ReviewError('An existing review item was not preserved; submission stopped.')
    original_ids = {item['id'] for item in before['items']
                    if item.get('attributes', {}).get('state') != 'REMOVED'}
    retained_ids = {item['id'] for item in ready['items']
                    if item.get('attributes', {}).get('state') != 'REMOVED'}
    if not original_ids <= retained_ids:
        raise ReviewError('An existing review-item identity was not preserved; submission stopped.')
    if prepare_only:
        print(json.dumps({**ready['report'], 'result': 'prepared_not_submitted'}))
        return
    if not ready['report']['allSubscriptionMetadataApproved']:
        # Apple documents the first subscription submission through the ASC UI,
        # together with an app binary. Never claim API preparation submitted it.
        raise ReviewError('First subscription review is prepared, not submitted. '
                          'Submit the complete draft in App Store Connect with a MANUAL hold.')
    draft = ready['draft']
    api.request('PATCH', f'/v1/reviewSubmissions/{draft["id"]}', {'data': {
        'type': 'reviewSubmissions', 'id': draft['id'], 'attributes': {'submitted': True},
    }})
    for attempt in range(61):
        verified = audit(api, version, number, notes, package)
        require_checks(verified)
        if state(verified['target']) in REVIEWED:
            print(json.dumps({**verified['report'], 'result': 'in_review'}))
            return
        if attempt == 60:
            raise ReviewError('Could not verify review submission and attached items.')
        sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=['before-upload', 'ready'], default='ready')
    parser.add_argument('--package', type=Path, help='Exact signed package covered by smoke evidence')
    parser.add_argument('--diagnose-review-links', action='store_true',
                        help='GET-only submission/item state and linkage comparison')
    args = parser.parse_args()
    if args.diagnose_review_links:
        print(json.dumps(diagnose_review_links(AppleAPI()), sort_keys=True))
        return
    version, number = source_version()
    snapshot = audit(AppleAPI(), version, number, package=args.package)
    print(json.dumps(snapshot['report'], sort_keys=True))
    require_checks(snapshot, before_upload=args.phase == 'before-upload')


if __name__ == '__main__':
    try:
        main()
    except (ReviewError, OSError, ValueError, KeyError, TypeError):
        # Keep unexpected server payloads and local credential paths private too.
        raise SystemExit('Store audit failed; inspect check booleans or private configuration.') from None
