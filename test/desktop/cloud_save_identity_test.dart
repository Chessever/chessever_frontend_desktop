import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';

void main() {
  const cloud = BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
    analysisId: 'exact-inserted-row',
    title: 'White vs Black',
  );
  const local = BoardTabLibrarySaveOrigin.localPgnFile(
    sourcePath: 'fixture.pgn',
    sourceIndex: 0,
    sourceFileGameCount: 1,
    title: 'Original',
  );
  bool mayAttach({
    BoardTabLibrarySaveOrigin? source,
    BoardTabLibrarySaveOrigin? attached,
    bool live = true,
    bool activation = true,
  }) => shouldAttachLibraryIdentityAfterSaveCompletion(
    tabStillExists: live,
    gameStillMatches: activation,
    savingArgs:
        source == null
            ? null
            : BoardTabGameArgs(
              pgn: '',
              label: '',
              whiteName: '',
              blackName: '',
              librarySaveOrigin: source,
            ),
    currentArgs: null,
    savingAttachedOrigin: attached,
    currentAttachedOrigin: attached,
    hasUpdateTarget: true,
  );

  test('first cloud save retains exact ID for repeated Update', () {
    final target = libraryCloudUpdateTargetForCompletedSave(
      gameCount: 1,
      selectedCloudFolderCount: 1,
      selectedLocalPathCount: 0,
      insertedOrigin: cloud,
    );
    final outcome = LibrarySaveOutcome(
      savedRows: 1,
      folderCount: 1,
      cloudUpdateTarget: target,
    );
    expect(mayAttach(), isTrue);
    final state = StateController<Map<String, BoardTabLibrarySaveOrigin>>({});
    addTearDown(state.dispose);
    state.attachCloudSavedAnalysis(
      tabId: 'board',
      origin: outcome.cloudUpdateTarget!,
    );
    for (var i = 0; i < 2; i++) {
      expect(
        resolveBoardTabLibrarySaveOrigin(
          sourceOrigin: null,
          attachedOrigin: state.state['board'],
        )?.analysisId,
        'exact-inserted-row',
      );
    }
  });

  test('Save as copy never retargets canonical local or cloud origins', () {
    for (final origin in [local, cloud]) {
      expect(mayAttach(source: origin), isFalse);
      expect(mayAttach(attached: origin), isFalse);
    }
  });

  test(
    'bulk, multiple destinations and partial success have no cloud target',
    () {
      for (final counts in [(2, 1, 0), (1, 2, 0), (1, 1, 1)]) {
        expect(
          libraryCloudUpdateTargetForCompletedSave(
            gameCount: counts.$1,
            selectedCloudFolderCount: counts.$2,
            selectedLocalPathCount: counts.$3,
            insertedOrigin: cloud,
          ),
          isNull,
        );
      }
      expect(
        libraryCloudUpdateTargetForCompletedSave(
          gameCount: 1,
          selectedCloudFolderCount: 1,
          selectedLocalPathCount: 0,
          insertedOrigin: null,
        ),
        isNull,
      );
    },
  );

  test('source origin blocks copy attachment even with identical args', () {
    for (final origin in [local, cloud]) {
      final args = BoardTabGameArgs(
        pgn: '',
        label: '',
        whiteName: '',
        blackName: '',
        librarySaveOrigin: origin,
      );
      expect(
        shouldAttachLibraryIdentityAfterSaveCompletion(
          tabStillExists: true,
          gameStillMatches: true,
          savingArgs: args,
          currentArgs: args,
          savingAttachedOrigin: null,
          currentAttachedOrigin: null,
          hasUpdateTarget: true,
        ),
        isFalse,
      );
    }
  });

  test('cloud origin survives args copy and detached payload round-trip', () {
    const args = BoardTabGameArgs(
      pgn: '1. e4 *',
      label: 'Fixture',
      whiteName: 'White',
      blackName: 'Black',
      librarySaveOrigin: cloud,
    );
    final restored = DesktopBoardWindowPayload.decode(
      DesktopBoardWindowPayload.fromArgs(args.copyWith(label: 'Copy')).encode(),
    );
    expect(restored.args?.librarySaveOrigin?.analysisId, cloud.analysisId);
    expect(restored.args?.librarySaveOrigin?.kind, cloud.kind);
  });

  test(
    'dialog single insert captures ID before mounted checks; busy guard remains',
    () {
      final source =
          File(
            'lib/desktop/widgets/library/library_save_to_folder_dialog.dart',
          ).readAsStringSync();
      expect(source, contains('repo.createSavedAnalysis(rows.single)'));
      expect(source, contains('analysisId: inserted.id'));
      expect(source, contains('selectedLocalPaths.isEmpty'));
      expect(source, contains('PopScope<LibrarySaveOutcome>(canPop: !busy'));
      expect(source, contains('widget.onCommitted(committedOutcome!)'));
    },
  );

  test('stale activation and closed tab cannot attach completion', () {
    expect(mayAttach(activation: false), isFalse);
    expect(mayAttach(live: false), isFalse);
  });

  test(
    'dismissal waits for write and returns retained committed identity',
    () async {
      final route = Completer<LibrarySaveOutcome?>();
      final write = Completer<void>();
      LibrarySaveOutcome? committed;
      final result = waitForLibrarySaveOutcome(route.future, [
        write.future,
      ], () => committed);
      route.complete(null);
      committed = const LibrarySaveOutcome(
        savedRows: 1,
        folderCount: 1,
        cloudUpdateTarget: cloud,
      );
      write.complete();
      expect((await result)?.cloudUpdateTarget?.analysisId, cloud.analysisId);
    },
  );

  test(
    'Board general save keeps cloud destinations; exact-ID update fails closed',
    () {
      final source =
          File('lib/desktop/panes/board_pane.dart').readAsStringSync();
      final save = source.substring(
        source.indexOf('Future<void> saveGameToLibraryActionImpl'),
        source.indexOf('Future<void> savePgnActionImpl'),
      );
      expect(
        save,
        contains('destinationMode: LibrarySaveDestinationMode.cloudAndLocal'),
      );
      expect(save, isNot(contains('LibrarySaveDestinationMode.localOnly')));
      final update = source.substring(
        source.indexOf(
          'case BoardTabLibrarySaveOriginKind.cloudSavedAnalysis:',
        ),
        source.indexOf(
          'case BoardTabLibrarySaveOriginKind.localPgnFile:',
          source.indexOf(
            'case BoardTabLibrarySaveOriginKind.cloudSavedAnalysis:',
          ),
        ),
      );
      expect(update, contains('getSavedAnalysis(analysisId)'));
      expect(
        update,
        contains(
          "throw StateError('Original cloud library game was not found.')",
        ),
      );
      expect(update, contains('isCurrentActivation()'));
      expect(update, isNot(contains('createSavedAnalysis')));
    },
  );
}
