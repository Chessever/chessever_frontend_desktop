import 'dart:io' as io;

import 'package:chessground/chessground.dart' as cg;
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/board_analysis_recovery.dart';
import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

ChessGame game(String pgn) => ChessGame.fromPgn('recovery', pgn);

BoardAnalysisRecovery recovery(
  ChessGame source, {
  BoardAnnotations annotations = const BoardAnnotations(),
  Map<int, List<int>> userNags = const {},
}) => BoardAnalysisRecovery(
  game: source,
  annotations: annotations,
  userNags: userNags,
  selectedPath: const ['e2e4', 'c7c5'],
  clearedPath: const ['e2e4'],
);

void main() {
  test(
    'clear/restore round trip includes root, nested branches, comments and NAGs',
    () {
      final source = game(
        r'{Root note} 1. e4 $1 {First} e5 (1... c5 $2 {Sicilian} 2. Nf3 (2. Nc3)) 2. Nf3 *',
      );
      final cleared = clearGameAnalysis(source);
      expect(cleared.rootComments, isEmpty);
      expect(gameHasClearableAnalysis(cleared), isFalse);
      final restored = restoreClearedBoardAnalysis(
        checkpoint: source,
        current: cleared,
      );
      expect(restored.toJson(), source.toJson());
      expect(source.mainline.first.comments, contains('First'));
    },
  );

  test('root-only and starting-comment-only analysis is clearable', () {
    final root = game('1. e4 *').copyWith(rootComments: ['root']);
    expect(gameHasClearableAnalysis(root), isTrue);
    expect(clearGameAnalysis(root).rootComments, isEmpty);
    final move = root.mainline.first.copyWith(startingComments: ['before']);
    final before = root.copyWith(rootComments: [], mainline: [move]);
    expect(gameHasClearableAnalysis(before), isTrue);
    expect(clearGameAnalysis(before).mainline.first.startingComments, isNull);
  });

  test(
    'later comments, branches, quality and positional symbols all survive',
    () {
      final source = game(
        r'1. e4 $1 {old comment} e5 (1... c5 $2 {old branch}) *',
      );
      final current = game(
        r'1. e4 $4 $14 {new comment} e5 (1... c5 2. Nf3 {new tail}) (1... e6) *',
      );
      final restored = restoreClearedBoardAnalysis(
        checkpoint: source,
        current: current,
      );
      expect(
        restored.mainline.first.comments,
        containsAll(['old comment', 'new comment']),
      );
      expect(restored.mainline.first.nags, containsAll([4, 14]));
      expect(restored.mainline.first.nags, isNot(contains(1)));
      final branches = restored.mainline.first.variations!;
      expect(
        branches.map((line) => line.first.uci),
        containsAll(['c7c5', 'e7e6']),
      );
      final sicilian = branches.singleWhere((line) => line.first.uci == 'c7c5');
      expect(sicilian.first.comments, contains('old branch'));
      expect(sicilian.last.uci, 'g1f3');
    },
  );

  test(
    'current mainline, newest headers and runtime provenance are authoritative',
    () {
      final source = game(r'1. e4 $1 {kept} e5 {stale} 2. Nf3 *');
      final current = game('1. e4 c5 2. Nf3 d6 *').copyWith(
        metadata: {
          'Result': '*',
          'Event': 'latest',
          ChessGame.metadataIsLiveKey: true,
        },
      );
      final restored = restoreClearedBoardAnalysis(
        checkpoint: source,
        current: current,
      );
      expect(
        restored.mainline.map((move) => move.uci),
        current.mainline.map((move) => move.uci),
      );
      expect(restored.metadata, same(current.metadata));
      expect(restored.mainline.first.comments, contains('kept'));
      expect(restored.mainline[1].comments ?? [], isEmpty);
      final takenBack = current.copyWith(
        mainline: current.mainline.take(1).toList(),
      );
      expect(
        restoreClearedBoardAnalysis(
          checkpoint: source,
          current: takenBack,
        ).mainline,
        hasLength(1),
      );
    },
  );

  test(
    'confirmed private prediction is folded into latest live continuation',
    () {
      final source = game('1. e4 e5 (1... c5 {prediction} 2. Nf3) *');
      final current = game('1. e4 c5 2. Nf3 d6 *');
      final restored = restoreClearedBoardAnalysis(
        checkpoint: source,
        current: current,
      );
      expect(
        restored.mainline.map((move) => move.uci),
        current.mainline.map((move) => move.uci),
      );
      expect(restored.mainline.first.variations, isNull);
      expect(restored.mainline[1].comments, contains('prediction'));
    },
  );

  test('detached root lines and machine annotations round trip', () {
    final source = game('1. e4 {[%eval 0.35] [%clk 0:09:42]} e5 *').copyWith(
      detachedRootAnalysis: [game('1. d4 d5 *').mainline],
      overrideDetachedRootAnalysis: true,
    );
    final restored = restoreClearedBoardAnalysis(
      checkpoint: source,
      current: clearGameAnalysis(source),
    );
    expect(restored.toJson(), source.toJson());
  });

  test(
    'a different starting position cannot receive checkpoint tree or NAGs',
    () {
      final source = game(r'1. e4 $1 *');
      final current = game(
        '1. d4 *',
      ).copyWith(startingFen: 'different-position');
      expect(
        restoreClearedBoardAnalysis(checkpoint: source, current: current),
        same(current),
      );
      expect(
        restoreBoardAnalysisUserNags(
          checkpoint: recovery(
            source,
            userNags: {
              0: [1],
            },
          ),
          current: current,
          userNags: {
            0: [4],
          },
        ),
        {
          0: [4],
        },
      );
    },
  );

  test(
    'user overlays stay separate, newer quality wins, correction drops stale ply',
    () {
      final source = game('1. e4 e5 *');
      final checkpoint = recovery(
        source,
        userNags: {
          0: [1, 14],
          1: [2],
        },
      );
      final restored = restoreBoardAnalysisUserNags(
        checkpoint: checkpoint,
        current: game('1. e4 c5 *'),
        userNags: {
          0: [4, 18],
        },
      );
      expect(restored, {
        0: [4, 18, 14],
      });
      expect(source.mainline.first.nags, isNull);
    },
  );

  test('all positions arrows and circles survive together with later ink', () {
    const arrow = cg.Arrow(
      color: Color(0xff00ff00),
      orig: Square.e2,
      dest: Square.e4,
    );
    const circle = cg.Circle(color: Color(0xffff0000), orig: Square.d4);
    const later = cg.Circle(color: Color(0xff0000ff), orig: Square.f3);
    final old = BoardAnnotations(
      shapes: {arrow},
      positionShapes: {
        'root': {arrow},
        'other': {circle},
      },
    );
    final now = BoardAnnotations(
      shapes: {later},
      positionShapes: {
        'root': {later},
      },
    );
    final restored = restoreBoardAnalysisShapes(old, now);
    expect(restored.shapes, {arrow, later});
    expect(restored.positionShapes, {
      'root': {arrow, later},
      'other': {circle},
    });
    expect(old.positionShapes['root'], {arrow});
  });

  test(
    'selection follows UCI identity, restores removed branch or keeps later navigation',
    () {
      final checkpoint = recovery(game('1. e4 e5 (1... c5) *'));
      expect(checkpoint.restorePath(['e2e4']), ['e2e4', 'c7c5']);
      expect(checkpoint.restorePath(['e2e4', 'e7e5']), ['e2e4', 'e7e5']);
      final target = game('1. e4 e5 (1... e6) (1... c5) *');
      final pointer = pointerForUciPathForTesting(
        target,
        checkpoint.selectedPath,
      );
      expect(pointer, isNotNull);
      expect(pointer, isNot([0, 0, 0]));
    },
  );

  test(
    'game/tab checkpoints survive switching and session clear, not tab close',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tabs = container.read(desktopTabsProvider.notifier);
      final tabA = tabs.open(TabKind.board, reuseExisting: false);
      final tabB = tabs.open(TabKind.board, reuseExisting: false);
      final source = recovery(game('1. e4 {private A} *'));
      final BoardAnalysisRecoveryOwner a = (tabId: tabA, game: 'game-A');
      final BoardAnalysisRecoveryOwner b = (tabId: tabA, game: 'game-B');
      final BoardAnalysisRecoveryOwner otherTab = (tabId: tabB, game: 'game-A');
      container.read(boardAnalysisRecoveryProvider.notifier).state = {
        a: source,
      };
      expect(container.read(boardAnalysisRecoveryProvider)[b], isNull);
      expect(container.read(boardAnalysisRecoveryProvider)[otherTab], isNull);
      tabs.activate(tabB);
      tabs.activate(tabA);
      container.read(boardPaneSessionByTabIdProvider.notifier).clear(tabA);
      expect(container.read(boardAnalysisRecoveryProvider)[a], same(source));
      tabs.close(tabA);
      expect(container.read(boardAnalysisRecoveryProvider), isEmpty);
      final freshContainer = ProviderContainer();
      addTearDown(freshContainer.dispose);
      expect(freshContainer.read(boardAnalysisRecoveryProvider), isEmpty);
    },
  );

  test(
    'live reconciliation advances recovery and never resurrects removed source branches',
    () {
      const original = '1. e4 e5 (1... c5 2. Nf3) *';
      final checkpoint = recovery(
        game('1. e4 e5 (1... c5 2. Nf3 Nc6 {private suffix}) *'),
      );
      final reconciled = reconcileCanonicalBroadcastLocalAnnotationsForTesting(
        previousBroadcastPgn: original,
        currentGame: checkpoint.game,
        freshGame: game('1. e4 e5 2. Nf3 *'),
        userNags: checkpoint.userNags,
      );
      final followed = checkpoint.followBroadcast(
        game: reconciled.game,
        userNags: reconciled.userNags,
        broadcastPgn: '1. e4 e5 2. Nf3 *',
      );
      final restored = restoreClearedBoardAnalysis(
        checkpoint: followed.game,
        current: game('1. e4 e5 2. Nf3 *'),
      );
      expect(restored.mainline.first.variations, isNull);
      expect(restored.mainline, hasLength(3));
    },
  );

  test(
    'cleared workspace stays authoritative over repeated source refreshes',
    () {
      final board =
          io.File('lib/desktop/panes/board_pane.dart').readAsStringSync();
      expect(
        board,
        contains('final clearedAnalysisActive = currentRecovery() != null;'),
      );
      expect(
        board,
        contains('checkpoint: oldGame, current: clearGameAnalysis(freshGame)'),
      );
      expect(board, contains('hasAnalysisRecovery || lichessGameId == null'));
    },
  );

  test(
    'production wires synchronous same-row toggle, atomic ink undo and both live paths',
    () {
      final board =
          io.File('lib/desktop/panes/board_pane.dart').readAsStringSync();
      final menu =
          io.File(
            'lib/desktop/widgets/board_context_menu.dart',
          ).readAsStringSync();
      final reset = board.substring(
        board.indexOf('Future<void> resetEditsAction()'),
        board.indexOf('void openBoardSettingsTab()'),
      );
      expect(reset, isNot(contains('await ')));
      expect(reset, isNot(contains('showResetEditsConfirmation')));
      expect(reset, contains('restoreClearedBoardAnalysis('));
      expect(reset, contains('restoreAllAnnotations('));
      expect(reset, contains('restoreRecovery: true'));
      expect(board, contains('restoreAnalysis: hasAnalysisRecovery'));
      expect(
        board,
        contains('followRecoveryThroughBroadcast(trimmed, freshGame)'),
      );
      expect(
        board,
        contains(
          "followRecoveryThroughBroadcast(pgn, ChessGame.fromPgn('', pgn))",
        ),
      );
      expect(menu, contains('if (restoreAnalysis)'));
      expect(menu, contains("label: 'Restore analysis'"));
      expect(menu, contains("label: 'Clear analysis'"));
    },
  );
}
