import 'dart:async';
import 'dart:js_interop';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:web/web.dart' as web;

import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/services/desktop_web_navigation.dart';
import 'package:chessever/web/web_mount.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';

class _HistoryPage {
  const _HistoryPage(this.tabId, this.path, this.restore);
  final String? tabId;
  final String path;
  final void Function() restore;
}

/// Owns browser navigation for the shared desktop shell. Flutter's Navigator
/// URL reporting stays disabled, so it cannot overwrite these addresses.
///
/// Paths held here are app paths. The address bar carries them under the
/// page's mount ('/' on app.chessever.com, '/webapp/' on chessever.com), so the
/// conversion happens only where this reads or writes `location`/`history`.
class WebUrlSync {
  WebUrlSync._();

  static ProviderSubscription<String>? _location;
  static ProviderSubscription<({String id, bool userSelected})?>? _round;
  static Future<void> _restores = Future<void>.value();
  static JSFunction? _onPopState;
  static final Map<int, _HistoryPage> _pages = {};
  static bool _restoring = false;
  static bool _scheduled = false;
  static int _index = 0;
  static int _generation = 0;
  static String? _pinnedTab;
  static String? _pinnedPath;
  static String? _pinnedGeneratedPath;
  static String _mount = '/';

  static String _browserPath() => webAppPath(
    '${web.window.location.pathname}${web.window.location.search}',
    _mount,
  );

  static Uri _currentUri() =>
      webAppUri(Uri.parse(web.window.location.href), _mount);

  static void _pin(ProviderContainer container, String path) {
    _pinnedTab = container.read(desktopTabsProvider).activeId;
    _pinnedPath = path;
    _pinnedGeneratedPath = container.read(desktopWebLocationProvider);
  }

  static String _target(ProviderContainer container) {
    final generated = container.read(desktopWebLocationProvider);
    if (_pinnedTab == container.read(desktopTabsProvider).activeId &&
        generated == _pinnedGeneratedPath &&
        _pinnedPath != null) {
      return _pinnedPath!;
    }
    _pinnedTab = _pinnedPath = _pinnedGeneratedPath = null;
    return generated;
  }

  static _HistoryPage _capture(ProviderContainer container, String path) =>
      _HistoryPage(
        container.read(desktopTabsProvider).activeId,
        path,
        captureDesktopWebPage(container),
      );

  static void _stamp(String path, {required bool replace}) {
    final state = {'chessever': true, 'index': _index}.jsify();
    final url = webBrowserPath(path, _mount);
    if (replace) {
      web.window.history.replaceState(state, '', url);
    } else {
      web.window.history.pushState(state, '', url);
    }
  }

  static Future<void> start(ProviderContainer container) async {
    stop();
    final generation = _generation;
    _index = 0;
    _pages.clear();
    _restoring = true;
    _mount = webMountPath;
    final arrival = _currentUri();
    try {
      if (await openDesktopWebLocation(arrival, container) &&
          arrival.path != '/') {
        _pin(
          container,
          arrival.hasQuery ? '${arrival.path}?${arrival.query}' : arrival.path,
        );
      }
    } finally {
      _restoring = false;
    }
    if (generation != _generation) return;
    final path = _target(container);
    _pages[0] = _capture(container, path);
    // Stamp even when the path already matches. Otherwise the first Back has
    // no state and is mistaken for a closed tab or a navigation out of the app.
    _stamp(path, replace: true);

    void sync() {
      if (_restoring || _scheduled) return;
      _scheduled = true;
      // Opening a tab and installing its arguments is one navigation, not an
      // intermediate /analysis followed by a second /games entry.
      scheduleMicrotask(() {
        _scheduled = false;
        if (generation != _generation || _restoring) return;
        final path = _target(container);
        if (_browserPath() == path) return;
        _pages.removeWhere((index, _) => index > _index);
        _index++;
        _pages[_index] = _capture(container, path);
        // Browser history remains usable after eviction: reopen its URL.
        _pages.removeWhere((index, _) => index < _index - 100);
        _stamp(path, replace: false);
      });
    }

    _location = container.listen(desktopWebLocationProvider, (_, _) => sync());
    _round = container.listen<({String id, bool userSelected})?>(
      userSelectedRoundProvider,
      (_, next) {
        final tab = container.read(desktopTabsProvider).active;
        if (_restoring ||
            next == null ||
            !next.userSelected ||
            tab?.kind != TabKind.tournamentDetail) {
          return;
        }
        final event = container.read(tournamentByTabIdProvider)[tab!.id];
        if (event == null) return;
        container
            .read(desktopWebRoundByTabIdProvider.notifier)
            .update(
              (rounds) => {
                ...rounds,
                tab.id: (eventId: event.id, roundId: next.id),
              },
            );
      },
    );
    _onPopState =
        ((web.PopStateEvent event) {
          final uri = _currentUri();
          final state = event.state;
          _restores = _restores.catchError((Object _) {}).then((_) async {
            if (generation == _generation) {
              await _restore(container, state, uri);
            }
          });
          unawaited(_restores);
        }).toJS;
    web.window.addEventListener('popstate', _onPopState);
  }

  static Future<void> _restore(
    ProviderContainer container,
    JSAny? state,
    Uri uri,
  ) async {
    final decoded = state?.dartify();
    final index =
        decoded is Map && decoded['chessever'] == true
            ? decoded['index']
            : null;
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final page = index is num ? _pages[index.toInt()] : null;
    _restoring = true;
    try {
      if (index is num) _index = index.toInt();
      final exists =
          page != null &&
          container
              .read(desktopTabsProvider)
              .tabs
              .any((tab) => tab.id == page.tabId);
      if (exists) {
        page.restore();
      } else {
        await openDesktopWebLocation(uri, container);
      }
      _pin(container, path);
      _pages[_index] = _capture(container, path);
      _stamp(path, replace: true);
    } finally {
      _restoring = false;
    }
  }

  static void stop() {
    _generation++;
    _location?.close();
    _location = null;
    _round?.close();
    _round = null;
    final listener = _onPopState;
    if (listener != null) web.window.removeEventListener('popstate', listener);
    _onPopState = null;
    _scheduled = false;
    _pinnedTab = _pinnedPath = _pinnedGeneratedPath = null;
  }
}
