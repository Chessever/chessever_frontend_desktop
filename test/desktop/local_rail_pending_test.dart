import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';

void main() {
  testWidgets('select is not open; pending is named; newest activation wins', (
    tester,
  ) async {
    final pending = <String, Completer<TournamentGameSummary>>{};
    final rows = [
      for (final name in ['A', 'Piorun', 'C'])
        TournamentGameSummary(
          id: name,
          name: name,
          whitePlayer: name,
          blackPlayer: 'Nakamura',
          hasPgn: true,
          pgn: '[White "$name"]\n[Black "Nakamura"]\n\n1. e4 e5 *',
          localPgnSource: TournamentGameLocalPgnSource(
            sourcePath: 'fixture.pgn',
            sourceIndex: 0,
            sourceFileGameCount: 3,
            pgnFingerprint: name,
            title: name,
          ),
        ),
    ];
    final container = ProviderContainer(
      overrides: [
        retainedLocalPgnHydratorProvider.overrideWithValue(
          (row) =>
              (pending[row.id] = Completer<TournamentGameSummary>()).future,
        ),
      ],
    );
    final tab = openBoardGameTabFromContainer(
      container,
      BoardTabGameArgs(
        pgn: rows.first.pgn!,
        label: 'A',
        whiteName: 'A',
        blackName: 'Nakamura',
        databaseTitle: 'Fixture',
        databaseGames: rows,
        gameListSelectedId: 'A',
      ),
      reuseExisting: false,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 600, child: EventGamesTable(tabId: tab)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Piorun').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(pending, isEmpty);
    expect(
      container.read(boardTabGameArgsByTabIdProvider)[tab]!.gameListSelectedId,
      'A',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pending.keys, contains('Piorun'));
    expect(find.text('Opening Piorun vs Nakamura…'), findsOneWidget);
    expect(
      container.read(boardTabGameArgsByTabIdProvider)[tab]!.gameListSelectedId,
      'A',
    );
    await tester.tap(find.text('C').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('C').first);
    await tester.pump();
    expect(pending.keys, contains('C'));
    expect(find.text('Opening C vs Nakamura…'), findsOneWidget);
    pending['C']!.complete(rows.last);
    await tester.pump();
    expect(
      container.read(boardTabGameArgsByTabIdProvider)[tab]!.gameListSelectedId,
      'C',
    );
    pending['Piorun']!.complete(rows[1]);
    await tester.pump();
    expect(
      container.read(boardTabGameArgsByTabIdProvider)[tab]!.gameListSelectedId,
      'C',
    );
    expect(find.text('Opening Piorun vs Nakamura…'), findsNothing);
    expect(find.text('Opening C vs Nakamura…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
