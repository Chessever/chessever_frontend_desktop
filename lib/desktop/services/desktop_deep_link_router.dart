import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/desktop_app.dart'
    show desktopRootNavigatorKey;
import 'package:chessever/desktop/panes/library_pane.dart'
    show DatabaseWorkspaceArgs, openDatabaseWorkspaceTabForContainer;
import 'package:chessever/desktop/services/desktop_build_identity.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_team.dart';
import 'package:chessever/desktop/widgets/desktop_team_standings_view.dart'
    show DesktopTeamStandingsMode, teamStandingsModeByTabIdProvider;
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/library/shared_book_dialogs.dart'
    show showSharedBookPreviewDialog;
import 'package:chessever/repository/gamebase/memorial_player_local_search.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardPlayerProfileDataSourceProvider;
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart'
    show playerTourScreenProvider;
import 'package:chessever/screens/tour_detail/team_tour/team_tour_screen_provider.dart'
    show teamStandingsProvider;
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

/// Destinations an incoming link can open, in mobile dispatch priority:
/// game, book, folder, player scorecard, team scorecard, broadcast, player
/// profile.
enum DesktopIncomingLinkTarget {
  game,
  book,
  folder,
  playerScoreCard,
  teamScoreCard,
  broadcast,
  playerProfile,
}

/// One parsed incoming link. Only the fields of [target] are meaningful.
@immutable
class DesktopIncomingLink {
  const DesktopIncomingLink._(
    this.target, {
    this.game,
    this.broadcast,
    this.shareToken,
    this.folderId,
    this.fideId,
    this.teamName,
    this.profileId,
  });

  final DesktopIncomingLinkTarget target;
  final DesktopGameDeepLink? game;
  final DesktopBroadcastDeepLink? broadcast;
  final String? shareToken;
  final String? folderId;
  final int? fideId;

  /// Already percent-decoded (`Uri.pathSegments` decodes).
  final String? teamName;

