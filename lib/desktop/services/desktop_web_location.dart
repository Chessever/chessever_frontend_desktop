import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_team.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_web_board_position.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory_provider.dart';
import 'package:chessever/desktop/state/desktop_calendar_location.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/screens/calendar/calendar_screen.dart';
import 'package:chessever/screens/group_event/group_event_screen.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';

final desktopWebRoundByTabIdProvider =
    StateProvider<Map<String, ({String eventId, String roundId})>>((_) => {});

/// Every shell surface owns an address, including app-only tools. Keep shared
/// paths identical to the Next.js site; adding a TabKind makes this exhaustive
/// switch fail analysis until its route is chosen.
String desktopWebBasePath(TabKind kind) => switch (kind) {
  TabKind.board => '/analysis',
  TabKind.tournaments || TabKind.tournamentDetail => '/broadcast',
  TabKind.smartGames => '/games/search',
  TabKind.library || TabKind.databaseWorkspace => '/databases',
  TabKind.favorites => '/favorites',
  TabKind.players => '/players',
  TabKind.rankings => '/rankings',
  TabKind.calendar => '/calendar',
  TabKind.countrymen => '/countrymen',
  TabKind.settings => '/broadcast/settings',
  TabKind.howToUse => '/learn',
  TabKind.openingExplorer => '/analysis?explorer=1',
  TabKind.boardEditor => '/analysis?editor=1',
  TabKind.watch => '/watch',
  TabKind.playerScoreCard || TabKind.playerProfile => '/chess-players',
  TabKind.userProfile => '/account',
  TabKind.boardSettings => '/broadcast/settings?section=board',
  TabKind.play => '/play',
  TabKind.teamScoreCard => '/broadcast',
  TabKind.collections || TabKind.collectionWorkspace => '/collections',
  TabKind.inbox => '/app/inbox',
  TabKind.likes => '/app/likes',
};

/// Parse list/tool routes BEFORE the deep-link parser: `settings`, `hubs` and
/// `search` are reserved words, never broadcast or game ids.
TabKind? desktopWebListKind(Uri uri) {
  final path = '/${uri.pathSegments.where((s) => s.isNotEmpty).join('/')}';
  if (path == '/analysis') {
    if (uri.queryParameters['editor'] == '1') return TabKind.boardEditor;
    if (uri.queryParameters['explorer'] == '1') return TabKind.openingExplorer;
    return TabKind.board;
  }
  if (path == '/broadcast/settings') {
    return uri.queryParameters['section'] == 'board'
        ? TabKind.boardSettings
        : TabKind.settings;
  }
  return switch (path) {
    '/' ||
    '/broadcast' ||
    '/broadcasts' ||
    '/broadcast/hubs' => TabKind.tournaments,
    '/games/search' => TabKind.smartGames,
    '/library' || '/databases' || '/folders' || '/books' => TabKind.library,
    '/favorites' => TabKind.favorites,
    '/players' => TabKind.players,
    '/rankings' || '/chess-players' => TabKind.rankings,
    '/calendar' => TabKind.calendar,
    '/countrymen' => TabKind.countrymen,
    '/settings' => TabKind.settings,
    '/learn' || '/how-to-use' => TabKind.howToUse,
    '/watch' => TabKind.watch,
    '/account' => TabKind.userProfile,
    '/play' => TabKind.play,
    '/collections' => TabKind.collections,
    '/inbox' || '/app/inbox' => TabKind.inbox,
    _ => null,
  };
}

String desktopWebPlayerPath(String name, String identity) {
  var display = name.trim();
  if (display.contains(',')) {
    final parts = display.split(',');
    display =
        '${parts.sublist(1).join(',').trim()} ${parts.first.trim()}'.trim();
  }
  var slug = display.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 120) slug = slug.substring(0, 120);
  return '/player/${slug.isEmpty ? 'player' : slug}/${Uri.encodeComponent(identity)}';
}

String _pathOf(String url) {
  final uri = Uri.parse(url);
  return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
}

