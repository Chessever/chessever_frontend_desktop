import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/services/auth/desktop_guest_account_merger.dart';
import 'package:chessever/desktop/services/auth/guest_account_merge.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

/// The browser build keeps a pending guest merge in the app database
/// (IndexedDB there), because its sign-in leaves the page. The snapshot must
/// survive a write/read round trip and be gone after clear.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    databaseDirectory = await Directory.systemTemp.createTemp(
      'chessever-guest-merge-store-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => databaseDirectory.path,
        );
    sqfliteFfiInit();
    sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
    await AppDatabase.instance.database;
  });

  tearDownAll(() async {
    await AppDatabase.instance.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (await databaseDirectory.exists()) {
      await databaseDirectory.delete(recursive: true);
    }
  });

  test('a pending snapshot survives a round trip and clears', () async {
    final store = AppDatabaseGuestMergePendingStore();
    expect(await store.read(), isNull);

    final capturedAt = DateTime.utc(2026, 10, 28, 12);
    await store.write(
      GuestAccountSnapshot(
        guestUserId: 'guest-1',
        capturedAt: capturedAt,
        rows: const GuestAccountRows(),
      ),
    );

    final restored = await store.read();
    expect(restored, isNotNull);
    expect(restored!.guestUserId, 'guest-1');
    expect(restored.capturedAt, capturedAt);

    await store.clear();
    expect(await store.read(), isNull);
  });
}
