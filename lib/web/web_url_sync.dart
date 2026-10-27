import 'dart:async';
import 'dart:js_interop';

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
/// on the same page. Each new page is a browser history entry carrying its
/// tab, so Back and Forward move between pages instead of leaving the app.
class WebUrlSync {
  WebUrlSync._();

  static ProviderSubscription<DesktopTabsState>? _tabs;
  static ProviderSubscription<Map<String, BoardTabGameArgs>>? _boards;
  static ProviderSubscription<Object?>? _events;
  static JSFunction? _onPopState;

  /// The tab the arrival address opened, that address, and the address the
  /// tab itself produced then. While the tab still shows that page the
  /// visitor's own URL stays in the bar, rather than one rebuilt from the
  /// tab (an event's canonical slug can differ from the tour slug the
  /// visitor used); once it shows another page the bar follows it.
  static String? _arrivalTabId;
  static String? _arrivalPath;
  static String? _arrivalTabPath;

  /// Set while a Back or Forward is being applied, so the tab change it
  /// causes rewrites the current entry instead of pushing a new one.
  static bool _restoring = false;

  static Future<void> start(ProviderContainer container) async {
    await _openInitialPath(Uri.base, container);
    final arrival = Uri.base;
    if (arrival.pathSegments.any((s) => s.isNotEmpty)) {
      _arrivalTabId = container.read(desktopTabsProvider).activeId;
      _arrivalPath =
          arrival.hasQuery ? '${arrival.path}?${arrival.query}' : arrival.path;
      _arrivalTabPath = _pathForActiveTab(container);
    }

    String target() {
      final activeId = container.read(desktopTabsProvider).activeId;
      final tabPath = _pathForActiveTab(container);
      if (_arrivalTabId != null &&
          activeId == _arrivalTabId &&
          tabPath == _arrivalTabPath) {
        return _arrivalPath!;
      }
      _arrivalTabId = null;
      return tabPath;
    }

    void sync({bool replace = false}) {
      final path = target();
      final location = web.window.location;
      if ('${location.pathname}${location.search}' == path) return;
      final activeId = container.read(desktopTabsProvider).activeId;
      final state = {'tab': activeId}.jsify();
      if (replace || _restoring) {
        web.window.history.replaceState(state, '', path);
      } else {
        web.window.history.pushState(state, '', path);
      }
    }

    _tabs = container.listen(desktopTabsProvider, (_, _) => sync());
    _boards = container.listen(
      boardTabGameArgsByTabIdProvider,
      (_, _) => sync(),
    );
    _events = container.listen(tournamentByTabIdProvider, (_, _) => sync());

    _onPopState =
        ((web.PopStateEvent event) {
          unawaited(_restore(container, event.state, sync));
        }).toJS;
    web.window.addEventListener('popstate', _onPopState);

    sync(replace: true);
  }

  /// Shows the page a Back or Forward landed on: its tab when still open,
  /// else the address opened afresh.
  static Future<void> _restore(
    ProviderContainer container,
    JSAny? state,
    void Function({bool replace}) sync,
  ) async {
    _restoring = true;
    try {
      final tabId = (state?.dartify() as Map?)?['tab'];
      final tabs = container.read(desktopTabsProvider);
      if (tabId is String && tabs.tabs.any((tab) => tab.id == tabId)) {
        container.read(desktopTabsProvider.notifier).activate(tabId);
      } else {
        await _openInitialPath(Uri.parse(web.window.location.href), container);
      }
      sync(replace: true);
    } finally {
      _restoring = false;
    }
  }

  static void stop() {
    _tabs?.close();
    _boards?.close();
    _events?.close();
    final onPopState = _onPopState;
    if (onPopState != null) {
      web.window.removeEventListener('popstate', onPopState);
    }
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

  static Future<void> _openInitialPath(
    Uri current,
    ProviderContainer container,
  ) async {
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
}
