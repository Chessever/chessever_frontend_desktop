import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqlite/resqlite.dart' as resqlite;
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';

String games(int count) => List.generate(
  count,
  (i) =>
      '[Event "Queue $i"]\n[White "White $i"]\n[Black "Black"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 *\n',
).join('\n');
void main() {
  late Directory temp;
  late resqlite.Database db;
  late LocalChessDatabaseRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('small-import-queue-');
    db = await resqlite.Database.open('${temp.path}/cache.db');
    await createLocalChessResqliteDatabaseSchema(db);
    repo = LocalChessDatabaseRepository(database: () async => db);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  test(
    'five games complete before the unrelated large import finishes',
    () async {
      final large = await File(
        '${temp.path}/large.pgn',
      ).writeAsString(games(5000));
      final small = await File('${temp.path}/five.pgn').writeAsString(games(5));
      final started = Completer<void>();
      final order = <String>[];
      final largeFuture = repo
          .importSingleFileSource(
            path: large.path,
            onProgress: (p) {
              if (p.message == 'Importing games...' && !started.isCompleted) {
                started.complete();
              }
            },
          )
          .then((s) {
            order.add('large');
            return s;
          });
      await started.future;
      final smallFuture = repo.importSingleFileSource(path: small.path).then((
        s,
      ) {
        order.add('small');
        return s;
      });
      final smallResult = await smallFuture;
      final largeResult = await largeFuture;
      expect(smallResult!.root.gameCount, 5);
      expect(largeResult!.root.gameCount, 5000);
      expect(
        (await db.select(
          'SELECT COUNT(*) AS n FROM local_chess_games',
        )).single['n'],
        5005,
      );
      expect(
        order,
        ['small', 'large'],
        reason:
            'An independent five-game import must finish at a batch boundary, not wait for the whole large source.',
      );
    },
  );
  test('failure of a short import leaves the large source intact', () async {
    final large = await File(
      '${temp.path}/large.pgn',
    ).writeAsString(games(5000));
    final small = await File(
      '${temp.path}/failure.pgn',
    ).writeAsString(games(5));
    final started = Completer<void>();
    final big = repo.importSingleFileSource(
      path: large.path,
      onProgress: (p) {
        if (p.message == 'Importing games...' && !started.isCompleted) {
          started.complete();
        }
      },
    );
    await started.future;
    final token = OperationCancellationToken();
    final short = repo.importSingleFileSource(
      path: small.path,
      cancellationToken: token,
      onProgress: (p) {
        if (p.message == 'Finalizing PGN...') token.cancel();
      },
    );
    await expectLater(short, throwsA(isA<OperationCanceledException>()));
    expect((await big)!.root.gameCount, 5000);
    expect(
      (await db.select(
        'SELECT COUNT(*) AS n FROM local_chess_games',
      )).single['n'],
      5000,
    );
    expect(
      (await repo.importSingleFileSource(path: small.path))!.root.gameCount,
      5,
    );
  });
  test(
    'cooperative import does not release the global mutation lifetime',
    () async {
      final large = await File(
        '${temp.path}/large.pgn',
      ).writeAsString(games(5000));
      final small = await File('${temp.path}/five.pgn').writeAsString(games(5));
      final started = Completer<void>();
      var mutationRan = false;
      final big = repo.importSingleFileSource(
        path: large.path,
        onProgress: (p) {
          if (p.message == 'Importing games...' && !started.isCompleted) {
            started.complete();
          }
        },
      );
      await started.future;
      final mutation = LocalChessDatabaseRepository.runLocalPgnFileWriteQueued(
        () async {
          mutationRan = true;
        },
      );
      final smallResult = await repo.importSingleFileSource(path: small.path);
      expect(smallResult!.root.gameCount, 5);
      expect(
        mutationRan,
        isFalse,
        reason:
            'Only the owning importer may yield to an independent import; arbitrary file mutations must stay serialized.',
      );
      await big;
      await mutation;
      expect(mutationRan, isTrue);
    },
  );
  test(
    'same-path join and canceled retry never overlap or duplicate rows',
    () async {
      final file = await File('${temp.path}/five.pgn').writeAsString(games(5));
      final token = OperationCancellationToken();
      Future<LocalChessSource?>? retry;
      final first = repo.importSingleFileSource(
        path: file.path,
        cancellationToken: token,
        onProgress: (p) {
          if (p.message == 'Finalizing PGN...' && retry == null) {
            token.cancel();
            // A new user command originates outside the writer callback's Zone.
            retry = Zone.root.run(
              () => repo.importSingleFileSource(path: file.path),
            );
          }
        },
      );
      await expectLater(first, throwsA(isA<OperationCanceledException>()));
      expect((await retry!)!.root.gameCount, 5);
      final joined = await Future.wait(
        List.generate(4, (_) => repo.importSingleFileSource(path: file.path)),
      );
      expect(joined.map((s) => s!.root.gameCount), everyElement(5));
      expect(
        (await db.select(
          'SELECT COUNT(*) AS n FROM local_chess_games',
        )).single['n'],
        5,
      );
      expect(await file.readAsString(), games(5));
    },
  );
  test(
    'cancellation of the large owner does not delete a completed small import',
    () async {
      final large = await File(
        '${temp.path}/large.pgn',
      ).writeAsString(games(5000));
      final small = await File('${temp.path}/five.pgn').writeAsString(games(5));
      final started = Completer<void>();
      final token = OperationCancellationToken();
      final big = repo.importSingleFileSource(
        path: large.path,
        cancellationToken: token,
        onProgress: (p) {
          if (p.message == 'Importing games...' && !started.isCompleted) {
            started.complete();
          }
        },
      );
      final canceled = expectLater(
        big,
        throwsA(isA<OperationCanceledException>()),
      );
      await started.future;
      expect(
        (await repo.importSingleFileSource(path: small.path))!.root.gameCount,
        5,
      );
      token.cancel();
      await canceled;
      expect(
        (await db.select(
          'SELECT COUNT(*) AS n FROM local_chess_games',
        )).single['n'],
        5,
      );
      expect(
        (await repo.loadFreshFileNode(
          small.path,
          rootPath: temp.path,
        ))!.gameCount,
        5,
      );
    },
  );
  test('different-path imports on two handles share the same writer', () async {
    final other = await resqlite.Database.open('${temp.path}/cache.db');
    final secondRepo = LocalChessDatabaseRepository(
      database: () async => other,
    );
    final large = await File(
      '${temp.path}/large.pgn',
    ).writeAsString(games(1000));
    final small = await File('${temp.path}/five.pgn').writeAsString(games(5));
    final another = await File(
      '${temp.path}/another-five.pgn',
    ).writeAsString(games(5));
    final started = Completer<void>();
    try {
      final big = repo.importSingleFileSource(
        path: large.path,
        onProgress: (p) {
          if (p.message == 'Importing games...' && !started.isCompleted) {
            started.complete();
          }
        },
      );
      await started.future;
      final both = await Future.wait([
        secondRepo.importSingleFileSource(path: small.path),
        repo.importSingleFileSource(path: another.path),
      ]);
      expect(both.map((s) => s!.root.gameCount), everyElement(5));
      expect((await big)!.root.gameCount, 1000);
      expect(
        (await db.select(
          'SELECT COUNT(*) AS n FROM local_chess_games',
        )).single['n'],
        1010,
      );
    } finally {
      await other.close();
    }
  });
  test(
    'canceling an import still waiting for the writer settles promptly',
    () async {
      final small = await File('${temp.path}/five.pgn').writeAsString(games(5));
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = LocalChessDatabaseRepository.runLocalPgnFileWriteQueued(
        () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      final token = OperationCancellationToken();
      final pending = repo.importSingleFileSource(
        path: small.path,
        cancellationToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.cancel();
      Object? failure;
      try {
        await pending.timeout(const Duration(milliseconds: 500));
      } catch (e) {
        failure = e;
      }
      release.complete();
      await blocker;
      try {
        await pending;
      } catch (_) {}
      expect(failure, isA<OperationCanceledException>());
      expect(
        (await db.select(
          'SELECT COUNT(*) AS n FROM local_chess_games',
        )).single['n'],
        0,
      );
    },
  );
}
