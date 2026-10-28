"""Exercise the installed package over every externally supplied fixture.

Usage: python verify_package.py HELPER_EXE FIXTURE_ROOT OUTPUT_ROOT
Never imports the implementation or uses a development Python at runtime.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    helper, fixtures, output = map(lambda v: Path(v).resolve(), sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    before = hashes(fixtures)
    rejected = {'Chess960Corrupt', 'NormalNoPop', 'UnusualStart'}
    report = []
    for source in sorted(fixtures.rglob('*.cbh')):
        destination = output / source.parent.name
        process = subprocess.run([str(helper), '--source', str(source), '--destination', str(destination),
                                  '--encoding', 'windows-1252'], capture_output=True, text=True, timeout=180)
        final = json.loads(process.stdout.splitlines()[-1])
        expected_reject = source.parent.name in rejected
        assert (process.returncode == 2) if expected_reject else (process.returncode == 0), final
        if expected_reject:
            assert not list(destination.rglob('*.pgn'))
        else:
            assert final['type'] == 'complete' and Path(final['path']).exists()
            receipt = json.loads((Path(final['path']).parent / 'conversion.json').read_text())
            assert receipt['pgnSha256'] == hashlib.sha256(Path(final['path']).read_bytes()).hexdigest()
        assert not list(destination.glob('.cbh-*'))
        report.append(dict(case=source.parent.name, exitCode=process.returncode, **final))
    assert len(report) == 10, 'Expected the complete evaluation corpus'
    assert before == hashes(fixtures), 'Source fixtures changed'
    result = dict(cases=report, generatedGames=sum(r.get('games', 0) for r in report),
                  sourceFilesUnchanged=True)
    (output / 'package-verification.json').write_text(json.dumps(result, indent=2), encoding='utf8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
