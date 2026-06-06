import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/chess_board_screen_new.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/library/pgn_import_preview_screen.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/services/deep_link_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/pgn_multi_parser.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Convert a parsed [ChessGame] into the minimal [GamesTourModel] shape that
/// [ChessBoardScreenNew] and [PgnImportPreviewScreen] expect when rendering
/// cards + boards for imported games (no Supabase round/tour row behind it).
///
/// Kept as a top-level function so both the intake service and the preview
/// screen can use the same mapping, guaranteeing cards look identical.
GamesTourModel chessGameToImportedGamesTourModel(ChessGame game) {
  final md = game.metadata;
  final whiteName = md['White']?.toString().trim() ?? '';
  final blackName = md['Black']?.toString().trim() ?? '';
  final whiteTitle = md['WhiteTitle']?.toString().trim() ?? '';
  final blackTitle = md['BlackTitle']?.toString().trim() ?? '';
  final whiteElo = int.tryParse(md['WhiteElo']?.toString().trim() ?? '') ?? 0;
  final blackElo = int.tryParse(md['BlackElo']?.toString().trim() ?? '') ?? 0;

  final whiteFed = _firstNonEmpty([
    md['WhiteFed'],
    md['WhiteCountry'],
    md['WhiteTeam'],
  ]);
  final blackFed = _firstNonEmpty([
    md['BlackFed'],
    md['BlackCountry'],
    md['BlackTeam'],
  ]);
  final whiteFideId = _parseFideId(md['WhiteFideId']);
  final blackFideId = _parseFideId(md['BlackFideId']);

  final status = GameStatus.fromString(md['Result']?.toString() ?? '*');
  final parsedDate = _parsePgnDate(md['Date']?.toString());

  return GamesTourModel(
    gameId: game.gameId,
    source: GameSource.boardEditor,
    whitePlayer: PlayerCard(
      name: whiteName.isEmpty ? 'White' : whiteName,
      federation: whiteFed,
      title: whiteTitle,
      rating: whiteElo,
      countryCode: whiteFed,
      fideId: whiteFideId,
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: blackName.isEmpty ? 'Black' : blackName,
      federation: blackFed,
      title: blackTitle,
      rating: blackElo,
      countryCode: blackFed,
      fideId: blackFideId,
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: status,
    roundId: md['Round']?.toString() ?? 'import_preview',
    tourId: md['Event']?.toString() ?? 'import_preview',
    pgn: exportGameToPgn(game),
    eco: md['ECO']?.toString(),
    openingName: md['Opening']?.toString(),
    lastMoveTime: parsedDate,
  );
}

String _firstNonEmpty(List<dynamic> candidates) {
  for (final c in candidates) {
    final s = c?.toString().trim() ?? '';
    if (s.isNotEmpty && s != '?') return s;
  }
  return '';
}

int? _parseFideId(dynamic raw) {
  final s = raw?.toString().trim() ?? '';
  if (s.isEmpty || s == '?' || s == '0') return null;
  final parsed = int.tryParse(s);
  return (parsed != null && parsed > 0) ? parsed : null;
}

DateTime? _parsePgnDate(String? date) {
  if (date == null || date.isEmpty) return null;
  try {
    if (date.contains('.')) {
      final parts = date.split('.');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final d = int.tryParse(parts[2]);
        if (y != null && m != null && d != null) {
          return DateTime(y, m, d);
        }
      }
    }
    return DateTime.tryParse(date);
  } catch (_) {
    return null;
  }
}

/// Centralizes "take a PGN blob and route the user somewhere sensible".
///
/// Used by:
/// - In-app file picker (from the Add-to-Library sheet) — always routes to
///   [PgnImportPreviewScreen] so the UX matches clipboard paste.
/// - OS "Open with ChessEver" from Files.app / Android file managers — routes
///   single-game PGNs directly to [ChessBoardScreenNew] and multi-game PGNs to
///   [PgnImportPreviewScreen], per product spec.
class PgnFileIntakeService {
  PgnFileIntakeService._();

  static final PgnFileIntakeService instance = PgnFileIntakeService._();

  StreamSubscription<List<SharedMediaFile>>? _intentStreamSub;
  bool _isInitialized = false;

