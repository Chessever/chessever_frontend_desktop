import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'package:chessever/desktop/widgets/board_share_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/utils/game_share_utils.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _lichessShortIdPattern = RegExp(r'^[A-Za-z0-9]{8}$');

String? buildDesktopGameShareUrl({
  GamesTourModel? game,
  String? gameId,
  String? tourSlug,
  String? roundSlug,
}) {
  final modelUrl = game == null ? null : buildGameShareUrl(game: game);
  if (modelUrl != null && modelUrl.trim().isNotEmpty) return modelUrl;
  if (game != null &&
      game.source != GameSource.supabase &&
      game.source != GameSource.savedAnalysis) {
    return null;
  }

  final id = (gameId ?? game?.gameId)?.trim();
  if (id == null || !_isResolvableSharedGameId(id)) return null;

  final uri = Uri.parse('https://chessever.com/games/$id');
  final queryParams = <String, String>{};
  final tour = (tourSlug ?? game?.tourSlug)?.trim();
  final round = (roundSlug ?? game?.roundSlug)?.trim();
  if (tour != null && tour.isNotEmpty) queryParams['tour'] = tour;
  if (round != null && round.isNotEmpty) queryParams['round'] = round;

  return queryParams.isEmpty
      ? uri.toString()
      : uri.replace(queryParameters: queryParams).toString();
}

String? buildSavedAnalysisShareUrl(SavedAnalysis analysis) {
  return buildDesktopGameShareUrl(gameId: analysis.sourceGameId);
}

String buildDesktopEventShareUrl({
  required String id,
  required String title,
  String? tourId,
  String? tourSlug,
}) {
  final resolvedTourId = tourId?.trim();
  final resolvedTourSlug = tourSlug?.trim();
  if (resolvedTourId != null &&
      resolvedTourId.isNotEmpty &&
      resolvedTourSlug != null &&
      resolvedTourSlug.isNotEmpty) {
    return 'https://chessever.com/broadcast/$resolvedTourSlug/$resolvedTourId';
  }

  final slug = _slugify(title);
  return 'https://chessever.com/broadcast/$slug/$id';
}

Future<String?> resolveDesktopEventShareUrl({
  required WidgetRef ref,
  required GroupEventCardModel event,
}) async {
  if (event.eventSource == EventSource.communityEvent) return null;

  ({String id, String slug})? tour;
  try {
    tour = await ref
        .read(groupBroadcastRepositoryProvider)
        .getPrimaryTourSlugAndId(event.id);
  } catch (_) {
    tour = null;
  }

  return buildDesktopEventShareUrl(
    id: event.id,
    title: event.title,
    tourId: tour?.id,
    tourSlug: tour?.slug,
  );
}

Future<void> shareDesktopEvent({
  required BuildContext context,
  required WidgetRef ref,
  required GroupEventCardModel event,
}) async {
  final url = await resolveDesktopEventShareUrl(ref: ref, event: event);
  if (!context.mounted) return;
  if (url == null || url.isEmpty) {
    _toast(context, 'This event has no shareable broadcast link.', error: true);
    return;
  }
  await Share.share(url, sharePositionOrigin: _shareOrigin(context));
}

