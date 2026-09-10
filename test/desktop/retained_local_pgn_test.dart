import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/retained_local_pgn.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/services/local_chess_pgn_fingerprint.dart';
import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

String _pgn(String name, [String comment = '']) =>
    '[Event "Fixture"]\n[White "$name"]\n[Black "Opponent"]\n'
    '[Result "*"]\n\n1. e4 $comment e5 2. Nf3 Nc6 *';

TournamentGameSummary _row(File file, int index, String name) {
  final pgn = _pgn(name);
  return TournamentGameSummary(
    id: name,
    name: name,
    whitePlayer: name,
    blackPlayer: 'Opponent',
    hasPgn: true,
    pgn: pgn,
    localPgnSource: TournamentGameLocalPgnSource(
      sourcePath: file.path,
      sourceIndex: index,
      sourceFileGameCount: 2,
      pgnFingerprint: localChessPgnFingerprint(pgn),
      recordRevision: localPgnRecordRevision(pgn),
      title: name,
    ),
  );
}

LocalLibraryGameUpdateTarget _target(TournamentGameLocalPgnSource source) =>
    LocalLibraryGameUpdateTarget(
      sourcePath: source.sourcePath,
      indexInFile: source.sourceIndex,
      fileGameCount: source.sourceFileGameCount,
      pgnFingerprint: source.pgnFingerprint,
      recordRevision: source.recordRevision,
    );

BoardTabGameArgs _args(List<TournamentGameSummary> rows) => BoardTabGameArgs(
  pgn: rows.first.pgn!,
  label: 'A',
  whiteName: 'A',
  blackName: 'Opponent',
  databaseTitle: 'Fixture',
  databaseGames: rows,
  gameListSelectedId: 'A',
  librarySaveOrigin: BoardTabLibrarySaveOrigin.localPgnFile(
    sourcePath: rows.first.localPgnSource!.sourcePath,
    sourceIndex: 0,
    sourceFileGameCount: 2,
    sourcePgnFingerprint: rows.first.localPgnSource!.pgnFingerprint,
    sourceRecordRevision: rows.first.localPgnSource!.recordRevision,
    title: 'A',
  ),
);