/// A single derived dependency graph replaces the old four hand-maintained
/// listeners. Identity and subview changes now update the address as well.
final desktopWebLocationProvider = Provider<String>((ref) {
  final tab = ref.watch(desktopTabsProvider).active;
  if (tab == null) return '/broadcast';
  switch (tab.kind) {
    case TabKind.board:
      final args = ref.watch(boardTabGameArgsByTabIdProvider)[tab.id];
      final session = ref.watch(
        boardPaneSessionByTabIdProvider.select((sessions) => sessions[tab.id]),
      );
      final url =
          args?.sourceGame != null
              ? buildDesktopGameShareUrl(game: args!.sourceGame)
              : buildDesktopGameShareUrl(gameId: args?.gameId);
      final query = <String, String>{};
      final currentSession =
          session != null &&
                  (args?.gameId == null ||
                      args!.gameId == session.lastAppliedGameId)
              ? session
              : null;
      if (currentSession != null) {
        final navigator = ChessGameNavigatorState(
          game: currentSession.game,
          movePointer: currentSession.pointer,
        );
        if (url == null || currentSession.pointer.length > 1) {
          query['fen'] = navigator.currentFen;
        } else {
          final ply =
              currentSession.pointer.isEmpty
                  ? 0
                  : currentSession.pointer.first + 1;
          if (ply != currentSession.game.mainline.length) query['ply'] = '$ply';
        }
        if (currentSession.flipped) query['flip'] = '1';
      } else if (args?.initialBoardFlipped == true) {
        query['flip'] = '1';
      }
      return Uri(
        path:
            url == null || (currentSession?.pointer.length ?? 0) > 1
                ? '/analysis'
                : Uri.parse(url).path,
        queryParameters: query.isEmpty ? null : query,
      ).toString();
    case TabKind.tournamentDetail:
      final event = ref.watch(tournamentForTabProvider(tab.id));
      if (event == null) return '/broadcast';
      var path = _pathOf(
        buildDesktopEventShareUrl(id: event.id, title: event.title),
      );
      final round = ref.watch(desktopWebRoundByTabIdProvider)[tab.id];
      if (round != null && round.eventId == event.id) {
        path = '$path/round/${Uri.encodeComponent(round.roundId)}';
      }
      final segment = ref.watch(tournamentDetailSegmentByTabIdProvider(tab.id));
      return segment == TournamentDetailSegment.games
          ? path
          : '$path?tab=${segment.name}';
    case TabKind.playerProfile:
      final player = ref.watch(playerProfileByTabIdProvider)[tab.id];
      final identity =
          player?.memorialRouteId ??
          player?.fideId?.toString() ??
          player?.gamebasePlayerId;
      if (player == null || identity == null) return '/chess-players';
      final path = desktopWebPlayerPath(player.playerName, identity);
      final section =
          ref.watch(playerProfileSectionByTabIdProvider)[tab.id] ??
          PlayerProfileSection.about;
      return section == PlayerProfileSection.about &&
              player.memorialRouteId != null
          ? path
          : '$path/${section.name}';
    case TabKind.playerScoreCard:
      final player = ref.watch(playerScoreCardByTabIdProvider)[tab.id];
      final context = ref.watch(playerScoreCardContextByTabIdProvider)[tab.id];
      final event = context?.selectedBroadcast;
      if (player == null) return '/chess-players';
      if (event != null && player.fideId != null) {
        return '${_pathOf(buildDesktopEventShareUrl(id: event.id, title: event.name))}/player/${player.fideId}';
      }
      return desktopWebPlayerPath(
        player.name,
        '${player.fideId ?? player.name}',
      );
    case TabKind.teamScoreCard:
      final team = ref.watch(teamScoreCardByTabIdProvider)[tab.id];
      final event = team?.selectedBroadcast;
      if (team == null || event == null) return '/broadcast';
      return '${_pathOf(buildDesktopEventShareUrl(id: event.id, title: event.name))}/team/${Uri.encodeComponent(team.teamName)}';
    case TabKind.collectionWorkspace:
      final collection =
          ref.watch(collectionWorkspaceArgsByTabIdProvider)[tab.id];
      return collection == null
          ? '/collections'
          : '/collections/${Uri.encodeComponent(collection.slug)}';
    case TabKind.databaseWorkspace:
      final database = ref.watch(databaseWorkspaceArgsByTabIdProvider)[tab.id];
      if (database == null) return '/databases';
      // Local device paths are never placed in a shareable address.
      return switch (database.source) {
        DatabaseWorkspaceSource.folder =>
          '/databases/${Uri.encodeComponent(database.folderId)}',
        DatabaseWorkspaceSource.twic => '/databases/twic',
        DatabaseWorkspaceSource.local => '/databases?source=local',
      };
    case TabKind.likes:
      final period = ref.watch(communityLikesPeriodProvider);
      final day = ref.watch(communityLikesDayProvider);
      final section = ref.watch(communityLikesSectionProvider);
      if (section == CommunityLikesSection.about) return '/app/likes';
      final query = <String, String>{
        if (day != null)
          'date':
              '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
        if (section == CommunityLikesSection.players) 'view': 'players',
      };
      return Uri(
        path: '/app/likes/${period.name}',
        queryParameters: query.isEmpty ? null : query,
      ).toString();
    case TabKind.smartGames:
      final type = ref.watch(desktopSmartGamesTypeByTabIdProvider)[tab.id];
      return type?.name == 'miniatures'
          ? '/app/miniatures/${ref.watch(desktopMiniaturesSectionByTabIdProvider(tab.id)).name}'
          : Uri(
            path: '/games/search',
            queryParameters: type == null ? null : {'collection': type.name},
          ).toString();
    case TabKind.tournaments:
      final category = ref.watch(selectedGroupCategoryProvider);
      return '/broadcast?tab=${category == GroupEventCategory.forYou ? 'for-you' : category.name}';
    case TabKind.calendar:
      final detail = ref.watch(desktopCalendarDetailByTabIdProvider)[tab.id];
      if (detail != null) return desktopCalendarEventPath(detail.event);
      final mode = ref.watch(desktopCalendarModeProvider);
      final year = ref.watch(selectedYearProvider);
      final month = ref.watch(selectedMonthProvider);
      return Uri(
        path: '/calendar',
        queryParameters: {
          'mode': mode.name,
          'month': '$year-${month.toString().padLeft(2, '0')}',
        },
      ).toString();
    default:
      return desktopWebBasePath(tab.kind);
  }
});

