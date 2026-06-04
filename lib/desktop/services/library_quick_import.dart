import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/library/providers/library_folders_provider.dart'
    show kTwicBookId, libraryFoldersStreamProvider, subscribedBooksProvider;
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart'
    show pgnHasMoves;
import 'package:chessever/utils/pgn_multi_parser.dart';
import 'package:chessever/utils/save_to_library_guard.dart';

/// `true` when [folder] can receive direct PGN imports (writable, not TWIC,
/// not a subscribed read-only book). The drop targets, Ctrl+V handler, and
/// the rail-row hover affordance all gate on this same predicate.
bool isWritableLibraryFolder(LibraryFolder folder) {
  return !folder.isSubscribed && folder.id != kTwicBookId;
}

/// Reads, parses, and bulk-saves chess files at [paths] into [folder] with
/// the same row chunking and free-tier guard as the save-to-folder dialog.
/// Emits a toast on outcome. Returns the row count actually written.
Future<int> quickImportPathsToFolder({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  required List<String> paths,
}) async {
  if (!isWritableLibraryFolder(folder)) {
    showDesktopToast(context, '"${folder.name}" is read-only.', error: true);
    return 0;
  }
  if (paths.isEmpty) return 0;
  final games = await _parseChessGamesFromPaths(paths);
  if (games.isEmpty) {
    if (context.mounted) {
      showDesktopToast(
        context,
        'No PGN games found in the dropped files.',
        error: true,
      );
    }
    return 0;
  }
  if (!context.mounted) return 0;
  return _saveAndToast(
    context: context,
    ref: ref,
    folder: folder,
    games: games,
    verb: 'Imported',
  );
}

/// Ctrl+V handler: take the clipboard text, parse it as one or many PGNs,
/// and bulk-save into [folder].
Future<int> quickImportClipboardToFolder({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
}) async {
  if (!isWritableLibraryFolder(folder)) {
    showDesktopToast(context, '"${folder.name}" is read-only.', error: true);
    return 0;
  }
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  final text = clipboard?.text?.trim();
  if (text == null || text.isEmpty) {
    if (context.mounted) {
      showDesktopToast(
        context,
        'Clipboard is empty — copy a PGN first.',
        error: true,
      );
    }
    return 0;
  }
  final games = parsePgnsToChessGames(text).map((e) => e.chessGame).toList();
  if (games.isEmpty) {
    if (context.mounted) {
      showDesktopToast(
        context,
        'Clipboard does not contain a valid PGN.',
        error: true,
      );
    }
    return 0;
  }
  if (!context.mounted) return 0;
  return _saveAndToast(
    context: context,
    ref: ref,
    folder: folder,
    games: games,
    verb: 'Pasted',
  );
}

/// Ctrl+C handler for the games listview: serialize [analyses] as a single
/// multi-PGN blob to the system clipboard. Returns the count actually
/// written (skips empty games).
Future<int> copySavedAnalysesAsPgn({
  required BuildContext context,
  required List<SavedAnalysis> analyses,
}) async {
  if (analyses.isEmpty) {
    showDesktopToast(context, 'Nothing to copy.', error: true);
    return 0;
  }
  return copyPgnTextsAsPgn(
    context: context,
    pgns: analyses.map((a) => exportGameToPgn(a.chessGame)),
  );
}

/// Copy already-serialized PGN strings as one clipboard blob. Used by
/// read-only database sources (local PGN previews, broadcasts) where the row
/// model already carries full PGN text rather than SavedAnalysis rows.
///
/// Header-only/empty PGNs are deliberately skipped so Ctrl+C never places a
/// blob on the clipboard that Ctrl+V will reject as invalid.
Future<int> copyPgnTextsAsPgn({
  required BuildContext context,
  required Iterable<String?> pgns,
}) async {
  final rawPgns = pgns.toList(growable: false);
  final parts = copyablePgnTextParts(rawPgns);
  if (parts.isEmpty) {
    if (context.mounted) {
      showDesktopToast(context, 'No PGN with moves to copy.', error: true);
    }
    return 0;
  }
  await Clipboard.setData(ClipboardData(text: parts.join('\n\n')));
  if (context.mounted) {
    final n = parts.length;
    final skipped = rawPgns.length - n;
    final suffix = skipped > 0 ? ' ($skipped skipped without moves)' : '';
    showDesktopToast(
      context,
      'Copied $n ${n == 1 ? 'game' : 'games'} as PGN$suffix.',
    );
  }
  return parts.length;
}

