import 'dart:async';

import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final folder = LibraryFolder(
  id: 'database-a',
  userId: 'account-a',
  name: 'Preparation',
  color: '#0FB4E5',
  icon: 'database',
  orderIndex: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _Repository extends LibraryRepository {
  int reads = 0;
  Future<List<LibraryFolder>> Function()? fetch;
  @override
  Future<List<LibraryFolder>> getFolders() async {
    reads++;
    return fetch == null ? [folder] : await fetch!();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://placeholder.supabase.co',
      anonKey: 'placeholder-key',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (_) async => throw StateError('No network in tests'),
      ),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets('desktop preserves loaded folders through Realtime failures', (
    tester,
  ) async {
    final repository = _Repository();
    final updates = StreamController<List<LibraryFolder>>.broadcast();
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        libraryFolderAuthenticatedUserIdProvider.overrideWithValue('account-a'),
        libraryFolderStreamFactoryProvider.overrideWithValue(
          () => updates.stream,
        ),
      ],
    );
    container.listen(libraryFoldersStreamProvider, (_, __) {});
    updates.add([folder]);
    await tester.pump(Duration.zero);
    updates.addError(
      RealtimeSubscribeException(RealtimeSubscribeStatus.channelError),
    );
    await tester.pump(Duration.zero);
    expect(container.read(libraryFoldersStreamProvider).requireValue, [folder]);
    expect(repository.reads, 0);
    updates.add([folder.copyWith(name: 'Renamed on phone')]);
    await tester.pump(Duration.zero);
    expect(
      container.read(libraryFoldersStreamProvider).requireValue.single.name,
      'Renamed on phone',
    );
    container.dispose();
    await tester.pump(Duration.zero);
    await updates.close();
  });

  testWidgets('desktop HTTP fallback cannot overwrite a newer live folder', (
    tester,
  ) async {
    final snapshot = Completer<List<LibraryFolder>>();
    final repository = _Repository()..fetch = () => snapshot.future;
    final updates = StreamController<List<LibraryFolder>>.broadcast();
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        libraryFolderAuthenticatedUserIdProvider.overrideWithValue('account-a'),
        libraryFolderStreamFactoryProvider.overrideWithValue(
          () => updates.stream,
        ),
      ],
    );
    container.listen(libraryFoldersStreamProvider, (_, __) {});
    for (var i = 0; i < 5; i++) {
      updates.addError(
        RealtimeSubscribeException(RealtimeSubscribeStatus.channelError),
      );
    }
    await tester.pump(Duration.zero);
    expect(repository.reads, 1);
    updates.add([folder.copyWith(name: 'Updated on phone')]);
    await tester.pump(Duration.zero);
    snapshot.complete([folder]);
    await tester.pump(Duration.zero);
    expect(
      container.read(libraryFoldersStreamProvider).requireValue.single.name,
      'Updated on phone',
    );
    container.dispose();
    await tester.pump(Duration.zero);
    await updates.close();
  });

  testWidgets(
    'desktop loads an HTTP snapshot when subscription setup fails first',
    (tester) async {
      final repository = _Repository();
      final updates = StreamController<List<LibraryFolder>>.broadcast();
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repository),
          libraryFolderAuthenticatedUserIdProvider.overrideWithValue(
            'account-a',
          ),
          libraryFolderStreamFactoryProvider.overrideWithValue(
            () => updates.stream,
          ),
        ],
      );
      container.listen(libraryFoldersStreamProvider, (_, __) {});
      updates.addError(
        RealtimeSubscribeException(RealtimeSubscribeStatus.channelError),
      );
      await tester.pump(Duration.zero);
      expect(repository.reads, 1);
      expect(container.read(libraryFoldersStreamProvider).requireValue, [
        folder,
      ]);
      container.dispose();
      await tester.pump(Duration.zero);
      await updates.close();
    },
  );
}
