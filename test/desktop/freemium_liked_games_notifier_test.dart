import 'dart:async';

import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/liked_games/liked_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _likesFolder = LibraryFolder(
  id: 'likes',
  userId: 'user-1',
  name: 'Liked Games',
  color: '#F5453A',
  icon: 'liked',
  orderIndex: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  isLikedGames: true,
);

const _pgn =
    '[White "Carlsen, Magnus"]\n[Black "Nakamura, Hikaru"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0';

GamesTourModel _game(String id) => GamesTourModel(
  gameId: id,
  whitePlayer: PlayerCard(
    name: 'Carlsen, Magnus',
    federation: 'NOR',
    title: 'GM',
    rating: 2830,
    countryCode: 'NOR',
    team: null,
  ),
  blackPlayer: PlayerCard(
    name: 'Nakamura, Hikaru',
    federation: 'USA',
    title: 'GM',
    rating: 2800,
    countryCode: 'USA',
    team: null,
  ),
  whiteTimeDisplay: '--:--',
  blackTimeDisplay: '--:--',
  whiteClockCentiseconds: 0,
  blackClockCentiseconds: 0,
  gameStatus: GameStatus.whiteWins,
  roundId: 'r',
  tourId: 't',
  pgn: _pgn,
);

/// In-memory stand-in for the Supabase-backed repository. Every write is
/// recorded so tests can assert what reached "the server".
class _Repository extends LibraryRepository {
  final List<SavedAnalysis> server = <SavedAnalysis>[];
  final List<Map<String, dynamic>> insertPayloads = <Map<String, dynamic>>[];
  final List<List<String>> tagCalls = <List<String>>[];
  final List<String> tagTargets = <String>[];
  List<Duration> tagDelays = <Duration>[];
  Completer<void>? createGate;
  Object? createError;
  int reads = 0;
  int _ids = 0;

  @override
  Future<LibraryFolder> ensureLikedGamesFolder() async => _likesFolder;

  @override
  Future<List<SavedAnalysis>> getSavedAnalyses({
    String? folderId,
    bool? isFavorite,
  }) async {
    reads++;
    return server.where((a) => a.folderId == folderId).toList();
  }

  @override
  Future<SavedAnalysis> createSavedAnalysis(SavedAnalysis analysis) async {
    insertPayloads.add(analysis.toSupabaseInsert());
    final gate = createGate;
    if (gate != null) await gate.future;
    final error = createError;
    if (error != null) throw error;
    final serverTime = DateTime.utc(2026, 9, 12, 12);
    final created = analysis.copyWith(
      id: 'row-${++_ids}',
      createdAt: serverTime,
      updatedAt: serverTime,
    );
    server.add(created);
    return created;
  }

  @override
  Future<void> deleteSavedAnalysis(String analysisId) async {
    server.removeWhere((a) => a.id == analysisId);
  }

  @override
  Future<SavedAnalysis> updateSavedAnalysisTags({
    required String analysisId,
    required List<String> tags,
  }) async {
    final call = tagCalls.length;
    tagCalls.add(tags);
    tagTargets.add(analysisId);
    if (call < tagDelays.length) await Future<void>.delayed(tagDelays[call]);
    final index = server.indexWhere((a) => a.id == analysisId);
    final updated = server[index].copyWith(tags: tags);
    server[index] = updated;
    return updated;
  }
}