@visibleForTesting
List<String> copyablePgnTextParts(Iterable<String?> pgns) {
  final parts = <String>[];
  for (final raw in pgns) {
    final pgn = raw?.trim();
    if (pgn != null && pgn.isNotEmpty && pgnHasMoves(pgn)) {
      parts.add(pgn);
    }
  }
  return parts;
}

Future<int> _saveAndToast({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  required List<ChessGame> games,
  required String verb,
}) async {
  try {
    final saved = await _bulkSave(
      context: context,
      ref: ref,
      folder: folder,
      games: games,
    );
    if (saved > 0 && context.mounted) {
      showDesktopToast(
        context,
        '$verb $saved ${saved == 1 ? 'game' : 'games'} into "${folder.name}".',
      );
    }
    return saved;
  } catch (e) {
    if (context.mounted) {
      showDesktopToast(
        context,
        '${verb.toLowerCase()} failed: $e',
        error: true,
      );
    }
    return 0;
  }
}

Future<int> _bulkSave({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  required List<ChessGame> games,
}) async {
  final allowed = await canSaveMoreGames(context, gamesToAdd: games.length);
  if (!allowed || !context.mounted) return 0;

  final repo = ref.read(libraryRepositoryProvider);
  final userId = repo.supabase.auth.currentUser?.id;
  if (userId == null) {
    throw StateError('You need to be signed in to save games.');
  }

  final now = DateTime.now();
  final rows = <SavedAnalysis>[
    for (final game in games)
      SavedAnalysis(
        id: '',
        userId: userId,
        folderId: folder.id,
        title: _titleFor(game),
        chessGame: game,
        analysisState: const {},
        variationComments: const {},
        lastViewedPosition: -1,
        tags: const [],
        isFavorite: false,
        createdAt: now,
        updatedAt: now,
      ),
  ];

  const chunkSize = 250;
  for (var i = 0; i < rows.length; i += chunkSize) {
    final end = math.min(i + chunkSize, rows.length);
    await repo.createSavedAnalysesBulk(rows.sublist(i, end));
  }
  ref.invalidate(libraryFoldersStreamProvider);
  ref.invalidate(subscribedBooksProvider);
  return rows.length;
}

Future<List<ChessGame>> _parseChessGamesFromPaths(List<String> paths) async {
  final games = <ChessGame>[];
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      try {
        await for (final entity in Directory(
          path,
        ).list(recursive: true, followLinks: false)) {
          if (entity is File && _isPgnPath(entity.path)) {
            games.addAll(await _gamesFromFile(entity.path));
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('quickImport: scan $path failed: $e');
      }
    } else if (type == FileSystemEntityType.file && _isPgnPath(path)) {
      games.addAll(await _gamesFromFile(path));
    }
  }
  return games;
}

bool _isPgnPath(String path) => path.toLowerCase().endsWith('.pgn');

Future<List<ChessGame>> _gamesFromFile(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final utf = utf8.decode(bytes, allowMalformed: true);
    final text =
        utf.trim().isNotEmpty ? utf : latin1.decode(bytes, allowInvalid: true);
    return parsePgnsToChessGames(text).map((e) => e.chessGame).toList();
  } catch (e) {
    if (kDebugMode) debugPrint('quickImport: read $path failed: $e');
    return const [];
  }
}

String _titleFor(ChessGame game) {
  final white = (game.metadata['White']?.toString().trim() ?? '');
  final black = (game.metadata['Black']?.toString().trim() ?? '');
  final w = white.isEmpty ? 'White' : white;
  final b = black.isEmpty ? 'Black' : black;
  return '$w vs $b';
}

/// Coordinates outer-vs-inner DropTarget arbitration. The outer
/// [LocalChessDropZone] checks [recentlyConsumed] in a microtask-deferred
/// onDragDone so an inner drop target nested inside it (e.g. a folder rail
/// row) can claim the drop first regardless of dispatch order.
class LibraryDropArbiter {
  bool _claimed = false;

  void claim() => _claimed = true;

  /// Reads the claim flag and resets it for the next drop event.
  bool consumeClaim() {
    final v = _claimed;
    _claimed = false;
    return v;
  }
}
