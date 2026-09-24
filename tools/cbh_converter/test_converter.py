"""Strict publisher tests; fixtures are explicit local developer inputs."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location('converter', ROOT / 'converter.py')

class PublisherTest(unittest.TestCase):
    def setUp(self):
        if not all(os.environ.get(key) and Path(os.environ[key]).is_file()
                   for key in ('CBH_TEST_FIXTURE', 'CBH_TEST_PROBE')):
            self.skipTest('Set CBH_TEST_FIXTURE and CBH_TEST_PROBE to local fixture/native decoder files')

    def test_undecodable_metadata_is_contextual_and_atomic(self):
        import converter
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext, file in zip(converter.EXTENSIONS, converter.sources(fixture)):
                shutil.copy2(file, root / ('sample' + ext))
            source = root / 'sample.cbh'
            index = bytearray(source.read_bytes()[:92])
            index[6:10] = (2).to_bytes(4, 'big')
            source.write_bytes(index)
            annotators = source.with_suffix('.cbc')
            data = bytearray(annotators.read_bytes())
            start = 28 + data[24] + int.from_bytes(index[64:67], 'big') * 62 + 9
            data[start:start + 45] = b'bad\x9d'.ljust(45, b'\0')
            annotators.write_bytes(data)
            before = converter.fingerprints(converter.sources(source))
            with self.assertRaisesRegex(ValueError, 'Record 1: Annotator:.*explicit source encoding'):
                converter.convert(source, root / 'out', probe=Path(os.environ['CBH_TEST_PROBE']))
            self.assertEqual(list((root / 'out').iterdir()), [])
            self.assertEqual(before, converter.fingerprints(converter.sources(source)))

    def test_unknown_comment_bytes_are_declared_in_publication(self):
        import base64
        import io
        import chess.pgn
        import converter
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext, file in zip(converter.EXTENSIONS, converter.sources(fixture)):
                shutil.copy2(file, root / ('sample' + ext))
            source = root / 'sample.cbh'
            index = bytearray(source.read_bytes()[:92])
            index[6:10] = (2).to_bytes(4, 'big')
            index[51:55] = (26).to_bytes(4, 'big')
            source.write_bytes(index)
            payload = b'\0\0\x81Against'
            entry = bytes(3) + b'\x82' + (6 + len(payload)).to_bytes(2, 'big') + payload
            frame = bytes(10) + (14 + len(entry)).to_bytes(4, 'big') + entry
            source.with_suffix('.cba').write_bytes(bytes(26) + frame)
            result = converter.convert(source, root / 'out', probe=Path(os.environ['CBH_TEST_PROBE']))
            self.assertEqual(result['preservation']['unknownTextByteRecords'], [1])
            self.assertEqual(result['preservation']['uninterpretedRecords'], [1])
            pgn = Path(result['path'])
            parsed = chess.pgn.read_game(io.StringIO(pgn.read_text(encoding='utf8')))
            self.assertIn('[ChessBase unknown byte 0x81]Against', str(parsed))
            self.assertEqual(base64.b64decode(parsed.headers['ChessBaseAnnotationFrame']), frame)
            receipt = json.loads((pgn.parent / 'conversion.json').read_text())
            self.assertEqual(receipt['preservation'], result['preservation'])
            self.assertIn('visible-undefined-byte-escapes', receipt['commentEncoding'])

    def test_exact_stems_and_legacy_receipts(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for stem in ['savio', 'Savio Games']:
                source_dir = root / stem
                source_dir.mkdir()
                for ext, file in zip(module.EXTENSIONS, module.sources(fixture)):
                    shutil.copy2(file, source_dir / (stem + ext))
                source = source_dir / (stem + '.cbh')
                output = source_dir / 'converted'
                first = module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']))
                pgn = Path(first['path'])
                self.assertEqual(pgn.name, stem + '.pgn')
                receipt = pgn.parent / 'conversion.json'
                saved = json.loads(receipt.read_text())
                self.assertEqual(saved.pop('pgnFile'), pgn.name)
                legacy = pgn.with_name('database.pgn')
                pgn.rename(legacy)
                receipt.write_text(json.dumps(saved))
                reused = module.convert(source, output)
                self.assertTrue(reused['reused'])
                self.assertEqual(Path(reused['path']), legacy)
                legacy.write_bytes(legacy.read_bytes() + b'\n{User edit}\n')
                edited = legacy.read_bytes()
                choice = module.convert(source, output)
                self.assertTrue(choice['needsChoice'])
                fresh = module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']), existing_copy='fresh')
                self.assertFalse(fresh['reused'])
                self.assertEqual(Path(fresh['path']).name, stem + '.pgn')
                self.assertEqual(legacy.read_bytes(), edited)

    def test_real_conversion_is_atomic_and_reuses_only_unchanged_copy(self):
        self.assertTrue((ROOT / 'converter.py').exists(), 'production converter missing')
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_dir = root / 'source'
            source_dir.mkdir()
            for file in fixture.parent.glob(fixture.stem + '.*'):
                if file.is_file():
                    shutil.copy2(file, source_dir / file.name)
            source = source_dir / fixture.name
            before = {p.name: p.read_bytes() for p in source_dir.iterdir()}
            output = root / 'durable'
            first = module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']))
            pgn = Path(first['path'])
            self.assertTrue(pgn.is_file())
            self.assertEqual(pgn.name, source.stem + '.pgn')
            self.assertGreater(first['games'], 0)
            second = module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']))
            self.assertEqual(first['path'], second['path'])
            self.assertTrue(second['reused'])
            pgn.write_text(pgn.read_text(encoding='utf8') + '\n{User edit}\n', encoding='utf8')
            edited = pgn.read_bytes()
            choice = module.convert(source, output)
            self.assertTrue(choice['needsChoice'])
            third = module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']), existing_copy='fresh')
            self.assertNotEqual(first['path'], third['path'])
            self.assertEqual(pgn.read_bytes(), edited)
            self.assertEqual(before, {p.name: p.read_bytes() for p in source_dir.iterdir()})
            self.assertFalse(list(output.glob('.cbh-*')))

    def test_metadata_and_cancellation_never_publish_partial_database(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            original = root / 'source'
            original.mkdir()
            for file in fixture.parent.glob(fixture.stem + '.*'):
                if file.is_file():
                    shutil.copy2(file, original / file.name)
            source = original / fixture.name
            output = root / 'durable'
            cancel = root / 'cancel'
            cancel.touch()
            with self.assertRaises(InterruptedError):
                module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']), cancel=cancel)
            self.assertFalse(output.exists())
            cancel.unlink()
            for ext in ('.cbp', '.cbt', '.cbc', '.cbs'):
                file = source.with_suffix(ext)
                content = file.read_bytes()
                file.write_bytes(content[:24])
                with self.assertRaisesRegex(ValueError, 'metadata'):
                    module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']))
                self.assertEqual(list(output.iterdir()), [])
                file.write_bytes(content)
            def cancel_after_record(done, total):
                cancel.touch()
            with self.assertRaises(InterruptedError):
                module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']), cancel=cancel, progress=cancel_after_record)
            self.assertEqual(list(output.iterdir()), [])
            cancel.unlink()
            def mutate_after_record(done, total):
                with source.with_suffix('.cbp').open('ab') as stream:
                    stream.write(b'x')
            with self.assertRaisesRegex(ValueError, 'Source changed'):
                module.convert(source, output, probe=Path(os.environ['CBH_TEST_PROBE']), progress=mutate_after_record)
            self.assertEqual(list(output.iterdir()), [])

    def test_whole_record_truncation_is_not_a_smaller_database(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for file in fixture.parent.glob(fixture.stem + '.*'):
                if file.is_file():
                    shutil.copy2(file, root / file.name)
            source = root / fixture.name
            source.write_bytes(source.read_bytes()[:-46])
            with self.assertRaisesRegex(ValueError, 'count'):
                module.validate_snapshot(source)

    def test_partial_dates_and_extended_results_preserve_source_metadata(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        import io
        import chess.pgn
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext, file in zip(module.EXTENSIONS, module.sources(fixture)):
                shutil.copy2(file, root / ('metadata' + ext))
            source = root / 'metadata.cbh'
            original = bytearray(source.read_bytes()[:92])
            original[6:10] = (2).to_bytes(4, 'big')
            # Includes the exact bytes behind the user's record-59 rejection.
            for date, result, expected in [
                (0x0fc74a, 5, '2019.10.10'),
                (0, 3, '????.??.??'),
                (1972 << 9, 4, '1972.??.??'),
                ((2026 << 9) | (9 << 5), 6, '2026.09.??'),
                ((2026 << 9) | (9 << 5) | 22, 7, '2026.09.22'),
            ]:
                with self.subTest(date=expected, result=result):
                    data = bytearray(original)
                    data[70:73] = date.to_bytes(3, 'big')
                    data[73] = result
                    source.write_bytes(data)
                    converted = module.convert(source, root / 'output', probe=Path(os.environ['CBH_TEST_PROBE']))
                    game = chess.pgn.read_game(io.StringIO(Path(converted['path']).read_text(encoding='utf8')))
                    self.assertEqual(converted['games'], 1)
                    self.assertEqual(game.headers['Date'], expected)
                    self.assertEqual(game.headers['Result'], {3: '*', 4: '0-1', 5: '1/2-1/2', 6: '1-0', 7: '*'}[result])
                    self.assertEqual(game.headers.get('ChessBaseResultCode'), str(result) if result > 3 else None)
                    self.assertEqual(game.headers.get('ChessBaseResult'), {4: '-:+', 5: '=:=', 6: '+:-', 7: '0-0'}.get(result))
                    self.assertEqual(game.headers.get('Termination'), 'forfeit' if result in (4, 5, 6) else None)

    def test_invalid_metadata_still_refuses_without_publication(self):
        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext, file in zip(module.EXTENSIONS, module.sources(fixture)):
                shutil.copy2(file, root / ('invalid' + ext))
            source = root / 'invalid.cbh'
            original = bytearray(source.read_bytes()[:92])
            original[6:10] = (2).to_bytes(4, 'big')
            for packed, result in [((2026 << 9) | (13 << 5), 3), (0, 8), (0, 255)]:
                data = bytearray(original)
                data[70:73] = packed.to_bytes(3, 'big')
                data[73] = result
                source.write_bytes(data)
                with self.assertRaisesRegex(ValueError, 'date/result metadata'):
                    module.convert(source, root / 'output', probe=Path(os.environ['CBH_TEST_PROBE']))
                self.assertEqual(list((root / 'output').iterdir()), [])

    def test_adapter_preserves_explicit_eco_and_event_date(self):
        from adapter import make_game
        row = dict(fen='rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                   white='García', black='B', event='E', site='S', date=[2026, 9, 22],
                   round=4, subround=2, result=0, whiteElo=0, blackElo=0, tags=[], moves=[],
                   eco='B12', eventDate=[2026, 9, 20])
        game = make_game(row, False)
        self.assertEqual(game.headers.get('ECO'), 'B12')
        self.assertEqual(game.headers.get('EventDate'), '2026.09.20')
        self.assertEqual(game.headers['White'], 'García')

if __name__ == '__main__':
    unittest.main()