ProviderContainer _container(
  _Repository repository, {
  LikedGameRecordedHook? hook,
}) {
  final container = ProviderContainer(
    overrides: [
      libraryRepositoryProvider.overrideWithValue(repository),
      currentUserProvider.overrideWithValue(
        AppUser(id: 'user-1', createdAt: DateTime(2026)),
      ),
      if (hook != null) likedGameRecordedHookProvider.overrideWithValue(hook),
    ],
  );
  addTearDown(container.dispose);
  return container;
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

  test(
    'a second tap while a like is in flight is a read, not a flip',
    () async {
      final repository = _Repository()..createGate = Completer<void>();
      final container = _container(repository);
      await container.read(likedGamesProvider.future);
      final notifier = container.read(likedGamesProvider.notifier);

      final first = notifier.toggle(_game('g1'));
      final second = notifier.toggle(_game('g1'));
      expect(await second, isFalse);

      repository.createGate!.complete();
      expect(await first, isTrue);
      expect(repository.insertPayloads, hasLength(1));
      expect(repository.server, hasLength(1));
      final rows = container.read(likedGamesProvider).requireValue;
      expect(rows.where((a) => a.sourceGameId == 'g1'), hasLength(1));
      expect(rows.single.id, 'row-1');
    },
  );

  test(
    'the insert carries no client timestamps: the server decides liked-at',
    () async {
      final repository = _Repository();
      final container = _container(repository);
      await container.read(likedGamesProvider.future);
      await container.read(likedGamesProvider.notifier).toggle(_game('g1'));
      final payload = repository.insertPayloads.single;
      expect(payload.containsKey('created_at'), isFalse);
      expect(payload.containsKey('updated_at'), isFalse);
      expect(payload['folder_id'], 'likes');
      expect(
        container.read(likedGamesProvider).requireValue.single.createdAt,
        DateTime.utc(2026, 9, 12, 12),
      );
    },
  );

  test(
    'a failed like reloads from the server instead of keeping a phantom',
    () async {
      final repository =
          _Repository()..createError = Exception('insert failed');
      final container = _container(repository);
      await container.read(likedGamesProvider.future);
      expect(repository.reads, 1);

      final liked = await container
          .read(likedGamesProvider.notifier)
          .toggle(_game('g1'));

      expect(liked, isFalse);
      expect(repository.reads, 2);
      expect(container.read(likedGamesProvider).requireValue, isEmpty);
      expect(container.read(isGameLikedProvider('g1')), isFalse);
    },
  );

  test('rapid tag taps persist in order and the last tap wins', () async {
    final repository = _Repository();
    final container = _container(repository);
    await container.read(likedGamesProvider.future);
    final notifier = container.read(likedGamesProvider.notifier);
    await notifier.toggle(_game('g1'));

    // The first write is the slowest; serialization must still keep order.
    repository.tagDelays = const [
      Duration(milliseconds: 60),
      Duration(milliseconds: 10),
      Duration.zero,
    ];
    final writes = [
      notifier.setTagsForLikeId('g1', ['Trap']),
      notifier.setTagsForLikeId('g1', ['Trap', 'Sacrifice']),
      notifier.setTagsForLikeId('g1', [' Sacrifice ', 'Sacrifice']),
    ];
    expect(container.read(likedGameTagsProvider('g1')), ['Sacrifice']);

    expect(await Future.wait(writes), [true, true, true]);
    expect(repository.tagCalls, [
      ['Trap'],
      ['Trap', 'Sacrifice'],
      ['Sacrifice'],
    ]);
    expect(repository.server.single.tags, ['Sacrifice']);
    expect(container.read(likedGameTagsProvider('g1')), ['Sacrifice']);
  });

  test(
    'a tag chosen while the like is in flight lands on the created row',
    () async {
      final repository = _Repository()..createGate = Completer<void>();
      final container = _container(repository);
      await container.read(likedGamesProvider.future);
      final notifier = container.read(likedGamesProvider.notifier);

      final like = notifier.toggle(_game('g1'));
      final tag = notifier.setTagsForLikeId('g1', ['Beautiful Mate']);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repository.tagCalls, isEmpty);

      repository.createGate!.complete();
      expect(await like, isTrue);
      expect(await tag, isTrue);
      expect(repository.tagTargets, ['row-1']);
      expect(repository.server.single.tags, ['Beautiful Mate']);
    },
  );

  test('a failing bookkeeping hook never rolls back a saved like', () async {
    final repository = _Repository();
    final container = _container(
      repository,
      hook: ({required userId}) async => throw StateError('cadence'),
    );
    await container.read(likedGamesProvider.future);

    final liked = await container
        .read(likedGamesProvider.notifier)
        .toggle(_game('g1'));

    expect(liked, isTrue);
    expect(repository.reads, 1);
    expect(container.read(isGameLikedProvider('g1')), isTrue);
  });

  test(
    'unliking removes the row and removal is reflected immediately',
    () async {
      final repository = _Repository();
      final container = _container(repository);
      await container.read(likedGamesProvider.future);
      final notifier = container.read(likedGamesProvider.notifier);
      await notifier.toggle(_game('g1'));
      expect(await notifier.toggle(_game('g1')), isFalse);
      expect(repository.server, isEmpty);
      expect(container.read(likedGamesProvider).requireValue, isEmpty);
    },
  );
}
