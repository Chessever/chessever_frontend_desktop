"""Encoding regression: synthetic byte fields, no private game data."""
import base64
import io
import json
import unittest

import chess
import chess.pgn
from adapter import make_game, text, comment_text


def record(**changes):
    row = dict(fen=chess.STARTING_FEN, white='White', black='Black', event='Event',
               site='', date=[2025, 1, 1], round=1, subround=0, result=0,
               whiteElo=0, blackElo=0, tags=[], moves=[], pregameComments=[])
    row.update(changes)
    return row


class EncodingTest(unittest.TestCase):
    def test_utf8_metadata_with_undefined_cp1252_byte_roundtrips_exactly(self):
        raw = bytes.fromhex('4d53c39d')
        game = make_game(record(tags=[['Annotator', raw.decode('latin1')]]),
                         False, preserve_raw=True)
        self.assertEqual(game.headers['Annotator'], 'MS\u00dd')
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(dict(parsed.headers), dict(game.headers))
        archive = json.loads(base64.b64decode(parsed.headers['ChessBaseRawText']))
        self.assertEqual(archive, [{'field': 'Annotator', 'hex': raw.hex(), 'encoding': 'utf-8'}])
        self.assertEqual(parsed.headers['Annotator'].encode('utf8'), raw)

    def test_legacy_metadata_and_ambiguous_bytes_keep_existing_profile(self):
        self.assertEqual(text('Caf\xe9'), 'Caf\xe9')
        self.assertEqual(text('\x93Title\x94'), '\u201cTitle\u201d')
        # Both codecs accept this. Do not silently change the selected profile.
        self.assertEqual(text('\xc3\xa9'), '\u00c3\u00a9')

    def test_undefined_bytes_are_not_ignored_or_latin1_guessed(self):
        for value in (b'bad\x9d', b'\x81', b'\x8d', b'\x8f', b'\x90'):
            with self.subTest(hex=value.hex()):
                with self.assertRaises(ValueError):
                    text(value.decode('latin1'))
                with self.assertRaises(ValueError):
                    comment_text(value.decode('latin1'))

    def test_unknown_encoding_reports_the_field_without_discarding_it(self):
        with self.assertRaisesRegex(ValueError, 'Annotator:.*explicit source encoding'):
            make_game(record(tags=[['Annotator', 'bad\u009d']]), False, preserve_raw=True)
        with self.assertRaisesRegex(ValueError, 'comment:.*explicit source encoding'):
            comment_text('bad\u009d')

    def test_unknown_comment_byte_is_visible_and_source_exact(self):
        raw = b'\x81Against'
        entry = dict(move=0, type=130, payloadBytes=(b'\0\0' + raw).decode('latin1'))
        row = record(pregameComments=[dict(kind='before', textBytes=raw.decode('latin1'))],
                     rawAnnotations=[entry])
        game = make_game(row, False, preserve_raw=True)
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(parsed.comment, '[ChessBase unknown byte 0x81]Against')
        self.assertIn('not interpreted', parsed.headers['ChessBaseUnknownTextBytes'])
        archive = json.loads(base64.b64decode(parsed.headers['ChessBaseRawAnnotations']))
        self.assertEqual(bytes.fromhex(archive[0]['hex']), b'\0\0' + raw)
        self.assertEqual(archive[0]['type'], 130)
        self.assertEqual(archive[0]['move'], 0)
        with self.assertRaises(ValueError):
            make_game(row, False)
        row['rawAnnotations'] = [dict(move=0, type=130, payloadBytes='\0\0Different')]
        with self.assertRaisesRegex(ValueError, 'matching raw annotation'):
            make_game(row, False, preserve_raw=True)

    def test_visible_escapes_retain_every_undefined_byte_and_literal_lookalikes(self):
        samples = [b'prefix' + bytes([b]) + b' suffix' for b in (0x81, 0x8D, 0x8F, 0x90, 0x9D)]
        samples += [b'\x81\x81{caf\xe9} [ChessBase unknown byte 0x81]\x9d']
        for raw in samples:
            with self.subTest(hex=raw.hex()):
                expected = ''.join(f'[ChessBase unknown byte 0x{b:02X}]'
                                   if b in (0x81, 0x8D, 0x8F, 0x90, 0x9D)
                                   else bytes([b]).decode('cp1252') for b in raw)
                expected = expected.replace('{', '&#123;').replace('}', '&#125;')
                row = record(pregameComments=[dict(kind='after', textBytes=raw.decode('latin1'))],
                             rawAnnotations=[dict(move=0xFFFFFF, type=2, payloadBytes=(b'\0\0'+raw).decode('latin1'))])
                game = make_game(row, False, preserve_raw=True)
                parsed = chess.pgn.read_game(io.StringIO(str(game)))
                self.assertEqual(parsed.comment, expected)
                archive = json.loads(base64.b64decode(parsed.headers['ChessBaseRawAnnotations']))
                self.assertEqual(bytes.fromhex(archive[0]['hex'])[2:], raw)
                self.assertNotIn('\ufffd', parsed.comment)

    def test_comment_utf8_and_legacy_behavior_unchanged(self):
        self.assertEqual(comment_text('Bo\xc5\x9f hamle'), 'Bo\u015f hamle')
        self.assertEqual(comment_text('Caf\xe9'), 'Caf\xe9')


if __name__ == '__main__':
    unittest.main()
