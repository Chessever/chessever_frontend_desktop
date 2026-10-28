"""Origin lookup tests: no native decoder needed to prove reuse boundaries."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import converter

class OriginTest(unittest.TestCase):
    def test_renamed_and_edited_copy_requires_explicit_choice(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for ext in converter.EXTENSIONS:
                (root / ('source' + ext)).write_bytes(b'unchanged source ' + ext.encode())
            source = root / 'source.cbh'
            identity = converter.fingerprints(converter.sources(source))
            output = root / 'output'; folder = output / 'copy'; folder.mkdir(parents=True)
            pgn = folder / 'original.pgn'; pgn.write_text('[Event "original"]\n\n1. e4 *\n')
            receipt = dict(version=converter.VERSION, sourceSha256=identity, source=str(source),
                           key='legacy-key', games=1, pgnFile=pgn.name, pgnSha256=converter.digest(pgn))
            (folder / 'conversion.json').write_text(json.dumps(receipt))
            renamed = pgn.rename(folder / 'renamed.pgn')
            with patch.object(converter, 'decode', side_effect=AssertionError('must not regenerate')):
                result = converter.convert(source, output)
                self.assertTrue(result['reused'])
                self.assertEqual(Path(result['path']), renamed)
                # Receipt now names the recovered physical file, including for edits.
                saved = json.loads((folder / 'conversion.json').read_text())
                self.assertEqual(saved['pgnFile'], renamed.name)
                renamed.write_text('[Event "edited"]\n\n1. d4 *\n')
                edited = renamed.read_bytes()
                choice = converter.convert(source, output)
                self.assertTrue(choice['needsChoice'])
                self.assertEqual(renamed.read_bytes(), edited)
                reuse = converter.convert(source, output, existing_copy='reuse', selected_copy=str(renamed))
                self.assertEqual(Path(reuse['path']), renamed)
                self.assertTrue(reuse['edited'])
                self.assertEqual(renamed.read_bytes(), edited)
                with patch.object(converter, 'validate_snapshot', return_value=1):
                    with self.assertRaisesRegex(AssertionError, 'must not regenerate'):
                        converter.convert(source, output, existing_copy='fresh')
                self.assertEqual(renamed.read_bytes(), edited)

if __name__ == '__main__': unittest.main()