/// Capture page identity with the history entry. A tab can show several games
/// of the SAME kind, so remembering only its id (or calling goBack once) loses
/// the old game, collection, period or scorecard.
void Function() captureDesktopWebPage(ProviderContainer container) {
  final tabs = container.read(desktopTabsProvider);
  final tab = tabs.active;
  final boards = container.read(boardTabGameArgsByTabIdProvider);
  final sessions = container.read(boardPaneSessionByTabIdProvider);
  final events = container.read(tournamentByTabIdProvider);
  final players = container.read(playerProfileByTabIdProvider);
  final playerSections = container.read(playerProfileSectionByTabIdProvider);
  final scorecards = container.read(playerScoreCardByTabIdProvider);
  final scorecardContexts = container.read(
    playerScoreCardContextByTabIdProvider,
  );
  final teams = container.read(teamScoreCardByTabIdProvider);
  final collections = container.read(collectionWorkspaceArgsByTabIdProvider);
  final databases = container.read(databaseWorkspaceArgsByTabIdProvider);
  final smartTypes = container.read(desktopSmartGamesTypeByTabIdProvider);
  final period = container.read(communityLikesPeriodProvider);
  final day = container.read(communityLikesDayProvider);
  final section = container.read(communityLikesSectionProvider);
  final category = container.read(selectedGroupCategoryProvider);
  final calendarMode = container.read(desktopCalendarModeProvider);
  final year = container.read(selectedYearProvider);
  final month = container.read(selectedMonthProvider);
  final round = container.read(userSelectedRoundProvider);
  final scopedRounds = container.read(desktopWebRoundByTabIdProvider);
  final calendarDetails = container.read(desktopCalendarDetailByTabIdProvider);
  final miniatureSection =
      tab == null
          ? null
          : container.read(desktopMiniaturesSectionByTabIdProvider(tab.id));
  final segment =
      tab == null
          ? null
          : container.read(tournamentDetailSegmentByTabIdProvider(tab.id));
  return () {
    if (tab == null) return;
    void restore<T>(
      StateProvider<Map<String, T>> provider,
      Map<String, T> values,
    ) {
      final value = values[tab.id];
      container
          .read(provider.notifier)
          .update(
            (current) =>
                value == null
                    ? ({...current}..remove(tab.id))
                    : {...current, tab.id: value},
          );
    }

    restore(boardTabGameArgsByTabIdProvider, boards);
    restore(boardPaneSessionByTabIdProvider, sessions);
    final session = sessions[tab.id];
    if (tab.kind == TabKind.board && session != null) {
      final fen =
          ChessGameNavigatorState(
            game: session.game,
            movePointer: session.pointer,
          ).currentFen;
      container
          .read(desktopWebBoardPositionByTabIdProvider.notifier)
          .update(
            (positions) => {
              ...positions,
              tab.id: DesktopWebBoardPosition(
                fen: fen,
                flipped: session.flipped,
              ),
            },
          );
    }
    if (tab.kind == TabKind.board) {
      container
          .read(desktopWebBoardRestorationEpochProvider.notifier)
          .update((epochs) => {...epochs, tab.id: (epochs[tab.id] ?? 0) + 1});
    }
    restore(tournamentByTabIdProvider, events);
    restore(desktopWebRoundByTabIdProvider, scopedRounds);
    restore(playerProfileByTabIdProvider, players);
    restore(playerProfileSectionByTabIdProvider, playerSections);
    restore(playerScoreCardByTabIdProvider, scorecards);
    restore(playerScoreCardContextByTabIdProvider, scorecardContexts);
    restore(teamScoreCardByTabIdProvider, teams);
    restore(collectionWorkspaceArgsByTabIdProvider, collections);
    restore(databaseWorkspaceArgsByTabIdProvider, databases);
    restore(desktopSmartGamesTypeByTabIdProvider, smartTypes);
    if (tab.kind == TabKind.calendar) {
      final detail = calendarDetails[tab.id];
      container
          .read(desktopCalendarDetailByTabIdProvider.notifier)
          .update(
            (current) =>
                detail == null
                    ? ({...current}..remove(tab.id))
                    : {...current, tab.id: detail},
          );
    }
    if (tab.kind == TabKind.likes) {
      container.read(communityLikesPeriodProvider.notifier).state = period;
      container.read(communityLikesDayProvider.notifier).state = day;
      container.read(communityLikesSectionProvider.notifier).state = section;
    }
    if (tab.kind == TabKind.tournaments) {
      container.read(selectedGroupCategoryProvider.notifier).state = category;
    }
    if (tab.kind == TabKind.calendar) {
      container.read(desktopCalendarModeProvider.notifier).state = calendarMode;
      container.read(selectedYearProvider.notifier).state = year;
      container.read(selectedMonthProvider.notifier).state = month;
    }
    if (tab.kind == TabKind.tournamentDetail) {
      container.read(userSelectedRoundProvider.notifier).state = round;
    }
    if (miniatureSection != null) {
      container
          .read(desktopMiniaturesSectionByTabIdProvider(tab.id).notifier)
          .state = miniatureSection;
    }
    if (segment != null) {
      container
          .read(tournamentDetailSegmentByTabIdProvider(tab.id).notifier)
          .state = segment;
    }
    container
        .read(desktopTabsProvider.notifier)
        .restoreBrowserRoute(tab.id, tab.route);
  };
}
