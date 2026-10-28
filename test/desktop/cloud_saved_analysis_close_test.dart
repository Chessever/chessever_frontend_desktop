import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/state/user_move_nags.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart'
    show ChessboardView;
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/date_time_provider.dart';
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
      // The overlay rides beside the retained tree, never baked into it (a
      // restore reads the overlay again); the guard merges it to compare.
      final sessionStart = board.indexOf(
        'BoardPaneSession retainedBoardSession(',
      );
      final sessionEnd = board.indexOf('useEffect(', sessionStart);
      final stored = board.substring(sessionStart, sessionEnd);
      expect(stored, contains('game: chessGame.value,'));
      expect(stored, contains('userNags: userNags,'));
      expect(stored, isNot(contains('mergeUserMainlineNagsForGif(')));
      expect(board, contains('retainedBoardSession(sessionUserNags)'));
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

  test('a feed move follows a clean save; edits made before it still warn', () {
    final fed = reconcileCanonicalBroadcastLocalAnnotationsForTesting(
      previousBroadcastPgn: sourcePgn,
      currentGame: savedGame,
      freshGame: ChessGame.fromPgn(
        'event-game',
        sourcePgn.replaceAll('Nc6 *', 'Nc6 3. Bb5 *'),
      ),
      userNags: const {},
    ).game;
    expect(exportGameToPgn(fed), contains('Saved private variation'));
    // The probe: the old baseline lacks the feed move, so it warns.
    expect(
      boardSessionHasUnsavedAnalysis(sessionFor(fed, savedPgn: savedPgn)),
      isTrue,
    );
    final followed = savedAnalysisBaselineAfterFeed(
      lastSavedAnalysisPgn: savedPgn,
      boardPgnBeforeFeed: exportGameToPgn(savedGame),
      boardPgnAfterFeed: exportGameToPgn(fed),
    );
    expect(
      boardSessionHasUnsavedAnalysis(sessionFor(fed, savedPgn: followed)),
      isFalse,
    );
    final edited = ChessGame.fromPgn(
      'event-game',
      analysisPgn.replaceAll('Saved private variation', 'Edited after save'),
    );
    expect(
      savedAnalysisBaselineAfterFeed(
        lastSavedAnalysisPgn: savedPgn,
        boardPgnBeforeFeed: exportGameToPgn(edited),
        boardPgnAfterFeed: exportGameToPgn(fed),
      ),
      savedPgn,
    );
    expect(
      savedAnalysisBaselineAfterFeed(
        lastSavedAnalysisPgn: null,
        boardPgnBeforeFeed: exportGameToPgn(savedGame),
        boardPgnAfterFeed: exportGameToPgn(fed),
      ),
      isNull,
    );
  });

  test('retained NAGs stay beside the tree but count as analysis', () {
    final plain = ChessGame.fromPgn('event-game', sourcePgn);
    final marked = BoardPaneSession(
      game: plain,
      pointer: const [1],
      pgnHeaders: const {},
      flipped: false,
      loadedFrom: 'event',
      lastAppliedPgn: sourcePgn,
      lastSavedAnalysisPgn: exportGameToPgn(plain).trim(),
      lastAppliedGameId: 'event-game',
      lastAppliedInitialFenKey: null,
      dirtySinceLoad: false,
      hasUnseenMoves: false,
      undoStack: const [],
      userNags: const {
        0: [1],
      },
    );
    expect(marked.game.mainline.first.nags, isNull);
    expect(boardSessionUserGame(marked).mainline.first.nags, contains(1));
    expect(boardSessionHasUnsavedAnalysis(marked), isTrue);
  });

  group('mounted live board', () {
    late Directory databaseDirectory;
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      databaseDirectory = await Directory.systemTemp.createTemp(
        'chessever-saved-analysis-close-',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => databaseDirectory.path,
          );
      sqfliteFfiInit();
      sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
      await AppDatabase.instance.database;
    });

    tearDownAll(() async {
      await AppDatabase.instance.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (await databaseDirectory.exists()) {
        await databaseDirectory.delete(recursive: true);
      }
    });

    testWidgets(
      'a feed move after a save does not make the untouched board unsaved',
      (tester) async {
        final board = await _pumpBoard(tester, live: true);
        // Private analysis the user then saves: a mark on the first move.
        board.toggleNag(0, 1);
        await board.settle();
        // A save persists the board as the user sees it, marks included.
        final savedPgn = exportGameToPgn(board.liveSession().game).trim();
        final retained = board.retained();
        await board.remountFrom(
          _copySession(
            retained,
            lastSavedAnalysisPgn: savedPgn,
            hasCommittedSave: true,
            savedSourceSeedPgn: retained.lastAppliedPgn,
            lastBroadcastPgn:
                retained.lastBroadcastPgn ?? retained.lastAppliedPgn,
          ),
        );
        expect(board.closeWarns(), isFalse, reason: 'clean right after save');

        await board.feed(_row(_liveGameId, nextMove: true));
        // Positive controls: the packet landed and the saved mark survived.
        expect(board.fen(), _nextMoveFen);
        expect(
          exportGameToPgn(board.liveSession().game),
          allOf(contains('2. Nf3'), contains(r'1. e4 $1')),
        );
        expect(
          board.closeWarns(),
          isFalse,
          reason: 'only the Event feed changed the board after the save',
        );
        expect(boardSessionHasUnsavedAnalysis(board.retained()), isFalse);

        // A user edit after the save must still be protected, in both the
        // mounted snapshot and the retained session the shell falls back to.
        board.toggleNag(2, 1);
        await board.settle();
        expect(board.closeWarns(), isTrue);
        expect(boardSessionHasUnsavedAnalysis(board.retained()), isTrue);
        await board.dispose();
      },
    );

    testWidgets('a restored board does not keep a NAG the user toggled off', (
      tester,
    ) async {
      final board = await _pumpBoard(tester, live: false);
      board.toggleNag(0, 1);
      await board.settle();
      // Positive control: the mark is part of what the board hands out.
      expect(exportGameToPgn(board.liveSession().game), contains(r'1. e4 $1'));

      await board.remountFrom(board.retained());
      board.toggleNag(0, 1);
      await board.settle();

      List<int> firstMoveNags(BoardPaneSession session) =>
          session.game.mainline.first.nags ?? const <int>[];
      expect(firstMoveNags(board.liveSession()), isNot(contains(1)));
      expect(firstMoveNags(board.retained()), isNot(contains(1)));
      await board.dispose();
    });
  });
}

