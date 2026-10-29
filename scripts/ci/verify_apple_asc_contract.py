"""Validate the catalog/review contracts against Apple's public OpenAPI file.

Default: fetch Apple's official public archive, without credentials. --spec can
check an independently downloaded JSON file. This is an explicit verification
tool, not a network dependency of every release build or offline unit test.
It does not call the authenticated ASC API or prove tenant-specific readiness.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

from mac_app_store_preflight import (ITEM_RELATIONSHIPS, ITEM_RESOURCE_TYPES,
                                     PASSED_METADATA_STATES, REVIEW_ITEM_INCLUDES, source_version)

SPEC_URL = ('https://developer.apple.com/sample-code/app-store-connect/'
            'app-store-connect-openapi-specification.zip')


class ContractError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def validate(spec, schema, value, location):
    """Check the subset of OpenAPI used by this script's explicit requests."""
    if '$ref' in schema:
        require(schema['$ref'].startswith('#/components/schemas/'), location + ' external schema')
        schema = {**spec['components']['schemas'][schema['$ref'].split('/')[-1]],
                  **{key: val for key, val in schema.items() if key != '$ref'}}
    if value is None and schema.get('nullable'):
        return
    if 'enum' in schema:
        require(value in schema['enum'], location + ' enum changed')
    kind = schema.get('type')
    if kind == 'object':
        require(isinstance(value, dict), location + ' expected object')
        require(set(schema.get('required', [])) <= value.keys(), location + ' required member missing')
        properties = schema.get('properties', {})
        for key, val in value.items():
            require(key in properties, location + '.' + key + ' is not declared')
            validate(spec, properties[key], val, location + '.' + key)
    elif kind == 'array':
        require(isinstance(value, list), location + ' expected array')
        for val in value:
            validate(spec, schema['items'], val, location + '[]')
    elif kind == 'string':
        require(isinstance(value, str), location + ' expected string')
    elif kind == 'integer':
        require(type(value) is int, location + ' expected integer')
        require(value <= schema.get('maximum', value), location + ' exceeds maximum')
    elif kind == 'boolean':
        require(type(value) is bool, location + ' expected boolean')


