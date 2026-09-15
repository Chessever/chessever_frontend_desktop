import 'dart:convert';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/state/broadcast_video_streams_provider.dart';
import 'package:chessever/desktop/widgets/broadcast_video_panel.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_platform_interface/webview_platform_interface.dart';

/// Regression test for the multi-tab broadcast restart: switching Board tabs
/// used to dispose the video player on every tab but the first, so coming
/// back reloaded the broadcast instead of continuing it.
///
/// The panel contract this locks in:
/// * a tab switch creates no new webview controller and issues no new page
///   load (foreground or background),
/// * the [WebViewWidget] element itself survives the background excursion
///   (no remount, no GlobalKey relocation of the platform view),
/// * only the 20s stop-grace blanks a background player; returning after
///   the grace reloads on the same controller.
void main() {
  setUpAll(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  setUp(_FakeWebViewPlatform.reset);

  Future<void> disposeTree(WidgetTester tester) async {
    // Unmount the ProviderScope so the streams poll timer is cancelled
    // before the fake-async pending-timer check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('tab switches keep every broadcast player loaded', (
    tester,
  ) async {
    _Harness.index.value = 0;
    await tester.pumpWidget(const _Harness());
    // Only the foreground tab mounts a player; a background tab never
    // starts a hidden load.
    await _pumpUntilLoads(tester, 1);
    expect(_FakeWebViewPlatform.controllers.length, 1);
    final embedUrl = broadcastVideoEmbedPageUri(
      scope: 'round',
      scopeId: 'r1',
      streamId: 's1',
      play: true,
    );
    expect(_FakeWebViewPlatform.controllers.single.loads, <Uri>[embedUrl]);
    final tabAElement = _webViewElement(tester, _Harness.panelAKey);

    // Activating the second tab mounts its own player; the first tab keeps
    // rendering its slot (hidden by the tab stack) instead of unmounting.
    _Harness.index.value = 1;
    await _pumpUntilLoads(tester, 2);
    expect(_FakeWebViewPlatform.controllers.length, 2);
    for (final controller in _FakeWebViewPlatform.controllers) {
      expect(controller.loads, <Uri>[embedUrl]);
    }
    expect(
      find.descendant(
        of: find.byKey(_Harness.panelAKey, skipOffstage: false),
        matching: find.byType(WebViewWidget, skipOffstage: false),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    // No GlobalKey relocation machinery: the platform view must never move
    // between tree positions, which detaches it natively.
    final webViews = tester
        .widgetList<WebViewWidget>(
          find.byType(WebViewWidget, skipOffstage: false),
        )
        .toList();
    expect(webViews.length, 2);
    for (final webView in webViews) {
      expect(webView.key, isNot(isA<GlobalKey>()));
    }

    // Switching back issues no new load and keeps the same element.
    _Harness.index.value = 0;
    await tester.pump();
    await tester.pump();
    expect(_FakeWebViewPlatform.controllers.length, 2);
    for (final controller in _FakeWebViewPlatform.controllers) {
      expect(controller.loads, <Uri>[embedUrl]);
    }
    expect(_webViewElement(tester, _Harness.panelAKey), same(tabAElement));
    addTearDown(() => disposeTree(tester));
  });

  testWidgets('the stop-grace blanks a background player, then it reloads', (
    tester,
  ) async {
    _Harness.index.value = 0;
    await tester.pumpWidget(const _Harness());
    await _pumpUntilLoads(tester, 1);
    _Harness.index.value = 1;
    await _pumpUntilLoads(tester, 2);
    expect(_FakeWebViewPlatform.controllers.length, 2);

    // Park tab A in the background past the 20s grace: it blanks its player
    // (compliance: no background playback) and unmounts the blanked view.
    await tester.pump(const Duration(seconds: 21));
    await tester.pump();

    final tabA = _FakeWebViewPlatform.controllers.firstWhere(
      (controller) => controller.loads.length > 1,
    );
    expect(
      tabA.loads,
      <Uri>[tabA.loads.first, Uri.parse('about:blank')],
    );
    expect(
      find.descendant(
        of: find.byKey(_Harness.panelAKey, skipOffstage: false),
        matching: find.byType(WebViewWidget, skipOffstage: false),
        skipOffstage: false,
      ),
      findsNothing,
    );
    // The foreground tab is untouched.
    final tabB = _FakeWebViewPlatform.controllers.firstWhere(
      (controller) => identical(controller, tabA) == false,
    );
    expect(tabB.loads.length, 1);

    // Returning reloads the same controller instead of creating a third one.
    _Harness.index.value = 0;
    await tester.pump();
    await tester.pump();
    expect(_FakeWebViewPlatform.controllers.length, 2);
    expect(tabA.loads.length, 3);
    expect(tabA.loads.first, tabA.loads.last);
    addTearDown(() => disposeTree(tester));
  });

  testWidgets('a background tab never starts a newly selected stream', (
    tester,
  ) async {
    _Harness.index.value = 0;
    await tester.pumpWidget(const _Harness());
    await _pumpUntilLoads(tester, 1);
    _Harness.index.value = 1;
    await _pumpUntilLoads(tester, 2);
    final firstUrl = broadcastVideoEmbedPageUri(
      scope: 'round',
      scopeId: 'r1',
      streamId: 's1',
      play: true,
    );
    final secondUrl = broadcastVideoEmbedPageUri(
      scope: 'round',
      scopeId: 'r1',
      streamId: 's2',
      play: true,
    );
    for (final controller in _FakeWebViewPlatform.controllers) {
      expect(controller.loads, <Uri>[firstUrl]);
    }

    // Both tabs share the tournament's stream choice. Retargeting it from
    // the foreground tab loads there at once but must not start a hidden
    // load on the background tab.
    ProviderScope.containerOf(
      tester.element(find.byType(PersistentIndexedStack)),
    ).read(broadcastVideoSessionPreferencesProvider.notifier).write(
      'ce-video.v1:tour-x',
      const BroadcastVideoPreference(selectedId: 's2', visible: true),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final tabB = _FakeWebViewPlatform.controllers.firstWhere(
      (controller) => controller.loads.length > 1,
    );
    expect(tabB.loads, <Uri>[firstUrl, secondUrl]);
    final tabA = _FakeWebViewPlatform.controllers.firstWhere(
      (controller) => identical(controller, tabB) == false,
    );
    expect(tabA.loads, <Uri>[firstUrl]);

    // Returning picks the new selection up on the same controller.
    _Harness.index.value = 0;
    await tester.pump();
    await tester.pump();
    expect(_FakeWebViewPlatform.controllers.length, 2);
    expect(tabA.loads, <Uri>[firstUrl, secondUrl]);
    addTearDown(() => disposeTree(tester));
  });
}

Element _webViewElement(WidgetTester tester, Key panelKey) {
  return tester.element(
    find.descendant(
      of: find.byKey(panelKey),
      matching: find.byType(WebViewWidget),
    ),
  );
}

/// Pumps until [count] controllers exist and each has issued its first load.
Future<void> _pumpUntilLoads(WidgetTester tester, int count) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final controllers = _FakeWebViewPlatform.controllers;
    if (controllers.length == count &&
        controllers.every((controller) => controller.loads.isNotEmpty)) {
      // One more frame so post-load rebuilds land.
      await tester.pump(const Duration(milliseconds: 100));
      return;
    }
  }
  fail(
    'expected $count loaded players, '
    'have ${_FakeWebViewPlatform.controllers.length}',
  );
}

class _Harness extends StatelessWidget {
  const _Harness();

  static final ValueNotifier<int> index = ValueNotifier<int>(0);
  static const Key panelAKey = Key('broadcast-panel-a');
  static const Key panelBKey = Key('broadcast-panel-b');

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        broadcastVideoStreamsClientProvider.overrideWithValue(
          BroadcastVideoStreamsClient(
            httpClient: MockClient((_) async {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'streams': <Object?>[
                    <String, Object?>{
                      'id': 's1',
                      'label': 'Main',
                      'provider': 'twitch',
                      'sourceId': 'chess',
                      'url': 'https://twitch.tv/chess',
                    },
                    <String, Object?>{
                      'id': 's2',
                      'label': 'Second',
                      'provider': 'twitch',
                      'sourceId': 'chess2',
                      'url': 'https://twitch.tv/chess2',
                    },
                  ],
                  'source': <String, Object?>{
                    'scope': 'round',
                    'id': 'r1',
                  },
                }),
                200,
              );
            }),
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: index,
            builder: (context, active, _) {
              return PersistentIndexedStack(
                index: active,
                children: [
                  KeyedSubtree(
                    key: const ValueKey<String>('desktop-tab:a:board'),
                    child: Center(
                      child: SizedBox(
                        width: 500,
                        child: BroadcastVideoPanel(
                          key: panelAKey,
                          tourId: 'tour-x',
                          tournamentStorageId: 'tour-x',
                          roundId: 'round-1',
                          active: active == 0,
                        ),
                      ),
                    ),
                  ),
                  KeyedSubtree(
                    key: const ValueKey<String>('desktop-tab:b:board'),
                    child: Center(
                      child: SizedBox(
                        width: 500,
                        child: BroadcastVideoPanel(
                          key: panelBKey,
                          tourId: 'tour-x',
                          tournamentStorageId: 'tour-x',
                          roundId: 'round-1',
                          active: active == 1,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _FakeWebViewPlatform extends WebViewPlatform {
  static final List<_FakePlatformController> controllers =
      <_FakePlatformController>[];

  static void reset() => controllers.clear();

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _FakePlatformController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWidget(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);
}

class _FakePlatformController extends PlatformWebViewController {
  _FakePlatformController(super.params) : super.implementation();

  final List<Uri> loads = <Uri>[];

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => true;
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakePlatformWidget extends PlatformWebViewWidget {
  _FakePlatformWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