  /// Start listening for OS file-open / share intents. Idempotent.
  Future<void> initialize(
    GlobalKey<NavigatorState> navigatorKey,
    WidgetRef ref,
  ) async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Cold start: app launched by tapping a .pgn file.
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isNotEmpty) {
        unawaited(
          _handleSharedMedia(initial, navigatorKey, waitAppReady: true),
        );
      }
      ReceiveSharingIntent.instance.reset();
    } catch (e) {
      debugPrint('PgnFileIntakeService: getInitialMedia failed: $e');
    }

    // Warm start: file-open arrives while app is running.
    _intentStreamSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (files) => unawaited(
        _handleSharedMedia(files, navigatorKey, waitAppReady: false),
      ),
      onError: (Object error) {
        debugPrint('PgnFileIntakeService: media stream error: $error');
      },
    );
  }

  void dispose() {
    _intentStreamSub?.cancel();
    _intentStreamSub = null;
    _isInitialized = false;
  }

  /// In-app entry point: user pasted/picked a PGN blob. Always routes to the
  /// preview screen (even for a single game), matching the clipboard flow.
  Future<bool> ingestPgnTextFromContext({
    required BuildContext context,
    required String text,
    String? sourceLabel,
    String? initialFolderId,
  }) async {
    _pgnImportLog(
      'ingest text start source=${sourceLabel ?? 'unknown'} chars=${text.length}',
    );
    final parsed = await _parseWithLoadingDialog(context, text);
    _pgnImportLog('ingest text parsed count=${parsed.length}');
    if (parsed.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'That file does not contain a valid PGN',
              style: TextStyle(color: kWhiteColor),
            ),
            backgroundColor: kRedColor.withValues(alpha: 0.9),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    if (!context.mounted) return false;
    await _pushPreview(
      context: context,
      parsed: parsed,
      sourceLabel: sourceLabel,
      initialFolderId: initialFolderId,
    );
    _pgnImportLog(
      'ingest text preview closed source=${sourceLabel ?? 'unknown'}',
    );
    return true;
  }

  /// Read, decode, and parse a PGN file off the UI isolate, then route it to
  /// the import preview. Returns false on I/O or decode failure.
  Future<bool> ingestPgnFileFromContext({
    required BuildContext context,
    required String path,
    String? sourceLabel,
    String? initialFolderId,
  }) async {
    _pgnImportLog(
      'ingest file start source=${sourceLabel ?? 'unknown'} path=$path',
    );
    final parsed = await _parseFileWithLoadingDialog(context, path);
    _pgnImportLog('ingest file parse returned count=${parsed?.length}');
    if (parsed == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not read that file.',
              style: TextStyle(color: kWhiteColor),
            ),
            backgroundColor: kRedColor.withValues(alpha: 0.9),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }
    if (parsed.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'That file does not contain a valid PGN',
              style: TextStyle(color: kWhiteColor),
            ),
            backgroundColor: kRedColor.withValues(alpha: 0.9),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    if (!context.mounted) return false;
    await _pushPreview(
      context: context,
      parsed: parsed,
      sourceLabel: sourceLabel ?? 'file',
      initialFolderId: initialFolderId,
    );
    _pgnImportLog('ingest file preview closed path=$path');
    return true;
  }

  Future<void> _handleSharedMedia(
    List<SharedMediaFile> files,
    GlobalKey<NavigatorState> navigatorKey, {
    required bool waitAppReady,
  }) async {
    if (files.isEmpty) return;
    final pgnFile = files.firstWhere(
      (f) => _looksLikePgn(f),
      orElse: () => files.first,
    );
    if (pgnFile.path.isEmpty) return;

    await handlePgnFilePath(
      pgnFile.path,
      navigatorKey,
      waitAppReady: waitAppReady,
    );
  }

  /// Public entry point for iOS file-open URLs delivered via app_links
  /// (DeepLinkService routes `file://` URIs here) and any other path-only
  /// caller. Reads the file, parses, then routes single-game PGNs to the
  /// board and multi-game PGNs to the preview screen — same behavior as
  /// the share-intent flow.
  Future<void> handlePgnFilePath(
    String path,
    GlobalKey<NavigatorState> navigatorKey, {
    required bool waitAppReady,
  }) async {
    if (path.isEmpty) return;
    _pgnImportLog('handle path start waitAppReady=$waitAppReady path=$path');

    if (waitAppReady) {
      _pgnImportLog('handle path waiting for app ready');
      try {
        await DeepLinkService.awaitAppReady().timeout(
          const Duration(seconds: 30),
        );
        _pgnImportLog('handle path app ready');
      } catch (_) {
        // Proceed anyway — worst case the push is deferred by the navigator.
        _pgnImportLog('handle path app ready timed out; continuing');
      }
    }

    final navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      _pgnImportLog('handle path abort: navigator unavailable');
      return;
    }
    // ignore: use_build_context_synchronously
    final context = navigator.context;
    // ignore: use_build_context_synchronously
    final parsed = await _parseFileWithLoadingDialog(context, path);
    _pgnImportLog('handle path parse returned count=${parsed?.length}');
    if (!navigator.mounted) {
      _pgnImportLog('handle path abort: navigator unmounted after parse');
      return;
    }
    if (parsed == null || parsed.isEmpty) {
      _pgnImportLog('handle path abort: no parsed games');
      return;
    }

    final games = parsed.map((e) => e.chessGame).toList();
    _pgnImportLog('handle path routing games=${games.length}');

    if (games.length == 1) {
      // Single-game file open → straight to the board, per spec.
      _openSingleGameOnBoard(navigator, games.single);
    } else {
      navigator.push(
        MaterialPageRoute(
          builder:
              (_) => PgnImportPreviewScreen(
                games: games,
                sourceLabel: 'shared file',
              ),
        ),
      );
    }
  }

  void _openSingleGameOnBoard(NavigatorState navigator, ChessGame game) {
    _pgnImportLog('open single game board gameId=${game.gameId}');
    final tourModel = chessGameToImportedGamesTourModel(game);
    final context = navigator.context;
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(chessboardViewFromProviderNew.notifier).state =
        ChessboardView.tour;

    navigator.push(
      MaterialPageRoute(
        builder:
            (_) => ChessBoardScreenNew(
              currentIndex: 0,
              games: [tourModel],
              showGamebaseButton: false,
              disableGamebaseOverlayByDefault: true,
            ),
      ),
    );
  }

  bool _looksLikePgn(SharedMediaFile f) {
    final lower = f.path.toLowerCase();
    if (lower.endsWith('.pgn')) return true;
    final mime = (f.mimeType ?? '').toLowerCase();
    return mime.contains('pgn');
  }

  Future<List<ParsedPgnEntry>> _parseWithLoadingDialog(
    BuildContext context,
    String text,
  ) async {
    _pgnImportLog('parse text with loading start chars=${text.length}');
    return _runWithLoadingDialog(context, () async {
      _pgnImportLog('parse text worker dispatch chars=${text.length}');
      final parsed = await parsePgnsToChessGamesAsync(text);
      _pgnImportLog('parse text worker complete count=${parsed.length}');
      return parsed;
    });
  }

  Future<List<ParsedPgnEntry>?> _parseFileWithLoadingDialog(
    BuildContext context,
    String path,
  ) async {
    _pgnImportLog('parse file with loading start path=$path');
    return _runWithLoadingDialog(context, () => _readAndParsePgnFile(path));
  }

  Future<T> _runWithLoadingDialog<T>(
    BuildContext context,
    Future<T> Function() loader,
  ) async {
    if (!context.mounted) {
      _pgnImportLog('loader context unmounted before dialog; running anyway');
      return loader();
    }
    _pgnImportLog('loader dialog show');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PgnImportLoadingDialog(),
    );
    try {
      _pgnImportLog('loader waiting for first frame');
      await WidgetsBinding.instance.endOfFrame;
      _pgnImportLog('loader first frame complete; starting worker');
      return await loader();
    } finally {
      _pgnImportLog(
        'loader worker finished; closing dialog mounted=${context.mounted}',
      );
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  Future<void> _pushPreview({
    required BuildContext context,
    required List<ParsedPgnEntry> parsed,
    String? sourceLabel,
    String? initialFolderId,
  }) {
    _pgnImportLog(
      'push preview start count=${parsed.length} source=${sourceLabel ?? 'unknown'}',
    );
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => PgnImportPreviewScreen(
              games: parsed.map((e) => e.chessGame).toList(),
              initialFolderId: initialFolderId,
              sourceLabel: sourceLabel,
            ),
      ),
    );
  }
}

