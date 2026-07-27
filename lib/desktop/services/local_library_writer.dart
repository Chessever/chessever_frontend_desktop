import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_pgn_atomic_write.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;

/// Result of a local library write batch.
class LocalLibraryWriteOutcome {
  const LocalLibraryWriteOutcome({
    required this.folderPath,
    required this.writtenPaths,
    required this.skipped,
    this.updateTargets = const <LocalLibraryGameUpdateTarget>[],
    this.errorMessage,
  });

  final String folderPath;
  final List<String> writtenPaths;
  final int skipped;
  final List<LocalLibraryGameUpdateTarget> updateTargets;
  final String? errorMessage;

  int get written => writtenPaths.length;
  bool get hasError => errorMessage != null;
}

/// Writes [ChessGame]s to a local PGN destination.
///
/// When [folderPath] points at a `.pgn` file, games are appended to that file —
/// this is the desktop "local database" flow. Folder destinations are still
/// supported for older registry entries and save each game as an individual
/// `.pgn` document inside the folder.
class LocalLibraryWriter {
  const LocalLibraryWriter({required this.folderPath});

  final String folderPath;

  Future<LocalLibraryWriteOutcome> writeGames(List<ChessGame> games) async {
    if (games.isEmpty) {
      return LocalLibraryWriteOutcome(
        folderPath: folderPath,
        writtenPaths: const <String>[],
        skipped: 0,
      );
    }

    final type = await FileSystemEntity.type(folderPath);
    if (_looksLikePgnFile(folderPath) &&
        (type == FileSystemEntityType.file ||
            type == FileSystemEntityType.notFound)) {
      return _appendGamesToPgnFile(games);
    }

    return _writeGamesToFolder(games);
  }

  Future<LocalLibraryWriteOutcome> _appendGamesToPgnFile(
    List<ChessGame> games,
  ) async {
    final file = File(folderPath);
    final parent = file.parent;
    if (!await parent.exists()) {
      return LocalLibraryWriteOutcome(
        folderPath: folderPath,
        writtenPaths: const <String>[],
        skipped: games.length,
        errorMessage: 'Folder does not exist: ${parent.path}',
      );
    }

    final written = <String>[];
    final writtenFingerprints = <String>[];
    var skipped = 0;
    String? error;

    try {
      final existing = await file.exists() ? await file.readAsString() : '';
      final existingGameCount = pgnGameRanges(existing).length;
      final buffer = StringBuffer();
      final existingTrimmed = existing.trimRight();
      if (existingTrimmed.isNotEmpty) {
        buffer
          ..write(existingTrimmed)
          ..write('\n\n');
      }

      for (final game in games) {
        final pgn = exportGameToPgn(game).trim();
        if (pgn.isEmpty) {
          skipped++;
          continue;
        }
        buffer
          ..write(pgn)
          ..write('\n\n');
        written.add(file.path);
        writtenFingerprints.add(localChessPgnFingerprint(pgn));
      }

      if (written.isNotEmpty) {
        await writeLocalPgnAtomically(
          file: file,
          expectedText: existing,
          nextText: buffer.toString(),
        );
      }

      final finalGameCount = existingGameCount + written.length;
      final updateTargets = <LocalLibraryGameUpdateTarget>[
        for (var i = 0; i < written.length; i++)
          LocalLibraryGameUpdateTarget(
            sourcePath: file.path,
            indexInFile: existingGameCount + i,
            fileGameCount: finalGameCount,
            pgnFingerprint: writtenFingerprints[i],
          ),
      ];

      return LocalLibraryWriteOutcome(
        folderPath: folderPath,
        writtenPaths: written,
        skipped: skipped,
        updateTargets: updateTargets,
      );
    } catch (e) {
      error = e.toString();
      skipped += games.length - written.length;
      written.clear();
    }

    return LocalLibraryWriteOutcome(
      folderPath: folderPath,
      writtenPaths: written,
      skipped: skipped,
      errorMessage: error,
    );
  }

  Future<LocalLibraryWriteOutcome> _writeGamesToFolder(
    List<ChessGame> games,
  ) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) {
      return LocalLibraryWriteOutcome(
        folderPath: folderPath,
        writtenPaths: const <String>[],
        skipped: games.length,
        errorMessage: 'Folder does not exist: $folderPath',
      );
    }

    final used = <String>{};
    final written = <String>[];
    var skipped = 0;
    String? error;

    for (final game in games) {
      try {
        final pgn = exportGameToPgn(game).trim();
        if (pgn.isEmpty) {
          skipped++;
          continue;
        }
        final base = _filenameStemFor(game);
        final path = _claimAvailablePath(dir.path, base, used);
        await File(path).writeAsString('$pgn\n', flush: true);
        used.add(_normalize(path));
        written.add(path);
      } catch (e) {
        skipped++;
        error ??= e.toString();
      }
    }

    return LocalLibraryWriteOutcome(
      folderPath: folderPath,
      writtenPaths: written,
      skipped: skipped,
      errorMessage: error,
    );
  }

  String _claimAvailablePath(String dir, String stem, Set<String> used) {
    for (var i = 1; i < 1000; i++) {
      final candidate = i == 1 ? '$stem.pgn' : '$stem ($i).pgn';
      final full = p.join(dir, candidate);
      final norm = _normalize(full);
      if (used.contains(norm)) continue;
      if (FileSystemEntity.typeSync(full) == FileSystemEntityType.notFound) {
        return full;
      }
    }
    // Extreme collision fallback — append a millisecond stamp.
    final unique = '$stem-${DateTime.now().millisecondsSinceEpoch}.pgn';
    return p.join(dir, unique);
  }

  String _normalize(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;
}

bool _looksLikePgnFile(String path) =>
    p.extension(path).toLowerCase() == '.pgn';

String _filenameStemFor(ChessGame game) {
  final white = (game.metadata['White']?.toString().trim() ?? '');
  final black = (game.metadata['Black']?.toString().trim() ?? '');
  final event = (game.metadata['Event']?.toString().trim() ?? '');
  final date = _normalizePgnDate(game.metadata['Date']?.toString());

  final players =
      '${white.isEmpty ? 'White' : white} vs ${black.isEmpty ? 'Black' : black}';
  final parts = <String>[
    if (date != null && date.isNotEmpty) date,
    players,
    if (event.isNotEmpty && event != '?') '[$event]',
  ];
  final raw = parts.join(' ');
  return sanitizeFilenameStem(raw);
}

/// Trims `?` placeholders out of a PGN date like "2024.??.??" → "2024" and
/// rewrites separators so the result is filename-safe across platforms.
String? _normalizePgnDate(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final segments =
      trimmed
          .split('.')
          .map((seg) => seg.replaceAll('?', '').trim())
          .where((seg) => seg.isNotEmpty)
          .toList();
  if (segments.isEmpty) return null;
  return segments.join('-');
}

/// Strip / collapse characters that Windows, macOS, or APFS treat as illegal
/// in filenames. Falls back to `Game` for an empty result.
String sanitizeFilenameStem(String input) {
  final replaced = input.replaceAll(RegExp(r'[\x00-]+'), ' ');
  final stripped =
      replaced
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
  const reserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  final upper = stripped.toUpperCase();
  if (stripped.isEmpty || reserved.contains(upper)) return 'Game';
  // Filesystems cap basename at ~255 bytes; trim defensively before the
  // ".pgn" suffix and the optional " (n)" disambiguator are appended.
  const maxStemLength = 180;
  if (stripped.length > maxStemLength) {
    return stripped.substring(0, maxStemLength).trim();
  }
  return stripped;
}