def verify_remaining_requests(spec):
    """Validate request shapes only. Never execute authenticated requests."""
    version, build = source_version()
    read_requests = (
        ('/v1/apps/{id}', {'fields[apps]': 'bundleId'}),
        ('/v1/apps/{id}/appStoreVersions', {
            'filter[platform]': 'MAC_OS', 'include': 'build', 'limit': 200,
            'fields[appStoreVersions]': 'versionString,appStoreState,appVersionState,releaseType,build',
            'fields[builds]': 'version'}),
        ('/v1/builds', {'filter[app]': '6824524785', 'filter[version]': build,
                        'include': 'preReleaseVersion', 'limit': 200,
                        'fields[builds]': 'version,processingState,expired,preReleaseVersion',
                        'fields[preReleaseVersions]': 'version,platform'}),
        ('/v1/appStoreVersions/{id}/build', {}),
        ('/v1/appStoreVersions/{id}/appStoreReviewDetail', {}),
        ('/v1/apps/{id}/appInfos', {'limit': 200}),
        ('/v1/appInfos/{id}/appInfoLocalizations', {'limit': 200}),
        ('/v1/appStoreVersions/{id}/appStoreVersionLocalizations', {'limit': 200}),
        ('/v1/apps/{id}/subscriptionGroups', {'limit': 200}),
        ('/v1/subscriptionGroups/{id}/subscriptions', {
            'limit': 200, 'fields[subscriptions]': 'subscriptionPeriod,state,productId'}),
        ('/v1/subscriptions/{id}/appStoreReviewScreenshot', {}),
        ('/v1/apps/{id}/reviewSubmissions', {'filter[platform]': 'MAC_OS', 'limit': 200}),
        ('/v1/apps/{id}/reviewSubmissions', {'limit': 200}),
        ('/v1/apps/{id}/reviewSubmissions', {
            'limit': 200, 'fields[reviewSubmissions]': 'platform,state,items,appStoreVersionForReview',
            'include': 'appStoreVersionForReview', 'fields[appStoreVersions]': 'versionString,platform'}),
        ('/v1/reviewSubmissions/{id}/items', {
            'include': ','.join(REVIEW_ITEM_INCLUDES)}),
        ('/v1/reviewSubmissions/{id}/items', {
            'limit': 200, 'fields[reviewSubmissionItems]': 'state,' + ','.join(ITEM_RELATIONSHIPS)}),
        ('/v1/appStoreVersions/{id}/appStoreVersionSubmission', {}),
        ('/v1/appStoreVersions/{id}', {}),
    )
    verified = []
    for path, query in read_requests:
        operation = spec['paths'][path]['get']
        params = {row['name']: row for row in operation.get('parameters', []) if row['in'] == 'query'}
        for key, value in query.items():
            require(key in params, path + ' query parameter not declared: ' + key)
            schema = params[key]['schema']
            validate(spec, schema, value.split(',') if schema.get('type') == 'array' else value,
                     path + '?' + key)
        verified.append({'method': 'GET', 'path': path, 'operationId': operation['operationId']})

    def linkage(kind, identifier):
        return {'data': {'type': kind, 'id': identifier}}

    mutations = [
        ('PATCH', '/v1/appStoreVersions/{id}', {
            'type': 'appStoreVersions', 'id': 'version-id',
            'attributes': {'versionString': version, 'releaseType': 'MANUAL'},
            'relationships': {'build': linkage('builds', 'build-id')}}),
        ('PATCH', '/v1/appStoreReviewDetails/{id}', {
            'type': 'appStoreReviewDetails', 'id': 'detail-id', 'attributes': {'notes': 'Review instructions'}}),
        ('PATCH', '/v1/appStoreVersionLocalizations/{id}', {
            'type': 'appStoreVersionLocalizations', 'id': 'locale-id', 'attributes': {'whatsNew': 'Release notes'}}),
        ('POST', '/v1/reviewSubmissions', {
            'type': 'reviewSubmissions', 'attributes': {'platform': 'MAC_OS'},
            'relationships': {'app': linkage('apps', '6824524785')}}),
        ('PATCH', '/v1/reviewSubmissions/{id}', {
            'type': 'reviewSubmissions', 'id': 'draft-id', 'attributes': {'submitted': True}}),
    ]
    for relation, kind in (('appStoreVersion', 'appStoreVersions'),
                            ('subscriptionGroupVersion', 'subscriptionGroupVersions'),
                            ('subscriptionVersion', 'subscriptionVersions')):
        mutations.append(('POST', '/v1/reviewSubmissionItems', {
            'type': 'reviewSubmissionItems', 'relationships': {
                'reviewSubmission': linkage('reviewSubmissions', 'draft-id'),
                relation: linkage(kind, 'target-id')}}))
    for method, path, data in mutations:
        operation = spec['paths'][path][method.lower()]
        schema = operation['requestBody']['content']['application/json']['schema']
        validate(spec, schema, {'data': data}, method + ' ' + path)
        verified.append({'method': method, 'path': path, 'operationId': operation['operationId'],
                         'payloadCheckedOnly': True})
    withdrawal = spec['paths']['/v1/appStoreVersionSubmissions/{id}']['delete']
    verified.append({'method': 'DELETE', 'path': '/v1/appStoreVersionSubmissions/{id}',
                     'operationId': withdrawal['operationId'], 'payloadCheckedOnly': True})
    return verified


