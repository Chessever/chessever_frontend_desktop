"""Windows development CBH publisher. No source writes, no partial databases.

The only text profile currently supported is explicitly selected Windows-1252.
Native parsing is isolated in a bounded child process over a private snapshot.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

import chess.pgn
from adapter import make_game, tree
from preservation import guiding_game, encoded
from origin import origin_id, existing_copies

VERSION = 'chessever-cbh-5-multi-stage-controls'
EXTENSIONS = ('.cbh', '.cbp', '.cbt', '.cbc', '.cbs', '.cbg', '.cba')
MAX_BYTES = 512 * 1024 * 1024
MAX_GAMES = 100000


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_cancel(cancel):
    if cancel is not None and cancel.exists():
        raise InterruptedError('Conversion cancelled. No database was opened.')


def sources(source):
    if source.suffix.lower() != '.cbh':
        raise ValueError('Select the classic .cbh file, not a companion or CBV/2CBH archive.')
    entries = {p.name.lower(): p for p in source.parent.iterdir() if p.is_file()}
    files = [entries.get((source.stem + ext).lower()) for ext in EXTENSIONS]
    if any(p is None for p in files):
        raise ValueError('Missing companion files. Keep CBH/CBP/CBT/CBC/CBS/CBG/CBA together.')
    if any(p.is_symlink() for p in files):
        raise ValueError('Linked source files are not supported.')
    if sum(p.stat().st_size for p in files) > MAX_BYTES:
        raise ValueError('This converter supports databases up to 512 MiB.')
    return files


def fingerprints(files):
    return {ext: digest(file) for ext, file in zip(EXTENSIONS, files)}


def validate_snapshot(source):
    """Validate every referenced metadata record before unsafe native readers."""
    header = source.read_bytes()
    if len(header) < 46 or len(header) % 46:
        raise ValueError('Truncated CBH index.')
    if header[:3] not in (b'\x00\x00\x2c', b'\x00\x00\x24') or header[3:6] not in (b'\x00\x2e\x01', b'\x00\x2e\x05'):
        raise ValueError('Unsupported classic CBH signature.')
    count = len(header) // 46 - 1
    if int.from_bytes(header[6:10], 'big') != count + 1:
        raise ValueError('CBH declared record count does not match the physical index.')
    if count > MAX_GAMES:
        raise ValueError('This converter supports at most 100,000 records.')
    metadata = {}
    for ext, size in (('.cbp', 67), ('.cbt', 99), ('.cbc', 62), ('.cbs', 68)):
        data = source.with_suffix(ext).read_bytes()
        if len(data) < 28:
            raise ValueError('Truncated metadata header: ' + ext)
        start = 28 + data[24]
        if start > len(data):
            raise ValueError('Invalid metadata header: ' + ext)
        metadata[ext] = (data, start, size)
    for n in range(count):
        record = header[46 * (n + 1):46 * (n + 2)]
        if record[0] & 2:
            # Guiding entries have a different index schema, not player ids.
            read_guiding(source, record)
            continue
        for ext, offset in (('.cbp', 9), ('.cbp', 12), ('.cbt', 15), ('.cbc', 18), ('.cbs', 21)):
            index = int.from_bytes(record[offset:offset + 3], 'big')
            data, start, size = metadata[ext]
            if start + (index + 1) * size > len(data):
                raise ValueError(f'Record {n + 1}: invalid {ext} metadata reference.')
        packed = int.from_bytes(record[24:27], 'big')
        # Classic CBH also stores forfeits (4..6) and both-lost (7).
        # Preserve these explicitly below. Zero date components mean unknown.
        if ((packed >> 5) & 15) > 12 or record[27] not in range(8):
            raise ValueError(f'Record {n + 1}: unsupported date/result metadata.')
    return count


def read_guiding(source, record):
    if record[5:9] != bytes(4):
        raise ValueError('Guiding text with separate annotations is unsupported')
    path = source.with_suffix('.cbg')
    offset = int.from_bytes(record[1:5], 'big')
    if offset < 26 or offset > path.stat().st_size - 4:
        raise ValueError('Invalid guiding-text offset')
    with path.open('rb') as stream:
        stream.seek(offset)
        header = stream.read(4)
        size = int.from_bytes(header[1:4], 'big')
        if size < 4 or size > path.stat().st_size - offset:
            raise ValueError('Invalid guiding-text length')
        raw = header + stream.read(size - 4)
    return guiding_game(raw, record)


def annotation_frame(source, index_record, native_entries):
    offset = int.from_bytes(index_record[5:9], 'big')
    if not offset:
        if native_entries: raise ValueError('Unexpected native annotation inventory')
        return b''
    path = source.with_suffix('.cba')
    with path.open('rb') as stream:
        if offset < 26 or offset > path.stat().st_size - 14:
            raise ValueError('Invalid annotation offset')
        stream.seek(offset)
        header = stream.read(14)
        size = int.from_bytes(header[10:14], 'big')
        if size < 14 or size > path.stat().st_size - offset:
            raise ValueError('Invalid annotation length')
        raw = header + stream.read(size - 14)
    entries = []
    cursor = 14
    while cursor < len(raw):
        if cursor + 6 > len(raw): raise ValueError('Truncated annotation entry')
        length = int.from_bytes(raw[cursor + 4:cursor + 6], 'big')
        if length < 6 or length > len(raw) - cursor: raise ValueError('Invalid annotation entry length')
        entries.append(dict(move=int.from_bytes(raw[cursor:cursor + 3], 'big'),
                            type=raw[cursor + 3], payloadBytes=raw[cursor + 6:cursor + length].decode('latin1')))
        cursor += length
    if entries != native_entries:
        raise ValueError('Native annotation inventory does not match source bytes')
    return raw


def decode(probe, source, output, cancel):
    with output.with_suffix('.log').open('wb') as log:
        process = subprocess.Popen([str(probe), str(source), str(output)], stdout=log, stderr=log,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        deadline = time.monotonic() + 120
        try:
            while process.poll() is None:
                check_cancel(cancel)
                if time.monotonic() > deadline:
                    raise TimeoutError('Decoder exceeded the two-minute safety limit.')
                if output.exists() and output.stat().st_size > MAX_BYTES:
                    raise ValueError('Decoded content exceeds the safety limit.')
                time.sleep(.05)
            # Exit 3 means per-record failures, not a process/transport failure.
            # The publisher validates every ordinal and accepts only explicitly
            # decoded guiding records; any failed game still aborts publication.
            if process.returncode not in (0, 3):
                raise ValueError('A corrupt or unsupported record was found. No partial database was saved.')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()


def convert(source, destination, *, probe=None, cancel=None, progress=None,
            existing_copy='ask', selected_copy=None):
    source = Path(source).absolute()
    destination = Path(destination).absolute()
    cancel = Path(cancel) if cancel else None
    check_cancel(cancel)
    files = sources(source)
    identity = fingerprints(files)
    key = origin_id(identity)
    destination.mkdir(parents=True, exist_ok=True)
    if existing_copy not in ('ask', 'reuse', 'fresh'):
        raise ValueError('Invalid existing-copy choice.')
    if existing_copy != 'fresh':
        copies = existing_copies(destination, identity, digest)
        if selected_copy is not None:
            copies = [entry for entry in copies if entry[0] == Path(selected_copy).absolute()]
            if len(copies) != 1:
                raise ValueError('The selected converted copy is no longer available.')
        if copies:
            # Do not silently bypass an edited copy in favor of an untouched one.
            pgn, saved, edited = next((c for c in copies if c[2]), copies[0])
            check_cancel(cancel)
            if identity != fingerprints(files):
                raise ValueError('Source changed while checking the existing copy.')
            needs_choice = existing_copy == 'ask' and (edited or len(copies) > 1 or saved.get('version') != VERSION)
            return dict(path=str(pgn), games=saved['games'], reused=not needs_choice,
                        edited=edited, needsChoice=needs_choice,
                        preservation=saved.get('preservation', {}))
        if existing_copy == 'reuse':
            raise ValueError('No verified converted copy is available. Choose fresh conversion.')
    probe = Path(probe) if probe else Path(__file__).resolve().parent / 'cbh_decode.exe'
    with tempfile.TemporaryDirectory(prefix='.cbh-', dir=destination) as temporary:
        work = Path(temporary)
        snapshot = work / 'source'
        snapshot.mkdir()
        for ext, file in zip(EXTENSIONS, files):
            check_cancel(cancel)
            shutil.copyfile(file, snapshot / ('database' + ext))
        snapshot_source = snapshot / 'database.cbh'
        if identity != fingerprints([snapshot / ('database' + e) for e in EXTENSIONS]):
            raise ValueError('Source changed while copying. Try again after closing its writer.')
        count = validate_snapshot(snapshot_source)
        index_bytes = snapshot_source.read_bytes()
        decoded = work / 'decoded.jsonl'
        decode(probe, snapshot_source, decoded, cancel)
        publish = work / 'publish'
        publish.mkdir()
        pgn = publish / (source.stem + '.pgn')
        preservation = dict(guidingTextRecords=[], rawAnnotationRecords=0,
                            uninterpretedRecords=[], unattachedRecords=[])
        with decoded.open(encoding='utf8') as rows, pgn.open('x', encoding='utf8', newline='\n') as target:
            if json.loads(next(rows))['records'] != count:
                raise ValueError('Native record count does not match the source.')
            actual = 0
            for line in rows:
                check_cancel(cancel)
                row = json.loads(line)
                index_record = index_bytes[46 * (actual + 1):46 * (actual + 2)]
                if row['record'] != actual or len(index_record) != 46:
                    raise ValueError('Corrupt or out-of-order record.')
                guiding = bool(index_record[0] & 2)
                if guiding:
                    game = read_guiding(snapshot_source, index_record)
                    preservation['guidingTextRecords'].append(actual + 1)
                else:
                    if row['error']:
                        raise ValueError(f'Record {actual + 1}: native game decoding failed; nothing published.')
                    frame = annotation_frame(snapshot_source, index_record, row.get('rawAnnotations'))
                    game = make_game(row, row['chess960'], preserve_raw=True)
                    game.headers['ChessBaseIndex'] = encoded(index_record)
                    if frame:
                        game.headers['ChessBaseAnnotationFrame'] = encoded(frame)
                        preservation['rawAnnotationRecords'] += 1
                    if row.get('unsupportedAnnotations'):
                        preservation['uninterpretedRecords'].append(actual + 1)
                    if row.get('unconsumedAnnotations'):
                        preservation['unattachedRecords'].append(actual + 1)
                source_result = index_record[27]
                if not guiding and source_result > 3:
                    # CBUtil.decodeGameResult/GameResult in Yarin78/morphy
                    # define 4..6 as forfeit outcomes and 7 as both lost.
                    # PGN has no 0-0 result: keep it explicitly, never guess.
                    game.headers['Result'] = {4: '0-1', 5: '1/2-1/2', 6: '1-0', 7: '*'}[source_result]
                    game.headers['ChessBaseResultCode'] = str(source_result)
                    game.headers['ChessBaseResult'] = {4: '-:+', 5: '=:=', 6: '+:-', 7: '0-0'}[source_result]
                    if source_result in (4, 5, 6):
                        game.headers['Termination'] = 'forfeit'
                exported = game.accept(chess.pgn.StringExporter(headers=True, variations=True, comments=True))
                reparsed = chess.pgn.read_game(io.StringIO(exported))
                if reparsed is None or reparsed.errors or tree(game, True) != tree(reparsed, True) or dict(game.headers) != dict(reparsed.headers):
                    raise ValueError(f'Record {actual + 1}: PGN cannot preserve this content.')
                target.write(exported + '\n\n')
                actual += 1
                if progress:
                    progress(actual, count)
            if actual != count:
                raise ValueError('Incomplete decoder output.')
            target.flush()
            os.fsync(target.fileno())
        manifest = dict(version=VERSION, key=key, source=str(source), sourceSha256=identity,
                        games=count, pgnSha256=digest(pgn), pgnFile=pgn.name, encoding='windows-1252',
                        commentEncoding='utf8-if-valid-else-windows-1252', preservation=preservation)
        with (publish / 'conversion.json').open('x', encoding='utf8') as stream:
            json.dump(manifest, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        if identity != fingerprints(sources(source)):
            raise ValueError('Source changed during conversion. No database was saved.')
        check_cancel(cancel)
        # Unique directory + one same-volume rename commits PGN and receipt together.
        final = destination / (source.stem[:60] + '-' + uuid.uuid4().hex)
        publish.rename(final)
        return dict(path=str(final / pgn.name), games=count, reused=False, preservation=preservation)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--encoding', required=True, choices=['windows-1252'])
    parser.add_argument('--cancel-file')
    parser.add_argument('--existing-copy', choices=['ask', 'reuse', 'fresh'], default='ask')
    parser.add_argument('--selected-copy')
    args = parser.parse_args()
    try:
        result = convert(args.source, args.destination, cancel=args.cancel_file,
                         existing_copy=args.existing_copy, selected_copy=args.selected_copy,
                         progress=lambda done, total: print(json.dumps(dict(type='progress', done=done, total=total)), flush=True))
        print(json.dumps(dict(type='complete', **result)), flush=True)
        return 0
    except Exception as error:
        print(json.dumps(dict(type='error', message=str(error))), flush=True)
        return 2


if __name__ == '__main__':
    sys.exit(main())