const _boardTabId = 'tournaments-default';
const _liveGameId = 'titled-tuesday-1';

const String _livePgn = '''
[Event "Titled Tuesday"]
[White "White 1"]
[Black "Black 1"]
[Result "*"]

1. e4 e5 *
''';

const String _nextMovePgn = '''
[Event "Titled Tuesday"]
[White "White 1"]
[Black "Black 1"]
[Result "*"]

1. e4 e5 2. Nf3 *
''';

const String _finishedPgn = '''
[Event "Club game"]
[White "White 1"]
[Black "Black 1"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
''';

const String _liveFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

const String _nextMoveFen =
    'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2';

final _moveTime = DateTime.utc(2026, 7, 14, 18, 0);

Map<String, dynamic> _row(String gameId, {required bool nextMove}) => {
  'id': gameId,
  'pgn': nextMove ? _nextMovePgn : _livePgn,
  'fen': nextMove ? _nextMoveFen : _liveFen,
  'status': 'ONGOING',
  'last_move': nextMove ? 'g1f3' : 'e7e5',
  'last_move_time':
      _moveTime.add(Duration(seconds: nextMove ? 3 : 1)).toIso8601String(),
  'last_clock_white': nextMove ? 176 : 177,
  'last_clock_black': 179,
};

BoardPaneSession _copySession(
  BoardPaneSession s, {
  String? lastSavedAnalysisPgn,
  bool? hasCommittedSave,
  String? savedSourceSeedPgn,
  String? lastBroadcastPgn,
}) => BoardPaneSession(
  game: s.game,
  pointer: s.pointer,
  pgnHeaders: s.pgnHeaders,
  flipped: s.flipped,
  loadedFrom: s.loadedFrom,
  lastAppliedPgn: s.lastAppliedPgn,
  lastAppliedGameId: s.lastAppliedGameId,
  lastAppliedInitialFenKey: s.lastAppliedInitialFenKey,
  dirtySinceLoad: s.dirtySinceLoad,
  hasUnseenMoves: s.hasUnseenMoves,
  undoStack: s.undoStack,
  lastSavedAnalysisPgn: lastSavedAnalysisPgn ?? s.lastSavedAnalysisPgn,
  lastBroadcastPgn: lastBroadcastPgn ?? s.lastBroadcastPgn,
  savedSourceSeedPgn: savedSourceSeedPgn ?? s.savedSourceSeedPgn,
  hasCommittedSave: hasCommittedSave ?? s.hasCommittedSave,
  detachedSeedPgn: s.detachedSeedPgn,
);

class _MountedBoard {
  _MountedBoard(
    this.tester,
    this.container,
    this.showPane,
    this.updates, {
    required this.live,
  });

  final WidgetTester tester;
  final ProviderContainer container;
  final ValueNotifier<bool> showPane;
  final StreamController<Map<String, dynamic>?> updates;
  final bool live;

  BoardPaneSession retained() =>
      container.read(boardPaneSessionByTabIdProvider)[_boardTabId]!;

  /// What the mounted pane would hand a save, a detach or the close guard.
  BoardPaneSession liveSession() =>
      container.read(boardPaneSnapshotReadersProvider)[_boardTabId]!().session;

