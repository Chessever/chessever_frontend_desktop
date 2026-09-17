import 'dart:async';

import 'package:chessever/desktop/widgets/library/library_cloud_rows.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cloud database must stay on screen while a background refresh runs.
///
/// The saved-game list used to be replaced by a loading placeholder whenever
/// `connectionState != ConnectionState.done`, which is exactly the state a
/// periodic catch-up fetch (or a realtime revision) produces. The visible
/// result was an intermittently empty game list that repopulated a moment
/// later. These cases pin the publication contract that fixes it: rows for the
/// rendered scope are never dropped, and only a scope with nothing loaded may
/// show a placeholder.
void main() {
  testWidgets('a refresh for the loaded scope keeps the rows on screen', (
    tester,
  ) async {
    final fetches = _FetchQueue();
    final observed = _Observations();
    final harness = _SnapshotHarness(
      folderId: 'mehmet',
      refreshKey: 0,
      fetch: fetches.call,
      observed: observed.capture,
    );

    await tester.pumpWidget(harness);
    expect(observed.latest.isInitialLoading, isTrue);
    expect(observed.latest.rows, isNull);

    fetches.completeNext(<SavedAnalysis>[_analysis('game-1')]);
    await tester.pump();
    expect(observed.latest.rows?.map((row) => row.id), <String>['game-1']);
    expect(observed.latest.isInitialLoading, isFalse);
    expect(observed.latest.isRefreshing, isFalse);

    // The periodic catch-up / realtime revision arrives: `rows` must stay
    // readable for the very build that starts the next fetch.
    await tester.pumpWidget(harness.withRefreshKey(1));
    expect(observed.latest.rows?.map((row) => row.id), <String>['game-1']);
    expect(observed.latest.isInitialLoading, isFalse);
    expect(observed.latest.isRefreshing, isTrue);

    fetches.completeNext(<SavedAnalysis>[
      _analysis('game-2'),
      _analysis('game-1'),
    ]);
    await tester.pump();
    expect(observed.latest.rows?.map((row) => row.id), <String>[
      'game-2',
      'game-1',
    ]);
    expect(observed.latest.isRefreshing, isFalse);
  });

  testWidgets('a stale completion cannot publish rows into a later fetch', (
    tester,
  ) async {
    final fetches = _FetchQueue();
    final observed = _Observations();
    final harness = _SnapshotHarness(
      folderId: 'mehmet',
      refreshKey: 0,
      fetch: fetches.call,
      observed: observed.capture,
    );

    await tester.pumpWidget(harness);
    await tester.pumpWidget(harness.withRefreshKey(1));

    // The superseded first fetch lands after the second one started.
    fetches.complete(0, <SavedAnalysis>[_analysis('stale')]);
    await tester.pump();
    expect(observed.latest.rows, isNull);

    fetches.completeNext(<SavedAnalysis>[_analysis('fresh')]);
    await tester.pump();
    expect(observed.latest.rows?.map((row) => row.id), <String>['fresh']);
  });

  testWidgets('a different database never inherits the previous rows', (
    tester,
  ) async {
    final fetches = _FetchQueue();
    final observed = _Observations();

    await tester.pumpWidget(
      _SnapshotHarness(
        folderId: 'mehmet',
        refreshKey: 0,
        fetch: fetches.call,
        observed: observed.capture,
      ),
    );
    fetches.completeNext(<SavedAnalysis>[_analysis('mehmet-1')]);
    await tester.pump();
    expect(observed.latest.rows?.map((row) => row.id), <String>['mehmet-1']);

    await tester.pumpWidget(
      _SnapshotHarness(
        folderId: 'karim',
        refreshKey: 0,
        fetch: fetches.call,
        observed: observed.capture,
      ),
    );
    expect(observed.latest.rows, isNull);
    expect(observed.latest.isInitialLoading, isTrue);

    fetches.completeNext(<SavedAnalysis>[_analysis('karim-1')]);
    await tester.pump();
    expect(observed.latest.rows?.map((row) => row.id), <String>['karim-1']);
  });

  testWidgets('a failed background refresh keeps the last good rows', (
    tester,
  ) async {
    final fetches = _FetchQueue();
    final observed = _Observations();
    final harness = _SnapshotHarness(
      folderId: 'mehmet',
      refreshKey: 0,
      fetch: fetches.call,
      observed: observed.capture,
    );

    await tester.pumpWidget(harness);
    fetches.completeNext(<SavedAnalysis>[_analysis('game-1')]);
    await tester.pump();
    expect(observed.latest.rows?.length, 1);

    await tester.pumpWidget(harness.withRefreshKey(1));
    fetches.failNext(StateError('temporary network failure'));
    await tester.pump();
    expect(observed.latest.rows?.map((row) => row.id), <String>['game-1']);
    expect(observed.latest.isInitialLoading, isFalse);
    // The failure is only worth surfacing when it left nothing to show.
    expect(observed.latest.error, isNull);
  });

  testWidgets('a failed first load surfaces the error and no rows', (
    tester,
  ) async {
    final fetches = _FetchQueue();
    final observed = _Observations();

    await tester.pumpWidget(
      _SnapshotHarness(
        folderId: 'mehmet',
        refreshKey: 0,
        fetch: fetches.call,
        observed: observed.capture,
      ),
    );
    fetches.failNext(StateError('offline'));
    await tester.pump();
    expect(observed.latest.rows, isNull);
    expect(observed.latest.isInitialLoading, isFalse);
    expect(observed.latest.error, isA<StateError>());
  });
}

