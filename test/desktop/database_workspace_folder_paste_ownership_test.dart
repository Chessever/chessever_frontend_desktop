import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/library_quick_import.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

void main() {
  testWidgets(
    'folder paste declines when ownership expires during clipboard access',
    (tester) async {
      final clipboardStarted = Completer<void>();
      final releaseClipboard = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method != 'Clipboard.getData') return null;
          clipboardStarted.complete();
          await releaseClipboard.future;
          return <String, Object?>{'text': _validClipboardPgn};
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var isCurrentOwner = true;
      final result = Completer<int>();

      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: _OwnedFolderPasteHarness(
              isCurrentOwner: () => isCurrentOwner,
              result: result,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('owned-folder-paste')));
      await clipboardStarted.future;
      isCurrentOwner = false;
      releaseClipboard.complete();

      expect(await result.future, 0);
    },
  );
}

const _validClipboardPgn = '''
[Event "Valid"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 1-0
''';

class _OwnedFolderPasteHarness extends ConsumerWidget {
  const _OwnedFolderPasteHarness({
    required this.isCurrentOwner,
    required this.result,
  });

  final bool Function() isCurrentOwner;
  final Completer<int> result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      key: const Key('owned-folder-paste'),
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        result.complete(
          await quickImportClipboardToFolder(
            context: context,
            ref: ref,
            folder: LibraryFolder(
              id: 'folder',
              userId: 'user',
              name: 'Folder',
              color: '#000000',
              icon: 'folder',
              orderIndex: 0,
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
            isCurrentOwner: isCurrentOwner,
          ),
        );
      },
      child: const SizedBox(width: 20, height: 20),
    );
  }
}
