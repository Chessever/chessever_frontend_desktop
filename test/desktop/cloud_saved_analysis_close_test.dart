import 'dart:async';
import 'dart:io';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:flutter_test/flutter_test.dart';

const sourcePgn =
    '[White "Source"]\n[Black "Opponent"]\n[Result "*"]\n\n'
    '1. e4 e5 2. Nf3 Nc6 *';
const analysisPgn =
    '[White "Source"]\n[Black "Opponent"]\n[Result "*"]\n\n'
    '1. e4 e5 (1... c5 \$247 {Saved private variation}) 2. Nf3 Nc6 *';

BoardPaneSession sessionFor(
  ChessGame game, {
  String? savedPgn,
  String? feedPgn = sourcePgn,
  bool dirty = true,
}) => BoardPaneSession(
  game: game,
  pointer: const [1],
  pgnHeaders: const {},
  flipped: false,
  loadedFrom: 'event',
  lastAppliedPgn: feedPgn,
  lastBroadcastPgn: feedPgn,
  lastSavedAnalysisPgn: savedPgn,
  lastAppliedGameId: 'event-game',
  lastAppliedInitialFenKey: null,
  dirtySinceLoad: dirty,
  hasUnseenMoves: false,
  undoStack: const [],
  hasCommittedSave: savedPgn != null,
);

