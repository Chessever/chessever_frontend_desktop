import 'dart:async';

import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/library/models/library_folder.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/repository/liked_games/like_realtime.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/models/like_tag.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/chess_title_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Resolves (and lazily creates) the per-user Likes collection: the one
/// `user_folders` row with `is_liked_games = true`. A like is an ordinary
/// `user_saved_analyses` row inside it.
final likedGamesFolderProvider = FutureProvider<LibraryFolder>((ref) async {
  ref.watch(currentUserProvider.select((user) => user?.id));
  final repo = ref.watch(libraryRepositoryProvider);
  return repo.ensureLikedGamesFolder();
});

/// All saved analyses inside the user's Likes collection, newest-first.
/// Drives the like state on game surfaces and the canonical toggle.
final likedGamesProvider =
    AsyncNotifierProvider<LikedGamesNotifier, List<SavedAnalysis>>(
      LikedGamesNotifier.new,
    );

/// Completed like writes also refresh counts when using the previous schema.
final likedGamesWriteRevisionProvider = StateProvider<int>((ref) => 0);

// Show a new like while its PGN is being resolved, before the saved row
// can be represented in the list. Scope it to the account that tapped.
final _pendingGameLikeOwnerProvider = StateProvider.family<String?, String>(
  (ref, likeId) => null,
);

final isGameLikePendingProvider = Provider.family<bool, String>((ref, likeId) {
  final owner = ref.watch(_pendingGameLikeOwnerProvider(likeId));
  return owner != null &&
      ref.watch(currentUserProvider.select((user) => user?.id)) == owner;
});

/// Immediate per-game tag selection while the canonical liked row is being
/// created or updated. `null` means "use the saved row"; an empty list means
/// "explicitly cleared".
final likedGamePendingTagsProvider =
    StateProvider.family<List<String>?, String>((ref, likeId) => null);

/// Selected tags for a liked game. The pending value wins while a write is in
/// flight, so reopening a surface shows the user's last tap immediately
/// instead of waiting on Supabase or a provider reload.
final likedGameTagsProvider = Provider.family<List<String>, String>((
  ref,
  likeId,
) {
  final pending = ref.watch(likedGamePendingTagsProvider(likeId));
  if (pending != null) return pending;

  final list = ref.watch(likedGamesProvider).valueOrNull;
  final analysis = list?.firstWhereOrNull((a) => a.sourceGameId == likeId);
  return analysis?.tags ?? const <String>[];
});

/// Side effect run after a like is persisted.
///
/// Mobile resets its like-reminder cadence here. Desktop has no reminder yet,
/// so this is null by default; the hook exists so any such bookkeeping stays
/// isolated from the like itself (see [LikedGamesNotifier.toggle]).
typedef LikedGameRecordedHook = Future<void> Function({required String userId});

final likedGameRecordedHookProvider = Provider<LikedGameRecordedHook?>(
  (ref) => null,
);

class LikedGamesNotifier extends AsyncNotifier<List<SavedAnalysis>> {
  LibraryRepository get _repo => ref.read(libraryRepositoryProvider);

  // Discard a background read that overlapped optimistic edits.
  int _localMutation = 0;

  void _serverChanged() =>
      ref.read(likedGamesWriteRevisionProvider.notifier).state++;
  final _removalOps = <Future<void>>{};

  void _listenForAccountChanges(Future<LibraryFolder> folderFuture) {
    final repo = _repo;
    final client = repo.supabase;
    final owner = client.auth.currentUser;
    if (owner == null || owner.isAnonymous) return;

    var active = true;
    Timer? timer;
    var refreshing = false;
    var dirty = false;
    Future<void> refresh() async {
      if (refreshing) return;
      refreshing = true;
      try {
        final folder = await folderFuture;
        if (!active) return;
        try {
          await future;
        } catch (_) {
          // A resumed connection can recover a failed initial list read.
        }
        while (active &&
            dirty &&
            client.auth.currentUser?.id == folder.userId) {
          await Future.wait<Object?>([
            ..._toggleOps.values,
            ..._removalOps,
            ..._tagWriteChains.values,
          ]);
          if (!active || client.auth.currentUser?.id != folder.userId) return;
          if (_toggleOps.isNotEmpty ||
              _removalOps.isNotEmpty ||
              _tagWriteChains.isNotEmpty) {
            continue;
          }
          final revision = _localMutation;
          dirty = false;
          final rows = await repo.getSavedAnalyses(folderId: folder.id);
          if (!active || client.auth.currentUser?.id != folder.userId) return;
          if (revision != _localMutation) {
            dirty = true;
            continue;
          }
          state = AsyncValue.data(rows);
        }
      } catch (error) {
        debugPrint('[LikedGames] live refresh failed: $error');
      } finally {
        refreshing = false;
      }
    }

    final stop = listenForLikeChanges(client, 'account-likes:${owner.id}', () {
      dirty = true;
      timer?.cancel();
      timer = Timer(
        const Duration(milliseconds: 150),
        () => unawaited(refresh()),
      );
    });
    ref.onDispose(() {
      active = false;
      timer?.cancel();
      stop();
    });
  }

