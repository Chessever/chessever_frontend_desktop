"""Synthetic preservation contracts; no user database contents."""
import base64
import io
import unittest
import chess.pgn
from preservation import guiding_game, preserve_annotations


def guiding_frame(documents):
    body = (3).to_bytes(4, 'little') + b'\x01' + len(documents).to_bytes(2, 'little')
    for lang, html in documents:
        raw = html.encode('utf8')
        body += lang.to_bytes(2, 'little') + len(raw).to_bytes(4, 'little') + raw + bytes(4)
    return b'\x80' + (len(body) + 4).to_bytes(3, 'big') + body


class PreservationTest(unittest.TestCase):
    def test_guiding_text_is_a_record_with_readable_root_and_exact_original(self):
        raw = guiding_frame([(0, '<html><body>Study <b>café</b> &amp; plan.</body></html>'),
                             (1, '<html><body></body></html>')])
        index = bytes(46)
        game = guiding_game(raw, index)
        self.assertIn('Study café & plan.', game.comment)
        self.assertEqual(game.headers['ChessBaseRecordType'], 'GuidingText')
        self.assertEqual(base64.b64decode(game.headers['ChessBaseGuidingText']), raw)
        self.assertEqual(base64.b64decode(game.headers['ChessBaseIndex']), index)
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(dict(parsed.headers), dict(game.headers))
        self.assertEqual(parsed.comment, game.comment)
        self.assertFalse(list(parsed.mainline_moves()))

    def test_guiding_record_is_published_not_skipped(self):
        import tempfile, shutil, os
        from pathlib import Path
        from converter import convert, EXTENSIONS
        if not all(os.environ.get(key) and Path(os.environ[key]).is_file()
                   for key in ('CBH_TEST_FIXTURE', 'CBH_TEST_PROBE')):
            self.skipTest('Set CBH_TEST_FIXTURE and CBH_TEST_PROBE to local fixture/native decoder files')
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext in EXTENSIONS:
                shutil.copy2(fixture.with_suffix(ext), root / ('text' + ext))
            source = root / 'text.cbh'
            header = bytearray(source.read_bytes()[:46]); header[6:10] = (2).to_bytes(4, 'big')
            index = bytearray(46); index[0] = 3; index[1:5] = (26).to_bytes(4, 'big')
            # A guiding tournament id is not a CBA offset (old code rejected it).
            index[7:10] = (865).to_bytes(3, 'big')
            raw = guiding_frame([(0, '<html><body>A study.</body></html>')])
            source.write_bytes(header + index)
            source.with_suffix('.cbg').write_bytes(bytes(26) + raw)
            result = convert(source, root / 'out', probe=Path(os.environ['CBH_TEST_PROBE']))
            self.assertEqual(result['games'], 1)
            parsed = chess.pgn.read_game(io.StringIO(Path(result['path']).read_text(encoding='utf8')))
            self.assertEqual(parsed.headers['ChessBaseRecordType'], 'GuidingText')
            self.assertIn('A study.', parsed.comment)
            self.assertEqual(base64.b64decode(parsed.headers['ChessBaseGuidingText']), raw)

    def test_unknown_annotations_are_preserved_in_durable_copy(self):
        import tempfile, shutil, os
        from pathlib import Path
        from converter import convert, EXTENSIONS
        if not all(os.environ.get(key) and Path(os.environ[key]).is_file()
                   for key in ('CBH_TEST_FIXTURE', 'CBH_TEST_PROBE')):
            self.skipTest('Set CBH_TEST_FIXTURE and CBH_TEST_PROBE to local fixture/native decoder files')
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext in EXTENSIONS:
                shutil.copy2(fixture.with_suffix(ext), root / ('sample' + ext))
            source = root / 'sample.cbh'
            index = bytearray(source.read_bytes()[:92]); index[6:10] = (2).to_bytes(4, 'big')
            index[51:55] = (26).to_bytes(4, 'big'); source.write_bytes(index)
            payload = bytes(range(256))
            entry = b'\0\0\0\x70' + (len(payload) + 6).to_bytes(2, 'big') + payload
            frame = bytes(10) + (len(entry) + 14).to_bytes(4, 'big') + entry
            source.with_suffix('.cba').write_bytes(bytes(26) + frame)
            result = convert(source, root / 'out', probe=Path(os.environ['CBH_TEST_PROBE']))
            game = chess.pgn.read_game(io.StringIO(Path(result['path']).read_text(encoding='utf8')))
            self.assertEqual(base64.b64decode(game.headers['ChessBaseAnnotationFrame']), frame)
            self.assertEqual(base64.b64decode(game.headers['ChessBaseIndex']), bytes(index[46:]))
            self.assertEqual(result['preservation']['rawAnnotationRecords'], 1)

    def test_guiding_titles_and_legacy_formatting_are_preserved(self):
        title = b'Chapter 1'
        body = b'Plan\r\x04\rCaf\xe9 {diagram}'
        formatting = bytes(range(32))
        data = (b'\x01\0\x01\0\0\0' + len(title).to_bytes(2, 'little') + title +
                b'\x01\x01\0\0\0' + len(body).to_bytes(2, 'little') + body +
                len(formatting).to_bytes(2, 'little') + formatting)
        raw = b'\x80' + (len(data) + 4).to_bytes(3, 'big') + data
        game = guiding_game(raw, bytes(46))
        self.assertIn('Title (language 0): Chapter 1', game.comment)
        self.assertIn('Café &#123;diagram&#125;', game.comment)
        self.assertIn('[ChessBase object 0x04]', game.comment)
        self.assertIn('archived', game.headers['ChessBaseGuidingRendering'])
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(base64.b64decode(parsed.headers['ChessBaseGuidingText']), raw)
        self.assertEqual(parsed.comment, game.comment)

    def test_guiding_html_titles_are_not_mistaken_for_version_bytes(self):
        title = b'Opening'
        document = b'<body>Idea <img alt="diagram" src="private.png"></body>'
        body = (b'\x03\0\x01\0\0\0' + len(title).to_bytes(2, 'little') + title +
                b'\x01\x01\0\0\0' + len(document).to_bytes(4, 'little') + document + bytes(4))
        raw = b'\x80' + (len(body) + 4).to_bytes(3, 'big') + body
        game = guiding_game(raw, bytes(46))
        self.assertIn('Opening', game.comment)
        self.assertIn('Idea', game.comment)
        self.assertIn('[Image: diagram]', game.comment)
        self.assertEqual(base64.b64decode(game.headers['ChessBaseGuidingText']), raw)

    def test_guiding_frames_are_bounded_and_unknown_versions_refused(self):
        raw = guiding_frame([(0, '<html><body></body></html>')])
        for cut in range(len(raw)):
            with self.assertRaises(ValueError):
                guiding_game(raw[:cut], bytes(46))
        other = bytearray(raw); other[4] = 9
        with self.assertRaises(ValueError):
            guiding_game(bytes(other), bytes(46))

    def test_unknown_annotation_bytes_and_addresses_roundtrip_in_headers(self):
        game = chess.pgn.Game()
        entries = [{'move': 0xffffff, 'type': 0x26, 'payloadBytes': bytes(range(256)).decode('latin1')},
                   {'move': 900, 'type': 3, 'payloadBytes': '\x07'}]
        preserve_annotations(game, entries)
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(dict(game.headers), dict(parsed.headers))
        import json
        decoded = json.loads(base64.b64decode(parsed.headers['ChessBaseRawAnnotations']))
        self.assertEqual(decoded, [{'move': e['move'], 'type': e['type'],
                                   'hex': e['payloadBytes'].encode('latin1').hex()} for e in entries])
        self.assertIn('original-source archive', parsed.headers['ChessBasePreservation'])
        self.assertIn('addresses are not rebound after edits', parsed.headers['ChessBasePreservation'])

if __name__ == '__main__':
    unittest.main()
