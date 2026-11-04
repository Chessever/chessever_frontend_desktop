import 'package:chessever/desktop/state/community_likes_providers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_web_board_position.dart';
import 'package:chessever/desktop/state/opening_explorer_seed.dart';
import 'package:chessever/screens/board_editor/board_editor_state.dart';
import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory_provider.dart';
import 'package:chessever/desktop/state/desktop_calendar_location.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/calendar/calendar_screen.dart';
import 'package:chessever/screens/group_event/group_event_screen.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';

/// Resolves incoming browser URLs without depending on browser APIs, so the
/// same route contract can be exercised by native unit tests.
Future<bool> openDesktopWebLocation(
  Uri current,
  ProviderContainer container,
) async {
  final segments = current.pathSegments;
  if (current.path == '/app/likes' || current.path == '/likes') {
    container.read(desktopTabsProvider.notifier).open(TabKind.likes);
    container.read(communityLikesSectionProvider.notifier).state =
        CommunityLikesSection.about;
    return true;
  }
  final isAnalysis = segments.isNotEmpty && segments.first == 'analysis';
  final kind =
      isAnalysis
          ? desktopWebListKind(current.replace(path: '/analysis'))
          : desktopWebListKind(current);
  String? fen = current.queryParameters['fen'];
  if (isAnalysis && fen == null && segments.length > 1) {
    final ranks = segments.sublist(
      const ['standard', 'fromPosition'].contains(segments[1]) ? 2 : 1,
    );
    if (ranks.isNotEmpty) fen = ranks.join('/');
  }
  fen = fen?.replaceAll(RegExp(r'[_+\s]+'), ' ').trim();
  if (fen != null) {
    if (fen.isEmpty || fen.length > 200) return false;
    try {
      Chess.fromSetup(Setup.parseFen(fen), ignoreImpossibleCheck: true);
    } catch (_) {
      return false;
    }
  }
  final rawPly = int.tryParse(current.queryParameters['ply'] ?? '');
  final ply = rawPly != null && rawPly >= 0 && rawPly <= 100000 ? rawPly : null;
  final flipped =
      const ['1', 'true'].contains(current.queryParameters['flip']) ||
      current.queryParameters['pov'] == 'black' ||
      current.queryParameters['color'] == 'black';
  void requestPosition(String id) {
    if (ply == null && fen == null && !flipped) return;
    container
        .read(desktopWebBoardPositionByTabIdProvider.notifier)
        .update(
          (positions) => {
            ...positions,
            id: DesktopWebBoardPosition(ply: ply, fen: fen, flipped: flipped),
          },
        );
  }

  if (kind != null) {
    final id = container.read(desktopTabsProvider.notifier).open(kind);
    if (kind == TabKind.board) {
      if (fen != null) {
        container
            .read(boardTabGameArgsByTabIdProvider.notifier)
            .update(
              (games) => {
                ...games,
                id: BoardTabGameArgs(
                  pgn: '[SetUp "1"]\n[FEN "$fen"]\n\n*',
                  label: 'Analysis',
                  whiteName: 'White',
                  blackName: 'Black',
                  fenSeed: fen,
                  initialFen: fen,
                  initialBoardFlipped: flipped,
                ),
              },
            );
      }
      requestPosition(id);
    } else if (kind == TabKind.boardEditor && fen != null) {
      container.read(boardEditorProvider.notifier).loadFen(fen);
    } else if (kind == TabKind.openingExplorer && fen != null) {
      container
          .read(openingExplorerSeedProvider.notifier)
          .state = OpeningExplorerSeed(fen: fen, exactFenSearch: true);
    }
    if (kind == TabKind.smartGames) {
      final name = current.queryParameters['collection'];
      final type =
          PremiumGamesType.values
              .where((type) => type.name == name)
              .firstOrNull;
      if (type != null) {
        container
            .read(desktopSmartGamesTypeByTabIdProvider.notifier)
            .update((types) => {...types, id: type});
      }
    }
    if (kind == TabKind.tournaments) {
      final value = current.queryParameters['tab'];
      container
          .read(selectedGroupCategoryProvider.notifier)
          .state = switch (value) {
        'for-you' => GroupEventCategory.forYou,
        'past' => GroupEventCategory.past,
        'search' => GroupEventCategory.search,
        _ => GroupEventCategory.current,
      };
    }
    if (kind == TabKind.calendar) {
      container
          .read(desktopCalendarDetailByTabIdProvider.notifier)
          .update((items) => {...items}..remove(id));
      final mode =
          DesktopCalendarMode.values
              .where((mode) => mode.name == current.queryParameters['mode'])
              .firstOrNull;
      if (mode != null) {
        container.read(desktopCalendarModeProvider.notifier).state = mode;
      }
      final date = RegExp(
        r'^(\d{4})-(\d{2})$',
      ).firstMatch(current.queryParameters['month'] ?? '');
      if (date != null) {
        final year = int.parse(date[1]!);
        final month = int.parse(date[2]!);
        if (year >= 1900 && year <= 2200 && month >= 1 && month <= 12) {
          container.read(selectedYearProvider.notifier).state = year;
          container.read(selectedMonthProvider.notifier).state = month;
        }
      }
    }
    return true;
  }
  if (segments.length >= 3 && segments[0] == 'calendar') {
    final event = await container.read(desktopCalendarWebEventLoaderProvider)(
      current,
    );
    if (event == null) return false;
    final id = container
        .read(desktopTabsProvider.notifier)
        .open(TabKind.calendar);
    container
        .read(desktopCalendarDetailByTabIdProvider.notifier)
        .update(
          (items) => {
            ...items,
            id: DesktopCalendarDetail(events: [event], index: 0),
          },
        );
    return true;
  }
  if (segments.length >= 2 &&
      segments[0] == 'app' &&
      segments[1] == 'miniatures') {
    final id = container
        .read(desktopTabsProvider.notifier)
        .open(TabKind.smartGames);
    container
        .read(desktopSmartGamesTypeByTabIdProvider.notifier)
        .update((types) => {...types, id: PremiumGamesType.miniatures});
    final section =
        DesktopMiniaturesSection.values
            .where(
              (section) =>
                  section.name == (segments.length > 2 ? segments[2] : 'games'),
            )
            .firstOrNull;
    if (section != null) {
      container
          .read(desktopMiniaturesSectionByTabIdProvider(id).notifier)
          .state = section;
    }
    return true;
  }
  if (current.path == '/databases/twic') {
    openDatabaseWorkspaceTabForContainer(
      container,
      const DatabaseWorkspaceArgs.twic(),
    );
    return true;
  }
  final website = current.replace(
    scheme: 'https',
    host: 'chessever.com',
    port: null,
  );
  if (!isDesktopRoutableWebDeepLink(website)) return false;
  final opened = await DesktopDeepLinkRouter.instance.handle(
    website,
    container,
    browserNavigation: true,
  );
  if (opened && segments.isNotEmpty && segments.first == 'games') {
    final id = container.read(desktopTabsProvider).activeId;
    if (id != null &&
        container.read(desktopTabsProvider).active?.kind == TabKind.board) {
      requestPosition(id);
    }
  }
  if (opened && segments.isNotEmpty && segments[0] == 'broadcast') {
    final id = container.read(desktopTabsProvider).activeId;
    final segment =
        TournamentDetailSegment.values
            .where((s) => s.name == current.queryParameters['tab'])
            .firstOrNull;
    if (id != null && segment != null) {
      container
          .read(tournamentDetailSegmentByTabIdProvider(id).notifier)
          .state = segment;
    }
    if (segments.length == 5 && segments[3] == 'round') {
      container.read(userSelectedRoundProvider.notifier).state = (
        id: segments[4],
        userSelected: true,
      );
      final event = container.read(tournamentByTabIdProvider)[id];
      if (id != null && event != null) {
        container
            .read(desktopWebRoundByTabIdProvider.notifier)
            .update(
              (rounds) => {
                ...rounds,
                id: (eventId: event.id, roundId: segments[4]),
              },
            );
      }
    }
  }
  return opened;
}