  /// In-flight per-game-id toggle calls, so rapid re-taps don't race.
  final Set<String> _inFlight = <String>{};

  /// Per-likeId future for the currently-running toggle. A tag chosen right
  /// after liking can fire before the optimistic liked row exists in `state`
  /// (the like's PGN resolve + insert is still running), so the tag write
  /// awaits this before looking for the row. Otherwise it finds nothing and
  /// is silently dropped.
  final Map<String, Future<void>> _toggleOps = <String, Future<void>>{};

  /// Per-game tag writes are queued so rapid chip taps persist in order and the
  /// last visible selection is also the final server value.
  final Map<String, Future<bool>> _tagWriteChains = <String, Future<bool>>{};

  @override
  Future<List<SavedAnalysis>> build() async {
    final folderFuture = ref.watch(likedGamesFolderProvider.future);
    _listenForAccountChanges(folderFuture);
    final folder = await folderFuture;
    final all = await _repo.getSavedAnalyses(folderId: folder.id);
    return all;
  }

  bool isLiked(String sourceGameId) {
    final list = state.valueOrNull;
    if (list == null) return false;
    return list.any((a) => a.sourceGameId == sourceGameId);
  }

  /// Optimistically likes/unlikes [game], using the same SavedAnalysis path
  /// as "Save to library". Returns the new state (`true` = now liked).
  /// Source-agnostic: works for broadcast, gamebase and TWIC games alike.
  Future<bool> toggle(GamesTourModel game) async {
    // Like identity is the original game (for saved-analysis games this is the
    // sourceGameId, not the synthetic `saved_analysis_<id>` gameId), so a game
    // liked here matches the same game opened from anywhere else.
    final likeId = game.likeId;
    if (!_inFlight.add(likeId)) {
      return isLiked(likeId);
    }

    // Publish this toggle's lifetime synchronously (before the first await) so
    // a tag write started while the like is mid-flight can wait for the liked
    // row to be created instead of racing ahead of the optimistic insert.
    final op = Completer<void>();
    _localMutation++;
    _toggleOps[likeId] = op.future;

    final ownerIdAtTap = ref.read(currentUserProvider)?.id;
    final lookedLiked = isLiked(likeId);
    final wasLoaded = state.hasValue && !state.isLoading && !state.hasError;
    List<SavedAnalysis> removed = const [];
    try {
      final folder = await ref.read(likedGamesFolderProvider.future);
      final userId = ref.read(currentUserProvider)?.id;
      if (userId == null || userId != folder.userId) {
        throw StateError('My Likes account changed');
      }
      if (!wasLoaded) await future;
      final list = List<SavedAnalysis>.from(state.requireValue);
      final existing = list.firstWhereOrNull((a) => a.sourceGameId == likeId);

      if (existing != null) {
        if (!wasLoaded || !lookedLiked || existing.id.isEmpty) return true;
        removed = list.where((a) => a.sourceGameId == likeId).toList();
        list.removeWhere((a) => a.sourceGameId == likeId);
        state = AsyncValue.data(list);
        await _repo.deleteGameLike(existing);
        if (ref.read(currentUserProvider)?.id != ownerIdAtTap) return false;
        _serverChanged();
        return false;
      }

      if (lookedLiked || ref.read(currentUserProvider)?.id != ownerIdAtTap) {
        return false;
      }

      ref.read(_pendingGameLikeOwnerProvider(likeId).notifier).state = userId;
      final chessGame = await _resolveChessGame(game);
      // Local placeholder times only. The insert payload omits created_at and
      // updated_at so Postgres `DEFAULT now()` is the authoritative liked-at,
      // which is the axis of the seven-day Likes window.
      final now = DateTime.now();
      final analysis = SavedAnalysis(
        id: '',
        userId: userId,
        folderId: folder.id,
        title: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
        sourceGameId: likeId,
        sourceTournamentId: game.tourId,
        chessGame: chessGame,
        analysisState: const {},
        variationComments: const {},
        lastViewedPosition: -1,
        tags: const [],
        notes: null,
        isFavorite: false,
        createdAt: now,
        updatedAt: now,
      );

      // OPTIMISTIC insert with a placeholder id; reconciled below.
      if (ref.read(currentUserProvider)?.id != ownerIdAtTap) return false;
      final current = state.requireValue;
      if (current.any((row) => row.sourceGameId == likeId)) return true;
      state = AsyncValue.data([analysis, ...current]);
      ref.read(_pendingGameLikeOwnerProvider(likeId).notifier).state = null;

      final created = await _repo.createGameLike(analysis);
      if (ref.read(currentUserProvider)?.id != ownerIdAtTap) return false;
      final localTags =
          (state.valueOrNull ?? const <SavedAnalysis>[])
              .firstWhereOrNull((a) => a.id.isEmpty && a.sourceGameId == likeId)
              ?.tags;
      final displayCreated =
          localTags != null && localTags.isNotEmpty
              ? created.copyWith(tags: localTags)
              : created;
      final reconciled =
          List<SavedAnalysis>.from(state.valueOrNull ?? const [])
            ..removeWhere(
              (a) =>
                  (a.id.isEmpty && a.sourceGameId == likeId) ||
                  a.id == created.id,
            )
            ..insert(0, displayCreated);
      state = AsyncValue.data(reconciled);
      _serverChanged();
      try {
        final hook = ref.read(likedGameRecordedHookProvider);
        if (hook != null) await hook(userId: userId);
      } catch (error) {
        // Liking is the primary action. A cadence/bookkeeping write must
        // never roll back or report failure for a successfully saved like.
        debugPrint('[LikedGames] like recorded hook failed: $error');
      }
      return true;
    } catch (e) {
      debugPrint('[LikedGames] toggle failed: $e');
      ref.read(_pendingGameLikeOwnerProvider(likeId).notifier).state = null;
      final current = state.valueOrNull;
      if (current != null &&
          ref.read(currentUserProvider)?.id == ownerIdAtTap) {
        state = AsyncValue.data([
          ...removed.where((row) => !current.any((a) => a.id == row.id)),
          ...current.where((a) => a.id.isNotEmpty || a.sourceGameId != likeId),
        ]);
        await _reload();
      }
      return isLiked(likeId);
    } finally {
      ref.read(_pendingGameLikeOwnerProvider(likeId).notifier).state = null;
      _localMutation++;
      _inFlight.remove(likeId);
      if (identical(_toggleOps[likeId], op.future)) {
        _toggleOps.remove(likeId);
      }
      op.complete();
    }
  }

