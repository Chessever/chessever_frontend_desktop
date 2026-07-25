import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/state/active_board_game.dart';

void main() {
  test('refreshed local PGN identity overrides the open-time identity', () {
    const openedOrigin = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: r'C:\Games\prep.pgn',
      sourceIndex: 0,
      sourceFileGameCount: 1,
      sourcePgnFingerprint: 'before-update',
      title: 'Original vs Opponent',
    );
    const refreshedOrigin = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: r'C:\Games\prep.pgn',
      sourceIndex: 0,
      sourceFileGameCount: 1,
      sourcePgnFingerprint: 'after-update',
      title: 'Renamed vs Opponent',
    );

    final effective = resolveBoardTabLibrarySaveOrigin(
      sourceOrigin: openedOrigin,
      attachedOrigin: refreshedOrigin,
    );

    expect(effective, same(refreshedOrigin));
    expect(effective?.sourcePgnFingerprint, 'after-update');
    expect(effective?.title, 'Renamed vs Opponent');
  });

  test('delayed update identity is rejected after the tab game changes', () {
    const updatingOrigin = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: r'C:\Games\first.pgn',
      sourceIndex: 0,
      sourceFileGameCount: 1,
      sourcePgnFingerprint: 'first-before-update',
      title: 'First game',
    );
    const replacementOrigin = BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: 'replacement-game.pgn',
      sourceIndex: 3,
      sourceFileGameCount: 5,
      sourcePgnFingerprint: 'replacement-current',
      title: 'Replacement game',
    );

    expect(
      shouldAcceptRefreshedLocalPgnOrigin(
        updatingOrigin: updatingOrigin,
        currentSourceOrigin: replacementOrigin,
        currentAttachedOrigin: null,
      ),
      isFalse,
    );
    expect(
      shouldAcceptRefreshedLocalPgnOrigin(
        updatingOrigin: updatingOrigin,
        currentSourceOrigin: updatingOrigin,
        currentAttachedOrigin: null,
      ),
      isTrue,
    );
    expect(
      shouldAcceptRefreshedLocalPgnOrigin(
        updatingOrigin: updatingOrigin,
        currentSourceOrigin: null,
        currentAttachedOrigin: null,
      ),
      isFalse,
    );
  });

  test(
    'completed update cannot attach refreshed identity to a replaced or closed tab',
    () async {
      const updatingOrigin = BoardTabLibrarySaveOrigin.localPgnFile(
        sourcePath: r'C:\Games\first.pgn',
        sourceIndex: 0,
        sourceFileGameCount: 1,
        sourcePgnFingerprint: 'first-before-update',
        title: 'First game',
      );
      const updatingArgs = BoardTabGameArgs(
        pgn: '1. e4 e5 *',
        label: 'First game',
        whiteName: 'White',
        blackName: 'Black',
        librarySaveOrigin: updatingOrigin,
      );
      const replacementArgs = BoardTabGameArgs(
        pgn: '1. d4 d5 *',
        label: 'Replacement game',
        whiteName: 'Replacement White',
        blackName: 'Replacement Black',
      );

      final replacementGate = Completer<void>();
      var currentArgs = updatingArgs;
      final replacementAcceptance = () async {
        await replacementGate.future;
        return shouldAttachRefreshedLocalPgnOriginAfterUpdate(
          tabStillExists: true,
          updatingArgs: updatingArgs,
          currentArgs: currentArgs,
          updatingOrigin: updatingOrigin,
          currentAttachedOrigin: null,
        );
      }();
      currentArgs = replacementArgs;
      replacementGate.complete();
      expect(await replacementAcceptance, isFalse);

      final closeGate = Completer<void>();
      var tabStillExists = true;
      final closeAcceptance = () async {
        await closeGate.future;
        return shouldAttachRefreshedLocalPgnOriginAfterUpdate(
          tabStillExists: tabStillExists,
          updatingArgs: updatingArgs,
          currentArgs: updatingArgs,
          updatingOrigin: updatingOrigin,
          currentAttachedOrigin: null,
        );
      }();
      tabStillExists = false;
      closeGate.complete();
      expect(await closeAcceptance, isFalse);
    },
  );

  test(
    'completed first save cannot attach identity to a replaced closed or retargeted tab',
    () {
      const savingArgs = BoardTabGameArgs(
        pgn: '1. e4 e5 *',
        label: 'First game',
        whiteName: 'White',
        blackName: 'Black',
      );
      const replacementArgs = BoardTabGameArgs(
        pgn: '1. d4 d5 *',
        label: 'Replacement game',
        whiteName: 'Replacement White',
        blackName: 'Replacement Black',
      );
      const attachedOrigin = BoardTabLibrarySaveOrigin.localPgnFile(
        sourcePath: r'C:\Games\other.pgn',
        sourceIndex: 1,
        sourceFileGameCount: 2,
        sourcePgnFingerprint: 'other',
        title: 'Other game',
      );

      expect(
        shouldAttachLocalPgnIdentityAfterSaveCompletion(
          tabStillExists: true,
          gameStillMatches: true,
          savingArgs: savingArgs,
          currentArgs: savingArgs,
          savingAttachedOrigin: null,
          currentAttachedOrigin: null,
          hasLocalUpdateTarget: true,
        ),
        isTrue,
      );
      expect(
        shouldAttachLocalPgnIdentityAfterSaveCompletion(
          tabStillExists: true,
          gameStillMatches: true,
          savingArgs: savingArgs,
          currentArgs: replacementArgs,
          savingAttachedOrigin: null,
          currentAttachedOrigin: null,
          hasLocalUpdateTarget: true,
        ),
        isFalse,
      );
      expect(
        shouldAttachLocalPgnIdentityAfterSaveCompletion(
          tabStillExists: false,
          gameStillMatches: true,
          savingArgs: savingArgs,
          currentArgs: savingArgs,
          savingAttachedOrigin: null,
          currentAttachedOrigin: null,
          hasLocalUpdateTarget: true,
        ),
        isFalse,
      );
      expect(
        shouldAttachLocalPgnIdentityAfterSaveCompletion(
          tabStillExists: true,
          gameStillMatches: true,
          savingArgs: savingArgs,
          currentArgs: savingArgs,
          savingAttachedOrigin: null,
          currentAttachedOrigin: attachedOrigin,
          hasLocalUpdateTarget: true,
        ),
        isFalse,
      );
    },
  );
}
