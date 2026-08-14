import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/local_chess_file_access.dart';
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

const int _kQuickImportMaxPgnBytes = 32 * 1024 * 1024;

/// `true` when [folder] can receive direct PGN imports (writable, not TWIC,
/// not a subscribed read-only book). The drop targets, Ctrl+V handler, and
/// the rail-row hover affordance all gate on this same predicate.
bool isWritableLibraryFolder(LibraryFolder folder) {
  return !folder.isSubscribed && folder.id != kTwicBookId;
}

@visibleForTesting
bool isPgnTooLargeForQuickFolderImport(int bytes) {
  return bytes > _kQuickImportMaxPgnBytes;
}

bool canQuickImportPathToFolder(String path) {
  final trimmed = path.trim();
  // Type, size, and directory checks happen in killable async workers. Drag
  // hover must never perform synchronous I/O against a locked/network path.
  return trimmed.isNotEmpty;
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
  _quickImportLog(
    'paths import start folder=${folder.id} count=${paths.length} paths=$paths',
  );
  if (!isWritableLibraryFolder(folder)) {
    _quickImportLog('paths import abort read-only folder=${folder.id}');
    showDesktopToast(context, '"${folder.name}" is read-only.', error: true);
    return 0;
  }
  if (paths.isEmpty) return 0;
  final parsed = await _parseChessGamesFromPaths(paths);
  final games = parsed.games;
  _quickImportLog('paths import parsed games=${games.length}');
  if (games.isEmpty) {
    if (context.mounted) {
      showDesktopToast(
        context,
        parsed.fileError ?? 'No PGN games found in the dropped files.',
        error: true,
        duration: const Duration(seconds: 7),
      );
    }
    return 0;
  }
  if (!context.mounted) return 0;
  final saved = await _saveAndToast(
    context: context,
    ref: ref,
    folder: folder,
    games: games,
    verb: 'Imported',
  );
  if (saved > 0 && parsed.fileError != null && context.mounted) {
    showDesktopToast(
      context,
      'Some PGN files were skipped. ${parsed.fileError}',
      error: true,
      duration: const Duration(seconds: 7),
    );
  }
  _quickImportLog('paths import saved=$saved folder=${folder.id}');
  return saved;
}