void main() {
  testWidgets(
    'modifier new-tab open reads physical annotations before inline PGN',
    (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('rail-new-tab-'),
      );
      final file = File('${dir!.path}/fixture.pgn');
      final rows = [_row(file, 0, 'A'), _row(file, 1, 'B')];
      final freshPgn = _pgn('A', '{changed outside retained rail}');
      await tester.runAsync(
        () => file.writeAsString('$freshPgn\n\n${_pgn('B')}'),
      );
      final hydrated = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          retainedLocalPgnHydratorProvider.overrideWithValue((row) async {
            try {
              return await hydrateRetainedLocalPgn(row);
            } finally {
              hydrated.complete();
            }
          }),
        ],
      );
      final tab = openBoardGameTabFromContainer(
        container,
        _args(rows),
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
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text('A').first);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => hydrated.future);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final newId = container.read(desktopTabsProvider).activeId;
      expect(newId, isNot(tab));
      final opened = container.read(boardTabGameArgsByTabIdProvider)[newId]!;
      expect(opened.pgn, freshPgn);
      expect(opened.gameId, isNull);
      expect(
        opened.librarySaveOrigin!.sourceRecordRevision,
        localPgnRecordRevision(freshPgn),
      );
      expect(
        container.read(boardTabGameArgsByTabIdProvider)[tab]!.pgn,
        rows.first.pgn,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );
  testWidgets(
    'physical save A, actual rail B/A, repeat update; retained tabs atomic',
    (tester) async {
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('retained-pgn-'),
      );
      final file = File('${dir!.path}/fixture.pgn');
      await tester.runAsync(
        () => file.writeAsString('${_pgn('A')}\n\n${_pgn('B')}\n'),
      );
      final rows = [_row(file, 0, 'A'), _row(file, 1, 'B')];
      final container = ProviderContainer();
      final tab = openBoardGameTabFromContainer(
        container,
        _args(rows),
        reuseExisting: false,
      );
      final other = openBoardGameTabFromContainer(
        container,
        _args(rows),
        reuseExisting: false,
        focus: false,
      );
      final privateSeed =
          container.read(boardTabGameArgsByTabIdProvider)[other]!;
      late WidgetRef railRef;
      late BuildContext railContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  railRef = ref;
                  railContext = context;
                  return SizedBox(
                    width: 600,
                    child: EventGamesTable(tabId: tab),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      var target = _target(rows.first.localPgnSource!);
      LocalLibraryGameUpdateOutcome? firstCommit;
      for (final comment in [
        '{long annotation} (1. d4 d5)',
        '{second annotation}',
      ]) {
        final previous = target;
        final outcome =
            (await tester.runAsync(
              () => updateLocalLibraryPgnGame(
                target: target,
                game: ChessGame.fromPgn('A', _pgn('A', comment)),
              ),
            ))!;
        firstCommit ??= outcome;
        publishRetainedLocalPgnCommit(
          container,
          previous: previous,
          outcome: outcome,
        );
        await tester.pump();
        final retained =
            container.read(boardTabGameArgsByTabIdProvider)[other]!;
        expect(retained.pgn, privateSeed.pgn); // no tree-seed replacement
        expect(retained.librarySaveOrigin, privateSeed.librarySaveOrigin);
        expect(
          shouldAttachRefreshedLocalPgnOriginAfterUpdate(
            tabStillExists: true,
            updatingArgs: privateSeed,
            currentArgs: retained,
            updatingOrigin: privateSeed.librarySaveOrigin!,
            currentAttachedOrigin: null,
          ),
          isTrue,
        ); // sibling summary refresh is not game replacement
        expect(
          shouldAttachRefreshedLocalPgnOriginAfterUpdate(
            tabStillExists: true,
            updatingArgs: privateSeed,
            currentArgs: retained.copyWith(pgn: retained.pgn),
            updatingOrigin: privateSeed.librarySaveOrigin!,
            currentAttachedOrigin: null,
          ),
          isFalse,
        ); // an actual replacement cannot adopt an old completion
        expect(retained.databaseGames.first.pgn, outcome.committedPgn);
        expect(
          retained.databaseGames.first.localPgnSource!.recordRevision,
          outcome.updateTarget.recordRevision,
        );
        await tester.runAsync(
          () =>
              navigateActiveEventGame(railRef, context: railContext, delta: 1),
        );
        await tester.pump();
        expect(
          container
              .read(boardTabGameArgsByTabIdProvider)[tab]!
              .gameListSelectedId,
          'B',
        );
        await tester.runAsync(
          () =>
              navigateActiveEventGame(railRef, context: railContext, delta: -1),
        );
        await tester.pump();
        final reopened = container.read(boardTabGameArgsByTabIdProvider)[tab]!;
        expect(reopened.gameId, isNull);
        expect(reopened.pgn, outcome.committedPgn);
        expect(
          reopened.librarySaveOrigin!.sourceRecordRevision,
          outcome.updateTarget.recordRevision,
        );
        target = _target(reopened.databaseGames.first.localPgnSource!);
        final disk = (await tester.runAsync(() => file.readAsString()))!;
        expect(pgnGameRanges(disk), hasLength(2));
        expect(
          localPgnRecordFromSnapshot(text: disk, indexInFile: 1),
          _pgn('B'),
        );
      }
      // A delayed older publication cannot roll back the second revision.
      publishRetainedLocalPgnCommit(
        container,
        previous: _target(rows.first.localPgnSource!),
        outcome: firstCommit!,
      );
      expect(
        container
            .read(boardTabGameArgsByTabIdProvider)[other]!
            .databaseGames
            .first
            .localPgnSource!
            .recordRevision,
        target.recordRevision,
      );
      // A read may refresh annotation-only differences; an old dirty save may not.
      final refreshed =
          (await tester.runAsync(() => hydrateRetainedLocalPgn(rows.first)))!;
      expect(refreshed.localPgnSource!.recordRevision, target.recordRevision);
      await tester.runAsync(() async {
        await expectLater(
          updateLocalLibraryPgnGame(
            target: _target(rows.first.localPgnSource!),
            game: ChessGame.fromPgn('stale', _pgn('A', '{stale}')),
          ),
          throwsStateError,
        );
      });
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(() => dir.delete(recursive: true));
    },
  );

  testWidgets(
    'delayed rail hydration cannot navigate after A/B/A ownership change',
    (tester) async {
      final pending = Completer<TournamentGameSummary>();
      final rows = [
        _row(File('fixture.pgn'), 0, 'A'),
        _row(File('fixture.pgn'), 1, 'B'),
      ];
      final container = ProviderContainer(
        overrides: [
          retainedLocalPgnHydratorProvider.overrideWithValue(
            (_) => pending.future,
          ),
        ],
      );
      final tab = openBoardGameTabFromContainer(
        container,
        _args(rows),
        reuseExisting: false,
      );
      final other = openBoardGameTabFromContainer(
        container,
        _args(rows),
        reuseExisting: false,
        focus: false,
      );
      late WidgetRef railRef;
      late BuildContext railContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                railRef = ref;
                railContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      final navigation = navigateActiveEventGame(
        railRef,
        context: railContext,
        delta: 1,
      );
      await tester.pump();
      container.read(desktopTabsProvider.notifier).activate(other);
      container.read(desktopTabsProvider.notifier).activate(tab);
      pending.complete(rows.last);
      await navigation;
      expect(
        container
            .read(boardTabGameArgsByTabIdProvider)[tab]!
            .gameListSelectedId,
        'A',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );
}