  void toggleNag(int ply, int nag) => container
      .read(userMoveNagsProvider.notifier)
      .toggleNag(_boardTabId, ply, nag);

  bool closeWarns() =>
      boardTabHasUnsavedAnalysis(tabId: _boardTabId, read: container.read);

  String fen() =>
      tester.widget<DesktopChessBoard>(find.byType(DesktopChessBoard)).fen;

  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  Future<void> feed(Map<String, dynamic> row) async {
    updates.add(row);
    await settle();
  }

  Future<void> remountFrom(BoardPaneSession session) async {
    showPane.value = false;
    await settle();
    container
        .read(boardPaneSessionByTabIdProvider.notifier)
        .put(_boardTabId, session);
    showPane.value = true;
    await settle();
    if (live) await feed(_row(_liveGameId, nextMove: false));
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }
}

Future<_MountedBoard> _pumpBoard(
  WidgetTester tester, {
  required bool live,
}) async {
  SharedPreferences.setMockInitialValues(const <String, Object>{});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1800, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final updates = StreamController<Map<String, dynamic>?>.broadcast(
    sync: true,
  );
  final rail = StreamController<Map<String, LiveGameUpdate>>.broadcast(
    sync: true,
  );
  addTearDown(updates.close);
  addTearDown(rail.close);
  final source = GamesTourModel.fromGame(
    Games.fromJson({
      'id': _liveGameId,
      'round_id': 'round-11',
      'round_slug': 'round-11',
      'tour_id': 'titled-tuesday',
      'tour_slug': 'titled-tuesday',
      'players': [
        {'name': 'White 1', 'fed': 'USA', 'rating': 2600},
        {'name': 'Black 1', 'fed': 'GER', 'rating': 2590},
      ],
      'status': 'ONGOING',
      'pgn': _livePgn,
      'fen': _liveFen,
      'last_move': 'e7e5',
      'last_move_time': _moveTime.toIso8601String(),
      'last_clock_white': 178,
      'last_clock_black': 179,
      'board_nr': 1,
    }),
  );
  final args = live
      ? BoardTabGameArgs(
    gameId: _liveGameId,
    pgn: _livePgn,
    label: 'White 1 - Black 1',
    whiteName: 'White 1',
    blackName: 'Black 1',
    tournamentTitle: 'Titled Tuesday',
    fenSeed: _liveFen,
    sourceGame: source,
    viewSource: ChessboardView.forYou,
    eventGames: [TournamentGameSummary.fromGamesTourModel(source)],
    gameListSelectedId: _liveGameId,
  )
      // A finished analysis tab: nothing re-seeds it after a restore.
      : const BoardTabGameArgs(
    pgn: _finishedPgn,
    label: 'White 1 - Black 1',
    whiteName: 'White 1',
    blackName: 'Black 1',
  );
  final showPane = ValueNotifier<bool>(true);
  addTearDown(showPane.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardTabGameArgsByTabIdProvider.overrideWith(
          (ref) => <String, BoardTabGameArgs>{_boardTabId: args},
        ),
        boardSettingsProviderNew.overrideWith(_QuietBoardSettings.new),
        engineSettingsProviderNew.overrideWith(_NoEngineSettings.new),
        keyboardShortcutsProvider.overrideWith(_DefaultShortcuts.new),
        liveGameUpdateArrivalStreamProvider.overrideWith(
          (ref, gameId) => _arrivals(updates.stream, gameId),
        ),
        gameUpdatesBatchStreamProvider.overrideWith((ref, key) => rail.stream),
        dateTimeProvider.overrideWith((ref) => Stream.value(_moveTime)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: showPane,
            builder:
                (context, show, _) =>
                    show
                        ? const BoardPane(tabId: _boardTabId)
                        : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  final board = _MountedBoard(
    tester,
    container,
    showPane,
    updates,
    live: live,
  );
  await board.settle();
  if (live) await board.feed(_row(_liveGameId, nextMove: false));
  expect(board.liveSession().game.mainline, isNotEmpty);
  return board;
}

Stream<LiveStreamArrival<LiveGameUpdate?>> _arrivals(
  Stream<Map<String, dynamic>?> updates,
  String gameId,
) async* {
  var sequence = 0;
  await for (final update in updates) {
    yield LiveStreamArrival<LiveGameUpdate?>(
      value:
          update == null ? null : LiveGameUpdate.fromLegacyMap(gameId, update),
      sessionEpoch: 1,
      sequence: ++sequence,
      isFallback: false,
    );
  }
}

class _QuietBoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(soundEnabled: false, showEvaluationBar: false);
}

class _NoEngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineGauge: false, showEngineAnalysis: false);
}

class _DefaultShortcuts extends KeyboardShortcutsNotifier {
  @override
  Future<BoardShortcutMap> build() async =>
      BoardShortcutMap(defaultBoardShortcuts());
}
