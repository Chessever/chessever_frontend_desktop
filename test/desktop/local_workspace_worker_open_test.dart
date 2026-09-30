import 'dart:io';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/local_chess_game_filter.dart';
import 'package:chessever/desktop/services/local_raw_pgn_catalog.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/state/local_board_games.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Cold extends LocalChessDatabaseRepository {
  _Cold() : super(database: () => throw StateError('No index writes'));

  @override
  Future<LocalChessSource?> loadFreshSource(
    List<String> paths, {
    String? sourceLabel,
    LocalChessScanProgressSink? onProgress,
  }) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Board reacquisition rejects changed source with unchanged count',
    () async {
      final dir = await Directory.systemTemp.createTemp('worker_revision_');
      final file = File('${dir.path}/one.pgn');
      const text =
          '[Event "Old"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n1. e4 e5 *\n';
      try {
        await file.writeAsString(text);
        final handle = await openLocalRawPgnCatalog(file.path);
        final board = LocalBoardGamesSource.query(
          path: file.path,
          totalCount: 1,
          search: '',
          sortBy: LocalChessGameSortField.originalOrder,
          sortDirection: LocalChessGameSortDirection.asc,
          filter: LocalChessGameFilter(),
          rawPgnCatalog: handle.descriptor,
        );
        handle.release();
        await file.writeAsString(text.replaceFirst('Old', 'New'));
        await expectLater(board.page(_Cold(), 0), throwsStateError);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'completed workspace keeps a bounded idle worker for warm reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workspace_worker_',
      );
      final file = File('${directory.path}/five.pgn');
      await file.writeAsString(_games(5));
      final container = ProviderContainer(
        overrides: [
          localChessDatabaseRepositoryProvider.overrideWithValue(_Cold()),
          localChessLibraryProvider.overrideWith(
            (ref) => LocalChessLibraryNotifier(),
          ),
        ],
      );
      try {
        final provider = localDatabaseWorkspaceSourceProvider(
          LocalDatabaseWorkspaceKey(file.path),
        );
        var hold = container.listen(provider, (_, __) {});
        final source = await container.read(provider.future);
        expect(source.games, isEmpty);
        expect(source.root.gameCount, 5);
        final descriptor = source.root.files.single.rawPgnCatalog!;
        final query = LocalRawPgnCatalogPageQuery(
          descriptor: descriptor,
          pageNumber: 0,
          pageSize: 100,
        );
        expect((await localRawPgnCatalogPage(query))!.games.length, 5);
        hold.close();
        await container.pump();
        expect(
          (await localRawPgnCatalogPage(query))!.games.length,
          5,
          reason: 'The worker should stay warm after the last tab closes.',
        );

        final progress = <LocalChessScanProgress>[];
        hold = container.listen(provider, (_, __) {});
        final reopened = await container.read(provider.future);
        final reopenedDescriptor = reopened.root.files.single.rawPgnCatalog!;
        expect(identical(reopenedDescriptor, descriptor), isTrue);
        expect(progress, isEmpty);
        expect(reopened.root.gameCount, 5);
        hold.close();
        await container.pump();
      } finally {
        container.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'warm reopen detects restored-mtime edit outside sampled regions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'workspace_stale_',
      );
      final file = File('${directory.path}/large.pgn');
      final text = _largeSingleGame();
      try {
        await file.writeAsString(text);
        final originalModified = (await file.stat()).modified;
        final handle = await openLocalRawPgnCatalog(file.path);
        final descriptor = handle.descriptor;
        handle.release();

        await file.writeAsString(text.replaceFirst('OldTag', 'NewTag'));
        await file.setLastModified(originalModified);

        final reopened = await openLocalRawPgnCatalog(file.path);
        try {
          expect(identical(reopened.descriptor, descriptor), isFalse);
          final page = await localRawPgnCatalogPage(
            LocalRawPgnCatalogPageQuery(
              descriptor: reopened.descriptor,
              pageNumber: 0,
              pageSize: 10,
            ),
          );
          expect(page!.games.single.game.metadata['Event'], 'Stable');
        } finally {
          reopened.release();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('canceled open waiter does not close another waiter session', () async {
    final directory = await Directory.systemTemp.createTemp(
      'workspace_cancel_',
    );
    final file = File('${directory.path}/cancel.pgn');
    final token = OperationCancellationToken();
    try {
      await file.writeAsString(_games(2));
      final canceled = openLocalRawPgnCatalog(
        file.path,
        cancellationToken: token,
        debugWorkerStartDelay: const Duration(milliseconds: 40),
      );
      final kept = openLocalRawPgnCatalog(file.path);
      token.cancel();
      await expectLater(canceled, throwsA(isA<OperationCanceledException>()));
      final handle = await kept;
      try {
        final page = await localRawPgnCatalogPage(
          LocalRawPgnCatalogPageQuery(
            descriptor: handle.descriptor,
            pageNumber: 0,
            pageSize: 10,
          ),
        );
        expect(page!.games.length, 2);
      } finally {
        handle.release();
      }
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('idle LRU eviction keeps active sessions pinned', () async {
    final directory = await Directory.systemTemp.createTemp('workspace_lru_');
    try {
      final files = <File>[];
      for (var i = 0; i < 4; i++) {
        final file = File('${directory.path}/$i.pgn');
        await file.writeAsString(_games(1, prefix: 'F$i'));
        files.add(file);
      }
      final active = await openLocalRawPgnCatalog(files[0].path);
      final activeQuery = LocalRawPgnCatalogPageQuery(
        descriptor: active.descriptor,
        pageNumber: 0,
        pageSize: 10,
      );
      for (final file in files.skip(1)) {
        final handle = await openLocalRawPgnCatalog(file.path);
        handle.release();
      }
      expect(
        await localRawPgnCatalogPage(activeQuery),
        isNotNull,
        reason: 'LRU/budget cleanup must not evict an active reference.',
      );
      active.release();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('idle worker expires after its inactivity timeout', () async {
    final directory = await Directory.systemTemp.createTemp('workspace_ttl_');
    final file = File('${directory.path}/ttl.pgn');
    try {
      await file.writeAsString(_games(1));
      final handle = await openLocalRawPgnCatalog(
        file.path,
        inactivityTimeout: const Duration(milliseconds: 20),
      );
      final query = LocalRawPgnCatalogPageQuery(
        descriptor: handle.descriptor,
        pageNumber: 0,
        pageSize: 10,
      );
      handle.release();
      expect(await localRawPgnCatalogPage(query), isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(await localRawPgnCatalogPage(query), isNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

String _games(int count, {String prefix = 'G'}) => List.generate(
  count,
  (i) =>
      '[Event "$prefix$i"]\n[White "A$i"]\n[Black "B"]\n[Result "*"]\n\n1. e4 e5 *\n',
).join('\n');

String _largeSingleGame() {
  final buffer =
      StringBuffer()
        ..writeln('[Event "Stable"]')
        ..writeln('[White "A"]')
        ..writeln('[Black "B"]')
        ..writeln('[Result "*"]')
        ..writeln();
  for (var i = 0; i < 9000; i++) {
    buffer.write('1. e4 e5 ');
  }
  buffer.write('{OldTag} ');
  for (var i = 0; i < 70000; i++) {
    buffer.write('{padding} ');
  }
  buffer.writeln('*');
  return buffer.toString();
}
