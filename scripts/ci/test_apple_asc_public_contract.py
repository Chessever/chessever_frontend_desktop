"""Opt-in checks against the real, independently downloaded Apple specification.

Set APPLE_ASC_SPEC_PATH to Apple's openapi.oas.json. Without it these tests
explicitly skip; fake resource fixtures are not substituted as API evidence.
"""
import copy
import json
import os
from pathlib import Path
import unittest

from verify_apple_asc_contract import ContractError, validate, verify


class ApplePublicContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = os.environ.get('APPLE_ASC_SPEC_PATH')
        if not path:
            raise unittest.SkipTest('Set APPLE_ASC_SPEC_PATH to an official Apple OpenAPI download.')
        cls.spec = json.loads(Path(path).read_text())

    def test_all_preflight_requests_and_preparation_payloads_match_the_public_spec(self):
        contracts = verify(self.spec)
        self.assertTrue(any(row['path'] == '/v1/subscriptionGroups/{id}/versions' for row in contracts))
        self.assertTrue(any(row['path'] == '/v1/subscriptions/{id}/versions' for row in contracts))
        self.assertTrue(any(row['path'] == '/v1/appStoreReviewDetails/{id}' for row in contracts))

    def test_a_missing_version_route_or_misspelled_relationship_cannot_pass(self):
        changed = copy.deepcopy(self.spec)
        del changed['paths']['/v1/subscriptionGroups/{id}/versions']
        with self.assertRaises(KeyError):
            verify(changed)
        changed = copy.deepcopy(self.spec)
        relationships = changed['components']['schemas']['ReviewSubmissionItemCreateRequest'][
            'properties']['data']['properties']['relationships']['properties']
        relationships['inventedSubscriptionVersion'] = relationships.pop('subscriptionVersion')
        with self.assertRaises(KeyError):
            verify(changed)

    def test_parent_subscription_id_type_is_rejected_for_a_metadata_version_item(self):
        schema = {'$ref': '#/components/schemas/ReviewSubmissionItemCreateRequest'}
        body = {'data': {'type': 'reviewSubmissionItems', 'relationships': {
            'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': 'draft-id'}},
            'subscriptionVersion': {'data': {'type': 'subscriptions', 'id': 'parent-id'}},
        }}}
        with self.assertRaises(ContractError):
            validate(self.spec, schema, body, 'POST /v1/reviewSubmissionItems')
        body['data']['relationships']['subscriptionVersion']['data']['type'] = 'subscriptionVersions'
        validate(self.spec, schema, body, 'POST /v1/reviewSubmissionItems')


if __name__ == '__main__':
    unittest.main()
