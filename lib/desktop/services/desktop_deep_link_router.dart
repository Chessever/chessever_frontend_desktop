import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/group_broadcast/group_tour_repository.dart';
import 'package:chessever/repository/supabase/tour/tour_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart';

@visibleForTesting
class DesktopBroadcastDeepLink {
  const DesktopBroadcastDeepLink({required this.id, this.slug});

  /// Tail identifier from `/broadcast/<slug>/<id>`.
  ///
  /// For current share URLs this is usually a `tours.id`; legacy links may
  /// carry a `group_broadcasts.id`. The repository can resolve both shapes.
  final String id;
  final String? slug;
}

@visibleForTesting
class DesktopGameDeepLink {
  const DesktopGameDeepLink({required this.id, this.tour, this.round});

  /// Tail identifier from `/games/<id>`.
  ///
  /// Phone/web links commonly carry a Lichess short id, while some internal
  /// links can carry a Supabase UUID. The game repository resolves both.
  final String id;
  final String? tour;
  final String? round;
}

bool _isChesseverWebUri(Uri uri) {
  return (uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == 'chessever.com' || uri.host == 'www.chessever.com');
}

bool _isChesseverSchemeUri(Uri uri) {
  return uri.scheme == 'chessever' || uri.scheme == 'com.chessever.app';
}

String? _nonEmptyQueryValue(Uri uri, String key) {
  final value = uri.queryParameters[key]?.trim();
  return value == null || value.isEmpty ? null : value;
}

@visibleForTesting
DesktopGameDeepLink? parseDesktopGameDeepLink(Uri uri) {
  final isChesseverWeb = _isChesseverWebUri(uri);
  final isChesseverScheme = _isChesseverSchemeUri(uri);

  if (!isChesseverWeb && !isChesseverScheme) return null;

  if (isChesseverWeb) {
    if (uri.pathSegments.length < 2 || uri.pathSegments.first != 'games') {
      return null;
    }
    return DesktopGameDeepLink(
      id: uri.pathSegments[1],
      tour: _nonEmptyQueryValue(uri, 'tour'),
      round: _nonEmptyQueryValue(uri, 'round'),
    );
  }

  if (uri.host != 'games' || uri.pathSegments.isEmpty) return null;
  return DesktopGameDeepLink(
    id: uri.pathSegments.first,
    tour: _nonEmptyQueryValue(uri, 'tour'),
    round: _nonEmptyQueryValue(uri, 'round'),
  );
}

@visibleForTesting
DesktopBroadcastDeepLink? parseDesktopBroadcastDeepLink(Uri uri) {
  final isChesseverWeb = _isChesseverWebUri(uri);
  final isChesseverScheme = _isChesseverSchemeUri(uri);

  if (!isChesseverWeb && !isChesseverScheme) return null;

  if (isChesseverWeb) {
    if (uri.pathSegments.isEmpty || uri.pathSegments.first != 'broadcast') {
      return null;
    }
    if (uri.pathSegments.length >= 3) {
      return DesktopBroadcastDeepLink(
        slug: uri.pathSegments[1],
        id: uri.pathSegments[2],
      );
    }
    if (uri.pathSegments.length == 2) {
      return DesktopBroadcastDeepLink(id: uri.pathSegments[1]);
    }
    return null;
  }

  if (uri.host != 'broadcast') return null;
  if (uri.pathSegments.length >= 2) {
    return DesktopBroadcastDeepLink(
      slug: uri.pathSegments[0],
      id: uri.pathSegments[1],
    );
  }
  if (uri.pathSegments.length == 1) {
    return DesktopBroadcastDeepLink(id: uri.pathSegments[0]);
  }
  return null;
}

List<Uri> desktopDeepLinkUrisFromArguments(Iterable<String> arguments) {
  final uris = <Uri>[];
  final seen = <String>{};
  for (final raw in arguments) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        (parseDesktopBroadcastDeepLink(uri) == null &&
            parseDesktopGameDeepLink(uri) == null)) {
      continue;
    }
    final key = uri.toString();
    if (seen.add(key)) uris.add(uri);
  }
  return uris;
}

class DesktopDeepLinkRouter {
  DesktopDeepLinkRouter._();
  static final DesktopDeepLinkRouter instance = DesktopDeepLinkRouter._();

  Uri? _lastHandledUri;
  DateTime? _lastHandledAt;
  bool _routing = false;

  Future<bool> handle(Uri uri, ProviderContainer container) async {
    final game = parseDesktopGameDeepLink(uri);
    if (game != null) return _handleGame(uri, game, container);

    final broadcast = parseDesktopBroadcastDeepLink(uri);
    if (broadcast == null) return false;
    return _handleBroadcast(uri, broadcast, container);
  }

