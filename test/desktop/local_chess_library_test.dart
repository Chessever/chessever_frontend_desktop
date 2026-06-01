import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/state/local_chess_library.dart';

void main() {
  group('local chess library state', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('chessever_local_state_');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test(
      'openPaths reports failure without replacing previous source',
      () async {
        final notifier = LocalChessLibraryNotifier();
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        final previousSource = notifier.state.source;
        final previousPath = notifier.state.selectedPath;
        expect(previousSource, isNotNull);
        expect(previousPath, isNotNull);

        final missing = await notifier.openPaths(<String>[
          '${temp.path}/missing-folder',
        ]);

        expect(missing, isFalse);
        expect(notifier.state.source, same(previousSource));
        expect(notifier.state.selectedPath, previousPath);
        expect(notifier.state.error, contains('File or folder does not exist'));
        expect(notifier.state.isScanning, isFalse);
      },
    );

    test(
      'openPaths rejects generic picker gz without replacing previous source',
      () async {
        final notifier = LocalChessLibraryNotifier();
        final file = File('${temp.path}/mini.pgn');
        await file.writeAsString(_samplePgn);
        final genericGzip = File('${temp.path}/notes.gz');
        await genericGzip.writeAsBytes(<int>[31, 139, 8, 0]);

        final opened = await notifier.openPaths(<String>[file.path]);
        expect(opened, isTrue);
        final previousSource = notifier.state.source;
        final previousPath = notifier.state.selectedPath;

        final genericOpened = await notifier.openPaths(<String>[
          genericGzip.path,
        ]);

        expect(genericOpened, isFalse);
        expect(notifier.state.source, same(previousSource));
        expect(notifier.state.selectedPath, previousPath);
        expect(notifier.state.error, contains('No recognized chess file'));
        expect(notifier.state.error, isNot(contains('Invalid argument')));
        expect(notifier.state.isScanning, isFalse);
      },
    );

    test('local open errors use user-facing messages', () {
      expect(
        localChessOpenErrorMessage(ArgumentError('Open a PGN file.')),
        'Open a PGN file.',
      );
      expect(
        localChessOpenErrorMessage(
          const FileSystemException('File or folder does not exist', '/tmp/db'),
        ),
        'File or folder does not exist: /tmp/db',
      );
    });
  });
}

const _samplePgn = '''
[Event "Candidates"]
[Site "Toronto"]
[Date "2024.04.04"]
[Round "1"]
[White "Carlsen, Magnus"]
[Black "Nakamura, Hikaru"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 1-0
''';
