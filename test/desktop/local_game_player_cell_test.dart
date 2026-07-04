import 'dart:async';

import 'package:chessever/desktop/widgets/library/local_game_player_cell.dart';
import 'package:chessever/providers/player_backfill_provider.dart';
import 'package:chessever/repository/supabase/chess_player/chess_player_repository.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/skeleton_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  Future<void> pumpCell(
    WidgetTester tester, {
    required Map<String, dynamic> metadata,
    String side = 'White',
    List<Override> overrides = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: LocalGamePlayerCell(metadata: metadata, side: side),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows title and FIDE-ID-backfilled flag for TWIC headers', (
    tester,
  ) async {
    // TWIC exports carry WhiteTitle + WhiteFideId but no country tag; the
    // flag must resolve through the chess_players FIDE-ID backfill.
    await pumpCell(
      tester,
      metadata: const {
        'White': 'Carlsen,M',
        'WhiteTitle': 'GM',
        'WhiteFideId': '1503014',
      },
      overrides: [
        chessPlayerByFideIdProvider.overrideWith(
          (ref, fideId) async =>
              fideId == 1503014
                  ? const ChessPlayer(
                    fideid: 1503014,
                    name: 'Carlsen, Magnus',
                    country: 'NOR',
                  )
                  : null,
        ),
      ],
    );

    expect(find.text('GM'), findsOneWidget);
    // Names render in the shared library-table abbreviated form (`Last, F.`).
    expect(find.text('Carlsen, M.'), findsOneWidget);
    expect(find.byType(FederationFlag), findsOneWidget);
  });

  testWidgets('shows flag straight from a federation header tag', (
    tester,
  ) async {
    await pumpCell(
      tester,
      side: 'Black',
      metadata: const {'Black': 'Mueller, Hans', 'BlackFed': 'GER'},
      overrides: [
        chessPlayerByNameProvider.overrideWith((ref, name) async => null),
      ],
    );

    expect(find.byType(FederationFlag), findsOneWidget);
    expect(find.text('Mueller, H.'), findsOneWidget);
  });

  testWidgets('normalizes malformed title tags', (tester) async {
    await pumpCell(
      tester,
      metadata: const {
        'White': 'Novak, Ana',
        'WhiteTitle': 'wgm',
        'WhiteFed': 'SRB',
      },
    );

    expect(find.text('WGM'), findsOneWidget);
  });

  testWidgets('renders plain name when headers carry no title or country', (
    tester,
  ) async {
    await pumpCell(
      tester,
      metadata: const {'White': 'Someone, Anon'},
      overrides: [
        chessPlayerByNameProvider.overrideWith((ref, name) async => null),
      ],
    );

    expect(find.byType(FederationFlag), findsNothing);
    expect(find.text('Someone, A.'), findsOneWidget);
  });

  testWidgets('falls back to side label for missing names', (tester) async {
    await pumpCell(
      tester,
      metadata: const {'White': '?'},
      overrides: [
        chessPlayerByNameProvider.overrideWith((ref, name) async => null),
      ],
    );

    expect(find.text('White'), findsOneWidget);
  });

  testWidgets('resolves a missing title on demand by FIDE ID', (tester) async {
    // TWIC headers carry no title tag; the cell must fetch it per row
    // instead of waiting for any import-time work.
    await pumpCell(
      tester,
      metadata: const {'White': 'Carlsen, Magnus', 'WhiteFideId': '1503014'},
      overrides: [
        chessPlayerByFideIdProvider.overrideWith(
          (ref, fideId) async => const ChessPlayer(
            fideid: 1503014,
            name: 'Carlsen, Magnus',
            title: 'GM',
            country: 'NOR',
          ),
        ),
      ],
    );

    expect(find.text('GM'), findsOneWidget);
    expect(find.byType(FederationFlag), findsOneWidget);
  });

  testWidgets('shows a shimmer while the on-demand title loads', (
    tester,
  ) async {
    final gate = Completer<ChessPlayer?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chessPlayerByFideIdProvider.overrideWith(
            (ref, fideId) => gate.future,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: LocalGamePlayerCell(
                    metadata: {
                      'White': 'Carlsen, Magnus',
                      'WhiteFideId': '1503014',
                    },
                    side: 'White',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SkeletonWidget), findsOneWidget);

    gate.complete(
      const ChessPlayer(
        fideid: 1503014,
        name: 'Carlsen, Magnus',
        title: 'GM',
        country: 'NOR',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SkeletonWidget), findsNothing);
    expect(find.text('GM'), findsOneWidget);
  });
}
