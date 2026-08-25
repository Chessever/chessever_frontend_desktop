import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/services/desktop_picture_in_picture_channel.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/board_picture_in_picture_mode.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/providers/country_dropdown_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_combined_games_provider.dart';
import 'package:chessever/screens/countrymen/provider/countrymen_mode_provider.dart';
import 'package:chessever/services/analytics/analytics_service.dart';

class DesktopBoardWindowService {
  DesktopBoardWindowService({
    this.createWindow,
    this.onPictureInPictureVisibilityChanged,
  });

  final Future<void> Function(DesktopBoardWindowPayload payload)? createWindow;
  final ValueChanged<BoardPictureInPictureVisibility>?
  onPictureInPictureVisibilityChanged;

  Future<void> _pictureInPictureQueue = Future<void>.value();
  bool _pictureInPictureVisible = false;
  String? _pictureInPictureGameId;

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

  Future<void> openPictureInPictureWindow(BoardTabGameArgs args) async {
    AnalyticsService.instance.trackEventDetached(
      'Desktop Picture In Picture Opened',
      properties: {
        'source': args.viewSource.name,
        'has_game_id': args.gameId?.trim().isNotEmpty == true,
        'has_pgn': args.pgn.trim().isNotEmpty,
      },
    );
    final payload = DesktopBoardWindowPayload.fromArgs(
      args,
      pictureInPicture: true,
    );
    if (createWindow != null) {
      await _openPayload(payload);
      return;
    }
    await _enqueuePictureInPictureOperation(() async {
      final previousVisible = _pictureInPictureVisible;
      final previousGameId = _pictureInPictureGameId;
      _setPictureInPictureVisible(args.gameId);
      try {
        await _showOrReplacePictureInPicture(payload);
      } catch (_) {
        if (previousVisible) {
          _setPictureInPictureVisible(previousGameId);
        } else {
          _setPictureInPictureHidden();
        }
        rethrow;
      }
    });
  }

  /// Toggle entry point for the manual in-board control.
  ///
  /// Pressing the selected control for the game already in PiP hides that
  /// child. Pressing from another live game replaces the existing child's
  /// board instead, preserving the strict one-PiP invariant.
  Future<void> togglePictureInPictureWindow(BoardTabGameArgs args) async {
    final payload = DesktopBoardWindowPayload.fromArgs(
      args,
      pictureInPicture: true,
    );
    if (createWindow != null) {
      await _openPayload(payload);
      return;
    }
    await _enqueuePictureInPictureOperation(() async {
      final gameId = _normalizedGameId(args.gameId);
      if (_pictureInPictureVisible &&
          gameId != null &&
          gameId == _pictureInPictureGameId) {
        _setPictureInPictureHidden();
        try {
          await _hidePictureInPicture();
        } catch (_) {
          _setPictureInPictureVisible(gameId);
          rethrow;
        }
        return;
      }
      final previousVisible = _pictureInPictureVisible;
      final previousGameId = _pictureInPictureGameId;
      _setPictureInPictureVisible(gameId);
      try {
        await _showOrReplacePictureInPicture(payload);
      } catch (_) {
        if (previousVisible) {
          _setPictureInPictureVisible(previousGameId);
        } else {
          _setPictureInPictureHidden();
        }
        rethrow;
      }
    });
  }

  Future<void> dismissPictureInPictureWindow() {
    return _enqueuePictureInPictureOperation(() async {
      final previousVisible = _pictureInPictureVisible;
      final previousGameId = _pictureInPictureGameId;
      _setPictureInPictureHidden();
      try {
        await _hidePictureInPicture();
      } catch (_) {
        if (previousVisible) {
          _setPictureInPictureVisible(previousGameId);
        }
        rethrow;
      }
    });
  }

  void markPictureInPictureVisible(String gameId) {
    _setPictureInPictureVisible(gameId);
  }

