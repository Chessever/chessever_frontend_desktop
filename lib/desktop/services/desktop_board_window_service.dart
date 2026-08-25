import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';
import 'package:chessever/services/analytics/analytics_service.dart';

class DesktopBoardWindowService {
  const DesktopBoardWindowService({this.createWindow});

  final Future<void> Function(DesktopBoardWindowPayload payload)? createWindow;

  Future<void> openBoardGameWindow(BoardTabGameArgs args) async {
    AnalyticsService.instance.trackEventDetached(
      'Desktop Board Window Opened',
      properties: {
        'source': args.viewSource.name,
        'has_game_id': args.gameId?.trim().isNotEmpty == true,
        'has_pgn': args.pgn.trim().isNotEmpty,
      },
    );
    await _openPayload(DesktopBoardWindowPayload.fromArgs(args));
  }

  Future<void> openDesktopTabWindow(
    ProviderContainer container,
    DesktopTab tab,
  ) async {
    final boardArgs = container.read(boardTabGameArgsByTabIdProvider)[tab.id];
    AnalyticsService.instance.trackEventDetached(
      'Desktop Tab Window Opened',
      properties: {
        'tab_kind': tab.kind.name,
        'has_board_game': boardArgs != null,
      },
    );
    await _openPayload(
      DesktopBoardWindowPayload.fromTab(
        tab,
        boardArgs: boardArgs,
        metadata: _metadataForTab(container, tab),
      ),
    );
  }

  Future<void> _openPayload(DesktopBoardWindowPayload payload) async {
    if (createWindow != null) {
      await createWindow!(payload);
      return;
    }
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      throw UnsupportedError('Board windows are only available on desktop');
    }
    final controller = await WindowController.create(
      WindowConfiguration(hiddenAtLaunch: true, arguments: payload.encode()),
    );
    await controller.show();
  }

  Future<bool> detachDesktopTabToWindow(
    ProviderContainer container,
    String tabId,
  ) async {
    final tab = container
        .read(desktopTabsProvider)
        .tabs
        .firstWhere(
          (tab) => tab.id == tabId,
          orElse:
              () => const DesktopTab(id: '', kind: TabKind.board, title: ''),
        );
    if (tab.id.isEmpty || tab.kind != TabKind.board || !tab.closable) {
      return false;
    }

    await openDesktopTabWindow(container, tab);
    container.read(desktopTabsProvider.notifier).close(tabId);
    AnalyticsService.instance.trackEventDetached(
      'Desktop Tab Detached',
      properties: {'tab_kind': tab.kind.name},
    );
    return true;
  }

  Future<bool> detachBoardTabToWindow(
    ProviderContainer container,
    String tabId,
  ) {
    return detachDesktopTabToWindow(container, tabId);
  }
}

Map<String, Object?> _metadataForTab(
  ProviderContainer container,
  DesktopTab tab,
) {
  switch (tab.kind) {
    case TabKind.tournamentDetail:
      final tournament = container.read(tournamentByTabIdProvider)[tab.id];
      if (tournament == null) return const <String, Object?>{};
      return <String, Object?>{
        'id': tournament.id,
        'title': tournament.title,
        'dates': tournament.dates,
        'maxAvgElo': tournament.maxAvgElo,
        'timeUntilStart': tournament.timeUntilStart,
        'tourEventCategory': tournament.tourEventCategory.name,
        'timeControl': tournament.timeControl,
        'endDate': tournament.endDate?.toIso8601String(),
        'startDate': tournament.startDate?.toIso8601String(),
        'location': tournament.location,
        'searchTerms': tournament.searchTerms,
        'eventSource': tournament.eventSource.name,
      };
    case TabKind.playerProfile:
      final args = container.read(playerProfileByTabIdProvider)[tab.id];
      if (args == null) return const <String, Object?>{};
      return <String, Object?>{
        'playerName': args.playerName,
        'fideId': args.fideId,
        'title': args.title,
        'federation': args.federation,
        'rating': args.rating,
        'dataSource': args.dataSource.name,
        'gamebasePlayerId': args.gamebasePlayerId,
        'memorialSourceIdentity': args.memorialSourceIdentity,
        'memorialRouteId': args.memorialRouteId,
      };
    case TabKind.countrymen:
      final effectiveCountry =
          container.read(effectiveCountryProvider).valueOrNull;
      final countrymenState =
          container.exists(countrymenCombinedGamesProvider)
              ? container.read(countrymenCombinedGamesProvider)
              : null;
      final countryCode =
          effectiveCountry?.countryCode ?? countrymenState?.countryCode;
      final countryName =
          effectiveCountry?.name ?? countrymenState?.countryName;
      final selectedMode = container.read(selectedCountrymenModeProvider);
      return <String, Object?>{
        if (countryCode != null && countryCode.trim().isNotEmpty)
          'countryCode': countryCode,
        if (countryName != null && countryName.trim().isNotEmpty)
          'countryName': countryName,
        'countrymenMode': selectedMode.name,
      };
    default:
      return const <String, Object?>{};
  }
}

final desktopBoardWindowServiceProvider = Provider<DesktopBoardWindowService>((
  ref,
) {
  return const DesktopBoardWindowService();
});

Future<void> openBoardGameWindow(WidgetRef ref, BoardTabGameArgs args) {
  return ref.read(desktopBoardWindowServiceProvider).openBoardGameWindow(args);
}

Future<bool> detachBoardTabToWindow(ProviderContainer container, String tabId) {
  return container
      .read(desktopBoardWindowServiceProvider)
      .detachBoardTabToWindow(container, tabId);
}

Future<bool> detachDesktopTabToWindow(
  ProviderContainer container,
  String tabId,
) {
  return container
      .read(desktopBoardWindowServiceProvider)
      .detachDesktopTabToWindow(container, tabId);
}