  /// Player identity: always the LAST path segment, so both
  /// `/player/<fideId>` and the SEO form `/player/<name-slug>/<identity>`
  /// resolve to the same identity.
  final String? profileId;
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Parses every link shape the desktop app routes, following the phone's
/// parser and dispatch priority exactly.
@visibleForTesting
DesktopIncomingLink? parseDesktopIncomingLink(Uri uri) {
  final isWeb = _isChesseverWebUri(uri);
  final isScheme = _isChesseverSchemeUri(uri);
  if (!isWeb && !isScheme) return null;

  final segs = uri.pathSegments;
  String? shareToken;
  String? folderId;
  String? broadcastId;
  String? broadcastSlug;
  int? fideId;
  String? teamName;
  String? profileId;

  if (isWeb) {
    if (segs.length >= 2 && segs[0] == 'books') shareToken = segs[1];
    if (segs.length >= 2 && (segs[0] == 'databases' || segs[0] == 'folders')) {
      folderId = segs[1];
    }
    if (segs.isNotEmpty && segs[0] == 'broadcast') {
      if (segs.length >= 3) {
        broadcastSlug = segs[1];
        broadcastId = segs[2];
      } else if (segs.length == 2) {
        broadcastId = segs[1];
      }
      if (segs.length >= 5 && segs[3] == 'player') {
        fideId = int.tryParse(segs[4]);
      } else if (segs.length >= 5 && segs[3] == 'team') {
        teamName = _trimmedOrNull(segs[4]);
      }
    }
    if (segs.length >= 2 && segs[0] == 'player') {
      profileId = _trimmedOrNull(segs.last);
    }
  } else {
    if (uri.host == 'player' && segs.isNotEmpty) {
      profileId = _trimmedOrNull(segs.last);
    }
    if (uri.host == 'books' && segs.isNotEmpty) shareToken = segs[0];
    if ((uri.host == 'databases' || uri.host == 'folders') && segs.isNotEmpty) {
      folderId = segs[0];
    }
    if (uri.host == 'broadcast' && segs.isNotEmpty) {
      final playerIdx = segs.indexOf('player');
      final teamIdx = segs.indexOf('team');
      if (playerIdx > 0) {
        broadcastId = segs[playerIdx - 1];
        if (playerIdx >= 2) broadcastSlug = segs[playerIdx - 2];
        if (playerIdx + 1 < segs.length) {
          fideId = int.tryParse(segs[playerIdx + 1]);
        }
      } else if (teamIdx > 0) {
        broadcastId = segs[teamIdx - 1];
        if (teamIdx >= 2) broadcastSlug = segs[teamIdx - 2];
        if (teamIdx + 1 < segs.length) {
          teamName = _trimmedOrNull(segs[teamIdx + 1]);
        }
      } else {
        broadcastId = segs.last;
        if (segs.length >= 2) broadcastSlug = segs[segs.length - 2];
      }
    }
  }

  final game = parseDesktopGameDeepLink(uri);
  if (game != null && game.id.isNotEmpty) {
    return DesktopIncomingLink._(DesktopIncomingLinkTarget.game, game: game);
  }
  if (shareToken != null && shareToken.isNotEmpty) {
    return DesktopIncomingLink._(
      DesktopIncomingLinkTarget.book,
      shareToken: shareToken,
    );
  }
  if (folderId != null && folderId.isNotEmpty) {
    return DesktopIncomingLink._(
      DesktopIncomingLinkTarget.folder,
      folderId: folderId,
    );
  }
  final broadcast =
      broadcastId == null || broadcastId.isEmpty
          ? null
          : DesktopBroadcastDeepLink(
            id: broadcastId,
            slug: _trimmedOrNull(broadcastSlug),
          );
  if (broadcast != null && fideId != null) {
    return DesktopIncomingLink._(
      DesktopIncomingLinkTarget.playerScoreCard,
      broadcast: broadcast,
      fideId: fideId,
    );
  }
  if (broadcast != null && teamName != null) {
    return DesktopIncomingLink._(
      DesktopIncomingLinkTarget.teamScoreCard,
      broadcast: broadcast,
      teamName: teamName,
    );
  }
  if (broadcast != null) {
    return DesktopIncomingLink._(
      DesktopIncomingLinkTarget.broadcast,
      broadcast: broadcast,
    );
  }
  if (profileId != null) {
    return DesktopIncomingLink._(
      DesktopIncomingLinkTarget.playerProfile,
      profileId: profileId,
    );
  }
  return null;
}

List<Uri> desktopDeepLinkUrisFromArguments(Iterable<String> arguments) {
  final uris = <Uri>[];
  final seen = <String>{};
  for (final raw in arguments) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || parseDesktopIncomingLink(uri) == null) {
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
  return parseDesktopIncomingLink(uri) != null;
}

const _linkFetchTimeout = Duration(seconds: 12);
const _standingsTimeout = Duration(seconds: 20);

class DesktopDeepLinkRouter {
  DesktopDeepLinkRouter._();
  static final DesktopDeepLinkRouter instance = DesktopDeepLinkRouter._();

  Uri? _lastHandledUri;
  DateTime? _lastHandledAt;
  bool _routing = false;

  Future<bool> handle(Uri uri, ProviderContainer container) async {
    final link = parseDesktopIncomingLink(uri);
    if (link == null) {
      _trackDeepLink(
        'Desktop Deep Link Ignored',
        uri,
        properties: {'reason': 'unsupported_route'},
      );
      return false;
    }
    switch (link.target) {
      case DesktopIncomingLinkTarget.game:
        return _handleGame(uri, link.game!, container);
      case DesktopIncomingLinkTarget.broadcast:
        return _handleBroadcast(uri, link.broadcast!, container);
      case DesktopIncomingLinkTarget.book:
        return _route(
          uri,
          'book',
          () => _openSharedBook(link.shareToken!, container),
        );
      case DesktopIncomingLinkTarget.folder:
        return _route(
          uri,
          'folder',
          () => _openFolder(link.folderId!, container),
        );
      case DesktopIncomingLinkTarget.playerScoreCard:
        return _route(
          uri,
          'player_scorecard',
          () => _openPlayerScoreCard(link.broadcast!, link.fideId!, container),
        );
      case DesktopIncomingLinkTarget.teamScoreCard:
        return _route(
          uri,
          'team_scorecard',
          () => _openTeamScoreCard(link.broadcast!, link.teamName!, container),
        );
      case DesktopIncomingLinkTarget.playerProfile:
        return _route(
          uri,
          'player_profile',
          () => _openPlayerProfile(link.profileId!, container),
        );
    }
  }

