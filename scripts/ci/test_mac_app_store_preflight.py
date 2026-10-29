"""Offline regression tests: rejected 481 -> source 525, without live writes."""
import copy
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from app_store_review import ReviewError
from mac_app_store_preflight import (APP, BUNDLE, PRIVACY_URL, REVIEW_NOTES,
                                     audit, item_refs, prepare, require_checks,
                                     source_version, submit_mac, product_version,
                                     review_items, ITEM_RELATIONSHIPS, REVIEW_ITEM_INCLUDES)
from mac_app_store_release_gates import OPERATIONAL_CHECKS

VERSION = '22.17.35'
BUILD = '525'


def resource(kind, identifier, **attributes):
    return dict(type=kind, id=identifier, attributes=attributes)


def item(kind, target, identifier=None):
    return dict(type='reviewSubmissionItems', id=identifier or target['id'] + '-item',
                attributes={'state': 'READY_FOR_REVIEW'},
                relationships={kind: {'data': {'type': target['type'], 'id': target['id']}}})


class MacFixture:
    def __init__(self, approved=False):
        self.requests = []
        self.commands = []
        self.version = resource('appStoreVersions', 'version-id', versionString='22.15.1',
                                appStoreState='REJECTED', releaseType='MANUAL')
        self.old_build = resource('builds', 'old-build', version='481')
        self.build = resource('builds', 'source-build', version=BUILD, processingState='VALID',
                              expired=False)
        self.build['relationships'] = {'preReleaseVersion': {'data': {'id': 'prerelease'}}}
        self.version['relationships'] = {'build': {'data': {'type': 'builds', 'id': 'old-build'}}}
        self.detail = resource('appStoreReviewDetails', 'review-details',
                               contactFirstName='private-first', contactLastName='private-last',
                               contactEmail='private@example.test', contactPhone='private-phone',
                               notes='stale external browser instructions', demoAccountRequired=True,
                               demoAccountName='private-demo', demoAccountPassword='private-password')
        self.info = resource('appInfos', 'info-id', appStoreState='REJECTED')
        self.locales = [resource('appInfoLocalizations', 'info-en', locale='en-US',
                                name='ChessEver', subtitle='Follow live chess',
                                privacyPolicyUrl=PRIVACY_URL)]
        self.version_locales = [resource('appStoreVersionLocalizations', 'version-en', locale='en-US')]
        self.group = resource('subscriptionGroups', 'group')
        self.plans = [resource('subscriptions', 'monthly', productId='fixture.monthly',
                               subscriptionPeriod='ONE_MONTH'),
                      resource('subscriptions', 'annual', productId='fixture.annual',
                               subscriptionPeriod='ONE_YEAR')]
        status = 'APPROVED' if approved else 'PREPARE_FOR_SUBMISSION'
        self.metadata = {
            'group': resource('subscriptionGroupVersions', 'group-version', state=status, version=1),
            'monthly': resource('subscriptionVersions', 'monthly-version', state=status, version=1),
            'annual': resource('subscriptionVersions', 'annual-version', state=status, version=1),
        }
        self.draft = resource('reviewSubmissions', 'draft', state='READY_FOR_REVIEW', platform='MAC_OS')
        self.items = [item('appStoreVersion', self.version), {
            'id': 'existing-event', 'type': 'reviewSubmissionItems',
            'relationships': {'appEvent': {'data': {'id': 'event', 'type': 'appEvents'}}}}]
        self.uploaded = True
        self.screenshot_complete = True
        self.paginated = None
        self.unexpanded_shape = 'empty'
        self.force_unexpanded = False

    def get(self, path, **query):
        self.requests.append(('GET', path, copy.deepcopy(query)))
        if path == f'/v1/apps/{APP}':
            data = resource('apps', APP, bundleId=BUNDLE)
        elif path.endswith('/appStoreVersions'):
            data = [self.version]
        elif path == '/v1/builds':
            return dict(data=[copy.deepcopy(self.build)] if self.uploaded else [], included=[
                resource('preReleaseVersions', 'prerelease', version=VERSION, platform='MAC_OS')])
        elif path.endswith('/build'):
            data = self.build if self.version['relationships']['build']['data']['id'] == 'source-build' else self.old_build
        elif path.endswith('/appStoreReviewDetail'):
            data = self.detail
        elif path.endswith('/appInfos'):
            data = [self.info]
        elif path.endswith('/appInfoLocalizations'):
            data = self.locales
        elif path.endswith('/appStoreVersionLocalizations'):
            data = self.version_locales
        elif path.endswith('/subscriptionGroups'):
            data = [self.group]
        elif path.endswith('/subscriptions'):
            data = self.plans
        elif path.endswith('/appStoreReviewScreenshot'):
            data = resource('subscriptionAppStoreReviewScreenshots', 'screenshot',
                            assetDeliveryState={'state': 'COMPLETE' if self.screenshot_complete else 'FAILED'})
        elif path.endswith('/versions'):
            data = [self.metadata[path.split('/')[-2]]]
        elif path.endswith('/reviewSubmissions'):
            data = [self.draft] if self.draft else []
        elif path.endswith('/items'):
            data = copy.deepcopy(self.items)
            if not query.get('include') or self.force_unexpanded:
                for row in data:
                    if self.unexpanded_shape == 'links':
                        row['relationships'] = {kind: {'links': {
                            'related': 'https://api.appstoreconnect.apple.com/v1/fixture'}}
                            for kind in row.get('relationships', {}) if kind != 'reviewSubmission'}
                    else:
                        row['relationships'] = {}
        else:
            raise AssertionError(path)
        return dict(data=copy.deepcopy(data), links={'next': 'https://untrusted.test/' if path == self.paginated else None})

    def request(self, method, path, body=None):
        self.requests.append((method, path, copy.deepcopy(body)))
        if path == '/v1/appStoreVersions/' + self.version['id']:
            self.version['attributes'].update(body['data']['attributes'])
            if body['data'].get('relationships'):
                self.version['relationships'].update(copy.deepcopy(body['data']['relationships']))
        elif path == '/v1/appStoreReviewDetails/review-details':
            self.detail['attributes'].update(body['data']['attributes'])
        elif path == '/v1/appStoreVersionLocalizations/version-en':
            self.version_locales[0]['attributes'].update(body['data']['attributes'])
        elif path == '/v1/reviewSubmissions' and method == 'POST':
            self.draft = resource('reviewSubmissions', 'draft', platform='MAC_OS', state='READY_FOR_REVIEW')
            return {'data': copy.deepcopy(self.draft)}
        elif path == '/v1/reviewSubmissionItems':
            self.items.append(dict(id='new-item-' + str(len(self.items)), **copy.deepcopy(body['data'])))
        elif path == '/v1/reviewSubmissions/draft':
            assert body['data']['attributes'] == {'submitted': True}
            self.draft['attributes']['state'] = 'WAITING_FOR_REVIEW'
            self.version['attributes']['appStoreState'] = 'WAITING_FOR_REVIEW'
        else:
            raise AssertionError((method, path))
        return {}

    def publisher(self, args):
        self.commands.append(args)
        self.uploaded = True