Future<void> copyDesktopShareUrl(
  BuildContext context,
  String? url, {
  String copiedLabel = 'Link copied to clipboard',
  String missingLabel = 'No shareable link available',
}) async {
  final text = url?.trim();
  if (text == null || text.isEmpty) {
    _toast(context, missingLabel, error: true);
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  _toast(context, copiedLabel);
}

Future<void> showDesktopGameShareDialog({
  required BuildContext context,
  required WidgetRef ref,
  required GamesTourModel game,
}) async {
  try {
    final pgn = await resolveGameSharePgn(
      game: game,
      analysisGame: null,
      savedAnalysisData: null,
      fetchSupabasePgn: (gameId) async {
        try {
          return await ref.read(gameRepositoryProvider).getGamePgn(gameId);
        } catch (_) {
          return null;
        }
      },
      fetchGamebasePgn: (gameId) async {
        try {
          final resolved = await ref
              .read(gamebaseRepositoryProvider)
              .getGameWithPgn(gameId);
          if (resolved == null) return null;
          final direct = resolved.pgn?.trim();
          if (direct != null && direct.isNotEmpty) return direct;
          return buildPgnFromGamebaseData(resolved.data);
        } catch (_) {
          return null;
        }
      },
    );

    final shareUrl = buildDesktopGameShareUrl(game: game);
    final chessGame = ChessGame.fromPgn(game.gameId, pgn);
    final snapshot = buildGameShareSnapshot(game: game, pgn: pgn);
    final headers = _headersForGame(chessGame, game, shareUrl: shareUrl);
    final shareGame = chessGame.copyWith(metadata: headers);

    if (!context.mounted) return;
    await showBoardShareDialog(
      context,
      chessGame: shareGame,
      headers: headers,
      position: _positionFromFen(snapshot.positionFen),
      lastMove: snapshot.lastMove,
      pointer: const <int>[],
      shareUrl: shareUrl,
    );
  } catch (_) {
    if (!context.mounted) return;
    _toast(context, 'Failed to prepare share dialog.', error: true);
  }
}

Future<void> showSavedAnalysisShareDialog({
  required BuildContext context,
  required SavedAnalysis analysis,
}) async {
  final game = analysis.chessGame;
  final shareUrl = buildSavedAnalysisShareUrl(analysis);
  final headers = _stringHeaders(game.metadata);
  _applyChesseverPgnSource(headers, shareUrl);
  final shareGame = game.copyWith(metadata: headers);
  final mainline = game.mainline;
  final fen = mainline.isEmpty ? game.startingFen : mainline.last.fen;
  final lastMove = mainline.isEmpty ? null : Move.parse(mainline.last.uci);

  await showBoardShareDialog(
    context,
    chessGame: shareGame,
    headers: headers,
    position: _positionFromFen(fen),
    lastMove: lastMove,
    pointer: const <int>[],
    shareUrl: shareUrl,
  );
}

Map<String, String> _headersForGame(
  ChessGame chessGame,
  GamesTourModel game, {
  String? shareUrl,
}) {
  final headers = _stringHeaders(chessGame.metadata);

  void putIfEmpty(String key, String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return;
    final current = headers[key]?.trim() ?? '';
    if (current.isEmpty || current == '?') headers[key] = text;
  }

  putIfEmpty('White', game.whitePlayer.name);
  putIfEmpty('Black', game.blackPlayer.name);
  putIfEmpty('WhiteFed', game.whitePlayer.federation);
  putIfEmpty('BlackFed', game.blackPlayer.federation);
  putIfEmpty('WhiteTitle', game.whitePlayer.title);
  putIfEmpty('BlackTitle', game.blackPlayer.title);
  if (game.whitePlayer.rating > 0) {
    putIfEmpty('WhiteElo', game.whitePlayer.rating.toString());
  }
  if (game.blackPlayer.rating > 0) {
    putIfEmpty('BlackElo', game.blackPlayer.rating.toString());
  }
  putIfEmpty('Event', game.tourSlug ?? game.tourId);
  putIfEmpty('Round', game.roundSlug);
  putIfEmpty('Result', game.gameStatus.displayText);
  _applyChesseverPgnSource(headers, shareUrl);

  return headers;
}

Map<String, String> _stringHeaders(Map<String, dynamic> metadata) {
  return metadata.map((key, value) => MapEntry(key, value?.toString() ?? ''));
}

void _applyChesseverPgnSource(Map<String, String> headers, String? shareUrl) {
  final url = shareUrl?.trim();
  if (url == null || url.isEmpty) return;
  headers['Site'] = url;
  headers['Source'] = url;
  headers['ChessEverSourceUrl'] = url;
}

Position _positionFromFen(String fen) {
  try {
    return Chess.fromSetup(Setup.parseFen(fen));
  } catch (_) {
    return Chess.initial;
  }
}

Rect _shareOrigin(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null) return const Rect.fromLTWH(0, 0, 1, 1);
  return box.localToGlobal(Offset.zero) & box.size;
}

void _toast(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  showDesktopToast(context, message, error: error);
}

bool _isResolvableSharedGameId(String id) {
  final trimmed = id.trim();
  return _uuidPattern.hasMatch(trimmed) ||
      _lichessShortIdPattern.hasMatch(trimmed);
}

String _slugify(String input) {
  final lower = input.toLowerCase();
  final dashed = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  final trimmed = dashed.replaceAll(RegExp(r'^-+|-+$'), '');
  return trimmed.isEmpty ? 'event' : trimmed;
}