def verify(spec):
    schemas = spec['components']['schemas']
    verified = []
    for parent, kind, schema in (
            ('subscriptionGroups', 'subscriptionGroupVersions', 'SubscriptionGroupVersion'),
            ('subscriptions', 'subscriptionVersions', 'SubscriptionVersion')):
        path = f'/v1/{parent}/{{id}}/versions'
        operation = spec['paths'][path]['get']
        response = operation['responses']['200']['content']['application/json']['schema']['$ref']
        require(response == f'#/components/schemas/{schema}sResponse', path + ' response changed')
        collection = schemas[schema + 'sResponse']['properties']['data']
        require(collection['type'] == 'array' and collection['items']['$ref'] ==
                '#/components/schemas/' + schema, path + ' collection changed')
        params = {row['name']: row for row in operation.get('parameters', [])}
        fields = params[f'fields[{kind}]']['schema']['items']['enum']
        require({'version', 'state'} <= set(fields), path + ' sparse fields changed')
        require(params['limit']['schema']['maximum'] >= 200, path + ' page limit changed')
        resource = schemas[schema]['properties']
        require(resource['type']['enum'] == [kind], schema + ' resource type changed')
        attrs = resource['attributes']['properties']
        require(attrs['version']['type'] == 'integer', schema + ' revision type changed')
        require(PASSED_METADATA_STATES <= set(attrs['state']['enum']), schema + ' state contract changed')
        verified.append({'method': 'GET', 'path': path, 'operationId': operation['operationId'],
                         'resourceType': kind, 'response': schema + 'sResponse'})

    operation = spec['paths']['/v1/reviewSubmissionItems']['post']
    body = operation['requestBody']['content']['application/json']['schema']['$ref']
    require(body == '#/components/schemas/ReviewSubmissionItemCreateRequest', 'Create-item body changed')
    data = schemas['ReviewSubmissionItemCreateRequest']['properties']['data']
    require({'type', 'relationships'} <= set(data['required']), 'Create-item required data changed')
    require(data['properties']['type']['enum'] == ['reviewSubmissionItems'], 'Create-item type changed')
    relationships = data['properties']['relationships']
    require('reviewSubmission' in relationships['required'], 'Review submission relationship is not required')
    for relation, target in (('reviewSubmission', 'reviewSubmissions'),
                             ('subscriptionVersion', 'subscriptionVersions'),
                             ('subscriptionGroupVersion', 'subscriptionGroupVersions')):
        linkage = relationships['properties'][relation]['properties']['data']
        require({'id', 'type'} <= set(linkage['required']), relation + ' linkage changed')
        require(linkage['properties']['type']['enum'] == [target], relation + ' resource type changed')
        require(linkage['properties']['id']['type'] == 'string', relation + ' ID type changed')
        read_link = schemas['ReviewSubmissionItem']['properties']['relationships']['properties'][relation] if relation != 'reviewSubmission' else None
        if read_link:
            require(read_link['properties']['data']['properties']['type']['enum'] == [target],
                    relation + ' read linkage changed')
    verified.append({'method': 'POST', 'path': '/v1/reviewSubmissionItems',
                     'operationId': operation['operationId'], 'request': 'ReviewSubmissionItemCreateRequest'})
    read = spec['paths']['/v1/reviewSubmissions/{id}/items']['get']
    fields = next(row for row in read['parameters'] if row['name'] == 'fields[reviewSubmissionItems]')
    require(set(ITEM_RELATIONSHIPS) | {'state'} <= set(fields['schema']['items']['enum']),
            'Review-item sparse fields changed')
    includes = next(row for row in read['parameters'] if row['name'] == 'include')
    require(set(REVIEW_ITEM_INCLUDES) <= set(includes['schema']['items']['enum']),
            'Review-item include relationships changed')
    for relation, target in ITEM_RESOURCE_TYPES.items():
        schema = schemas['ReviewSubmissionItem']['properties']['relationships']['properties'][relation]
        require(schema['properties']['data']['properties']['type']['enum'] == [target],
                relation + ' review-item resource type changed')
    return verified + verify_remaining_requests(spec)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec', type=Path, help='Public openapi.oas.json downloaded from Apple')
    args = parser.parse_args()
    metadata = {'source': SPEC_URL, 'authenticatedApiProbed': False}
    if args.spec:
        raw = args.spec.read_bytes()
    else:
        with urllib.request.urlopen(SPEC_URL, timeout=40) as response:
            archive = response.read()
            metadata['lastModified'] = response.headers.get('Last-Modified')
        metadata['archiveSha256'] = hashlib.sha256(archive).hexdigest()
        with zipfile.ZipFile(io.BytesIO(archive)) as package:
            names = [name for name in package.namelist() if name.endswith('.json') and '__MACOSX' not in name]
            require(len(names) == 1, 'Unexpected official specification archive contents')
            raw = package.read(names[0])
    spec = json.loads(raw)
    version, build = source_version()
    metadata.update(sourceVersion=version, sourceBuild=build,
                    specVersion=spec['info']['version'], specSha256=hashlib.sha256(raw).hexdigest(),
                    contracts=verify(spec))
    print(json.dumps(metadata, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ContractError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        raise SystemExit('Apple public OpenAPI contract verification failed: ' + type(error).__name__) from None
