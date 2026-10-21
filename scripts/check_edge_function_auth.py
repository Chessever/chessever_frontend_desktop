#!/usr/bin/env python3
"""Read-only production gateway/auth probes. Never print configuration values."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

PROJECT = 'oelbsuggrzyqwzmvidju'
EXPECTED = {
    'stripe-webhook', 'revenuecat-webhook', 'revenuecat-sync',
    'onesignal-dispatch', 'github-webhook', 'fetch-fide-photo-webp',
    'fetch-lichess-annotations', 'stripe-checkout', 'stripe-portal',
    'entitlement', 'prep-games-check', 'gamebase-proxy',
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--public-config', type=Path)
    args = parser.parse_args()
    config = {k: os.environ.get(k, '') for k in ('SUPABASE_URL', 'SUPABASE_ANON_KEY')}
    if args.public_config:
        for line in args.public_config.read_text().splitlines():
            match = re.match(r'(SUPABASE_URL|SUPABASE_ANON_KEY)\s*=\s*(.*)', line)
            if match:
                config[match[1]] = match[2].strip().strip('\"\'')
    if config['SUPABASE_URL'].rstrip('/') != f'https://{PROJECT}.supabase.co':
        raise SystemExit('Refusing to probe an unexpected project URL.')
    if not config['SUPABASE_ANON_KEY']:
        raise SystemExit('Public project key is required.')
    inventory = json.loads(subprocess.check_output([
        'supabase', 'functions', 'list', '--project-ref', PROJECT, '--output', 'json',
    ]))
    found = {f.get('slug', f.get('name')): f for f in inventory}
    if 'gamebase-proxy' not in found:
        raise SystemExit('Production proxy is not deployed.')
    wrong = [name for name in EXPECTED & found.keys() if found[name].get('verify_jwt') is not False]
    if wrong:
        raise SystemExit('Unexpected gateway JWT verification: ' + ', '.join(sorted(wrong)))
    print('Configured gateway flags match intent for', len(EXPECTED & found.keys()), 'functions.')
    base = f'https://{PROJECT}.supabase.co/functions/v1/gamebase-proxy'
    probes = [
        ('public read', '/api/player?pageSize=1&pageNumber=0', config['SUPABASE_ANON_KEY'], 200),
        ('missing client key', '/api/player?pageSize=1', '', 401),
        ('wrong client key', '/api/player?pageSize=1', 'invalid-audit-fixture', 401),
        ('staff route blocked', '/api/ingest/pgn-games', config['SUPABASE_ANON_KEY'], 403),
    ]
    for label, path, key, expected in probes:
        options = f'url = "{base}{path}"\n'
        if key:
            options += f'header = "apikey: {key}"\nheader = "Authorization: Bearer {key}"\n'
        result = subprocess.run([
            'curl', '--silent', '--max-time', '30', '--write-out', '\n%{http_code}',
            '--config', '-',
        ], input=options, text=True, capture_output=True, check=True)
        body, _, status = result.stdout.rpartition('\n')
        if status != str(expected) or 'UNAUTHORIZED_LEGACY_JWT' in body or 'UNAUTHORIZED_NO_AUTH_HEADER' in body:
            raise SystemExit(f'{label}: unexpected response {status}; body omitted.')
        print(f'{label}: {status}')


if __name__ == '__main__':
    main()
