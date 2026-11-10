@TestOn('browser')
library;

// The local-database flow as the browser app wires it: the shared cache
// database, worker handles opened by file path, import, both tree builds and
// tree reads, with the page's event loop watched for stalls.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartchess/dartchess.dart' show Chess, Move, NormalMove, Position;
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/compact_local_tree_index.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

import 'harness.dart';

String _randomGamesPgn(int count, {int plies = 40, int seed = 7}) {
  final random = Random(seed);
  final out = StringBuffer();
  for (var g = 0; g < count; g++) {
    Position position = Chess.initial;
    final sans = <String>[];
    for (var ply = 0; ply < plies; ply++) {
      final moves = <Move>[
        for (final entry in position.legalMoves.entries)
          for (final to in entry.value.squares)
            NormalMove(from: entry.key, to: to),
      ];
      if (moves.isEmpty) break;
      // Few distinct openings, then free play, like a real database.
      final pick =
          ply < 6 ? random.nextInt(min(3, moves.length)) : random.nextInt(moves.length);
      final (next, san) = position.makeSan(moves[pick]);
      sans.add(ply.isEven ? '${ply ~/ 2 + 1}. $san' : san);
      position = next;
    }
    final result = const ['1-0', '0-1', '1/2-1/2'][g % 3];
    out
      ..writeln('[Event "Open ${g % 50}"]')
      ..writeln('[Site "Test"]')
      ..writeln('[Date "2024.${(g % 12 + 1).toString().padLeft(2, '0')}.01"]')
      ..writeln('[Round "${g % 9 + 1}"]')
      ..writeln('[White "Player ${g % 400}"]')
      ..writeln('[Black "Player ${(g * 7 + 3) % 400}"]')
      ..writeln('[WhiteElo "${2200 + g % 500}"]')
      ..writeln('[BlackElo "${2200 + (g * 3) % 500}"]')
      ..writeln('[Result "$result"]')
      ..writeln()
      ..writeln('${sans.join(' ')} $result')
      ..writeln();
  }
  return out.toString();
}

const int _games = int.fromEnvironment('LOCAL_DB_FLOW_GAMES', defaultValue: 3000);

const bool _verbose = bool.fromEnvironment('LOCAL_DB_FLOW_VERBOSE');

void main() {
  setUpAll(mountBrowserLocalDatabase);

  test('import, build tree and read it back through the shared cache', () async {
    final repo = LocalChessDatabaseRepository(
      database: () => LocalChessCacheDatabase.instance.database,
      databaseWithProgress:
          ({onProgress}) => LocalChessCacheDatabase.instance
              .databaseWithProgress(onProgress: onProgress),
      databaseFilePath: () async => LocalChessCacheDatabase.instance.path,
      purgeDatabase:
          () => LocalChessCacheDatabase.instance.openDedicatedConnection(),
    );
    final pgn = File('/home/chessever/documents/flow.pgn');
    final clock = Stopwatch()..start();
    await pgn.writeAsString(_randomGamesPgn(_games));
    // ignore: avoid_print
    print('[flow] generated $_games games ${pgn.lengthSync()} bytes '
        '${clock.elapsedMilliseconds}ms');

    var maxGapMs = 0;
    var last = DateTime.now();
    var phase = '';
    final phaseWatch = Stopwatch()..start();
    void onProgress(LocalChessScanProgress progress) {
      final name = progress.message.replaceAll(RegExp(r'[0-9,.]+'), '#');
      if (name == phase) return;
      if (_verbose && phase.isNotEmpty) {
        // ignore: avoid_print
        print('[phase] ${phaseWatch.elapsedMilliseconds}ms $phase');
      }
      phase = name;
      phaseWatch.reset();
    }

    final ticker = Timer.periodic(const Duration(milliseconds: 8), (_) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      if (gap > maxGapMs) maxGapMs = gap;
      if (_verbose && gap > 150) {
        // ignore: avoid_print
        print('[stall] ${gap}ms during $phase');
      }
      last = now;
    });
    Future<T> timed<T>(String label, Future<T> Function() body) async {
      maxGapMs = 0;
      last = DateTime.now();
      phase = '';
      final watch = Stopwatch()..start();
      final result = await body();
      onProgress(LocalChessScanProgress(fraction: 1, message: 'end'));
      // ignore: avoid_print
      print('[flow] $label ${watch.elapsedMilliseconds}ms '
          'longest stall ${maxGapMs}ms');
      return result;
    }

    final source = await timed(
      'import',
      () => repo.importSingleFileSource(
        path: pgn.path,
        onProgress: onProgress,
      ),
    );
    expect(source, isNotNull);

    final cached = await timed(
      'tree from cached games',
      () => repo.rebuildOpeningTreeFromCachedGames(
        databasePath: pgn.path,
        onProgress: onProgress,
      ),
    );
    expect(cached, isNotNull);
    expect(cached!.index.isUsable, isTrue);
    expect(cached.index.downloadedGameCount, _games);

    final direct = await timed(
      'tree from PGN file',
      () => repo.rebuildOpeningTreeFromPgnFile(
        databasePath: pgn.path,
        onProgress: onProgress,
      ),
    );
    expect(direct, isNotNull);
    expect(direct!.index.isUsable, isTrue);
    expect(File(compactLocalTreeIndexPath(pgn.path)).existsSync(), isTrue);
    ticker.cancel();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