Future<List<ParsedPgnEntry>?> _readAndParsePgnFile(String path) {
  return Isolate.run(() async {
    try {
      _pgnImportLog('worker file start path=$path');
      final file = File(path);
      if (!await file.exists()) {
        _pgnImportLog('worker file missing path=$path');
        return null;
      }
      final stat = await file.stat();
      _pgnImportLog(
        'worker file stat bytes=${stat.size} modified=${stat.modified.toIso8601String()}',
      );
      final bytes = await file.readAsBytes();
      _pgnImportLog('worker file read bytes=${bytes.length}');
      // Most PGNs are ASCII/UTF-8; a few TWIC files are latin1. Try UTF-8
      // first (allowMalformed so a stray byte doesn't kill the whole file),
      // fall back to latin1 if the result is empty after trim.
      final utf = utf8.decode(bytes, allowMalformed: true);
      final text =
          utf.trim().isNotEmpty
              ? utf
              : latin1.decode(bytes, allowInvalid: true);
      _pgnImportLog('worker file decoded chars=${text.length}');
      final stopwatch = Stopwatch()..start();
      final parsed = parsePgnsToChessGames(text);
      stopwatch.stop();
      _pgnImportLog(
        'worker file parsed count=${parsed.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return parsed;
    } catch (e) {
      _pgnImportLog('worker file failed path=$path error=$e');
      return null;
    }
  });
}

void _pgnImportLog(String message) {
  stdout.writeln('[PGN_IMPORT ${DateTime.now().toIso8601String()}] $message');
}

class _PgnImportLoadingDialog extends StatelessWidget {
  const _PgnImportLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: kBackgroundColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                ),
              ),
              SizedBox(width: 16),
              Text(
                'Loading PGN...',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
