import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/services/local_chess_file_access.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalChessFileAccessException', () {
    test('classifies Windows sharing violations before native error text', () {
      for (final code in <int>[32, 33, 108]) {
        final error = FileSystemException(
          'File or folder does not exist',
          r'C:\Chess\brian.pgn',
          OSError('Localized native message', code),
        );

        final normalized = LocalChessFileAccessException.from(
          error,
          platform: LocalChessFileAccessPlatform.windows,
        );

        expect(normalized.issue, LocalChessFileAccessIssue.inUse);
        expect(normalized.osErrorCode, code);
      }
    });

    test('classifies Windows permission, missing, device, and disk errors', () {
      _expectWindowsCodes(<int>[
        5,
        65,
      ], LocalChessFileAccessIssue.permissionDenied);
      _expectWindowsCodes(<int>[2, 3], LocalChessFileAccessIssue.missing);
      _expectWindowsCodes(<int>[
        21,
        53,
        55,
        59,
        64,
        67,
        121,
      ], LocalChessFileAccessIssue.unavailable);
      _expectWindowsCodes(<int>[39, 112], LocalChessFileAccessIssue.noSpace);
    });

    test('classifies common POSIX errors without Windows code conflicts', () {
      _expectPosixCodes(<int>[
        1,
        13,
        30,
      ], LocalChessFileAccessIssue.permissionDenied);
      _expectPosixCodes(<int>[16], LocalChessFileAccessIssue.inUse);
      _expectPosixCodes(<int>[2, 20], LocalChessFileAccessIssue.missing);
      _expectPosixCodes(<int>[28, 69, 122], LocalChessFileAccessIssue.noSpace);
      _expectPosixCodes(<int>[
        5,
        6,
        19,
        60,
        64,
        65,
        70,
        110,
        112,
        113,
        116,
      ], LocalChessFileAccessIssue.unavailable);
    });

    test('normalizes a persisted Windows scanner failure', () {
      const persisted =
          "Could not scan this file: FileSystemException: Cannot open file, "
          "path = 'C:\\Users\\Ada\\Games\\brian.pgn' "
          '(OS Error: The process cannot access the file because it is being '
          'used by another process., errno = 32)';

      final normalized = LocalChessFileAccessException.from(
        persisted,
        platform: LocalChessFileAccessPlatform.windows,
      );

      expect(normalized.issue, LocalChessFileAccessIssue.inUse);
      expect(normalized.osErrorCode, 32);
      expect(normalized.path, r'C:\Users\Ada\Games\brian.pgn');
      expect(normalized.userMessage, contains('"brian.pgn"'));
    });

    test('falls back to stable phrases when a persisted code is absent', () {
      final normalized = LocalChessFileAccessException.from(
        'Could not scan file: sharing violation',
      );
      const scannerMessage = LocalChessFileAccessException(
        issue: LocalChessFileAccessIssue.inUse,
        path: r'C:\Games\brian.pgn',
      );
      final restored = LocalChessFileAccessException.from(
        scannerMessage.userMessage,
        path: scannerMessage.path,
      );

      expect(normalized.issue, LocalChessFileAccessIssue.inUse);
      expect(restored.issue, LocalChessFileAccessIssue.inUse);
    });

    test('every recovery message round-trips to its access category', () {
      for (final issue in LocalChessFileAccessIssue.values) {
        final original = LocalChessFileAccessException(
          issue: issue,
          path: '/tmp/example.pgn',
        );

        final restored = LocalChessFileAccessException.from(
          original.userMessage,
          path: original.path,
        );

        expect(restored.issue, issue, reason: issue.name);
      }
    });

    test('in-use guidance is explicit and does not expose the full path', () {
      final normalized = LocalChessFileAccessException.from(
        FileSystemException(
          'Sharing violation',
          r'C:\Users\Ada\Secret\brian.pgn',
          const OSError('Sharing violation', 32),
        ),
        platform: LocalChessFileAccessPlatform.windows,
      );

      expect(normalized.userMessage, contains('another app'));
      expect(normalized.userMessage, contains('ChessBase'));
      expect(normalized.userMessage, contains('Close the PGN'));
      expect(normalized.userMessage, contains('try again'));
      expect(normalized.userMessage, contains('brian.pgn'));
      expect(normalized.userMessage, isNot(contains(r'C:\Users\Ada')));
    });

    test('changed and stalled failures have distinct recovery guidance', () {
      const changed = LocalChessFileAccessException.changed(
        path: '/tmp/live.pgn',
      );
      const stalled = LocalChessFileAccessException.stalled(
        path: '/Volumes/NAS/live.pgn',
      );

      expect(changed.issue, LocalChessFileAccessIssue.changed);
      expect(changed.userMessage, contains('Finish saving'));
      expect(stalled.issue, LocalChessFileAccessIssue.stalled);
      expect(stalled.userMessage, contains('network connection'));
    });

    test('extracts a Windows filename on a non-Windows host', () {
      expect(
        localChessFileNameFromPath(r'\\server\share\folder\brian.pgn'),
        'brian.pgn',
      );
      expect(localChessFileNameFromPath('/tmp/brian.pgn'), 'brian.pgn');
    });

    test('reads a stable app-owned byte snapshot', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_stable_read_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/stable.pgn');
      final original = List<int>.generate(
        (1024 * 1024) + 73,
        (index) => index % 251,
      );
      await file.writeAsBytes(original, flush: true);

      final snapshot = await readStableLocalChessFileBytes(file.path);

      expect(snapshot, original);
    });

    test('killable read worker aborts after I/O inactivity', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_stalled_read_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/stalled.pgn');
      await file.writeAsString('[Event "Test"]\n\n1. e4 *');

      final read = readStableLocalChessFileBytesInWorker(
        file.path,
        inactivityTimeout: const Duration(milliseconds: 25),
        debugWorkerStartDelay: const Duration(seconds: 2),
      );

      await expectLater(
        read,
        throwsA(
          isA<LocalChessFileAccessException>().having(
            (error) => error.issue,
            'issue',
            LocalChessFileAccessIssue.stalled,
          ),
        ),
      );
    });

    test(
      'killable path probe returns stable metadata and fingerprint',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'chessever_path_probe_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/stable.pgn');
        final bytes = List<int>.generate(4097, (index) => index % 251);
        await file.writeAsBytes(bytes, flush: true);

        final fileProbe = await probeLocalChessPathInWorker(
          file.path,
          includeContentFingerprint: true,
        );
        final directoryProbe = await probeLocalChessPathInWorker(
          directory.path,
        );
        final missingProbe = await probeLocalChessPathInWorker(
          '${directory.path}/missing.pgn',
        );

        expect(fileProbe.isFile, isTrue);
        expect(fileProbe.sizeBytes, bytes.length);
        expect(fileProbe.modifiedAt, isNotNull);
        expect(
          fileProbe.contentFingerprint,
          computeLocalChessBytesContentFingerprint(Uint8List.fromList(bytes)),
        );
        expect(directoryProbe.isDirectory, isTrue);
        expect(missingProbe.type, FileSystemEntityType.notFound);
      },
    );

    test('path probes follow user-selected file and directory links', () async {
      if (Platform.isWindows) return;
      final directory = await Directory.systemTemp.createTemp(
        'chessever_link_probe_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final targetFile = File('${directory.path}/target.pgn');
      await targetFile.writeAsString('[Event "Link"]\n\n1. e4 *');
      final fileLink = Link('${directory.path}/linked.pgn');
      await fileLink.create(targetFile.path);
      final targetFolder =
          await Directory('${directory.path}/target-folder').create();
      await File(
        '${targetFolder.path}/inside.pgn',
      ).writeAsString('[Event "Folder link"]\n\n1. d4 *');
      final folderLink = Link('${directory.path}/linked-folder');
      await folderLink.create(targetFolder.path);

      final fileProbe = await probeLocalChessPathInWorker(fileLink.path);
      final folderProbe = await probeLocalChessPathInWorker(folderLink.path);
      final listed = await listLocalChessPgnFilesInWorker(folderLink.path);

      expect(fileProbe.isFile, isTrue);
      expect(folderProbe.isDirectory, isTrue);
      expect(listed, <String>['${folderLink.path}/inside.pgn']);
    });

    test('killable path probe aborts after inactivity', () async {
      final probe = probeLocalChessPathInWorker(
        '/unused/stalled.pgn',
        inactivityTimeout: const Duration(milliseconds: 25),
        debugWorkerStartDelay: const Duration(seconds: 2),
      );

      await expectLater(
        probe,
        throwsA(
          isA<LocalChessFileAccessException>().having(
            (error) => error.issue,
            'issue',
            LocalChessFileAccessIssue.stalled,
          ),
        ),
      );
    });

    test('killable directory worker finds recursive PGN files', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_directory_read_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final nested = await Directory('${directory.path}/nested').create();
      final rootPgn = File('${directory.path}/root.pgn');
      final nestedPgn = File('${nested.path}/nested.PGN');
      await rootPgn.writeAsString('[Event "Root"]');
      await nestedPgn.writeAsString('[Event "Nested"]');
      await File('${nested.path}/notes.txt').writeAsString('ignore');

      final paths = await listLocalChessPgnFilesInWorker(directory.path);

      expect(paths, containsAll(<String>[rootPgn.path, nestedPgn.path]));
      expect(paths, hasLength(2));
    });

    test('directory worker accepts caller-provided chess suffixes', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_directory_suffixes_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pgn = File('${directory.path}/root.pgn');
      final compressed = File('${directory.path}/root.pgn.zst');
      final unsupported = File('${directory.path}/root.cbh');
      await pgn.writeAsString('[Event "Root"]');
      await compressed.writeAsBytes(const <int>[1, 2, 3]);
      await unsupported.writeAsBytes(const <int>[4, 5, 6]);

      final paths = await listLocalChessPgnFilesInWorker(
        directory.path,
        allowedSuffixes: const <String>['.pgn', '.pgn.zst', '.cbh'],
      );

      expect(
        paths,
        containsAll(<String>[pgn.path, compressed.path, unsupported.path]),
      );
    });

    test('killable directory worker aborts after inactivity', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_stalled_directory_',
      );
      addTearDown(() => directory.delete(recursive: true));

      final listing = listLocalChessPgnFilesInWorker(
        directory.path,
        inactivityTimeout: const Duration(milliseconds: 25),
        debugWorkerStartDelay: const Duration(seconds: 2),
      );

      await expectLater(
        listing,
        throwsA(
          isA<LocalChessFileAccessException>().having(
            (error) => error.issue,
            'issue',
            LocalChessFileAccessIssue.stalled,
          ),
        ),
      );
    });

    test('rejects a PGN changed while its snapshot is being copied', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_changed_read_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/live.pgn');
      await file.writeAsBytes(
        List<int>.filled((2 * 1024 * 1024) + 31, 65),
        flush: true,
      );
      var changed = false;

      final read = readStableLocalChessFileBytes(
        file.path,
        maxAttempts: 1,
        onProgress: (fraction) {
          if (changed || fraction <= 0 || fraction >= 1) return;
          changed = true;
          file.writeAsBytesSync(<int>[66], mode: FileMode.append, flush: true);
        },
      );

      await expectLater(
        read,
        throwsA(
          isA<LocalChessFileAccessException>().having(
            (error) => error.issue,
            'issue',
            LocalChessFileAccessIssue.changed,
          ),
        ),
      );
    });

    test('copies a stable large-file snapshot to app-owned storage', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_snapshot_copy_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/source.pgn');
      final destination = File('${directory.path}/snapshot.pgn');
      final original = List<int>.generate(
        (2 * 1024 * 1024) + 19,
        (index) => index % 239,
      );
      await source.writeAsBytes(original, flush: true);

      final stableStat = await copyStableLocalChessFile(
        source.path,
        destination.path,
      );

      expect(stableStat.size, original.length);
      expect(await destination.readAsBytes(), original);
    });

    test('byte and file fingerprints use the same cache format', () async {
      final directory = await Directory.systemTemp.createTemp(
        'chessever_snapshot_fingerprint_',
      );
      addTearDown(() => directory.delete(recursive: true));

      for (final size in <int>[1024, (300 * 1024) + 17]) {
        final contents = List<int>.generate(size, (index) => index % 251);
        final file = File('${directory.path}/$size.pgn');
        await file.writeAsBytes(contents, flush: true);
        final snapshot = await readStableLocalChessFileSnapshot(file.path);

        expect(
          computeLocalChessBytesContentFingerprint(snapshot.bytes),
          await computeLocalChessFileContentFingerprint(
            file.path,
            stat: snapshot.sourceStat,
          ),
        );
      }
    });
  });
}

void _expectWindowsCodes(
  Iterable<int> codes,
  LocalChessFileAccessIssue expected,
) {
  for (final code in codes) {
    final normalized = LocalChessFileAccessException.from(
      OSError('Localized native message', code),
      platform: LocalChessFileAccessPlatform.windows,
    );
    expect(normalized.issue, expected, reason: 'Windows error code $code');
  }
}

void _expectPosixCodes(
  Iterable<int> codes,
  LocalChessFileAccessIssue expected,
) {
  for (final code in codes) {
    final normalized = LocalChessFileAccessException.from(
      OSError('Localized native message', code),
      platform: LocalChessFileAccessPlatform.posix,
    );
    expect(normalized.issue, expected, reason: 'POSIX errno $code');
  }
}
