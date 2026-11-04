import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_smart_games.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory.dart';
import 'package:chessever/desktop/state/desktop_calendar_directory_provider.dart';
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
  final kind = desktopWebListKind(current);
  if (kind != null) {
    final id = container.read(desktopTabsProvider.notifier).open(kind);
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
  final segments = current.pathSegments;
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
  );
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
    }
  }
  return opened;
}
