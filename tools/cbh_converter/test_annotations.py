"""Native regression frames use public fixtures, never private database contents."""
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

import chess.pgn
from adapter import make_game, tree


class AnnotationTest(unittest.TestCase):
    def setUp(self):
        if not all(os.environ.get(key) and Path(os.environ[key]).is_file()
                   for key in ('CBH_TEST_FIXTURE', 'CBH_TEST_PROBE')):
            self.skipTest('Set CBH_TEST_FIXTURE and CBH_TEST_PROBE to local fixture/native decoder files')

    def decode(self, entries, null_moves=False, event_bytes=None, annotator_bytes=None):
        fixture = Path(os.environ['CBH_TEST_FIXTURE'])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for file in fixture.parent.glob(fixture.stem + '.*'):
                if file.is_file():
                    shutil.copy2(file, root / file.name)
            source = root / fixture.name
            index = bytearray(source.read_bytes()[:92])
            index[6:10] = (2).to_bytes(4, 'big')
            index[51:55] = (26).to_bytes(4, 'big')
            if null_moves:
                # Orthodox substitution table maps 0xaa to opcode zero;
                # each subsequent stored token adds the flattened move count.
                index[47:51] = (26).to_bytes(4, 'big')
                source.with_suffix('.cbg').write_bytes(bytes(26) + bytes([0, 0, 0, 6, 0xaa, 0xab]))
            if event_bytes is not None:
                data = bytearray(source.with_suffix('.cbt').read_bytes())
                start = 28 + data[24] + int.from_bytes(index[61:64], 'big') * 99 + 9
                data[start:start + 40] = event_bytes.ljust(40, b'\0')
                source.with_suffix('.cbt').write_bytes(data)
            if annotator_bytes is not None:
                data = bytearray(source.with_suffix('.cbc').read_bytes())
                start = 28 + data[24] + int.from_bytes(index[64:67], 'big') * 62 + 9
                data[start:start + 45] = annotator_bytes.ljust(45, b'\0')
                source.with_suffix('.cbc').write_bytes(data)
            source.write_bytes(index)
            frame = b''.join(move.to_bytes(3, 'big') + bytes([kind]) +
                             (len(payload) + 6).to_bytes(2, 'big') + payload
                             for move, kind, payload in entries)
            source.with_suffix('.cba').write_bytes(bytes(26 + 10) +
                (len(frame) + 14).to_bytes(4, 'big') + frame)
            output = root / 'decoded.jsonl'
            result = subprocess.run([os.environ['CBH_TEST_PROBE'], str(source), str(output)],
                                    capture_output=True, check=False)
            row = json.loads(output.read_text().splitlines()[1])
            return result.returncode, row

    def game(self, entries):
        code, row = self.decode(entries)
        self.assertEqual(code, 0)
        game = make_game(row, row['chess960'])
        exported = game.accept(chess.pgn.StringExporter(headers=True, variations=True, comments=True))
        parsed = chess.pgn.read_game(io.StringIO(exported))
        self.assertFalse(parsed.errors)
        self.assertEqual(tree(game, True), tree(parsed, True))
        self.assertEqual(dict(game.headers), dict(parsed.headers))
        return game

    def test_json_transport_preserves_non_ascii_metadata_and_payload(self):
        payload = bytes(range(256))
        code, row = self.decode([(0, 0x70, payload)], event_bytes=b'Caf\xe9\nCup')
        self.assertEqual(code, 0)
        self.assertEqual(row['unsupportedAnnotations'][0]['payloadBytes'].encode('latin1'), payload)
        # Metadata strings are mutable lvalues in the probe: these must use
        # the byte encoder too, not ADL's std::quoted overload.
        self.assertEqual(row['event'], 'Caf\xe9\nCup')

    def test_utf8_annotator_bytes_survive_native_transport_and_pgn(self):
        import base64
        raw = bytes.fromhex('4d53c39d')
        code, row = self.decode([], annotator_bytes=raw)
        self.assertEqual(code, 0)
        self.assertEqual(dict(row['tags'])['Annotator'].encode('latin1'), raw)
        game = make_game(row, False, preserve_raw=True)
        self.assertEqual(game.headers['Annotator'], 'MS\u00dd')
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(dict(game.headers), dict(parsed.headers))
        archive = json.loads(base64.b64decode(parsed.headers['ChessBaseRawText']))
        self.assertEqual(bytes.fromhex(archive[0]['hex']), raw)

    def test_literal_comment_braces_are_visible_and_raw_bytes_roundtrip(self):
        import base64
        payload = b'\0\0Text } { conclusion (ol} 1984'
        code, row = self.decode([(0, 2, payload)])
        self.assertEqual(code, 0)
        game = make_game(row, False, preserve_raw=True)
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(tree(game, True), tree(parsed, True))
        self.assertIn('Text &#125; &#123; conclusion (ol&#125; 1984', parsed.variations[0].comment)
        archive = json.loads(base64.b64decode(parsed.headers['ChessBaseRawAnnotations']))
        self.assertEqual(bytes.fromhex(archive[0]['hex']), payload)

    def test_utf8_comment_is_decoded_before_legacy_fallback(self):
        value = 'Позиция café \ue00d'
        code, row = self.decode([(0, 2, b'\0\0' + value.encode('utf8'))])
        self.assertEqual(code, 0)
        game = make_game(row, False, preserve_raw=True)
        self.assertEqual(game.variations[0].comment, value)
        self.assertIn('ChessBaseRawAnnotations', game.headers)

    def test_unattached_framed_annotations_are_explicit_not_illegal_moves(self):
        code, row = self.decode([(999, 2, b'\0\0orphan')], null_moves=True)
        self.assertEqual(code, 0)
        self.assertTrue(row['unconsumedAnnotations'])
        self.assertEqual(row['rawAnnotations'], [{'move': 999, 'type': 2, 'payloadBytes': '\0\0orphan'}])
        with self.assertRaisesRegex(ValueError, 'unattached'):
            make_game(row, False)
        game = make_game(row, False, preserve_raw=True)
        self.assertIn('ChessBaseRawAnnotations', game.headers)
        self.assertNotIn('orphan', game.comment)
        self.assertEqual(len(list(game.mainline_moves())), 2)

    def test_native_null_opcode_is_explicit_and_survives_pgn(self):
        code, row = self.decode([(0, 7, bytes([0, 0, 2, 0]))], null_moves=True)
        self.assertEqual(code, 0)
        self.assertEqual([m['promotion'] for m in row['moves']], [6, 6])
        game = make_game(row, False)
        self.assertEqual([m.uci() for m in game.mainline_moves()], ['0000', '0000'])
        parsed = chess.pgn.read_game(io.StringIO(str(game)))
        self.assertEqual(tree(game, True), tree(parsed, True))

    def test_additional_stored_nag_identities_are_not_discarded(self):
        game = self.game([(0, 3, bytes([7])), (1, 3, bytes([0, 8])),
                          (2, 3, bytes([1, 10, 142])), (3, 3, bytes([0, 30]))])
        self.assertEqual([node.nags for node in list(game.mainline())[:4]],
                         [{7}, {8}, {1, 10, 142}, {30}])

    def test_signed_engine_evaluation_and_depth(self):
        game = self.game([(0, 0x21, struct.pack('<hhh', -250, 0, 18)),
                          (1, 0x21, struct.pack('<hhh', 325, 0, 0)),
                          (2, 0x21, struct.pack('<hhh', -3, 1, 22))])
        nodes = list(game.mainline())
        self.assertIn('[%eval -2.50,18]', nodes[0].comment)
        self.assertIn('[%eval 3.25]', nodes[1].comment)
        self.assertIn('[%eval #-3,22]', nodes[2].comment)
        self.assertEqual(nodes[0].eval_depth(), 18)

    def test_elapsed_time_preserves_auxiliary_byte_without_inventing_clock(self):
        game = self.game([(0, 7, bytes([1, 2, 3, 94])), (1, 7, bytes([0, 0, 8, 0]))])
        nodes = list(game.mainline())
        self.assertEqual(nodes[0].emt(), 3723)
        self.assertIn('[%cbh_emt_flags 94]', nodes[0].comment)
        self.assertIsNone(nodes[0].clock())
        self.assertEqual(nodes[1].comment, '[%emt 0:00:08]')

    def test_verified_position_labels_are_attached_and_visible(self):
        game = self.game([(0, 0x18, b'\x01'), (1, 0x22, (1 << 9).to_bytes(4, 'big')),
                          (2, 0x23, bytes([3, 0x33, 0x22, 0x11]))])
        nodes = list(game.mainline())
        self.assertIn('Critical opening position', nodes[0].comment)
        self.assertIn('Sacrifice', nodes[1].comment)
        self.assertIn('#112233', nodes[2].comment)
        self.assertIn('moves only', nodes[2].comment)

    def test_unused_time_control_series_are_not_lost_controls(self):
        payload = struct.pack('>IIHB', 24000, 200, 1000, 3) + struct.pack('>IIHB', 0, 0, 1000, 5) * 2
        game = self.game([(0xffffff, 0x24, payload)])
        self.assertEqual(game.headers['TimeControl'], '240+2')
        self.assertIn('Time control: 240+2', game.comment)

    def test_multi_stage_time_control_is_visible_at_root_and_roundtrips(self):
        payload = (struct.pack('>IIHB', 540000, 3000, 40, 1) +
                   struct.pack('>IIHB', 180000, 3000, 1000, 3) + bytes(11))
        game = self.game([(0xffffff, 0x24, payload)])
        self.assertEqual(game.headers['TimeControl'], '40/5400+30:1800+30')
        self.assertIn('Time control: 40/5400+30:1800+30 seconds', game.comment)
        self.assertNotIn('Time control:', game.variations[0].comment)

    def test_global_increment_time_control(self):
        payload = struct.pack('>IIHB', 600000, 1000, 1000, 3) + bytes(22)
        game = self.game([(0xffffff, 0x24, payload), (0, 7, bytes([0, 1, 2, 10]))])
        self.assertEqual(game.headers['TimeControl'], '6000+10')
        self.assertIn('[%emt 0:01:02]', game.variations[0].comment)

    def test_unsupported_semantics_and_malformed_frames_still_refused(self):
        tc = struct.pack('>IIHB', 600000, 1000, 1000, 3) + bytes(22)
        for entry in [(0, 0x21, struct.pack('<hhh', 5, 3, 0)),
                      (0, 0x21, struct.pack('<hhh', 5, 0, -1)),
                      (0, 0x21, bytes(5)), (0, 7, bytes(3)),
                      (0, 7, bytes([0, 60, 0, 0])), (0, 0x24, tc),
                      (0xffffff, 0x24, tc[:-1]),
                      (0xffffff, 0x24, tc[:-1] + b'\x01'),
                      (0, 0x70, bytes(4))]:
            with self.subTest(kind=entry[1], payload=entry[2].hex()):
                code, row = self.decode([entry])
                if code == 0:
                    with self.assertRaises(ValueError):
                        make_game(row, row['chess960'])


if __name__ == '__main__':
    unittest.main()