  /// Resolves full PGN + display metadata so a liked game saves identically
  /// to the manual "Save to library" flow.
  Future<ChessGame> _resolveChessGame(GamesTourModel game) async {
    String? pgn = game.pgn;
    final hasMoves = pgn != null && pgnHasMoves(pgn);

    if (!hasMoves) {
      try {
        final supabasePgn = await ref
            .read(gameRepositoryProvider)
            .getGamePgn(game.gameId);
        if (supabasePgn != null && pgnHasMoves(supabasePgn)) {
          pgn = supabasePgn;
        }
      } catch (_) {}

      if (pgn == null || !pgnHasMoves(pgn)) {
        final fullGame = await ref
            .read(gamebaseRepositoryProvider)
            .getGameWithPgn(game.gameId);
        if (fullGame != null) {
          if (fullGame.pgn != null && pgnHasMoves(fullGame.pgn!)) {
            pgn = fullGame.pgn;
          } else if (fullGame.data != null) {
            final builtPgn = buildPgnFromGamebaseData(fullGame.data);
            if (builtPgn != null && pgnHasMoves(builtPgn)) {
              pgn = builtPgn;
            }
          }
        }
      }
    }

    if (pgn == null || pgn.trim().isEmpty) {
      throw Exception('Game PGN not found');
    }

    final chessGame = ChessGame.fromPgn(game.gameId, pgn);
    final meta = Map<String, dynamic>.from(chessGame.metadata);

    meta['White'] = game.whitePlayer.name;
    meta['Black'] = game.blackPlayer.name;

    final whiteFed =
        game.whitePlayer.countryCode.isNotEmpty
            ? game.whitePlayer.countryCode
            : game.whitePlayer.federation;
    final blackFed =
        game.blackPlayer.countryCode.isNotEmpty
            ? game.blackPlayer.countryCode
            : game.blackPlayer.federation;
    if (whiteFed.isNotEmpty) meta['WhiteFed'] = whiteFed;
    if (blackFed.isNotEmpty) meta['BlackFed'] = blackFed;
    // The game's own title tags are the title of the day: keep them.
    ChessTitleUtils.fillMissingTitleTags(
      meta,
      white: game.whitePlayer.title,
      black: game.blackPlayer.title,
    );
    if (game.whitePlayer.rating > 0) {
      meta['WhiteElo'] = game.whitePlayer.rating.toString();
    }
    if (game.blackPlayer.rating > 0) {
      meta['BlackElo'] = game.blackPlayer.rating.toString();
    }
    // Persist FIDE ids so color filters can identify each side. Broadcast and
    // gamebase PGNs often omit these headers.
    if (game.whitePlayer.fideId != null) {
      meta['WhiteFideId'] = game.whitePlayer.fideId.toString();
    }
    if (game.blackPlayer.fideId != null) {
      meta['BlackFideId'] = game.blackPlayer.fideId.toString();
    }
    if (game.eco != null && game.eco!.isNotEmpty) {
      meta['ECO'] = game.eco!;
    }
    if (game.openingName != null && game.openingName!.isNotEmpty) {
      meta['Opening'] = game.openingName!;
    }
    if (game.tourSlug != null && game.tourSlug!.isNotEmpty) {
      meta.putIfAbsent('Event', () => game.tourSlug!);
    }

    // Filter-relevant fields the raw PGN headers don't carry. The broadcast
    // time-control category ('standard'/'rapid'/'blitz') is distinct from the
    // PGN `TimeControl` increment string. Stored as strings to stay PGN-export
    // safe.
    if (game.timeControl != null && game.timeControl!.isNotEmpty) {
      meta['TcCategory'] = game.timeControl!;
    }
    meta['IsOnline'] = game.isOnline ? 'true' : 'false';

    return chessGame.copyWith(metadata: meta);
  }