class _Observations {
  LibraryCloudRowsSnapshot? _latest;

  /// The publication from the most recent build. Every build publishes, so a
  /// read before the first build is a test bug rather than a null case.
  LibraryCloudRowsSnapshot get latest => _latest!;

  void capture(LibraryCloudRowsSnapshot snapshot) => _latest = snapshot;
}

class _FetchQueue {
  final List<Completer<List<SavedAnalysis>>> _pending =
      <Completer<List<SavedAnalysis>>>[];

  Future<List<SavedAnalysis>> call() {
    final completer = Completer<List<SavedAnalysis>>();
    _pending.add(completer);
    return completer.future;
  }

  void complete(int index, List<SavedAnalysis> rows) =>
      _pending[index].complete(rows);

  void completeNext(List<SavedAnalysis> rows) =>
      complete(_pending.length - 1, rows);

  void failNext(Object error) => _pending.last.completeError(error);
}

class _SnapshotHarness extends HookWidget {
  const _SnapshotHarness({
    required this.folderId,
    required this.refreshKey,
    required this.fetch,
    required this.observed,
  });

  final String folderId;
  final int refreshKey;
  final Future<List<SavedAnalysis>> Function() fetch;
  final void Function(LibraryCloudRowsSnapshot snapshot) observed;

  _SnapshotHarness withRefreshKey(int refreshKey) => _SnapshotHarness(
    folderId: folderId,
    refreshKey: refreshKey,
    fetch: fetch,
    observed: observed,
  );

  @override
  Widget build(BuildContext context) {
    final snapshot = useLibraryCloudRows(
      scope: libraryCloudDatabaseScope(folderId, isSubscribed: false),
      refreshKeys: <Object?>[refreshKey],
      fetch: fetch,
    );
    observed(snapshot);
    return const SizedBox.shrink();
  }
}

SavedAnalysis _analysis(String id) => SavedAnalysis(
  id: id,
  userId: 'account-a',
  folderId: 'mehmet',
  title: '$id vs Opponent',
  chessGame: ChessGame(
    gameId: id,
    startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    metadata: const <String, dynamic>{
      'White': 'White',
      'Black': 'Black',
      'Result': '1-0',
    },
    mainline: const <ChessMove>[],
  ),
  analysisState: const <String, dynamic>{},
  variationComments: const <String, String>{},
  lastViewedPosition: 0,
  tags: const <String>[],
  isFavorite: false,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
