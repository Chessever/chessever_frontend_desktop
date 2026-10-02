import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/collections_reader.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/board_share_dialog.dart';
import 'package:chessever/desktop/widgets/collections/collection_actions.dart';
import 'package:chessever/desktop/widgets/collections/collection_catalog_row.dart';
import 'package:chessever/desktop/widgets/collections/collection_reading_views.dart';
import 'package:chessever/desktop/widgets/desktop_game_filter_dialog.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/providers/favorite_events_provider.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'support/collections_fakes.dart';

/// Hands the test a [WidgetRef], for the actions that take one.
Future<(WidgetRef, ProviderContainer)> _ref(
  WidgetTester tester, {
  required FakeCollectionsReader reader,
  FakeFavoriteEvents? favorites,
  Widget? child,
}) async {
  late WidgetRef captured;
  final container = ProviderContainer(
    overrides: [
      collectionsReaderProvider.overrideWithValue(reader),
      favoriteEventsProvider.overrideWith(
        () => favorites ?? FakeFavoriteEvents(),
      ),
      subscriptionProvider.overrideWith(
        (ref) => FakeSubscription(premiumSubscription),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              captured = ref;
              return child ?? const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (captured, container);
}

void main() {
  group('starring a collection', () {
    testWidgets('a guest is asked to sign in and nothing is written', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final favorites = FakeFavoriteEvents();
      final (ref, _) = await _ref(tester, reader: reader, favorites: favorites);

      final outcome = await toggleCollectionStar(
        ref,
        freeBook,
        hasPermanentAccount: () => false,
      );

      expect(outcome, CollectionStarOutcome.needsAccount);
      expect(favorites.toggled, isEmpty);
      expect(reader.stars, isEmpty);
    });

    testWidgets('an account writes the phone\'s favorite row and the count', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final favorites = FakeFavoriteEvents();
      final (ref, container) = await _ref(
        tester,
        reader: reader,
        favorites: favorites,
      );

      final starred = await toggleCollectionStar(
        ref,
        freeBook,
        hasPermanentAccount: () => true,
      );
      await tester.pump();

      expect(starred, CollectionStarOutcome.starred);
      expect(favorites.toggled, ['collection:my-60-memorable-games']);
      expect(reader.stars, [('my-60-memorable-games', true)]);
      expect(
        container.read(collectionStarredProvider('my-60-memorable-games')),
        isTrue,
      );
      expect(container.read(favoriteCollectionSlugsProvider), {
        'my-60-memorable-games',
      });
      expect(
        container.read(
          collectionEngagementCountsProvider('my-60-memorable-games'),
        )?['starCount'],
        38,
      );

      final unstarred = await toggleCollectionStar(
        ref,
        freeBook,
        hasPermanentAccount: () => true,
      );
      await tester.pump();

      expect(unstarred, CollectionStarOutcome.unstarred);
      expect(reader.stars.last, ('my-60-memorable-games', false));
      expect(
        container.read(collectionStarredProvider('my-60-memorable-games')),
        isFalse,
      );
    });
  });

  group('confirming Premium after a purchase', () {
    testWidgets('re-reads fresh until the server opens the collection', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final (ref, container) = await _ref(tester, reader: reader);
      var reads = 0;
      // The purchase reaches the server on the third look.
      final confirmed = () async {
        final future = confirmCollectionPremium(
          ref,
          'zurich-1953',
          waits: const [Duration.zero, Duration.zero, Duration.zero],
        );
        return future;
      }();
      // Unlock it once two reads have gone by.
      container.listen(collectionDetailProvider('zurich-1953'), (_, next) {
        if (next.hasValue && ++reads == 2) reader.lockedSlugs = {};
      });

      expect(await tester.runAsync(() => confirmed), isTrue);
      expect(reader.detailReads.length, 3);
      expect(reader.freshReads, 3, reason: 'every look asks the server anew');
      expect(reader.isFreshAccess('zurich-1953'), isFalse);
      expect(container.read(collectionConfirmingProvider), isEmpty);
    });

    testWidgets('gives up after its waits when it stays locked', (
      tester,
    ) async {
      final reader = FakeCollectionsReader();
      final (ref, container) = await _ref(tester, reader: reader);

      final confirmed = await tester.runAsync(
        () => confirmCollectionPremium(
          ref,
          'zurich-1953',
          waits: const [Duration.zero, Duration.zero],
        ),
      );

      expect(confirmed, isFalse);
      expect(reader.detailReads.length, 2);
      expect(container.read(collectionConfirmingProvider), isEmpty);
    });

    test('the default waits add up to about thirty-five seconds', () {
      final total = kCollectionPremiumConfirmWaits.fold<Duration>(
        Duration.zero,
        (sum, wait) => sum + wait,
      );

      expect(total, const Duration(seconds: 35));
    });
  });

  group('a collection game is read, not taken', () {
    const collectionArgs = BoardTabGameArgs(
      pgn: '1. e4 e5 *',
      label: 'A vs B',
      whiteName: 'A',
      blackName: 'B',
      accessContext: collectionAccessContext,
    );
    const game = TournamentGameSummary(
      id: 'g1',
      name: 'A vs B',
      whitePlayer: 'A',
      blackPlayer: 'B',
      hasPgn: true,
    );

    test('its provenance is a free surface that marks the content', () {
      expect(collectionAccessContext.isCollectionContent, isTrue);
      expect(collectionArgs.sourceAccessContext.isCollectionContent, isTrue);
      expect(collectionArgs.admissionContext.isCollectionContent, isTrue);

      final decision = evaluateDesktopAccess(
        context: collectionArgs.admissionContext,
        subscription: freeSubscription,
        entitlement: const DesktopEntitlementSnapshot(accountId: 'a'),
      );
      expect(
        decision.isAllowed,
        isTrue,
        reason: 'the server already decided who may read it',
      );
      expect(
        const DesktopAccessContext(
          feature: DesktopFeature.broadcast,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.broadcast,
        ).isCollectionContent,
        isFalse,
      );
    });

    test('the board rail refuses to copy or insert it, for everyone', () {
      for (final subscription in [freeSubscription, premiumSubscription]) {
        final container = ProviderContainer(
          overrides: [
            subscriptionProvider.overrideWith(
              (ref) => FakeSubscription(subscription),
            ),
          ],
        );
        addTearDown(container.dispose);

        for (final action in [DesktopAction.copy, DesktopAction.insertMove]) {
          expect(
            admitEventRailContentAction(
              container,
              activeArgs: collectionArgs,
              games: const [game],
              action: action,
              surface: 'test',
            ),
            isFalse,
            reason:
                '${action.name} with isSubscribed=${subscription.isSubscribed}',
          );
        }
      }
    });

    test('the share dialog offers the image and the GIF, never the PGN', () {
      List<String> labels({required bool pgn}) => [
        for (final action in boardShareActionDescriptors(
          copyImage: () {},
          generateGif: () {},
          downloadImage: () {},
          copyPgn: pgn ? () {} : null,
        ))
          action.label,
      ];

      expect(labels(pgn: true), contains('Copy PGN'));
      expect(labels(pgn: false), isNot(contains('Copy PGN')));
      expect(labels(pgn: false), [
        'Copy Image',
        'Generate GIF',
        'Download PNG',
      ]);
    });
  });

  group('routes', () {
    test('Collections joins the sidebar without renumbering a shortcut', () {
      expect(desktopMainRouteShortcutNumber(DesktopPane.collections), 0);
      expect(desktopMainRouteShortcutNumber(DesktopPane.tournaments), 1);
      expect(desktopMainRouteShortcutNumber(DesktopPane.library), 2);
      expect(desktopMainRouteShortcutNumber(DesktopPane.favorites), 3);
      expect(desktopMainRouteShortcutNumber(DesktopPane.play), 9);
      expect(
        desktopMainRoutes
            .map((route) => route.pane)
            .toList()
            .indexOf(DesktopPane.collections),
        desktopMainRoutes
                .map((route) => route.pane)
                .toList()
                .indexOf(DesktopPane.library) +
            1,
      );
      expect(tabKindForPane(DesktopPane.collections), TabKind.collections);
      expect(TabKind.collections.defaultTitle, 'Collections');
      expect(TabKind.collectionWorkspace.defaultTitle, 'Collection');
    });
  });

  group('collections about an event', () {
    testWidgets('nothing is drawn when the event has none', (tester) async {
      await _ref(
        tester,
        reader: FakeCollectionsReader(),
        child: CollectionsBoundToEvent(
          anchors: CollectionEventAnchors(groups: ['gb_1']),
        ),
      );
      await tester.pump();

      expect(find.text('Collection'), findsNothing);
      expect(find.text('Collections'), findsNothing);
      expect(find.byType(CollectionCatalogRow), findsNothing);
    });

    testWidgets('bound collections are listed under their heading', (
      tester,
    ) async {
      await _ref(
        tester,
        reader: _BoundReader(),
        child: CollectionsBoundToEvent(
          anchors: CollectionEventAnchors(groups: ['gb_1']),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Collection'), findsOneWidget);
      expect(find.byType(CollectionCatalogRow), findsOneWidget);
    });
  });

  group('filters', () {
    testWidgets('the dialog shows only what a collection can be searched by', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder:
                  (context) => TextButton(
                    onPressed:
                        () => showDesktopGameFilterDialog(
                          context: context,
                          currentFilter: GameFilter(),
                          sections: const {
                            DesktopGameFilterSection.eco,
                            DesktopGameFilterSection.result,
                            DesktopGameFilterSection.year,
                          },
                        ),
                    child: const Text('open'),
                  ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('ECO / OPENING'), findsOneWidget);
      expect(find.text('RESULT'), findsOneWidget);
      expect(find.text('YEAR RANGE'), findsOneWidget);
      expect(find.text('TIME CONTROL'), findsNothing);
      expect(find.text('AVG. RATING'), findsNothing);
      expect(find.text('FINISH'), findsNothing);
    });
  });
}

class _BoundReader extends FakeCollectionsReader {
  @override
  Future<List<Collection>> fetchBooksForEvent(
    CollectionEventAnchors anchors,
  ) async => const [freeBook];
}