/// Ctrl+V handler: take the clipboard text, parse it as one or many PGNs,
/// and bulk-save into [folder].
Future<int> quickImportClipboardToFolder({
  required BuildContext context,
  required WidgetRef ref,
  required LibraryFolder folder,
  bool Function()? isCurrentOwner,
}) async {
  _quickImportLog('clipboard import start folder=${folder.id}');
  if (!isWritableLibraryFolder(folder)) {
    _quickImportLog('clipboard import abort read-only folder=${folder.id}');
    showDesktopToast(context, '"${folder.name}" is read-only.', error: true);
    return 0;
  }
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  if (isCurrentOwner?.call() == false) return 0;
  final text = clipboard?.text?.trim();
  if (text == null || text.isEmpty) {
    _quickImportLog('clipboard import abort empty');
    if (context.mounted) {
      showDesktopToast(
        context,
        'Clipboard is empty — copy a PGN first.',
        error: true,
      );
    }
    return 0;
  }
  _quickImportLog('clipboard import parse dispatch chars=${text.length}');
  final games =
      (await parsePgnsToChessGamesAsync(text)).map((e) => e.chessGame).toList();
  if (isCurrentOwner?.call() == false) return 0;
  _quickImportLog('clipboard import parsed games=${games.length}');
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
  final saved = await _saveAndToast(
    context: context,
    ref: ref,
    folder: folder,
    games: games,
    verb: 'Pasted',
    isCurrentOwner: isCurrentOwner,
  );
  _quickImportLog('clipboard import saved=$saved folder=${folder.id}');
  return saved;
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
  bool Function()? isCurrentOwner,
}) async {
  try {
    final saved = await _bulkSave(
      context: context,
      ref: ref,
      folder: folder,
      games: games,
      isCurrentOwner: isCurrentOwner,
    );
    if (saved > 0 && context.mounted && isCurrentOwner?.call() != false) {
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
  bool Function()? isCurrentOwner,
}) async {
  final allowed = await canSaveMoreGames(context, gamesToAdd: games.length);
  if (!allowed || !context.mounted || isCurrentOwner?.call() == false) {
    return 0;
  }

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
  var saved = 0;
  for (var i = 0; i < rows.length; i += chunkSize) {
    if (isCurrentOwner?.call() == false) break;
    final end = math.min(i + chunkSize, rows.length);
    await repo.createSavedAnalysesBulk(rows.sublist(i, end));
    saved = end;
  }
  if (saved > 0) {
    ref.invalidate(libraryFoldersStreamProvider);
    ref.invalidate(subscribedBooksProvider);
  }
  return saved;
}

Future<({List<ChessGame> games, String? fileError})> _parseChessGamesFromPaths(
  List<String> paths,
) async {
  _quickImportLog('scan paths start count=${paths.length}');
  final games = <ChessGame>[];
  String? firstFileError;
  for (final path in paths) {
    if (_isPgnPath(path)) {
      _quickImportLog('scan file pgn path=$path');
      final parsed = await _gamesFromFile(path);
      games.addAll(parsed.games);
      firstFileError ??= parsed.fileError;
      continue;
    }

    _quickImportLog('scan directory start path=$path');
    try {
      final pgnPaths = await listLocalChessPgnFilesInWorker(path);
      for (final pgnPath in pgnPaths) {
        _quickImportLog('scan directory pgn path=$pgnPath');
        final parsed = await _gamesFromFile(pgnPath);
        games.addAll(parsed.games);
        firstFileError ??= parsed.fileError;
      }
    } on LocalChessFileAccessException catch (error) {
      _quickImportLog('scan directory failed path=$path error=$error');
      firstFileError ??= error.userMessage;
    } catch (error) {
      _quickImportLog('scan directory failed path=$path error=$error');
      firstFileError ??=
          'ChessEver couldn\'t scan "${localChessFileNameFromPath(path)}". '
          'Check the folder or network connection, then try again.';
    }
  }
  _quickImportLog('scan paths complete games=${games.length}');
  return (games: games, fileError: firstFileError);
}

bool _isPgnPath(String path) => path.toLowerCase().endsWith('.pgn');

Future<({List<ChessGame> games, String? fileError})> _gamesFromFile(
  String path,
) async {
  try {
    _quickImportLog('worker file start path=$path');
    final bytes = await readStableLocalChessFileBytesInWorker(
      path,
      maxBytes: _kQuickImportMaxPgnBytes,
    );
    try {
      return await Isolate.run(() {
        _quickImportLog('worker file read bytes=${bytes.length}');
        final utf = utf8.decode(bytes, allowMalformed: true);
        final text =
            utf.trim().isNotEmpty
                ? utf
                : latin1.decode(bytes, allowInvalid: true);
        _quickImportLog('worker file decoded chars=${text.length}');
        final stopwatch = Stopwatch()..start();
        final games =
            parsePgnsToChessGames(text).map((e) => e.chessGame).toList();
        stopwatch.stop();
        _quickImportLog(
          'worker file parsed games=${games.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
        return (games: games, fileError: null);
      });
    } catch (e) {
      _quickImportLog('worker parse failed path=$path error=$e');
      return (
        games: const <ChessGame>[],
        fileError:
            'ChessEver couldn\'t import "${localChessFileNameFromPath(path)}". '
            'The PGN may be incomplete or damaged.',
      );
    }
  } on LocalChessFileAccessException catch (e) {
    _quickImportLog('worker file failed path=$path error=$e');
    return (games: const <ChessGame>[], fileError: e.userMessage);
  } on ArgumentError catch (e) {
    _quickImportLog('worker file skipped path=$path error=$e');
    return (
      games: const <ChessGame>[],
      fileError:
          '"${localChessFileNameFromPath(path)}" is too large for quick '
          'folder import. Open it as a local database instead.',
    );
  } catch (e) {
    _quickImportLog('worker file failed path=$path error=$e');
    return (
      games: const <ChessGame>[],
      fileError:
          'ChessEver couldn\'t import "${localChessFileNameFromPath(path)}". '
          'Close it in other apps or copy it to a local folder, then try '
          'again.',
    );
  }
}

void _quickImportLog(String message) {
  stdout.writeln(
    '[PGN_QUICK_IMPORT ${DateTime.now().toIso8601String()}] $message',
  );
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
