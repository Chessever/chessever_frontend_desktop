import 'dart:async';
import 'package:chessever/desktop/services/desktop_board_window_readiness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;

void main() {
  for (final outcome in [
    'ready',
    'timeout',
    'failure',
    'wrong-window',
    'stale-transfer',
    'late-save',
    'replaced',
  ]) {
    test('detachment waits for matching child readiness: $outcome', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tabId = container
          .read(desktopTabsProvider.notifier)
          .open(TabKind.board, title: 'Scratch', reuseExisting: false);
      final shown = Completer<void>();
      final ack = Completer<Object?>();
      String? transferId;
      var creates = 0;
      final service = DesktopBoardWindowService(
        childReadyTimeout: const Duration(milliseconds: 200),
        createDetachedWindow: (payload) async {
          creates++;
          transferId =
              DesktopBoardWindowPayload.decode(
                payload.encode(),
              ).detachTransferId;
          shown.complete();
          return DetachedBoardWindow(
            windowId: 'child',
            probe: (_) => ack.future,
          );
        },
      );
      final pending = service.detachDesktopTabToWindow(container, tabId);
      await shown.future;
      expect(
        container.read(desktopTabsProvider).tabs.any((t) => t.id == tabId),
        isTrue,
      );
      expect(await service.detachDesktopTabToWindow(container, tabId), isFalse);
      expect(creates, 1);
      if (outcome == 'late-save') {
        container
            .read(boardTabAttachedLibrarySaveOriginByTabIdProvider.notifier)
            .attachCloudSavedAnalysis(
              tabId: tabId,
              origin: const BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
                analysisId: 'saved-during-startup',
                title: 'Saved',
              ),
            );
      }
      if (outcome == 'replaced') {
        container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
          tabId: const BoardTabGameArgs(
            pgn: '1. c4 *',
            label: 'Replacement',
            whiteName: '',
            blackName: '',
          ),
        };
      }
      if (outcome == 'failure') {
        ack.completeError(StateError('child restoration failed'));
      } else if (outcome != 'timeout') {
        ack.complete({
          'ready': true,
          'windowId': outcome == 'wrong-window' ? 'other-child' : 'child',
          'transferId':
              outcome == 'stale-transfer' ? 'old-transfer' : transferId,
        });
      }
      expect(await pending, outcome == 'ready');
      expect(
        container.read(desktopTabsProvider).tabs.any((t) => t.id == tabId),
        outcome != 'ready',
      );
      if (outcome == 'timeout') {
        ack.complete({
          'ready': true,
          'windowId': 'child',
          'transferId': transferId,
        });
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(desktopTabsProvider).tabs.any((t) => t.id == tabId),
          isTrue,
        );
      }
    });
  }

  test(
    'unsaved scratch detaches without inventing identity; late edits stay open',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final tabId = container
          .read(desktopTabsProvider.notifier)
          .open(TabKind.board, title: 'Unsaved', reuseExisting: false);
      var pgn = '1. d4 *';
      container.read(boardPaneSnapshotReadersProvider)[tabId] =
          () => (
            seed: null,
            session: BoardPaneSession(
              game: ChessGame.fromPgn('unsaved', pgn),
              pointer: const [],
              pgnHeaders: const {},
              flipped: false,
              loadedFrom: null,
              lastAppliedPgn: null,
              lastAppliedGameId: null,
              lastAppliedInitialFenKey: null,
              dirtySinceLoad: true,
              hasUnseenMoves: false,
              undoStack: const [],
            ),
          );
      DesktopBoardWindowPayload? sent;
      final service = DesktopBoardWindowService(
        createDetachedWindow: (payload) async {
          sent = DesktopBoardWindowPayload.decode(payload.encode());
          return DetachedBoardWindow(
            windowId: 'child',
            probe: (id) async {
              pgn = '1. d4 d5 *'; // Edit AFTER native show, BEFORE readiness.
              return {'ready': true, 'windowId': 'child', 'transferId': id};
            },
          );
        },
      );
      expect(await service.detachDesktopTabToWindow(container, tabId), isFalse);
      expect(
        container.read(desktopTabsProvider).tabs.any((t) => t.id == tabId),
        isTrue,
      );
      expect(sent!.args, isNull);
      final child = ProviderContainer();
      addTearDown(child.dispose);
      sent!.restoreBoardSession(child, 'child');
      expect(
        child.read(boardTabAttachedLibrarySaveOriginByTabIdProvider)['child'],
        isNull,
      );
      final restored = child.read(boardPaneSessionByTabIdProvider)['child']!;
      expect(exportGameToPgn(restored.game), contains('d4'));
      expect(restored.hasCommittedSave, isFalse);
      expect(restored.dirtySinceLoad, isTrue);
    },
  );

  for (final scratch in [true, false]) {
    for (final cloud in [true, false]) {
      test(
        'first ${cloud ? 'cloud' : 'local'} save then detach scratch=$scratch edits',
        () async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          final tabId = container
              .read(desktopTabsProvider.notifier)
              .open(TabKind.board, title: 'Scratch', reuseExisting: false);
          final args =
              scratch
                  ? null
                  : const BoardTabGameArgs(
                    pgn: '1. e4 *',
                    label: 'Opening seed',
                    whiteName: '',
                    blackName: '',
                  );
          if (args != null) {
            container.read(boardTabGameArgsByTabIdProvider.notifier).state = {
              tabId: args,
            };
          }
          final origins = container.read(
            boardTabAttachedLibrarySaveOriginByTabIdProvider.notifier,
          );
          if (cloud) {
            origins.attachCloudSavedAnalysis(
              tabId: tabId,
              origin: const BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
                analysisId: 'inserted-row',
                title: 'Saved',
              ),
            );
          } else {
            origins.attachLocalPgn(
              tabId: tabId,
              sourcePath: 'fixture.pgn',
              sourceIndex: 2,
              sourceFileGameCount: 3,
              sourcePgnFingerprint: 'mainline',
              sourceRecordRevision: 'exact-revision',
              title: 'Saved',
            );
          }
          container.read(boardPaneSnapshotReadersProvider)[tabId] =
              () => (
                seed: args,
                session: BoardPaneSession(
                  game: ChessGame.fromPgn(
                    'scratch',
                    '1. e4 {new comment} e5 (1... c5) *',
                  ),
                  pointer: const [0],
                  pgnHeaders: const {},
                  flipped: true,
                  loadedFrom: null,
                  lastAppliedPgn: '1. e4 *',
                  lastAppliedGameId: null,
                  lastAppliedInitialFenKey: null,
                  dirtySinceLoad: true,
                  hasUnseenMoves: false,
                  undoStack: const [],
                  hasCommittedSave: true,
                ),
              );
          DesktopBoardWindowPayload? sent;
          final service = DesktopBoardWindowService(
            createDetachedWindow: (payload) async {
              sent = DesktopBoardWindowPayload.decode(payload.encode());
              final child = ProviderContainer();
              addTearDown(child.dispose);
              sent!.restoreBoardSession(child, 'child');
              return DetachedBoardWindow(
                windowId: 'child',
                probe:
                    (id) async => {
                      'ready': true,
                      'windowId': 'child',
                      'transferId': id,
                    },
              );
            },
          );
          expect(
            await service.detachDesktopTabToWindow(container, tabId),
            isTrue,
          );
          expect(
            container.read(desktopTabsProvider).tabs.any((t) => t.id == tabId),
            isFalse,
          );
          if (scratch) {
            expect(
              sent!.args,
              isNull,
            ); // Scratch stays scratch in both engines.
          } else {
            expect(sent!.args!.pgn, contains('new comment'));
            expect(sent!.args!.pgn, contains('c5'));
            expect(
              sent!.args!.librarySaveOrigin!.kind,
              origins.state[tabId]!.kind,
            );
          }
          final child = ProviderContainer();
          addTearDown(child.dispose);
          sent!.restoreBoardSession(child, 'child');
          final restored =
              child.read(boardPaneSessionByTabIdProvider)['child']!;
          expect(exportGameToPgn(restored.game), contains('new comment'));
          expect(restored.lastAppliedPgn, '1. e4 *');
          expect(restored.detachedSeedPgn, contains('new comment'));
          expect(sent!.encode(), contains('new comment'));
          expect(sent!.encode(), contains('c5'));
          expect(restored.dirtySinceLoad, isTrue);
          expect(restored.hasCommittedSave, isTrue);
          final origin =
              child.read(
                boardTabAttachedLibrarySaveOriginByTabIdProvider,
              )['child']!;
          expect(origin.analysisId, cloud ? 'inserted-row' : null);
          expect(origin.sourceRecordRevision, cloud ? null : 'exact-revision');
          expect(origin.sourceIndex, cloud ? null : 2);
          expect(origin.sourcePath, cloud ? null : 'fixture.pgn');
          expect(origin.sourceFileGameCount, cloud ? null : 3);
          expect(origin.sourcePgnFingerprint, cloud ? null : 'mainline');
        },
      );
    }
  }
}