void main() {
  test(
    'successful cloud snapshot stays clean after identical Event refresh',
    () {
      final working = ChessGame.fromPgn('event-game', analysisPgn);
      final savedPgn = exportGameToPgn(working);
      final promoted = rebaseBoardAfterSavedSnapshot(
        before: working,
        saved: ChessGame.fromPgn('event-game', savedPgn),
        current: working,
      );
      final refreshed = reconcileCanonicalBroadcastLocalAnnotationsForTesting(
        previousBroadcastPgn: sourcePgn,
        currentGame: promoted,
        freshGame: ChessGame.fromPgn('event-game', sourcePgn),
        userNags: const {},
      );
      // Positive controls: the refresh really retained private analysis, and
      // its feed-relative local-edits flag is deliberately true.
      expect(refreshed.hasLocalEdits, isTrue);
      expect(
        exportGameToPgn(refreshed.game),
        contains('Saved private variation'),
      );
      expect(exportGameToPgn(refreshed.game), contains('\$247'));
      expect(
        boardSessionHasUnsavedAnalysis(
          sessionFor(
            refreshed.game,
            savedPgn: savedPgn,
            dirty: refreshed.hasLocalEdits,
          ),
        ),
        isFalse,
        reason:
            'Differences from the Event feed are not unsaved after persistence',
      );
    },
  );

  test(
    'close immediately after save reads live snapshot before retained frame',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final game = ChessGame.fromPgn('event-game', analysisPgn);
      final pgn = exportGameToPgn(game);
      container
          .read(boardPaneSessionByTabIdProvider.notifier)
          .put('board', sessionFor(game));
      var reads = 0;
      container.read(boardPaneSnapshotReadersProvider)['board'] = () {
        reads++;
        return (seed: null, session: sessionFor(game, savedPgn: pgn));
      };
      expect(
        boardTabHasUnsavedAnalysis(tabId: 'board', read: container.read),
        isFalse,
      );
      expect(reads, 1);
    },
  );

  test('detached window keeps saved baseline separate from canonical feed', () {
    final game = ChessGame.fromPgn('event-game', analysisPgn);
    final saved = exportGameToPgn(game);
    final payload = DesktopBoardWindowPayload.fromBoardSession(
      const DesktopTab(id: 'source', kind: TabKind.board, title: 'Analysis'),
      openingArgs: null,
      session: sessionFor(game, savedPgn: saved),
      attachedOrigin: null,
    );
    final transferred = DesktopBoardWindowPayload.decode(payload.encode());
    final container = ProviderContainer();
    addTearDown(container.dispose);
    transferred.restoreBoardSession(container, 'child');
    final restored = container.read(boardPaneSessionByTabIdProvider)['child']!;
    expect(restored.lastSavedAnalysisPgn, saved);
    expect(restored.lastBroadcastPgn, sourcePgn);
    expect(boardSessionHasUnsavedAnalysis(restored), isFalse);
  });

  test(
    'saved snapshot compares content rather than header order or formatting',
    () {
      final saved =
          '[White "Source"]\n[Black "Opponent"]\n[Result "*"]\n\n1. e4 e5 *';
      final current =
          '[Result "*"]\n[Black "Opponent"]\n[White "Source"]\n\n1. e4   e5 *\n';
      expect(
        shouldConfirmBoardAnalysisDiscard(
          dirtySinceLoad: true,
          currentPgn: current,
          lastAppliedPgn: sourcePgn,
          lastSavedAnalysisPgn: saved,
        ),
        isFalse,
      );
    },
  );

  final savedGame = ChessGame.fromPgn('event-game', analysisPgn);
  final savedPgn = exportGameToPgn(savedGame);
  for (final change
      in <String, String>{
        'comment': analysisPgn.replaceAll(
          'Saved private variation',
          'Later private prose',
        ),
        'native quality': analysisPgn.replaceAll('\$247', '\$242'),
        'positional NAG': analysisPgn.replaceAll('\$247', '\$247 \$14'),
        'clock': analysisPgn.replaceAll(
          'Saved private variation',
          'Saved private variation [%clk 0:12:34]',
        ),
        'graphic': analysisPgn.replaceAll(
          'Saved private variation',
          'Saved private variation [%cal Ge2e4]',
        ),
        'header': analysisPgn.replaceAll('"Source"', '"Edited header"'),
        'new nested continuation': analysisPgn.replaceAll(
          '2. Nf3 Nc6',
          '2. Nf3 (2. Bc4 Nc6) Nc6',
        ),
        'removed saved branch': sourcePgn,
        'changed mainline': '1. d4 d5 2. c4 e6 *',
      }.entries) {
    for (final dirty in [false, true]) {
      test('post-save ${change.key} warns even with restored dirty=$dirty', () {
        final changed = ChessGame.fromPgn('event-game', change.value);
        expect(
          boardSessionHasUnsavedAnalysis(
            sessionFor(changed, savedPgn: savedPgn, dirty: dirty),
          ),
          isTrue,
        );
      });
    }
  }

  test(
    'undo back before a successful save warns; redo to saved content is clean',
    () {
      final beforeSave = ChessGame.fromPgn('event-game', sourcePgn);
      expect(
        boardSessionHasUnsavedAnalysis(
          sessionFor(beforeSave, savedPgn: savedPgn, dirty: false),
        ),
        isTrue,
      );
      expect(
        boardSessionHasUnsavedAnalysis(
          sessionFor(savedGame, savedPgn: savedPgn, dirty: true),
        ),
        isFalse,
      );
    },
  );

  test('ordinary replay does not create unsaved analysis', () {
    expect(
      boardSessionHasUnsavedAnalysis(
        sessionFor(savedGame, savedPgn: savedPgn, dirty: false),
      ),
      isFalse,
    );
    expect(
      boardSessionHasUnsavedAnalysis(
        sessionFor(ChessGame.fromPgn('event-game', sourcePgn), dirty: false),
      ),
      isFalse,
    );
  });

  test(
    'edits during a pending save survive and require another save',
    () async {
      final write = Completer<String>();
      var current = savedGame;
      String? persisted;
      final completion = write.future.then((pgn) {
        current = rebaseBoardAfterSavedSnapshot(
          before: savedGame,
          saved: ChessGame.fromPgn('event-game', pgn),
          current: current,
        );
        persisted = pgn;
      });
      current = ChessGame.fromPgn(
        'event-game',
        analysisPgn.replaceAll(
          'Saved private variation',
          'New edit while save was in flight',
        ),
      );
      write.complete(savedPgn);
      await completion;
      expect(
        exportGameToPgn(current),
        contains('New edit while save was in flight'),
      );
      expect(
        boardSessionHasUnsavedAnalysis(
          sessionFor(current, savedPgn: persisted),
        ),
        isTrue,
      );
      // Only the later successful snapshot may clear this newer edit.
      persisted = exportGameToPgn(current);
      expect(
        boardSessionHasUnsavedAnalysis(
          sessionFor(current, savedPgn: persisted),
        ),
        isFalse,
      );
    },
  );

  test('no successful save leaves edited analysis protected', () {
    expect(boardSessionHasUnsavedAnalysis(sessionFor(savedGame)), isTrue);
    expect(boardSessionHasUnsavedAnalysis(null), isFalse);
  });

  test('failed and cancelled writes cannot clear newer changes', () async {
    final changed = ChessGame.fromPgn(
      'event-game',
      analysisPgn.replaceAll(
        'Saved private variation',
        'Unsaved after failure',
      ),
    );
    var baseline = savedPgn;
    final write = Completer<String>();
    final completion = write.future.then((pgn) {
      baseline = pgn;
    });
    write.completeError(StateError('synthetic write failure'));
    await expectLater(completion, throwsStateError);
    expect(baseline, savedPgn);
    expect(
      boardSessionHasUnsavedAnalysis(sessionFor(changed, savedPgn: baseline)),
      isTrue,
    );
    // Cancel returns no committed snapshot; the baseline is deliberately unchanged.
    final cancelled = await Future<String?>.value(null);
    if (cancelled != null) baseline = cancelled;
    expect(
      boardSessionHasUnsavedAnalysis(sessionFor(changed, savedPgn: baseline)),
      isTrue,
    );
  });

  test(
    'live snapshot from another activation cannot clear this tab dirty state',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(boardPaneSessionByTabIdProvider.notifier)
          .put('board', sessionFor(savedGame));
      container.read(boardPaneSnapshotReadersProvider)['board'] =
          () => (
            seed: Object(),
            session: sessionFor(savedGame, savedPgn: savedPgn),
          );
      expect(
        boardTabHasUnsavedAnalysis(tabId: 'board', read: container.read),
        isTrue,
      );
    },
  );

  test('live unsaved edit wins over a clean retained session', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(boardPaneSessionByTabIdProvider.notifier)
        .put('board', sessionFor(savedGame, savedPgn: savedPgn));
    final changed = ChessGame.fromPgn('event-game', sourcePgn);
    container.read(boardPaneSnapshotReadersProvider)['board'] =
        () => (seed: null, session: sessionFor(changed, savedPgn: savedPgn));
    expect(
      boardTabHasUnsavedAnalysis(tabId: 'board', read: container.read),
      isTrue,
    );
  });

  test(
    'legacy detached payload remains conservative without saved baseline',
    () {
      final payload = DesktopBoardWindowPayload.fromBoardSession(
        const DesktopTab(id: 'source', kind: TabKind.board, title: 'Analysis'),
        openingArgs: null,
        session: sessionFor(savedGame),
        attachedOrigin: null,
      );
      final json = payload.toJson();
      final metadata = (json['metadata'] as Map).cast<String, Object?>();
      final data = (metadata['boardSession'] as Map).cast<String, Object?>();
      data.remove('lastSavedAnalysisPgn');
      data.remove('lastBroadcastPgn');
      metadata['boardSession'] = data;
      json['metadata'] = metadata;
      final restoredPayload = DesktopBoardWindowPayload.fromJson(json);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      restoredPayload.restoreBoardSession(container, 'legacy');
      final restored =
          container.read(boardPaneSessionByTabIdProvider)['legacy']!;
      expect(restored.lastSavedAnalysisPgn, isNull);
      expect(boardSessionHasUnsavedAnalysis(restored), isTrue);
    },
  );

  test(
    'retained snapshot includes every overlay change and canonical fast path advances provenance',
    () {
      final board = File(
        'lib/desktop/panes/board_pane.dart',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      final sessionStart = board.indexOf('final session = BoardPaneSession(');
      final sessionEnd = board.indexOf(
        'WidgetsBinding.instance.addPostFrameCallback',
        sessionStart,
      );
      final stored = board.substring(sessionStart, sessionEnd);
      expect(stored, contains('mergeUserMainlineNagsForGif('));
      expect(stored, contains('sessionUserNags'));
      expect(board, contains('lastBroadcastPgn.value = pgn;'));
    },
  );

  test('successful save publishes its retained baseline before a possible remount', () {
    final board = File('lib/desktop/panes/board_pane.dart').readAsStringSync()
        .replaceAll(RegExp(r'\s+'), ' ');
    final start = board.indexOf('void commit(String pgn)');
    final end = board.indexOf('return (ownsActivation:', start);
    final commit = board.substring(start, end);
    expect(commit, contains('boardSessionWriteToken.value++'));
    expect(commit, contains('read(boardPaneSnapshotReadersProvider)'));
    expect(commit, contains('read(boardPaneSessionByTabIdProvider.notifier)'));
  });

  test(
    'production save refresh close and session boundaries use separate baselines',
    () {
      String text(String path) =>
          File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      final board = text('lib/desktop/panes/board_pane.dart');
      final commitStart = board.indexOf('void commit(String pgn)');
      final commitEnd = board.indexOf('return (ownsActivation:', commitStart);
      final commit = board.substring(commitStart, commitEnd);
      expect(commit, contains('if (!ownsActivation())'));
      expect(commit, contains('lastSavedAnalysisPgn.value = pgn.trim()'));
      expect(commit, isNot(contains('lastBroadcastPgn.value = pgn')));
      expect(commit, isNot(contains('lastAppliedPgn.value = pgn')));
      expect(board, contains('dirtySinceLoad: dirtySinceLoad.value || lastSavedAnalysisPgn.value != null'));
      expect(
        board,
        contains(
          'previousBroadcastPgn: lastBroadcastPgn.value ?? lastAppliedPgn.value',
        ),
      );
      expect(
        RegExp(
          r'lastSavedAnalysisPgn: lastSavedAnalysisPgn.value',
        ).allMatches(board).length,
        greaterThanOrEqualTo(3),
      );
      expect(
        RegExp(r'lastSavedAnalysisPgn.value = null').allMatches(board).length,
        3,
      );
      final saveStart = board.indexOf(
        'Future<void> saveGameToLibraryActionImpl()',
      );
      final saveEnd = board.indexOf(
        'Future<void> savePgnActionImpl()',
        saveStart,
      );
      final save = board.substring(saveStart, saveEnd);
      expect(
        save.indexOf('outcome == null || !outcome.didSave'),
        lessThan(save.indexOf('saveCompletion.commit(')),
      );
      for (final path in [
        'lib/desktop/shell/desktop_tab_bar.dart',
        'lib/desktop/shell/desktop_shell.dart',
        'lib/desktop/widgets/event_games_table.dart',
      ]) {
        expect(text(path), contains('boardTabHasUnsavedAnalysis('));
      }
    },
  );
}
