import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_build_identity.dart';
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
import 'package:chessever/services/analytics/analytics_service.dart';

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
  return uri.scheme == DesktopBuildIdentity.current.urlScheme ||
      uri.scheme == 'com.chessever.app';
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

/// True when [uri] is a web link the desktop app can route internally.
bool isDesktopRoutableWebDeepLink(Uri uri) {
  if (!_isChesseverWebUri(uri)) return false;
  return parseDesktopBroadcastDeepLink(uri) != null ||
      parseDesktopGameDeepLink(uri) != null;
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
    if (broadcast == null) {
      _trackDeepLink(
        'Desktop Deep Link Ignored',
        uri,
        properties: {'reason': 'unsupported_route'},
      );
      return false;
    }
    return _handleBroadcast(uri, broadcast, container);
  }

  Future<bool> _handleBroadcast(
    Uri uri,
    DesktopBroadcastDeepLink broadcast,
    ProviderContainer container,
  ) async {
    if (_shouldIgnoreDuplicateOrBusy(uri)) {
      _trackDeepLink(
        'Desktop Deep Link Ignored',
        uri,
        properties: {'link_type': 'broadcast', 'reason': 'duplicate_or_busy'},
      );
      return true;
    }
    _trackDeepLink(
      'Desktop Deep Link Opened',
      uri,
      properties: {'link_type': 'broadcast'},
    );
    _markRouting(uri);

    try {
      await _openBroadcast(broadcast, container);
      _trackDeepLink(
        'Desktop Deep Link Completed',
        uri,
        properties: {'link_type': 'broadcast'},
      );
      return true;
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] failed to open $uri: $e\n$stack');
      }
      _trackDeepLink(
        'Desktop Deep Link Failed',
        uri,
        properties: {'link_type': 'broadcast'},
      );
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
    if (_shouldIgnoreDuplicateOrBusy(uri)) {
      _trackDeepLink(
        'Desktop Deep Link Ignored',
        uri,
        properties: {'link_type': 'game', 'reason': 'duplicate_or_busy'},
      );
      return true;
    }
    _trackDeepLink(
      'Desktop Deep Link Opened',
      uri,
      properties: {'link_type': 'game'},
    );
    _markRouting(uri);

    try {
      await _openGame(game, container);
      _trackDeepLink(
        'Desktop Deep Link Completed',
        uri,
        properties: {'link_type': 'game'},
      );
      return true;
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] failed to open $uri: $e\n$stack');
      }
      _trackDeepLink(
        'Desktop Deep Link Failed',
        uri,
        properties: {'link_type': 'game'},
      );
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
      eventGames: [TournamentGameSummary.fromGamesTourModel(game)],
      gameListSelectedId: game.gameId,
    );

    container.read(chessboardViewFromProviderNew.notifier).state =
        ChessboardView.tour;
    openBoardGameTabFromContainer(
      container,
      args,
      focus: true,
      reuseExisting: true,
      replaceActive: false,
    );
  }
}

void _trackDeepLink(
  String eventName,
  Uri uri, {
  Map<String, Object?> properties = const <String, Object?>{},
}) {
  AnalyticsService.instance.trackEventDetached(
    eventName,
    properties: {
      'scheme': uri.scheme,
      'host': uri.host,
      'path_segment_count': uri.pathSegments.length,
      ...properties,
    },
  );
}
