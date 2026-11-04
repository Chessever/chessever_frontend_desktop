import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/web_prep_source_access.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/widgets/desktop_board_access_gate.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/web_prep_source_access_gate.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

const _prepPath = '/app/player-workspace/mine/lichess.pgn';
const _renamedPath = '/app/library/renamed.pgn';

SubscriptionState get _premium => SubscriptionState(
  isSubscribed: true,
  expirationDate: DateTime.now().add(const Duration(days: 30)),
);

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.initialState) : super.stub();
  void set(SubscriptionState next) => state = next;
}

class _RegistryDatabase implements AppDatabase {
  _RegistryDatabase(this.entries, {this.release});
  final List<Map<String, Object?>> entries;
  final Completer<void>? release;

  @override
  Future<T?> getJson<T>(String key) async {
    if (key != 'desktop.local_libraries.v1') return null;
    await release?.future;
    return entries as T;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container({
  _Subscription? subscription,
  _RegistryDatabase? registry,
  bool web = true,
}) => ProviderContainer(
  overrides: [
    webPrepSourcePaywallEnabledProvider.overrideWithValue(web),
    subscriptionProvider.overrideWith(
      (_) => subscription ?? _Subscription(SubscriptionState()),
    ),
    desktopEntitlementProvider.overrideWithValue(
      const DesktopEntitlementSnapshot(accountId: 'account', generation: 1),
    ),
    localLibraryRegistryProvider.overrideWith(
      (_) => LocalLibraryRegistryNotifier(registry ?? _RegistryDatabase([])),
    ),
  ],
);

BoardTabGameArgs _args(String path) => BoardTabGameArgs(
  pgn: '1. e4 e5 *',
  label: 'Prep game',
  whiteName: 'White',
  blackName: 'Black',
  librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
    title: 'Prep game',
    sourcePath: path,
    sourceIndex: 0,
    sourceFileGameCount: 1,
  ),
);

Widget _host(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder:
            (context, child) => FTheme(data: FThemes.zinc.dark, child: child!),
        home: Scaffold(body: child),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generated and renamed Prep sources preserve provenance', () {
    expect(isWebPrepSourcePath(_prepPath), isTrue);
    expect(isWebPrepSourcePath('/app/player-workspace'), isTrue);
    expect(isWebPrepSourcePath('/app/ordinary.pgn'), isFalse);
    expect(
      isWebPrepSourcePath(
        _renamedPath,
        entries: [
          LocalLibraryEntry(
            path: _renamedPath,
            addedAt: DateTime(2026),
            groupId: 'player-workspace:mine',
            playerWorkspaceSource: 'lichess',
          ),
        ],
      ),
      isTrue,
    );
    expect(
      isWebPrepSourcePath('/app/player-workspace-not-mine/file.pgn'),
      isFalse,
    );
    expect(
      isWebPrepSourcePath(
        '/app/library',
        entries: [
          LocalLibraryEntry(
            path: _renamedPath,
            addedAt: DateTime(2026),
            groupId: 'player-workspace:mine',
          ),
        ],
      ),
      isTrue,
      reason: 'a folder preview must not reveal its gated Prep descendants',
    );
  });

  test('central board admission denies a free generated download', () async {
    final container = _container();
    addTearDown(container.dispose);
    final presented = <String>[];
    final unregister = registerDesktopPaywallPresenter(container, (
      decision, {
      DesktopAccessContext? context,
      DesktopAccessResume? resume,
      required String surface,
    }) async {
      presented.add(decision.reason.code);
      return false;
    });
    addTearDown(unregister);

    expect(openBoardGameTabFromContainer(container, _args(_prepPath)), isEmpty);
    expect(container.read(boardTabGameArgsByTabIdProvider), isEmpty);
    expect(presented, ['premium_prepare_computed']);
  });

  test('admitted Prep board and its rail retain Prep access context', () {
    final container = _container(subscription: _Subscription(_premium));
    addTearDown(container.dispose);

    final id = openBoardGameTabFromContainer(container, _args(_prepPath));
    expect(id, isNotEmpty);
    final args = container.read(boardTabGameArgsByTabIdProvider)[id]!;
    expect(args.admissionContext.feature, DesktopFeature.prepare);
    expect(args.sourceAccessContext.feature, DesktopFeature.prepare);
    expect(args.admissionContext.ownedDocument, isFalse);
  });

  test('native Prep downloads preserve ordinary local-file behavior', () {
    final container = _container(web: false);
    addTearDown(container.dispose);

    final id = openBoardGameTabFromContainer(container, _args(_prepPath));
    expect(id, isNotEmpty);
    expect(
      container
          .read(boardTabGameArgsByTabIdProvider)[id]!
          .admissionContext
          .feature,
      DesktopFeature.localFiles,
    );
  });

  testWidgets('renamed Prep reader waits for provenance before mounting', (
    tester,
  ) async {
    final release = Completer<void>();
    final registry = _RegistryDatabase([
      {
        'path': _renamedPath,
        'addedAt': '2026-11-05T00:00:00.000',
        'groupId': 'player-workspace:mine',
      },
    ], release: release);
    final container = _container(registry: registry);
    addTearDown(container.dispose);
    var mountedReaders = 0;
    await tester.pumpWidget(
      _host(
        container,
        WebPrepSourceAccessGate(
          path: _renamedPath,
          child: Builder(
            builder: (_) {
              mountedReaders++;
              return const Text('PGN reader');
            },
          ),
        ),
      ),
    );
    expect(mountedReaders, 0);
    expect(
      container
          .read(webPrepSourceAccessDecisionProvider(_renamedPath))!
          .outcome,
      DesktopAccess.checking,
    );
    release.complete();
    await tester.pumpAndSettle();
    expect(mountedReaders, 0);
    expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
    expect(find.byType(DesktopPaywallView), findsNothing);
  });

  testWidgets('ordinary retained files become readable after registry loads', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _host(
        container,
        const WebPrepSourceAccessGate(
          path: '/app/library/personal.pgn',
          child: Text('Personal PGN'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Personal PGN'), findsOneWidget);
    expect(find.byType(DesktopAccessLockedSurface), findsNothing);
  });

  testWidgets('Prep library content relocks when membership expires', (
    tester,
  ) async {
    final subscription = _Subscription(_premium);
    final container = _container(subscription: subscription);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _host(
        container,
        const WebPrepSourceAccessGate(
          path: _prepPath,
          child: Text('Prep games'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Prep games'), findsOneWidget);

    subscription.set(SubscriptionState());
    await tester.pumpAndSettle();
    expect(find.text('Prep games'), findsNothing);
    expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
  });

  testWidgets('clean restored Prep board cannot reuse an old admission latch', (
    tester,
  ) async {
    final subscription = _Subscription(_premium);
    final container = _container(subscription: subscription);
    addTearDown(container.dispose);
    final id = openBoardGameTabFromContainer(container, _args(_prepPath));
    await tester.pumpWidget(
      _host(
        container,
        DesktopBoardAccessGate(tabId: id, child: const Text('Prep board')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Prep board'), findsOneWidget);

    subscription.set(SubscriptionState());
    await tester.pumpAndSettle();
    expect(find.text('Prep board'), findsNothing);
    expect(find.byType(DesktopAccessLockedSurface), findsOneWidget);
  });
}