  void markPictureInPictureHidden() {
    _setPictureInPictureHidden();
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
    // PiP configures and reveals itself only after the secondary engine has
    // applied its compact always-on-top bounds. Showing it here would expose
    // the platform runner's large default rectangle for a visible frame.
    if (payload.pictureInPicture) return;
    await controller.show();
  }

  Future<void> _showOrReplacePictureInPicture(
    DesktopBoardWindowPayload payload,
  ) async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      throw UnsupportedError('Board windows are only available on desktop');
    }
    final existing = await _findPictureInPictureWindow();
    if (existing == null) {
      final controller = await WindowController.create(
        WindowConfiguration(hiddenAtLaunch: true, arguments: payload.encode()),
      );
      // Treat the first same-payload replacement as a readiness handshake.
      // A second rapid toggle is queued behind this, so it cannot hide the
      // child before that child's own startup callback shows it again.
      await _replacePictureInPictureWhenReady(controller, payload);
      await controller.show();
      return;
    }

    await _replacePictureInPictureWhenReady(existing, payload);
    await existing.show();
  }

  Future<void> _hidePictureInPicture() async {
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      return;
    }
    final existing = await _findPictureInPictureWindow();
    if (existing != null) await existing.hide();
  }

  Future<WindowController?> _findPictureInPictureWindow() async {
    final windows = await WindowController.getAll();
    for (final controller in windows) {
      try {
        final payload = DesktopBoardWindowPayload.decode(controller.arguments);
        if (payload.pictureInPicture) return controller;
      } catch (_) {
        // Primary and ordinary detached windows either have empty arguments
        // or a non-PiP payload. They are never candidates for reuse.
      }
    }
    return null;
  }

  Future<void> _replacePictureInPictureWhenReady(
    WindowController controller,
    DesktopBoardWindowPayload payload,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    // A second click can arrive while the just-created child is still
    // warming its independent Flutter engine. Wait briefly for that child's
    // method handler instead of creating a duplicate window in the gap.
    for (var attempt = 0; attempt < 200; attempt++) {
      try {
        final replaced = await replacePictureInPictureGame(
          controller: controller,
          encodedBoardPayload: payload.encode(),
        );
        if (replaced) return;
        lastError = StateError('PiP window did not accept its replacement');
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    Error.throwWithStackTrace(
      lastError ?? StateError('PiP window is unavailable'),
      lastStackTrace ?? StackTrace.current,
    );
  }

  Future<void> _enqueuePictureInPictureOperation(
    Future<void> Function() operation,
  ) {
    final queued = _pictureInPictureQueue.then((_) => operation());
    _pictureInPictureQueue = queued.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return queued;
  }

  void _setPictureInPictureVisible(String? gameId) {
    _pictureInPictureVisible = true;
    _pictureInPictureGameId = _normalizedGameId(gameId);
    onPictureInPictureVisibilityChanged?.call(
      BoardPictureInPictureVisibility.visible(_pictureInPictureGameId),
    );
  }

  void _setPictureInPictureHidden() {
    _pictureInPictureVisible = false;
    _pictureInPictureGameId = null;
    onPictureInPictureVisibilityChanged?.call(
      const BoardPictureInPictureVisibility.hidden(),
    );
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
  return DesktopBoardWindowService(
    onPictureInPictureVisibilityChanged: (visibility) {
      ref.read(boardPictureInPictureVisibilityProvider.notifier).state =
          visibility;
    },
  );
});

Future<void> openBoardGameWindow(WidgetRef ref, BoardTabGameArgs args) {
  return ref.read(desktopBoardWindowServiceProvider).openBoardGameWindow(args);
}

Future<void> openPictureInPictureWindow(WidgetRef ref, BoardTabGameArgs args) {
  return ref
      .read(desktopBoardWindowServiceProvider)
      .openPictureInPictureWindow(args);
}

Future<void> togglePictureInPictureWindow(
  WidgetRef ref,
  BoardTabGameArgs args,
) {
  return ref
      .read(desktopBoardWindowServiceProvider)
      .togglePictureInPictureWindow(args);
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

String? _normalizedGameId(String? gameId) {
  final normalized = gameId?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
