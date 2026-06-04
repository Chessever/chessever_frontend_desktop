import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

bool canSaveDesktopGameToLibrary(GamesTourModel game) {
  return game.gameStatus.isFinished;
}

Future<int> copyDesktopGamesAsResolvedPgn({
  required BuildContext context,
  required WidgetRef ref,
  required List<GamesTourModel> games,
}) async {
  if (games.isEmpty) {
    showDesktopToast(context, 'Nothing to copy.', error: true);
    return 0;
  }

  final pgns = <String>[];
  var skipped = 0;
  for (final game in games) {
    try {
      final chessGame = await resolveDesktopChessGameForLibrary(ref, game);
      final pgn = exportGameToPgn(chessGame).trim();
      if (pgn.isNotEmpty && pgnHasMoves(pgn)) {
        pgns.add(pgn);
      } else {
        skipped += 1;
      }
    } catch (_) {
      skipped += 1;
    }
  }

  if (!context.mounted) return 0;
  if (pgns.isEmpty) {
    showDesktopToast(context, 'No PGN with moves to copy.', error: true);
    return 0;
  }

  await Clipboard.setData(ClipboardData(text: pgns.join('\n\n')));
  if (!context.mounted) return pgns.length;
  final count = pgns.length;
  final suffix = skipped > 0 ? ' ($skipped skipped without moves)' : '';
  showDesktopToast(
    context,
    'Copied $count ${count == 1 ? 'game' : 'games'} as PGN$suffix.',
  );
  return count;
}

Future<void> saveDesktopGameToLibrary({
  required BuildContext context,
  required WidgetRef ref,
  required GamesTourModel game,
  required String sourceLabel,
}) async {
  if (!canSaveDesktopGameToLibrary(game)) {
    showDesktopToast(
      context,
      'Live games can be saved after they finish.',
      error: true,
    );
    return;
  }

  showDesktopToast(context, 'Preparing game...');

  try {
    final chessGame = await resolveDesktopChessGameForLibrary(ref, game);
    if (!context.mounted) return;

    final outcome = await showLibrarySaveToFolderDialog(
      context: context,
      ref: ref,
      games: [chessGame],
      sourceLabel: sourceLabel.trim().isEmpty ? 'finished game' : sourceLabel,
    );
    if (!context.mounted || outcome == null || !outcome.didSave) return;

    showDesktopToast(context, outcome.toToastMessage());
  } catch (e) {
    if (!context.mounted) return;
    showDesktopToast(context, 'Failed to prepare game: $e', error: true);
  }
}

Future<ChessGame> resolveDesktopChessGameForLibrary(
  WidgetRef ref,
  GamesTourModel game,
) async {
  String? pgn = game.pgn;
  if (pgn == null || !pgnHasMoves(pgn)) {
    try {
      final supabasePgn = await ref
          .read(gameRepositoryProvider)
          .getGamePgn(game.gameId);
      if (supabasePgn != null && pgnHasMoves(supabasePgn)) {
        pgn = supabasePgn;
      }
    } catch (_) {}
  }

  if (pgn == null || !pgnHasMoves(pgn)) {
    try {
      final fullGame = await ref
          .read(gamebaseRepositoryProvider)
          .getGameWithPgn(game.gameId);
      final direct = fullGame?.pgn;
      if (direct != null && pgnHasMoves(direct)) {
        pgn = direct;
      } else {
        final built = buildPgnFromGamebaseData(fullGame?.data);
        if (built != null && pgnHasMoves(built)) {
          pgn = built;
        }
      }
    } catch (_) {}
  }

  if (pgn == null || pgn.trim().isEmpty || !pgnHasMoves(pgn)) {
    throw Exception('PGN not found for game ${game.gameId}');
  }

  final chessGame = ChessGame.fromPgn(game.gameId, pgn);
  final metadata = Map<String, dynamic>.from(chessGame.metadata);
  _putNonEmpty(metadata, 'White', game.whitePlayer.name);
  _putNonEmpty(metadata, 'Black', game.blackPlayer.name);
  _putNonEmpty(metadata, 'WhiteTitle', game.whitePlayer.title);
  _putNonEmpty(metadata, 'BlackTitle', game.blackPlayer.title);
  if (game.whitePlayer.rating > 0) {
    metadata['WhiteElo'] = game.whitePlayer.rating.toString();
  }
  if (game.blackPlayer.rating > 0) {
    metadata['BlackElo'] = game.blackPlayer.rating.toString();
  }

  final whiteFed =
      game.whitePlayer.countryCode.trim().isNotEmpty
          ? game.whitePlayer.countryCode
          : game.whitePlayer.federation;
  final blackFed =
      game.blackPlayer.countryCode.trim().isNotEmpty
          ? game.blackPlayer.countryCode
          : game.blackPlayer.federation;
  _putNonEmpty(metadata, 'WhiteFed', whiteFed);
  _putNonEmpty(metadata, 'BlackFed', blackFed);
  _putNonEmpty(metadata, 'Event', _resolveEventName(game));

  final result = game.gameStatus.displayText;
  if (result.trim().isNotEmpty) {
    metadata['Result'] = result;
  }

  // Saved rows are static snapshots. Explicitly clear live-board flags so a
  // finished game opened from the library cannot keep following broadcasts.
  metadata[ChessGame.metadataIsLiveKey] = false;
  metadata[ChessGame.metadataAllowMainlineExtensionKey] = false;

  return chessGame.copyWith(metadata: metadata);
}

void _putNonEmpty(Map<String, dynamic> metadata, String key, String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return;
  metadata[key] = text;
}

String? _resolveEventName(GamesTourModel game) {
  final slug = game.tourSlug?.trim();
  if (slug != null && _isReadableEventName(slug)) {
    return _humanizeSlug(slug);
  }
  final id = game.tourId.trim();
  return _isReadableEventName(id) ? id : null;
}

bool _isReadableEventName(String value) {
  if (value.isEmpty) return false;
  if (value.length >= 24 &&
      RegExp(r'^[0-9a-f-]+$', caseSensitive: false).hasMatch(value)) {
    return false;
  }
  return true;
}

String _humanizeSlug(String value) {
  return value
      .split(RegExp(r'[-_]+'))
      .where((part) => part.trim().isNotEmpty)
      .map((part) {
        final lower = part.toLowerCase();
        return lower[0].toUpperCase() + lower.substring(1);
      })
      .join(' ');
}
