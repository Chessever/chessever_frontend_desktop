import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/state/my_databases_focus.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

void main() {
  test('database pin keys are stable for cloud and local databases', () {
    expect(libraryCloudDatabasePinKey('  folder-1  '), 'cloud:folder-1');

    final key = libraryLocalDatabasePinKey(
      '${Directory.systemTemp.path}${Platform.pathSeparator}Prep.pgn',
    );
    expect(key, startsWith('local:'));
    expect(
      key.substring('local:'.length),
      Platform.isWindows
          ? '${Directory.systemTemp.path}${Platform.pathSeparator}Prep.pgn'
              .toLowerCase()
          : '${Directory.systemTemp.path}${Platform.pathSeparator}Prep.pgn',
    );
  });

  test(
    'migrates the v1 hidden and pinned records into one v2 record',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{
          _FocusDatabase.hiddenV1Key: <dynamic>[' hidden ', 4, 'hidden'],
          _FocusDatabase.pinnedV1Key: <dynamic>[
            'cloud:second',
            'cloud:first',
            'cloud:second',
          ],
        },
      );

      final notifier = MyDatabasesFocusNotifier(database);
      await notifier.loaded;

      expect(notifier.state.hiddenCloudFolderIds, <String>{'hidden'});
      expect(notifier.state.orderedPinnedDatabaseKeys, <String>[
        'cloud:second',
        'cloud:first',
      ]);
      expect(notifier.state.pinnedDatabaseKeys, <String>{
        'cloud:second',
        'cloud:first',
      });
      expect(notifier.state.orderedFolderKeys, isEmpty);
      expect(notifier.state.lastOpenedAtByItemKey, isEmpty);
      expect(notifier.state.catalogColumnWidths, isEmpty);
      expect(notifier.state.listViewPreferred, isTrue);
      expect(database.value(_FocusDatabase.v2Key), <String, Object?>{
        'version': 2,
        'hiddenCloudFolderIds': <String>['hidden'],
        'orderedPinnedDatabaseKeys': <String>['cloud:second', 'cloud:first'],
        'pinnedOrderCustomized': false,
        'orderedFolderKeys': <String>[],
        'lastOpenedAtByItemKey': <String, String>{},
        'catalogColumnWidths': <String, double>{},
        'listViewPreferred': true,
      });
    },
  );

  test(
    'pin waits for hydration and appends the new pin at the bottom',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{
          _FocusDatabase.v2Key: _v2Record(
            pinned: <String>['cloud:second', 'cloud:first'],
          ),
        },
        delayReads: true,
      );
      final notifier = MyDatabasesFocusNotifier(database);
      await database.readStarted;

      final pin = notifier.pinDatabase(' cloud:new ');
      await Future<void>.delayed(Duration.zero);
      expect(database.writeCount, 0);

      database.releaseReads();
      await pin;

      expect(notifier.state.orderedPinnedDatabaseKeys, <String>[
        'cloud:second',
        'cloud:first',
        'cloud:new',
      ]);
      expect(notifier.state.pinnedOrderCustomized, isTrue);
      expect(
        (database.value(_FocusDatabase.v2Key)
            as Map<String, dynamic>)['orderedPinnedDatabaseKeys'],
        <String>['cloud:second', 'cloud:first', 'cloud:new'],
      );
    },
  );

  test(
    'unpin removes the key from order and compatibility membership',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{
          _FocusDatabase.v2Key: _v2Record(
            pinned: <String>['cloud:first', 'cloud:second'],
          ),
        },
      );
      final notifier = MyDatabasesFocusNotifier(database);

      await notifier.unpinDatabase(' cloud:first ');

      expect(notifier.state.orderedPinnedDatabaseKeys, <String>[
        'cloud:second',
      ]);
      expect(notifier.state.pinnedDatabaseKeys, <String>{'cloud:second'});
    },
  );

  test(
    'reorders pinned databases and folders and persists their order',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{
          _FocusDatabase.v2Key: _v2Record(
            pinned: <String>['cloud:a', 'cloud:b', 'local:c'],
            folders: <String>['folder:a', 'folder:b', 'folder:c'],
          ),
        },
      );
      final notifier = MyDatabasesFocusNotifier(database);
      await notifier.loaded;

      await notifier.reorderPinnedDatabase('local:c', 0);
      await notifier.reorderFolder('folder:a', 2);

      expect(notifier.state.orderedPinnedDatabaseKeys, <String>[
        'local:c',
        'cloud:a',
        'cloud:b',
      ]);
      expect(notifier.state.orderedFolderKeys, <String>[
        'folder:b',
        'folder:c',
        'folder:a',
      ]);

      final reloaded = MyDatabasesFocusNotifier(database);
      await reloaded.loaded;
      expect(reloaded.state.orderedPinnedDatabaseKeys, <String>[
        'local:c',
        'cloud:a',
        'cloud:b',
      ]);
      expect(reloaded.state.orderedFolderKeys, <String>[
        'folder:b',
        'folder:c',
        'folder:a',
      ]);
    },
  );

  test('sets a complete pinned order without admitting unknown keys', () async {
    final database = _FocusDatabase(
      values: <String, Object?>{
        _FocusDatabase.v2Key: _v2Record(
          pinned: <String>['cloud:a', 'cloud:b', 'local:c'],
        ),
      },
    );
    final notifier = MyDatabasesFocusNotifier(database);
    await notifier.loaded;

    await notifier.setPinnedDatabaseOrder(<String>[
      'local:c',
      'unknown:item',
      'cloud:a',
    ]);

    expect(notifier.state.orderedPinnedDatabaseKeys, <String>[
      'local:c',
      'cloud:a',
      'cloud:b',
    ]);
    expect(notifier.state.pinnedOrderCustomized, isTrue);
  });

  test(
    'set folder order trims duplicates and supports later reordering',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{_FocusDatabase.v2Key: _v2Record()},
      );
      final notifier = MyDatabasesFocusNotifier(database);

      await notifier.setFolderOrder(<String>[
        ' folder:b ',
        'folder:a',
        'folder:b',
        '',
      ]);
      await notifier.reorderFolder('folder:a', 0);

      expect(notifier.state.orderedFolderKeys, <String>[
        'folder:a',
        'folder:b',
      ]);
    },
  );

  test(
    'all mutations share one queue with immutable durable snapshots',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{_FocusDatabase.v2Key: _v2Record()},
        delayWrites: true,
      );
      final notifier = MyDatabasesFocusNotifier(database);
      await notifier.loaded;

      final pin = notifier.pinDatabase('cloud:first');
      await database.writeStarted(0);
      expect(notifier.state.orderedPinnedDatabaseKeys, <String>['cloud:first']);

      final hide = notifier.hideCloudFolder('folder:hidden');
      await Future<void>.delayed(Duration.zero);
      expect(database.writeCount, 1);
      expect(database.maxActiveWrites, 1);

      database.releaseWrite(0);
      await pin;
      await database.writeStarted(1);
      expect(database.writeCount, 2);
      expect(database.maxActiveWrites, 1);

      database.releaseWrite(1);
      await hide;

      final firstSnapshot = database.writeArguments.first;
      expect(firstSnapshot['orderedPinnedDatabaseKeys'], <String>[
        'cloud:first',
      ]);
      expect(firstSnapshot['hiddenCloudFolderIds'], isEmpty);
      expect(notifier.state.hiddenCloudFolderIds, <String>{'folder:hidden'});
      expect(database.maxActiveWrites, 1);
    },
  );

  test(
    'failed persistence rolls back optimistic state and propagates',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{_FocusDatabase.v2Key: _v2Record()},
        delayWrites: true,
        failWrites: true,
      );
      final notifier = MyDatabasesFocusNotifier(database);
      await notifier.loaded;

      final pin = notifier.pinDatabase('cloud:failed');
      await database.writeStarted(0);
      expect(notifier.state.pinnedDatabaseKeys, <String>{'cloud:failed'});

      database.releaseWrite(0);
      await expectLater(pin, throwsA(isA<StateError>()));

      expect(notifier.state.pinnedDatabaseKeys, isEmpty);
      expect(
        (database.value(_FocusDatabase.v2Key)
            as Map<String, dynamic>)['orderedPinnedDatabaseKeys'],
        isEmpty,
      );
    },
  );

  test('a failed mutation does not poison the mutation queue', () async {
    final database = _FocusDatabase(
      values: <String, Object?>{_FocusDatabase.v2Key: _v2Record()},
      failuresRemaining: 1,
    );
    final notifier = MyDatabasesFocusNotifier(database);

    await expectLater(
      notifier.pinDatabase('cloud:failed'),
      throwsA(isA<StateError>()),
    );
    await notifier.pinDatabase('cloud:succeeds');

    expect(notifier.state.orderedPinnedDatabaseKeys, <String>[
      'cloud:succeeds',
    ]);
  });

  test('records a successful open timestamp by stable item key', () async {
    final database = _FocusDatabase(
      values: <String, Object?>{_FocusDatabase.v2Key: _v2Record()},
    );
    final notifier = MyDatabasesFocusNotifier(database);
    final openedAt = DateTime.utc(2026, 9, 2, 18, 45, 12);

    await notifier.recordSuccessfulOpen(' cloud:analysis ', openedAt: openedAt);

    expect(notifier.state.lastOpenedAtByItemKey['cloud:analysis'], openedAt);

    final reloaded = MyDatabasesFocusNotifier(database);
    await reloaded.loaded;
    expect(reloaded.state.lastOpenedAtByItemKey['cloud:analysis'], openedAt);
  });

  test(
    'catalog widths and list-view preference persist across reload',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{_FocusDatabase.v2Key: _v2Record()},
      );
      final notifier = MyDatabasesFocusNotifier(database);

      await notifier.setCatalogColumnWidth(' name ', 248.5);
      await notifier.setCatalogColumnWidth('games', 96);
      await notifier.setListViewPreferred(false);

      final reloaded = MyDatabasesFocusNotifier(database);
      await reloaded.loaded;
      expect(reloaded.state.catalogColumnWidths, <String, double>{
        'name': 248.5,
        'games': 96,
      });
      expect(reloaded.state.listViewPreferred, isFalse);

      await reloaded.resetCatalogColumnWidths();
      final resetReloaded = MyDatabasesFocusNotifier(database);
      await resetReloaded.loaded;
      expect(resetReloaded.state.catalogColumnWidths, isEmpty);
    },
  );

  test('malformed v2 fields are isolated from valid fields', () async {
    final database = _FocusDatabase(
      values: <String, Object?>{
        _FocusDatabase.v2Key: <String, Object?>{
          'version': 2,
          'hiddenCloudFolderIds': <dynamic>[' hidden ', 8],
          'orderedPinnedDatabaseKeys': 'not a list',
          'orderedFolderKeys': <dynamic>['folder:a', 2, 'folder:a', 'folder:b'],
          'lastOpenedAtByItemKey': <String, Object?>{
            'cloud:good': '2026-09-02T18:45:12.000Z',
            'cloud:bad': 'not a timestamp',
            '': '2026-09-02T18:45:12.000Z',
          },
          'catalogColumnWidths': <String, Object?>{
            'name': 220,
            'negative': -1,
            'text': 'wide',
          },
          'listViewPreferred': 'false',
        },
      },
    );

    final notifier = MyDatabasesFocusNotifier(database);
    await notifier.loaded;

    expect(notifier.state.hiddenCloudFolderIds, <String>{'hidden'});
    expect(notifier.state.orderedPinnedDatabaseKeys, isEmpty);
    expect(notifier.state.orderedFolderKeys, <String>['folder:a', 'folder:b']);
    expect(notifier.state.lastOpenedAtByItemKey, <String, DateTime>{
      'cloud:good': DateTime.utc(2026, 9, 2, 18, 45, 12),
    });
    expect(notifier.state.catalogColumnWidths, <String, double>{'name': 220});
    expect(notifier.state.listViewPreferred, isTrue);
  });

  test('state collection snapshots cannot be mutated by callers', () async {
    final database = _FocusDatabase(
      values: <String, Object?>{
        _FocusDatabase.v2Key: _v2Record(
          hidden: <String>['hidden'],
          pinned: <String>['cloud:pinned'],
          folders: <String>['folder:a'],
          timestamps: <String, String>{
            'cloud:pinned': '2026-09-02T18:45:12.000Z',
          },
          widths: <String, double>{'name': 220},
        ),
      },
    );
    final notifier = MyDatabasesFocusNotifier(database);
    await notifier.loaded;

    expect(
      () => notifier.state.hiddenCloudFolderIds.add('other'),
      throwsUnsupportedError,
    );
    expect(
      () => notifier.state.orderedPinnedDatabaseKeys.add('cloud:other'),
      throwsUnsupportedError,
    );
    expect(
      () => notifier.state.pinnedDatabaseKeys.add('cloud:other'),
      throwsUnsupportedError,
    );
    expect(
      () => notifier.state.orderedFolderKeys.add('folder:b'),
      throwsUnsupportedError,
    );
    expect(
      () => notifier.state.lastOpenedAtByItemKey.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => notifier.state.catalogColumnWidths.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'hidden folders can be hidden and shown through the v2 record',
    () async {
      final database = _FocusDatabase(
        values: <String, Object?>{
          _FocusDatabase.v2Key: _v2Record(pinned: <String>['cloud:folder:a']),
        },
      );
      final notifier = MyDatabasesFocusNotifier(database);

      await notifier.hideCloudFolder(' folder:a ');
      expect(notifier.state.hiddenCloudFolderIds, <String>{'folder:a'});
      expect(notifier.state.pinnedDatabaseKeys, isEmpty);

      await notifier.showCloudFolder('folder:a');
      expect(notifier.state.hiddenCloudFolderIds, isEmpty);
    },
  );

  test('pinned databases still sort before unpinned databases', () {
    expect(compareLibraryDatabaseCatalogPinState(true, false), -1);
    expect(compareLibraryDatabaseCatalogPinState(false, true), 1);
    expect(compareLibraryDatabaseCatalogPinState(true, true), 0);
    expect(compareLibraryDatabaseCatalogPinState(false, false), 0);
  });
}

Map<String, Object?> _v2Record({
  List<String> hidden = const <String>[],
  List<String> pinned = const <String>[],
  List<String> folders = const <String>[],
  Map<String, String> timestamps = const <String, String>{},
  Map<String, double> widths = const <String, double>{},
  bool listViewPreferred = true,
  bool pinnedOrderCustomized = false,
}) {
  return <String, Object?>{
    'version': 2,
    'hiddenCloudFolderIds': hidden,
    'orderedPinnedDatabaseKeys': pinned,
    'pinnedOrderCustomized': pinnedOrderCustomized,
    'orderedFolderKeys': folders,
    'lastOpenedAtByItemKey': timestamps,
    'catalogColumnWidths': widths,
    'listViewPreferred': listViewPreferred,
  };
}

class _FocusDatabase implements AppDatabase {
  _FocusDatabase({
    Map<String, Object?> values = const <String, Object?>{},
    this.delayReads = false,
    this.delayWrites = false,
    this.failWrites = false,
    int failuresRemaining = 0,
  }) : _values = _copy(values) as Map<String, dynamic>,
       _failuresRemaining = failuresRemaining;

  static const hiddenV1Key = 'desktop.my_databases.hidden_cloud_ids.v1';
  static const pinnedV1Key = 'desktop.my_databases.pinned_database_keys.v1';
  static const v2Key = 'desktop.my_databases.focus.v2';

  final bool delayReads;
  final bool delayWrites;
  final bool failWrites;
  final Completer<void> _readStarted = Completer<void>();
  final Completer<void> _readRelease = Completer<void>();
  final List<Completer<void>> _writeStarts = List<Completer<void>>.generate(
    8,
    (_) => Completer<void>(),
  );
  final List<Completer<void>> _writeReleases = List<Completer<void>>.generate(
    8,
    (_) => Completer<void>(),
  );
  final List<Map<String, dynamic>> writeArguments = <Map<String, dynamic>>[];
  final Map<String, dynamic> _values;
  int _failuresRemaining;
  int writeCount = 0;
  int activeWrites = 0;
  int maxActiveWrites = 0;

  Future<void> get readStarted => _readStarted.future;

  Object? value(String key) => _copy(_values[key]);

  void releaseReads() {
    if (!_readRelease.isCompleted) _readRelease.complete();
  }

  Future<void> writeStarted(int index) => _writeStarts[index].future;

  void releaseWrite(int index) {
    if (!_writeReleases[index].isCompleted) {
      _writeReleases[index].complete();
    }
  }

  @override
  Future<T?> getJson<T>(String key) async {
    if (!_readStarted.isCompleted) _readStarted.complete();
    if (delayReads) await _readRelease.future;
    return _copy(_values[key]) as T?;
  }

  @override
  Future<void> setJson(String key, Object value) async {
    final writeIndex = writeCount++;
    activeWrites += 1;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    final argument = _copy(value) as Map<String, dynamic>;
    writeArguments.add(argument);
    if (!_writeStarts[writeIndex].isCompleted) {
      _writeStarts[writeIndex].complete();
    }
    try {
      if (delayWrites) await _writeReleases[writeIndex].future;
      if (failWrites || _failuresRemaining > 0) {
        if (_failuresRemaining > 0) _failuresRemaining -= 1;
        throw StateError('Focus state write failed');
      }
      _values[key] = _copy(value);
    } finally {
      activeWrites -= 1;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  static Object? _copy(Object? value) => jsonDecode(jsonEncode(value));
}
