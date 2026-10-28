import 'package:path/path.dart' as p;

export 'package:chessever/desktop/services/local_pgn_move_native.dart'
    if (dart.library.js_interop) 'package:chessever/desktop/services/local_pgn_move_web.dart';

String localPgnRenameDestination(String source, String name) {
  if (p.extension(source).toLowerCase() != '.pgn') {
    throw const FormatException('Only PGN databases can be renamed.');
  }
  var stem = name.trim();
  if (stem.toLowerCase().endsWith('.pgn')) {
    stem = stem.substring(0, stem.length - 4);
  }
  if (stem.isEmpty ||
      stem == '.' ||
      stem == '..' ||
      stem.endsWith('.') ||
      stem.endsWith(' ') ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(stem) ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(stem)) {
    throw const FormatException(
      'Enter a valid database name without path separators.',
    );
  }
  return p.join(p.dirname(source), '$stem.pgn');
}
