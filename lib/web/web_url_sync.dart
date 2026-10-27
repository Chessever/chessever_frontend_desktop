import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:web/web.dart' as web;

import 'package:chessever/desktop/services/desktop_deep_link_router.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';

/// Keeps app.chessever.com addresses interchangeable with chessever.com ones.
///
/// On load, the path is opened the way chessever.com would show it: detail
/// pages (games, broadcasts, players, collections, books) through the
/// desktop deep-link router, list pages as their tabs. Afterwards the address
/// bar follows the active tab, so dropping or adding `app.` keeps the visitor
/// on the same page.
class WebUrlSync {
  WebUrlSync._();

  static ProviderSubscription<DesktopTabsState>? _tabs;
  static ProviderSubscription<Map<String, BoardTabGameArgs>>? _boards;

  /// The tab the arrival address opened, and that address. While the tab
  /// stays active the visitor's own URL stays in the bar, rather than one
  /// rebuilt from the tab (an event's canonical slug can differ from the
  /// tour slug the visitor used).
  static String? _arrivalTabId;
  static String? _arrivalPath;

  static Future<void> start(ProviderContainer container) async {
    await _openInitialPath(container);
    final arrival = Uri.base;
    if (arrival.pathSegments.any((s) => s.isNotEmpty)) {
      _arrivalTabId = container.read(desktopTabsProvider).activeId;
      _arrivalPath =
          arrival.hasQuery ? '${arrival.path}?${arrival.query}' : arrival.path;
    }
    void sync() {
      final activeId = container.read(desktopTabsProvider).activeId;
      if (_arrivalTabId != null && activeId == _arrivalTabId) {
        _replacePath(_arrivalPath!);
        return;
      }
      _arrivalTabId = null;
      _replacePath(_pathForActiveTab(container));
    }

    _tabs = container.listen(desktopTabsProvider, (_, _) => sync());
    // A different game in the arrival tab is a new page; follow it.
    _boards = container.listen(boardTabGameArgsByTabIdProvider, (_, _) {
      _arrivalTabId = null;
      sync();
    });
    sync();
  }

  static void stop() {
    _tabs?.close();
    _boards?.close();
  }

  /// List pages on chessever.com and the tab that shows the same content.
  static const Map<String, TabKind> _listPages = {
    'broadcast': TabKind.tournaments,
    'broadcasts': TabKind.tournaments,
    'calendar': TabKind.calendar,
    'rankings': TabKind.rankings,
    'chess-players': TabKind.rankings,
    'watch': TabKind.watch,
    'analysis': TabKind.board,
  };

  static Future<void> _openInitialPath(ProviderContainer container) async {
    final current = Uri.base;
    final segments = current.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return;

    final website = Uri(
      scheme: 'https',
      host: 'chessever.com',
      pathSegments: segments,
      queryParameters:
          current.queryParameters.isEmpty ? null : current.queryParameters,
    );
    if (isDesktopRoutableWebDeepLink(website)) {
      await DesktopDeepLinkRouter.instance.handle(website, container);
      return;
    }
    final listTab = segments.length == 1 ? _listPages[segments.first] : null;
    if (listTab != null) {
      container.read(desktopTabsProvider.notifier).open(listTab);
    }
  }

  static String _pathForActiveTab(ProviderContainer container) {
    final tab = container.read(desktopTabsProvider).active;
    if (tab == null) return '/';
    switch (tab.kind) {
      case TabKind.board:
        final args = container.read(boardTabGameArgsByTabIdProvider)[tab.id];
        if (args == null) return '/analysis';
        final url =
            args.sourceGame != null
                ? buildDesktopGameShareUrl(game: args.sourceGame)
                : buildDesktopGameShareUrl(gameId: args.gameId);
        return url == null ? '/analysis' : _pathOf(url);
      case TabKind.tournamentDetail:
        final event = container.read(tournamentForTabProvider(tab.id));
        if (event == null) return '/broadcast';
        return _pathOf(
          buildDesktopEventShareUrl(id: event.id, title: event.title),
        );
      case TabKind.tournaments:
        return '/broadcast';
      case TabKind.calendar:
        return '/calendar';
      case TabKind.rankings:
        return '/rankings';
      case TabKind.watch:
        return '/watch';
      default:
        return '/';
    }
  }

  static String _pathOf(String url) {
    final uri = Uri.parse(url);
    return uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  }

  static void _replacePath(String path) {
    final location = web.window.location;
    if ('${location.pathname}${location.search}' == path) return;
    web.window.history.replaceState(null, '', path);
  }
}
