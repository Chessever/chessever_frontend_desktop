import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads deterministic tournament pages until the first short page',
    () async {
      final cursors = <String?>[];

      final values = await loadAllTournamentGamePages<int>(
        pageSize: 1000,
        fetchPage: (limit, afterId) async {
          cursors.add(afterId);
          final start = afterId == null ? 0 : int.parse(afterId) + 1;
          final length = start < 2000 ? limit : 7;
          return List<int>.generate(length, (index) => start + index);
        },
        idOf: (value) => '$value',
      );

      expect(values, hasLength(2007));
      expect(cursors, [null, '999', '1999']);
      expect(values.first, 0);
      expect(values.last, 2006);
    },
  );

  test('stops after one request when the first page is short', () async {
    var calls = 0;

    final values = await loadAllTournamentGamePages<int>(
      pageSize: 1000,
      fetchPage: (limit, afterId) async {
        calls += 1;
        return [1, 2, 3];
      },
      idOf: (value) => '$value',
    );

    expect(values, [1, 2, 3]);
    expect(calls, 1);
  });

  test('requests an empty terminator after an exact full page', () async {
    final cursors = <String?>[];

    final values = await loadAllTournamentGamePages<int>(
      pageSize: 2,
      fetchPage: (limit, afterId) async {
        cursors.add(afterId);
        return afterId == null ? [1, 2] : const <int>[];
      },
      idOf: (value) => '$value',
    );

    expect(values, [1, 2]);
    expect(cursors, [null, '2']);
  });

  test('does not skip untouched rows when an earlier row disappears', () async {
    final rows = <int>[1, 2, 3, 4, 5];
    var calls = 0;

    final values = await loadAllTournamentGamePages<int>(
      pageSize: 2,
      fetchPage: (limit, afterId) async {
        final page = rows
            .where((value) => afterId == null || value > int.parse(afterId))
            .take(limit)
            .toList(growable: false);
        if (calls++ == 0) rows.remove(1);
        return page;
      },
      idOf: (value) => '$value',
    );

    expect(values, [1, 2, 3, 4, 5]);
  });

  test('rejects a full continuation page whose cursor does not advance', () {
    expectLater(
      loadAllTournamentGamePages<int>(
        pageSize: 2,
        fetchPage: (_, _) async => [1, 2],
        idOf: (value) => '$value',
      ),
      throwsStateError,
    );
  });
}