  /// Removes a specific liked game by its saved-analysis id. Optimistic;
  /// reloads and returns `false` on failure so the caller can surface it.
  /// Removing a like is never gated.
  Future<bool> removeAnalysis(SavedAnalysis analysis) async {
    final op = Completer<void>();
    _removalOps.add(op.future);
    _localMutation++;
    try {
      return await _removeAnalysis(analysis);
    } finally {
      _localMutation++;
      _removalOps.remove(op.future);
      op.complete();
    }
  }

  Future<bool> _removeAnalysis(SavedAnalysis analysis) async {
    final list = List<SavedAnalysis>.from(state.valueOrNull ?? const [])
      ..removeWhere((a) => a.id == analysis.id);
    state = AsyncValue.data(list);
    try {
      final folder = await ref.read(likedGamesFolderProvider.future);
      await _repo.deleteSavedAnalysis(analysis.id, folderId: folder.id);
      _serverChanged();
      return true;
    } catch (e) {
      debugPrint('[LikedGames] removeAnalysis failed: $e');
      await _reload();
      return false;
    }
  }

  /// Sets the classification [tags] on the liked game identified by [likeId]
  /// (its `sourceGameId`). Only the `tags` column changes.
  ///
  /// Often called moments after a like, so the persisted row may not exist yet
  /// (the optimistic insert still carries a placeholder id). The write waits
  /// briefly for a row with a real id so the tag lands on the server record and
  /// survives the toggle's reconcile. No-op if the game isn't (or stops being)
  /// liked. Tagging is never gated.
  Future<bool> setTagsForLikeId(String likeId, List<String> tags) {
    _localMutation++;
    final normalized = _normalizeTags(tags);
    ref.read(likedGamePendingTagsProvider(likeId).notifier).state = normalized;
    _applyOptimisticTags(likeId, normalized);

    final previous = _tagWriteChains[likeId] ?? Future<bool>.value(true);
    final write = previous
        .catchError((Object _, StackTrace _) => false)
        .then((_) => _persistTagsForLikeId(likeId, normalized));

    _tagWriteChains[likeId] = write;
    unawaited(
      write.whenComplete(() {
        if (identical(_tagWriteChains[likeId], write)) {
          _tagWriteChains.remove(likeId);
        }
      }),
    );
    return write;
  }

