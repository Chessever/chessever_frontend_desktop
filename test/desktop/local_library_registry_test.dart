import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

void main() {
  test(
    'registration waits for hydration and cannot be overwritten by it',
    () async {
      const path = '/tmp/player-workspace/vasif/combined.pgn';
      final database = _DelayedRegistryDatabase(<dynamic>[
        <String, dynamic>{
          'path': path,
          'addedAt': '2026-07-10T00:00:00.000',
          'gameCount': 9998,
          'groupId': 'player-workspace:vasif',
          'groupLabel': 'GM Vasif Durarbayli',
        },
      ]);
      final notifier = LocalLibraryRegistryNotifier(database);
      await database.readStarted.future;

      final registration = notifier.registerAll(
        const <String>[path],
        metadataByPath: <String, LocalLibraryEntryMetadata>{
          path: LocalLibraryEntryMetadata.playerWorkspace(
            playerId: 'vasif',
            playerName: 'GM Vasif Durarbayli',
            gameCount: 20226,
            playerWorkspaceSource: playerWorkspaceCombinedSourceKey,
          ),
        },
      );
      database.releaseRead();
      await registration;
      await Future<void>.delayed(Duration.zero);

      expect(notifier.state.loaded, isTrue);
      expect(notifier.state.entries.single.gameCount, 20226);
      expect(
        notifier.state.entries.single.playerWorkspaceSource,
        playerWorkspaceCombinedSourceKey,
      );
      expect(
        (database.stored.single as Map<String, dynamic>)['gameCount'],
        20226,
      );
      expect(
        (database.stored.single
            as Map<String, dynamic>)['playerWorkspaceSource'],
        playerWorkspaceCombinedSourceKey,
      );
    },
  );
}

class _DelayedRegistryDatabase implements AppDatabase {
  _DelayedRegistryDatabase(List<dynamic> initial)
    : _stored = _copy(initial) as List<dynamic>;

  final readStarted = Completer<void>();
  final _releaseRead = Completer<void>();
  List<dynamic> _stored;

  List<dynamic> get stored => _copy(_stored) as List<dynamic>;

  void releaseRead() {
    if (!_releaseRead.isCompleted) _releaseRead.complete();
  }

  @override
  Future<T?> getJson<T>(String key) async {
    final snapshot = _copy(_stored);
    if (!readStarted.isCompleted) readStarted.complete();
    await _releaseRead.future;
    return snapshot as T?;
  }

  @override
  Future<void> setJson(String key, Object value) async {
    _stored = _copy(value) as List<dynamic>;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  static Object? _copy(Object? value) => jsonDecode(jsonEncode(value));
}