  Future<bool> _handleBroadcast(
    Uri uri,
    DesktopBroadcastDeepLink broadcast,
    ProviderContainer container,
  ) async {
    if (_shouldIgnoreDuplicateOrBusy(uri)) return true;
    _markRouting(uri);

    try {
      await _openBroadcast(broadcast, container);
      return true;
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] failed to open $uri: $e\n$stack');
      }
      return true;
    } finally {
      _routing = false;
    }
  }

  Future<bool> _handleGame(
    Uri uri,
    DesktopGameDeepLink game,
    ProviderContainer container,
  ) async {
    if (_shouldIgnoreDuplicateOrBusy(uri)) return true;
    _markRouting(uri);

    try {
      await _openGame(game, container);
      return true;
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] failed to open $uri: $e\n$stack');
      }
      return true;
    } finally {
      _routing = false;
    }
  }

  bool _shouldIgnoreDuplicateOrBusy(Uri uri) {
    final now = DateTime.now();
    if (_lastHandledUri == uri &&
        _lastHandledAt != null &&
        now.difference(_lastHandledAt!) < const Duration(seconds: 2)) {
      return true;
    }
    return _routing;
  }

  void _markRouting(Uri uri) {
    _lastHandledUri = uri;
    _lastHandledAt = DateTime.now();
    _routing = true;
  }

  Future<void> _openBroadcast(
    DesktopBroadcastDeepLink link,
    ProviderContainer container,
  ) async {
    final broadcast = await container
        .read(groupBroadcastRepositoryProvider)
        .getGroupBroadcastById(link.id)
        .timeout(const Duration(seconds: 12));

    await _preselectTourIfSharedLinkUsesTourId(
      container,
      linkId: link.id,
      groupBroadcastId: broadcast.id,
    );

    final tournament = GroupEventCardModel.fromGroupBroadcast(
      broadcast,
      const <String>[],
    );
    final tabs = container.read(desktopTabsProvider.notifier);
    final tabId = tabs.open(
      TabKind.tournamentDetail,
      title: tournament.title,
      reuseExisting: false,
      focus: true,
    );

    container.read(tournamentByTabIdProvider.notifier).update((existing) {
      return <String, GroupEventCardModel>{...existing, tabId: tournament};
    });
    container
        .read(tournamentDetailSegmentByTabIdProvider(tabId).notifier)
        .state = TournamentDetailSegment.games;
    container.read(selectedBroadcastModelProvider.notifier).state = broadcast;
    container.read(selectedTourModeProvider.notifier).state =
        TournamentDetailScreenMode.games;
  }

  Future<void> _preselectTourIfSharedLinkUsesTourId(
    ProviderContainer container, {
    required String linkId,
    required String groupBroadcastId,
  }) async {
    try {
      final tours = await container
          .read(tourRepositoryProvider)
          .getToursByIds([linkId])
          .timeout(const Duration(seconds: 8));
      if (tours.isEmpty) return;
      final tour = tours.first;
      if (tour.groupBroadcastId != groupBroadcastId) return;
      await AppDatabase.instance.setString(
        'selected_tour_$groupBroadcastId',
        tour.id,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] tour preselect skipped: $e');
      }
    }
  }

  Future<void> _openGame(
    DesktopGameDeepLink link,
    ProviderContainer container,
  ) async {
    final gameRow = await container
        .read(gameRepositoryProvider)
        .getGameByAnyId(link.id)
        .timeout(const Duration(seconds: 12));
    final game = GamesTourModel.fromGame(gameRow);
    final eventGames = await _eventGameSummariesForGame(container, game);
    final pgn = game.pgn?.trim() ?? '';

    final args = BoardTabGameArgs(
      gameId: game.gameId,
      pgn: pgn,
      label: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
      whiteName: game.whitePlayer.name,
      blackName: game.blackPlayer.name,
      whiteFederation: game.whitePlayer.federation,
      blackFederation: game.blackPlayer.federation,
      whiteTitle: game.whitePlayer.title,
      blackTitle: game.blackPlayer.title,
      whiteRating: game.whitePlayer.rating,
      blackRating: game.blackPlayer.rating,
      whiteFideId: game.whitePlayer.fideId,
      blackFideId: game.blackPlayer.fideId,
      fenSeed: game.fen,
      sourceGame: game.copyWith(pgn: pgn.isEmpty ? game.pgn : pgn),
      viewSource: ChessboardView.tour,
      tournamentTitle: link.tour ?? game.tourSlug ?? game.tourId,
      eventGames: eventGames,
      eventGamesLoading:
          eventGames.length <= 1 && game.tourId.trim().isNotEmpty,
      gameListSelectedId: game.gameId,
    );

    container.read(chessboardViewFromProviderNew.notifier).state =
        ChessboardView.tour;
    final tabId = openBoardGameTabFromContainer(
      container,
      args,
      focus: true,
      reuseExisting: true,
      replaceActive: false,
    );

    if (args.eventGamesLoading) {
      unawaited(_hydrateGameLinkEventContext(container, tabId, game));
    }
  }

  Future<List<TournamentGameSummary>> _eventGameSummariesForGame(
    ProviderContainer container,
    GamesTourModel game,
  ) async {
    if (game.tourId.trim().isEmpty) {
      return <TournamentGameSummary>[
        TournamentGameSummary.fromGamesTourModel(game),
      ];
    }

    try {
      final rows = await container
          .read(gameRepositoryProvider)
          .getGamesByTourId(game.tourId, limit: 200)
          .timeout(const Duration(seconds: 8));
      final summaries = <TournamentGameSummary>[];
      for (final row in rows) {
        try {
          summaries.add(
            TournamentGameSummary.fromGamesTourModel(
              GamesTourModel.fromGame(row),
            ),
          );
        } catch (_) {
          // Keep the active game usable even if a row is malformed.
        }
      }
      if (summaries.isNotEmpty) return summaries;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] event games hydrate skipped: $e');
      }
    }

    return <TournamentGameSummary>[
      TournamentGameSummary.fromGamesTourModel(game),
    ];
  }

  Future<void> _hydrateGameLinkEventContext(
    ProviderContainer container,
    String tabId,
    GamesTourModel game,
  ) async {
    final hydrated = await _eventGameSummariesForGame(container, game);
    final current = container.read(boardTabGameArgsByTabIdProvider)[tabId];
    if (current == null || current.gameId != game.gameId) return;

    container.read(boardTabGameArgsByTabIdProvider.notifier).update((existing) {
      final latest = existing[tabId];
      if (latest == null || latest.gameId != game.gameId) return existing;
      return <String, BoardTabGameArgs>{
        ...existing,
        tabId: latest.copyWith(eventGames: hydrated, eventGamesLoading: false),
      };
    });
  }
}
