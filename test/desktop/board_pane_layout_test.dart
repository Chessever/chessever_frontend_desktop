import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/providers/engine_settings_provider.dart';

void main() {
  test('desktop board eval bar hides when engine analysis is off', () {
    expect(
      shouldShowDesktopBoardEvalBar(
        const EngineSettings(showEngineAnalysis: false, showEngineGauge: true),
      ),
      isFalse,
    );
    expect(
      shouldShowDesktopBoardEvalBar(
        const EngineSettings(showEngineAnalysis: true, showEngineGauge: false),
      ),
      isFalse,
    );
    expect(
      shouldShowDesktopBoardEvalBar(
        const EngineSettings(showEngineAnalysis: true, showEngineGauge: true),
      ),
      isTrue,
    );
  });

  test('game-card eval bar follows engine gauge setting only after load', () {
    expect(
      shouldShowGameCardEvalBarFromSettings(
        const AsyncValue.data(EngineSettings(showEngineGauge: true)),
      ),
      isTrue,
    );
    expect(
      shouldShowGameCardEvalBarFromSettings(
        const AsyncValue.data(EngineSettings(showEngineGauge: false)),
      ),
      isFalse,
    );
    expect(
      shouldShowGameCardEvalBarFromSettings(
        const AsyncValue<EngineSettings>.loading(),
      ),
      isFalse,
    );
  });

  test('board resize never enters focus mode implicitly', () {
    final scenarios = [
      (
        requestedSize: 759.0,
        grewPastResizeLimit: false,
        isAlreadyFocused: false,
      ),
      (
        requestedSize: 760.0,
        grewPastResizeLimit: false,
        isAlreadyFocused: false,
      ),
      (
        requestedSize: 900.0,
        grewPastResizeLimit: false,
        isAlreadyFocused: false,
      ),
      (
        requestedSize: 620.0,
        grewPastResizeLimit: true,
        isAlreadyFocused: false,
      ),
      (requestedSize: 900.0, grewPastResizeLimit: true, isAlreadyFocused: true),
    ];
    for (final scenario in scenarios) {
      expect(
        shouldEnterBoardFocusAfterResize(
          requestedSize: scenario.requestedSize,
          grewPastResizeLimit: scenario.grewPastResizeLimit,
          isAlreadyFocused: scenario.isAlreadyFocused,
        ),
        isFalse,
      );
    }
  });

  test('board resize drag uses dominant signed axis without cancellation', () {
    expect(desktopBoardResizeDragDelta(const Offset(96, 24)), 96);
    expect(desktopBoardResizeDragDelta(const Offset(96, -24)), 96);
    expect(desktopBoardResizeDragDelta(const Offset(24, -96)), 96);
    expect(desktopBoardResizeDragDelta(const Offset(-24, -96)), -96);
    expect(desktopBoardResizeDragDelta(const Offset(-96, 24)), -96);
    expect(desktopBoardResizeDragDelta(const Offset(-24, 96)), -96);
  });

  test(
    'dirty board close confirmation only appears for notation-changing edits',
    () {
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: false,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4',
        ),
        isFalse,
      );
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: true,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4 e5',
        ),
        isFalse,
      );
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: true,
          currentPgn: '1. e4 e5',
          lastAppliedPgn: '1. e4',
        ),
        isTrue,
      );
      expect(
        shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: true,
          currentPgn: '1. e4',
          lastAppliedPgn: null,
        ),
        isTrue,
      );
    },
  );

  test('empty board args do not overwrite a restored build-tree session', () {
    expect(
      shouldApplyEmptyBoardArgsSeed(
        hasRestoredSession: false,
        hasCurrentMoves: true,
        dirtySinceLoad: true,
        loadedFrom: 'tab:Player tree',
      ),
      isTrue,
    );
    expect(
      shouldApplyEmptyBoardArgsSeed(
        hasRestoredSession: true,
        hasCurrentMoves: true,
        dirtySinceLoad: true,
        loadedFrom: 'tab:Player tree',
      ),
      isFalse,
    );
    expect(
      shouldApplyEmptyBoardArgsSeed(
        hasRestoredSession: true,
        hasCurrentMoves: false,
        dirtySinceLoad: false,
        loadedFrom: 'tab:Player tree',
      ),
      isFalse,
    );
  });

  test('hydrated tab PGN is persisted even for background Board tabs', () {
    const args = BoardTabGameArgs(
      gameId: 'game-1',
      pgn: '',
      label: 'Alpha vs Beta',
      whiteName: 'Alpha',
      blackName: 'Beta',
    );

    expect(
      shouldPersistHydratedBoardTabPgn(
        hydratedTabId: 'background-tab',
        currentArgs: args,
        expectedGameId: 'game-1',
      ),
      isTrue,
    );
    expect(
      shouldApplyHydratedBoardTabPgn(
        activeTabId: 'explorer-tab',
        hydratedTabId: 'background-tab',
      ),
      isFalse,
    );
  });

  test('hydrated tab PGN is ignored when the tab changed games', () {
    const args = BoardTabGameArgs(
      gameId: 'game-2',
      pgn: '',
      label: 'Gamma vs Delta',
      whiteName: 'Gamma',
      blackName: 'Delta',
    );

    expect(
      shouldPersistHydratedBoardTabPgn(
        hydratedTabId: 'board-tab',
        currentArgs: args,
        expectedGameId: 'game-1',
      ),
      isFalse,
    );
  });

  test('board focus reserves player rows and compact padding', () {
    final focused = computeBoardAreaChromeMetrics(
      focusMode: true,
      hasPlayerInfo: false,
    );

    expect(focused.hasHeaders, isTrue);
    expect(focused.topRowHeight, greaterThan(0));
    expect(focused.bottomRowHeight, greaterThan(0));
    expect(focused.headerGapTotal, greaterThan(0));
    expect(focused.outerPadding, greaterThan(0));
    expect(focused.outerPadding, lessThan(24));

    final regularWithoutPlayers = computeBoardAreaChromeMetrics(
      focusMode: false,
      hasPlayerInfo: false,
    );
    expect(regularWithoutPlayers.hasHeaders, isFalse);
    expect(regularWithoutPlayers.topRowHeight, 32);
    expect(regularWithoutPlayers.bottomRowHeight, 22);
  });
}