class MacPreflightTest(unittest.TestCase):
    def setUp(self):
        self.api = MacFixture()
        self.notes = REVIEW_NOTES.read_text().strip()
        self.release_notes = Path(__file__).with_name('mac_app_store_release_notes.txt')
        health = patch('mac_app_store_preflight.endpoint_readiness', return_value={'apple_endpoints_ready': True})
        evidence = patch('mac_app_store_preflight.review_evidence', return_value={
            'fresh_signed_candidate_evidence': True, 'purchase_restore_evidence': True,
            'review_smoke_evidence': True, **{key: True for key in OPERATIONAL_CHECKS}})
        health.start()
        evidence.start()
        self.addCleanup(health.stop)
        self.addCleanup(evidence.stop)

    def ready(self):
        initial = audit(self.api, VERSION, BUILD)
        prepare(self.api, initial, VERSION, self.api.build, self.notes, self.release_notes)
        return audit(self.api, VERSION, BUILD)

    def run_flow(self, **kwargs):
        with redirect_stdout(io.StringIO()) as out:
            submit_mac(self.api, 'fixture.pkg', VERSION, BUILD, self.release_notes,
                       publisher=self.api.publisher, sleep=lambda _: self.fail('Unexpected wait'), **kwargs)
        return json.loads(out.getvalue().splitlines()[-1])

    def test_read_only_audit_detects_rejected_481_and_stale_notes(self):
        snapshot = audit(self.api, VERSION, BUILD)
        report = snapshot['report']
        self.assertEqual(report['selectedBuild'], '481')
        self.assertFalse(report['checks']['version_matches_source'])
        self.assertFalse(report['checks']['selected_build_matches_source'])
        self.assertFalse(report['checks']['review_notes_current'])
        self.assertFalse(report['checks']['subscription_review_items_attached'])
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))
        require_checks(snapshot, before_upload=True)
        with self.assertRaisesRegex(ReviewError, 'selected_build_matches_source'):
            require_checks(snapshot)
        serialized = json.dumps(report)
        for value in ('private-', PRIVACY_URL, 'stale external', 'fixture.monthly'):
            self.assertNotIn(value, serialized)
        self.assertFalse(report['sandboxPurchaseVerified'])

    def test_prepare_selects_source525_preserves_items_and_adds_group_first(self):
        original = copy.deepcopy(self.api.items)
        ready = self.ready()
        require_checks(ready)
        self.assertEqual(ready['report']['selectedBuild'], BUILD)
        self.assertEqual(self.api.version['attributes']['releaseType'], 'MANUAL')
        self.assertEqual(self.api.items[:len(original)], original)
        self.assertEqual(self.api.items[1]['id'], 'existing-event')
        self.assertEqual([next(kind for kind in item['relationships'] if kind != 'reviewSubmission')
                          for item in self.api.items[2:]],
                         ['subscriptionGroupVersion', 'subscriptionVersion', 'subscriptionVersion'])
        self.assertTrue(all(method != 'DELETE' for method, _, _ in self.api.requests))
        count = len(self.api.items)
        prepare(self.api, ready, VERSION, self.api.build, self.notes, self.release_notes)
        self.assertEqual(len(self.api.items), count)
        self.assertEqual(set(self.api.detail['attributes']) - {'notes'},
                         set(MacFixture().detail['attributes']) - {'notes'})

    def test_default_preparation_never_claims_first_subscription_submission(self):
        report = self.run_flow(prepare_only=True)
        self.assertEqual(report['result'], 'prepared_not_submitted')
        self.assertFalse(report['sandboxPurchaseVerified'])
        self.assertEqual(self.api.version['attributes']['versionString'], VERSION)
        self.assertFalse(self.api.commands)  # Existing source build was reused.
        with self.assertRaisesRegex(ReviewError, 'First subscription review is prepared, not submitted'):
            self.run_flow()
        self.assertFalse(any(path == '/v1/reviewSubmissions/draft' and method == 'PATCH'
                             for method, path, _ in self.api.requests))

    def test_upload_once_and_prepare_missing_draft(self):
        self.api.uploaded = False
        self.api.draft = None
        self.api.items = []
        report = self.run_flow(prepare_only=True)
        self.assertEqual(report['result'], 'prepared_not_submitted')
        self.assertEqual(len(self.api.commands), 1)
        self.assertNotIn('--app-store', self.api.commands[0])
        self.assertIn(('appStoreVersion', 'version-id'), item_refs(self.api.items))

    def test_existing_approved_catalog_can_submit_and_retry_read_only(self):
        self.api = MacFixture(approved=True)
        report = self.run_flow()
        self.assertEqual(report['result'], 'in_review')
        self.assertTrue(report['allSubscriptionMetadataApproved'])
        self.api.requests.clear()
        self.assertEqual(self.run_flow()['result'], 'already_in_review')
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_privacy_url_contact_demo_and_listing_name_block_before_upload(self):
        for mutate in (
            lambda api: api.locales[0]['attributes'].update(privacyPolicyUrl=None),
            lambda api: api.locales[0]['attributes'].update(privacyPolicyUrl='https://wrong.test'),
            lambda api: api.locales[0]['attributes'].update(name='ChessEver for Mac'),
            lambda api: api.detail['attributes'].update(contactPhone=''),
            lambda api: api.detail['attributes'].update(demoAccountPassword=''),
            lambda api: api.version['attributes'].update(releaseType='AFTER_APPROVAL'),
        ):
            self.api = MacFixture()
            mutate(self.api)
            with self.subTest(mutate=mutate), self.assertRaises(ReviewError):
                self.run_flow(prepare_only=True)
            self.assertFalse(self.api.commands)
            self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_not_ready_server_configuration_blocks_even_preparation(self):
        with patch('mac_app_store_preflight.endpoint_readiness', return_value={
                'apple_endpoint_apple_auth_tokens_ready': False}):
            with self.assertRaisesRegex(ReviewError, 'apple_endpoint_apple_auth_tokens_ready'):
                self.run_flow(prepare_only=True)
        self.assertFalse(self.api.commands)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_active_unclassified_items_never_fall_through_to_draft_creation(self):
        self.api.items = [self.api.items[1]]
        with self.assertRaisesRegex(ReviewError, 'new draft must not be created'):
            self.run_flow(prepare_only=True)
        self.assertFalse(self.api.commands)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_platform_filtered_absence_is_checked_against_unfiltered_active_submissions(self):
        original_get = self.api.get

        def get(path, **query):
            if path.endswith('/reviewSubmissions') and 'filter[platform]' in query:
                return {'data': []}
            return original_get(path, **query)

        self.api.draft['attributes']['platform'] = None
        with patch.object(self.api, 'get', side_effect=get):
            with self.assertRaisesRegex(ReviewError, 'GET-only review-link diagnostic'):
                self.run_flow(prepare_only=True)
        self.assertFalse(self.api.commands)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_live_four_item_sparse_payload_is_expanded_and_existing_unresolved_draft_is_found(self):
        # Anonymized production shape: three metadata items ready for review,
        # one rejected app item; sparse GET relationships are empty/links only.
        for shape in ('empty', 'links'):
            self.api = MacFixture()
            self.api.unexpanded_shape = shape
            self.api.draft['attributes']['state'] = 'UNRESOLVED_ISSUES'
            for row in self.api.metadata.values():
                row['attributes']['state'] = 'READY_FOR_REVIEW'
            self.api.items = [
                item('subscriptionGroupVersion', self.api.metadata['group']),
                item('subscriptionVersion', self.api.metadata['monthly']),
                item('subscriptionVersion', self.api.metadata['annual']),
                item('appStoreVersion', self.api.version),
            ]
            self.api.items[-1]['attributes']['state'] = 'REJECTED'
            path = '/v1/reviewSubmissions/draft/items'
            sparse = self.api.get(path, **{'fields[reviewSubmissionItems]': 'state'})['data']
            with self.subTest(shape=shape):
                self.assertEqual([row['attributes']['state'] for row in sparse],
                                 ['READY_FOR_REVIEW'] * 3 + ['REJECTED'])
                with self.assertRaisesRegex(ReviewError, 'not expanded'):
                    item_refs(sparse)
                snapshot = audit(self.api, VERSION, BUILD)
                self.assertTrue(snapshot['report']['checks']['review_draft_contains_app'])
                self.assertTrue(snapshot['report']['checks']['subscription_review_items_attached'])
                self.assertFalse(snapshot['report']['checks']['review_submission_state_actionable'])
                self.assertEqual(snapshot['draft']['id'], self.api.draft['id'])
                self.assertEqual(len(snapshot['items']), 4)
                with self.assertRaises(ReviewError):
                    self.run_flow(prepare_only=True)
                self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

                # Only simulate the operator resolving the rejected submission.
                # Preparation must then retain all four item IDs and references.
                self.api.draft['attributes']['state'] = 'READY_FOR_REVIEW'
                original_ids = {row['id'] for row in self.api.items}
                original_refs = item_refs(self.api.items)
                self.run_flow(prepare_only=True)
                self.assertEqual({row['id'] for row in self.api.items}, original_ids)
                self.assertEqual(item_refs(self.api.items), original_refs)
                self.assertFalse(any(method == 'POST' for method, _, _ in self.api.requests))
                self.assertFalse(any(method == 'DELETE' for method, _, _ in self.api.requests))
                includes = [body['include'] for method, path, body in self.api.requests
                            if method == 'GET' and path.endswith('/items') and body.get('include')]
                self.assertTrue(includes)
                self.assertTrue(all(value == ','.join(REVIEW_ITEM_INCLUDES) for value in includes))

    def test_live_bulk_include_400_does_not_recur_with_the_verified_three_relationship_query(self):
        original_get = self.api.get

        def get(path, **query):
            # Reproduce the exact rejected request combination reported live.
            if (path.endswith('/items') and query.get('include') == ','.join(ITEM_RELATIONSHIPS)
                    and query.get('fields[reviewSubmissionItems]') == 'state,' + ','.join(ITEM_RELATIONSHIPS)):
                raise ReviewError('App Store API GET failed (HTTP 400).')
            return original_get(path, **query)

        with patch.object(self.api, 'get', side_effect=get):
            with self.assertRaisesRegex(ReviewError, 'HTTP 400'):
                self.api.get('/v1/reviewSubmissions/draft/items', **{
                    'limit': 200, 'include': ','.join(ITEM_RELATIONSHIPS),
                    'fields[reviewSubmissionItems]': 'state,' + ','.join(ITEM_RELATIONSHIPS)})
            rows = review_items(self.api, self.api.draft['id'])
        self.assertEqual(rows, self.api.items)
        self.assertEqual(self.api.requests[-1][2], {
            'include': 'appStoreVersion,subscriptionVersion,subscriptionGroupVersion'})
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_each_operational_proof_gate_blocks_final_submission_before_any_mutation(self):
        for missing in OPERATIONAL_CHECKS:
            self.api = MacFixture(approved=True)
            checks = {'fresh_signed_candidate_evidence': True, 'purchase_restore_evidence': True,
                      'review_smoke_evidence': True, **{key: True for key in OPERATIONAL_CHECKS}}
            checks[missing] = False
            with self.subTest(missing=missing), patch(
                    'mac_app_store_preflight.review_evidence', return_value=checks):
                with self.assertRaisesRegex(ReviewError, missing):
                    self.run_flow()
            self.assertFalse(self.api.commands)
            self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_relationships_unexpanded_even_with_include_stop_before_any_mutation(self):
        self.api.force_unexpanded = True
        with self.assertRaisesRegex(ReviewError, 'not expanded despite include'):
            self.run_flow(prepare_only=True)
        self.assertFalse(self.api.commands)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_captured_expanded_payload_with_null_relationships_matches_and_preserves_all_four_items(self):
        shape = json.loads(Path(__file__).with_name('fixtures').joinpath(
            'mac_app_store_review_item_shape.json').read_text())
        rows = shape['expanded']['data']
        self.api.items = copy.deepcopy(rows)
        self.api.draft['attributes']['state'] = 'UNRESOLVED_ISSUES'
        self.api.version['id'] = rows[3]['relationships']['appStoreVersion']['data']['id']
        for name, index, role in (
                ('group', 0, 'subscriptionGroupVersion'),
                ('monthly', 1, 'subscriptionVersion'),
                ('annual', 2, 'subscriptionVersion')):
            # These are test-catalog aliases. The safe capture proves the two
            # subscription version refs, not which product period each uses.
            self.api.metadata[name]['id'] = rows[index]['relationships'][role]['data']['id']
            self.api.metadata[name]['attributes']['state'] = 'READY_FOR_REVIEW'
        sparse = self.api.get('/v1/reviewSubmissions/draft/items', **{
            'fields[reviewSubmissionItems]': 'state'})
        self.assertEqual(sparse['data'], shape['unexpanded']['data'])
        with self.assertRaisesRegex(ReviewError, 'not expanded'):
            item_refs(sparse['data'])
        expanded = review_items(self.api, self.api.draft['id'])
        self.assertEqual(expanded, rows)
        self.assertEqual(len(item_refs(expanded)), 4)

        snapshot = audit(self.api, VERSION, BUILD)
        self.assertTrue(snapshot['report']['checks']['review_draft_contains_app'])
        self.assertTrue(snapshot['report']['checks']['subscription_review_items_attached'])
        self.assertFalse(snapshot['report']['checks']['review_submission_state_actionable'])
        self.assertEqual(snapshot['draft']['id'], self.api.draft['id'])
        with self.assertRaisesRegex(ReviewError, 'Resolve the rejected submission'):
            prepare(self.api, snapshot, VERSION, self.api.build, self.notes, self.release_notes)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

        self.api.draft['attributes']['state'] = 'READY_FOR_REVIEW'
        report = self.run_flow(prepare_only=True)
        self.assertEqual(report['result'], 'prepared_not_submitted')
        self.assertEqual(self.api.items, rows)
        self.assertFalse(any(method in ('POST', 'DELETE') for method, _, _ in self.api.requests))

    def test_removed_item_without_a_target_is_not_an_active_attachment(self):
        rows = [item('appStoreVersion', self.api.version),
                resource('reviewSubmissionItems', 'removed', state='REMOVED')]
        self.assertEqual(item_refs(rows), {('appStoreVersion', self.api.version['id'])})

    def test_purchase_evidence_is_required_for_submission_but_preparation_reports_it_missing(self):
        with patch('mac_app_store_preflight.review_evidence', return_value={
                'fresh_signed_candidate_evidence': False, 'purchase_restore_evidence': False,
                'review_smoke_evidence': False}):
            report = self.run_flow(prepare_only=True)
            self.assertFalse(report['checks']['purchase_restore_evidence'])
            with self.assertRaisesRegex(ReviewError, 'fresh_signed_candidate_evidence'):
                self.run_flow()

    def test_missing_catalog_screenshot_and_pagination_fail_closed(self):
        for mutate in (
            lambda api: api.plans.pop(),
            lambda api: setattr(api, 'screenshot_complete', False),
            lambda api: setattr(api, 'paginated', f'/v1/apps/{APP}/subscriptionGroups'),
        ):
            self.api = MacFixture()
            mutate(self.api)
            with self.subTest(mutate=mutate), self.assertRaises(ReviewError):
                self.run_flow(prepare_only=True)
            self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_active_review_and_newer_build_cannot_be_replaced_implicitly(self):
        self.api.version['attributes']['appStoreState'] = 'WAITING_FOR_REVIEW'
        with self.assertRaisesRegex(ReviewError, 'explicit replacement'):
            self.run_flow(prepare_only=True)
        self.api = MacFixture()
        self.api.old_build['attributes']['version'] = '999'
        with self.assertRaisesRegex(ReviewError, 'source_build_not_older'):
            self.run_flow(prepare_only=True)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_unresolved_draft_and_unattached_active_items_are_preserved(self):
        for mutate in (
            lambda api: api.draft['attributes'].update(state='UNRESOLVED_ISSUES'),
            lambda api: api.metadata['monthly']['attributes'].update(state='WAITING_FOR_REVIEW'),
        ):
            self.api = MacFixture()
            mutate(self.api)
            snapshot = audit(self.api, VERSION, BUILD)
            with self.subTest(mutate=mutate), self.assertRaises(ReviewError):
                prepare(self.api, snapshot, VERSION, self.api.build, self.notes, self.release_notes)
            self.assertTrue(all(method == 'GET' for method, _, _ in self.api.requests))

    def test_source_version_is_read_from_source_not_the_rejected_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'pubspec.yaml'
            path.write_text('name: fixture\nversion: 30.2.9+901\n')
            self.assertEqual(source_version(path), ('30.2.9', '901'))
            path.write_text('version: invalid\n')
            with self.assertRaises(ReviewError):
                source_version(path)

    def test_metadata_history_uses_numeric_current_revision_and_accepts_passed_review(self):
        path = '/v1/subscriptions/monthly/versions'
        for state in ('ACCEPTED', 'APPROVED', 'PREPARE_FOR_SUBMISSION'):
            current = resource('subscriptionVersions', 'current', version=3, state=state)
            rows = [resource('subscriptionVersions', 'rejected-history', version=1, state='REJECTED'),
                    current,
                    resource('subscriptionVersions', 'replaced-history', version=2,
                             state='REPLACED_WITH_NEW_VERSION')]
            with self.subTest(state=state), patch.object(self.api, 'get', return_value={'data': rows}) as get:
                result, passed = product_version(self.api, path)
                self.assertEqual(passed, state in ('ACCEPTED', 'APPROVED'))
                self.assertEqual(result, None if passed else current)
                self.assertEqual(get.call_args.kwargs['fields[subscriptionVersions]'], 'version,state')

    def test_metadata_contract_rejects_ambiguous_revisions_and_wrong_resource_type(self):
        for rows in ([resource('subscriptions', 'wrong-type', version=1, state='APPROVED')],
                     [resource('subscriptionVersions', 'no-revision', state='APPROVED')],
                     [resource('subscriptionVersions', 'first', version=2, state='READY_FOR_REVIEW'),
                      resource('subscriptionVersions', 'duplicate', version=2, state='PREPARE_FOR_SUBMISSION')]):
            with self.subTest(rows=rows), patch.object(self.api, 'get', return_value={'data': rows}):
                with self.assertRaises(ReviewError):
                    product_version(self.api, '/v1/subscriptions/monthly/versions')


if __name__ == '__main__':
    unittest.main()
