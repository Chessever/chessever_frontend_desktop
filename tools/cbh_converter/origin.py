"""Content-bound conversion provenance. Never replace a user's PGN."""
import hashlib
import json
import os
from pathlib import Path
import uuid


def origin_id(identity):
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def existing_copies(destination, identity, digest):
    found = []
    for manifest in sorted(destination.glob('*/conversion.json')):
        try:
            if manifest.is_symlink() or manifest.parent.is_symlink():
                continue
            saved = json.loads(manifest.read_text(encoding='utf8'))
            if not isinstance(saved, dict) or saved.get('sourceSha256') != identity:
                continue
            name = saved.get('pgnFile', 'database.pgn')
            if not isinstance(name, str) or Path(name).name != name or not name.lower().endswith('.pgn'):
                continue
            pgn = manifest.parent / name
            if pgn.is_symlink():
                continue
            if not pgn.is_file():
                aliases = saved.get('pgnAliases', [])
                if not isinstance(aliases, list):
                    continue
                alias_matches = [manifest.parent / n for n in aliases
                                 if isinstance(n, str) and Path(n).name == n and n.lower().endswith('.pgn')
                                 and not (manifest.parent / n).is_symlink() and (manifest.parent / n).is_file()]
                # A renamed untouched copy is identifiable without guessing a
                # filename. Ambiguous matches require fresh conversion instead.
                matches = alias_matches or [f for f in manifest.parent.glob('*.pgn')
                                            if not f.is_symlink() and digest(f) == saved.get('pgnSha256')]
                if len(matches) != 1:
                    continue
                pgn = matches[0]
                saved['pgnFile'] = pgn.name
                temporary = manifest.with_name('.conversion-' + uuid.uuid4().hex + '.tmp')
                try:
                    with temporary.open('x', encoding='utf8') as stream:
                        json.dump(saved, stream, indent=2)
                        stream.flush()
                        os.fsync(stream.fileno())
                    os.replace(temporary, manifest)
                finally:
                    temporary.unlink(missing_ok=True)
            found.append((pgn, saved, digest(pgn) != saved.get('pgnSha256')))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return found