  Future<bool> _persistTagsForLikeId(String likeId, List<String> tags) async {
    final target = await _waitForPersistedLike(likeId);
    if (target == null) {
      ref.read(likedGamePendingTagsProvider(likeId).notifier).state = null;
      return false;
    }

    try {
      final updated = await _repo.updateSavedAnalysisTags(
        analysisId: target.id,
        tags: tags,
      );
      _replaceAnalysis(updated);
      ref.read(likedGamePendingTagsProvider(likeId).notifier).state = null;
      return true;
    } catch (e) {
      debugPrint('[LikedGames] setTagsForLikeId failed: $e');
      await _reload();
      ref.read(likedGamePendingTagsProvider(likeId).notifier).state = null;
      return false;
    }
  }

  Future<SavedAnalysis?> _waitForPersistedLike(String likeId) async {
    // A like for this game may still be in flight: its row is inserted only
    // after a (possibly networked) PGN resolve. Wait for that toggle to settle
    // so the persisted row, with a real id, exists before tagging it. Without
    // this the early `!anyMatch` bail below fires and the tag is lost.
    final inFlightToggle = _toggleOps[likeId];
    if (inFlightToggle != null) {
      try {
        await inFlightToggle;
      } catch (_) {}
    }

    for (var attempt = 0; attempt < 12; attempt++) {
      final current = state.valueOrNull;
      if (current == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }

      final target = current.firstWhereOrNull(
        (a) => a.sourceGameId == likeId && a.id.isNotEmpty,
      );
      if (target != null) return target;
      // If the game isn't liked at all (no id-less placeholder either),
      // there's nothing to tag.
      final anyMatch = current.any((a) => a.sourceGameId == likeId);
      if (!anyMatch) return null;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    return (state.valueOrNull ?? const <SavedAnalysis>[]).firstWhereOrNull(
      (a) => a.sourceGameId == likeId && a.id.isNotEmpty,
    );
  }

  List<String> _normalizeTags(Iterable<String> tags) {
    return normalizeLikeTagLabels(tags);
  }

  bool _applyOptimisticTags(String likeId, List<String> tags) {
    final list = state.valueOrNull;
    if (list == null) return false;

    var changed = false;
    final now = DateTime.now();
    final updated = <SavedAnalysis>[
      for (final analysis in list)
        if (analysis.sourceGameId == likeId)
          () {
            changed = true;
            return analysis.copyWith(tags: tags, updatedAt: now);
          }()
        else
          analysis,
    ];
    if (changed) {
      state = AsyncValue.data(updated);
    }
    return changed;
  }

  void _replaceAnalysis(SavedAnalysis updated) {
    final list = state.valueOrNull;
    if (list == null) return;
    state = AsyncValue.data([
      for (final analysis in list)
        analysis.id == updated.id ? updated : analysis,
    ]);
  }

  Future<void> _reload() async {
    final next = await AsyncValue.guard(() async {
      final folder = await ref.read(likedGamesFolderProvider.future);
      return _repo.getSavedAnalyses(folderId: folder.id);
    });
    if (!next.hasError || !state.hasValue) state = next;
  }

  Future<void> refresh() => _reload();
}

/// Reactive check for whether a specific game is liked (by sourceGameId).
final isGameLikedProvider = Provider.family<bool, String>((ref, gameId) {
  if (ref.watch(isGameLikePendingProvider(gameId))) return true;
  final async = ref.watch(likedGamesProvider);
  return async.maybeWhen(
    data: (list) => list.any((a) => a.sourceGameId == gameId),
    orElse: () => false,
  );
});

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
