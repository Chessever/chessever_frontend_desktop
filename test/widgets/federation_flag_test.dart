import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  Future<void> pumpFlag(WidgetTester tester, String? federation) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FederationFlag(
              federation: federation,
              width: 22,
              height: 16,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('does not render a placeholder for empty federation', (
    tester,
  ) async {
    await pumpFlag(tester, '');

    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(FederationFlag)), Size.zero);
  });

  testWidgets(
    'renders the bundled FIDE mark for explicit FIDE federation values',
    (tester) async {
      for (final value in const ['FID', 'FIDE']) {
        await pumpFlag(tester, value);

        expect(find.byType(Image), findsOneWidget);
        final image = tester.widget<Image>(find.byType(Image));
        expect(image.image, isA<AssetImage>());
        expect(
          (image.image as AssetImage).assetName,
          'assets/pngs/fide_logo.webp',
        );
      }
    },
  );

  testWidgets('does not render a placeholder for unknown federation marker', (
    tester,
  ) async {
    await pumpFlag(tester, '?');

    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(FederationFlag)), Size.zero);
  });

  testWidgets('does not render a placeholder for unresolvable federation', (
    tester,
  ) async {
    await pumpFlag(tester, 'Atlantis');

    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(FederationFlag)), Size.zero);
  });

  bool isFideAsset(Image image) =>
      image.image is AssetImage &&
      (image.image as AssetImage).assetName == 'assets/pngs/fide_logo.webp';

  Future<void> pumpBackfilled(
    WidgetTester tester, {
    required String federation,
    int? fideId,
    ChessPlayer? resolvedPlayer,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chessPlayerByFideIdProvider.overrideWith(
            (ref, arg) async => resolvedPlayer,
          ),
          chessPlayerByNameProvider.overrideWith((ref, arg) async => null),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: BackfilledFederationFlag(
                federation: federation,
                fideId: fideId,
                width: 22,
                height: 16,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'BackfilledFederationFlag falls back to the FIDE mark when no country '
    'resolves for a FIDE marker',
    (tester) async {
      await pumpBackfilled(tester, federation: 'FIDE', fideId: 1);

      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.where(isFideAsset), hasLength(1));
    },
  );

  testWidgets(
    'BackfilledFederationFlag prefers the resolved national flag over the '
    'FIDE mark',
    (tester) async {
      await pumpBackfilled(
        tester,
        federation: 'FIDE',
        fideId: 1,
        resolvedPlayer: const ChessPlayer(
          fideid: 1,
          name: 'Tester',
          country: 'US',
        ),
      );

      // National flag wins: the bundled FIDE mark must not be rendered.
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.where(isFideAsset), isEmpty);
    },
  );
}
