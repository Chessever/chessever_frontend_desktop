import 'dart:async';
import 'dart:io';

import 'package:chessever/desktop/services/board_save_boundary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final firstRoute in ['file', 'library', 'update']) {
    for (final secondRoute in ['file', 'library', 'update']) {
      test('$firstRoute blocks overlapping $secondRoute before snapshot/write',
          () async {
        final boundary = BoardSaveBoundary();
        final releaseWrite = Completer<void>();
        var disk = 'opening';
        var baseline = 'opening';
        var captures = 0;
        final first = boundary.tryRun(() async {
          captures++;
          await releaseWrite.future;
          disk = 'first snapshot';
          baseline = disk;
        });
        final second = await boundary.tryRun(() async {
          captures++;
          disk = 'second snapshot';
          baseline = disk;
        });
        expect(second, isFalse);
        expect(captures, 1);
        releaseWrite.complete();
        expect(await first, isTrue);
        expect(disk, baseline);
        expect(disk, 'first snapshot');
        expect(await boundary.tryRun(() async {
          captures++;
          disk = 'retry captures fresh snapshot';
          baseline = disk;
        }), isTrue);
        expect(captures, 2);
        expect(disk, baseline);
      });
    }
  }

  test('dismissed Library route holds boundary until actual update settles',
      () async {
    final boundary = BoardSaveBoundary();
    final route = Completer<String?>();
    final write = Completer<void>();
    final pending = <Future<void>>[];
    var completed = false;
    final first = boundary.tryRun(() async {
      expect(await waitForSaveDialogWrites(route.future, pending), isNull);
      completed = true;
    });
    // Registered after dialog opens, as the real dialog registers its actions.
    pending.add(write.future);
    route.complete(null);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(await boundary.tryRun(() async => fail('overlapping write')), isFalse);
    write.complete();
    expect(await first, isTrue);
    expect(completed, isTrue);
    expect(await boundary.tryRun(() async {}), isTrue);
  });

  test('picker cancellation and thrown failure both release the boundary',
      () async {
    final boundary = BoardSaveBoundary();
    expect(await boundary.tryRun(() async {}), isTrue); // Cancel before write.
    await expectLater(
      boundary.tryRun(() async => throw StateError('write failed')),
      throwsStateError,
    );
    expect(await boundary.tryRun(() async {}), isTrue);
  });

  test('Board entrypoints and dismissed-dialog writes use the shared boundary',
      () {
    final board = File('lib/desktop/panes/board_pane.dart').readAsStringSync();
    expect(board, contains('boardSaveBoundary.tryRun(action)'));
    expect(board, contains('runBoardSave(saveGameToLibraryActionImpl)'));
    expect(board, contains('runBoardSave(savePgnActionImpl)'));
    expect(board, isNot(contains('boardCommittedSaveSequence')));
    expect(board, isNot(contains('await saveDesktopGameToLibrary(')));
    final routing = board.substring(
      board.indexOf('Future<void> saveGameToLibraryActionImpl()'),
      board.indexOf('Future<void> savePgnActionImpl()'),
    );
    expect(routing, contains('hasCommittedSave: hasCommittedSave.value'));
    expect(routing, contains('await resolveBoardLibrarySaveGame('));
    expect(routing, contains('saveCompletion.commit(exportGameToPgn(committedGame))'));
    expect(board, contains('restoredSession?.hasCommittedSave ?? false'));
    expect(board, contains('hasCommittedSave.value = true'));
    final dialog = File(
      'lib/desktop/widgets/library/library_save_to_folder_dialog.dart',
    ).readAsStringSync();
    expect(dialog, contains('await waitForSaveDialogWrites(route, pendingWrites)'));
    expect(
      dialog,
      contains('waitForLibrarySaveOutcome(route, pendingWrites, () => committedOutcome)'),
    );
    expect(dialog, contains('onWriteStarted: pendingWrites.add'));
    expect('widget.onWriteStarted(operation)'.allMatches(dialog), hasLength(2));
    final save = dialog.substring(dialog.indexOf('Future<void> _save('));
    expect(save.indexOf('_isSaving = true'),
        lessThan(save.indexOf('await canSaveMoreGames')));
    expect(save, contains('if (_isSaving || _isUpdatingOriginal) return;'));
  });
}