  /// Shared duplicate guard, analytics and failure reporting for the link
  /// targets added after game and broadcast. [open] returns a miss reason
  /// (the link landed somewhere sane but not on its target) or null.
  Future<bool> _route(
    Uri uri,
    String linkType,
    Future<String?> Function() open,
  ) async {
    if (_shouldIgnoreDuplicateOrBusy(uri)) {
      _trackDeepLink(
        'Desktop Deep Link Ignored',
        uri,
        properties: {'link_type': linkType, 'reason': 'duplicate_or_busy'},
      );
      return true;
    }
    _trackDeepLink(
      'Desktop Deep Link Opened',
      uri,
      properties: {'link_type': linkType},
    );
    _markRouting(uri);
    try {
      final missReason = await open();
      _trackDeepLink(
        missReason == null
            ? 'Desktop Deep Link Completed'
            : 'Desktop Deep Link Missed',
        uri,
        properties: {
          'link_type': linkType,
          if (missReason != null) 'reason': missReason,
        },
      );
      return true;
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('[desktop deeplink] failed to open $uri: $e\n$stack');
      }
      _trackDeepLink(
        'Desktop Deep Link Failed',
        uri,
        properties: {'link_type': linkType},
      );
      _notify("Couldn't open that link.", error: true);
      return true;
    } finally {
      _routing = false;
    }
  }

  BuildContext? get _uiContext => desktopRootNavigatorKey.currentContext;

  void _notify(String message, {bool error = false}) {
    final context = _uiContext;
    if (context == null || !context.mounted) return;
    showDesktopToast(context, message, error: error);
  }

  Future<String?> _openSharedBook(
    String shareToken,
    ProviderContainer container,
  ) async {
    final context = _uiContext;
    if (context == null || !context.mounted) {
      throw StateError('No desktop window to show the shared book in');
    }
    // The preview handles a revoked or unknown token itself.
    unawaited(showSharedBookPreviewDialog(context, shareToken: shareToken));
    return null;
  }

  Future<String?> _openFolder(
    String folderId,
    ProviderContainer container,
  ) async {
    final repo = container.read(libraryRepositoryProvider);
    LibraryFolder? folder;
    try {
      folder = await repo.getFolder(folderId).timeout(_linkFetchTimeout);
    } catch (_) {
      folder = null;
    }
    // Not owned: a subscribed shared book is also reachable by id.
    if (folder == null) {
      try {
        final subscribed = await repo.getSubscribedBooks().timeout(
          _linkFetchTimeout,
        );
        for (final book in subscribed) {
          if (book.id == folderId) {
            folder = book;
            break;
          }
        }
      } catch (_) {
        folder = null;
      }
    }
    if (folder == null) {
      container.read(desktopTabsProvider.notifier).open(TabKind.library);
      _notify("That database isn't in your library.", error: true);
      return 'folder_not_found';
    }
    openDatabaseWorkspaceTabForContainer(
      container,
      DatabaseWorkspaceArgs.folder(
        folderId: folder.id,
        title: folder.name,
        isSubscribed: folder.isSubscribed,
      ),
    );
    return null;
  }

  Future<String?> _openPlayerScoreCard(
    DesktopBroadcastDeepLink broadcastLink,
    int fideId,
    ProviderContainer container,
  ) async {
    await _openBroadcast(
      broadcastLink,
      container,
      segment: TournamentDetailSegment.standings,
    );
    final player = await _awaitInStandings<PlayerStandingModel>(
      container,
      playerTourScreenProvider,
      (standing) => standing.fideId == fideId,
    );
    if (player == null) {
      _notify("Couldn't find that player in this event.", error: true);
      return 'player_not_in_standings';
    }
    container.read(scoreCardGamesContextProvider.notifier).state = null;
    container.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
        PlayerProfileDataSource.supabase;
    openPlayerScoreCardFromContainer(
      container,
      player,
      fromTournamentContext: true,
    );
    return null;
  }

  Future<String?> _openTeamScoreCard(
    DesktopBroadcastDeepLink broadcastLink,
    String teamName,
    ProviderContainer container,
  ) async {
    final tabId = await _openBroadcast(
      broadcastLink,
      container,
      segment: TournamentDetailSegment.standings,
    );
    container.read(teamStandingsModeByTabIdProvider(tabId).notifier).state =
        DesktopTeamStandingsMode.teams;
    final target = teamName.trim().toLowerCase();
    final team = await _awaitInStandings<TeamStandingModel>(
      container,
      teamStandingsProvider,
      (standing) => standing.teamName.trim().toLowerCase() == target,
    );
    // Like the phone, open the score card even when standings have not
    // produced the team yet: it resolves to the full standing once they do.
    openTeamScoreCardFromContainer(
      container,
      TeamScoreCardTabArgs(
        teamName: team?.teamName ?? teamName,
        selectedBroadcast: container.read(selectedBroadcastModelProvider),
      ),
    );
    return team == null ? 'team_not_in_standings' : null;
  }

  Future<String?> _openPlayerProfile(
    String profileId,
    ProviderContainer container,
  ) async {
    final memorial = await findBundledMemorialPlayerByRouteId(profileId);
    if (memorial != null) {
      openPlayerProfileFromContainer(
        container,
        PlayerProfileArgs(
          playerName: memorial.name,
          fideId: int.tryParse(memorial.fideId ?? ''),
          title: memorial.title,
          federation: memorial.fed,
          rating:
              memorial.ratingClassical > 0 ? memorial.ratingClassical : null,
          gamebasePlayerId: memorial.gamebasePlayerId,
          memorialSourceIdentity: memorial.sourceIdentity,
          memorialRouteId: memorial.routeId,
        ),
      );
      return null;
    }

    final fideId = int.tryParse(profileId);
    final player =
        fideId == null || fideId <= 0
            ? null
            : await container
                .read(chessPlayerRepositoryProvider)
                .getPlayerByFideId(fideId)
                .timeout(_linkFetchTimeout);
    if (player == null || player.name.trim().isEmpty) {
      container.read(desktopTabsProvider.notifier).open(TabKind.players);
      _notify("Couldn't find that player.", error: true);
      return 'player_profile_not_found';
    }
    openPlayerProfileFromContainer(
      container,
      PlayerProfileArgs(
        playerName: player.name,
        fideId: player.fideid,
        title: player.title,
        federation: player.country,
        rating: player.rating,
      ),
    );
    return null;
  }

  /// Waits until [provider] emits non-empty standings, then returns the
  /// first row matching [matches], or null once loaded-but-absent or after
  /// [_standingsTimeout]. A one-shot read is unsafe: standings start empty
  /// while the event is still loading.
  Future<T?> _awaitInStandings<T>(
    ProviderContainer container,
    ProviderListenable<AsyncValue<List<T>>> provider,
    bool Function(T row) matches,
  ) async {
    final completer = Completer<T?>();
    void inspect(AsyncValue<List<T>> value) {
      if (completer.isCompleted) return;
      final rows = value.valueOrNull;
      if (rows == null || rows.isEmpty) return;
      for (final row in rows) {
        if (matches(row)) {
          completer.complete(row);
          return;
        }
      }
      completer.complete(null);
    }

    final subscription = container.listen<AsyncValue<List<T>>>(
      provider,
      (_, next) => inspect(next),
      fireImmediately: true,
    );
    final timer = Timer(_standingsTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      subscription.close();
    }
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

  Future<String> _openBroadcast(
    DesktopBroadcastDeepLink link,
    ProviderContainer container, {
    TournamentDetailSegment segment = TournamentDetailSegment.games,
  }) async {
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
        .state = segment;
    container.read(selectedBroadcastModelProvider.notifier).state = broadcast;
    container.read(selectedTourModeProvider.notifier).state =
        segment == TournamentDetailSegment.standings
            ? TournamentDetailScreenMode.standings
            : TournamentDetailScreenMode.games;
    return tabId;
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
      // A website share link resolves to an ordinary broadcast game: free.
      // The provenance is still recorded so the tab carries it everywhere.
      accessContext: const DesktopAccessContext(
        feature: DesktopFeature.broadcast,
        action: DesktopAction.openContent,
        origin: DesktopDiscoveryOrigin.deepLink,
      ),
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
