import 'dart:async';

import 'package:collection/collection.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Stores the base game model for each game, keyed by gameId.
/// Auto-disposes once no visible card/provider is observing the game.
final baseGameProvider = StateProvider.autoDispose
    .family<GamesTourModel?, String>((ref, gameId) => null);

/// Provider that combines the base game model with real-time updates from the stream.
/// This is used by game cards to show live updates without entering the game screen.
///
/// Keyed by gameId only (not baseGame) so that polling-triggered rebuilds of the
/// parent widget don't recreate the provider and disrupt the Supabase stream.
///
/// Multi-game surfaces should pass a shared game-id batch key for the
/// currently rendered context. Focused board views keep their single-game
/// stream; cards without an explicit/context key do not open hidden round-wide
/// subscriptions.
final liveGameCardProvider =
    AutoDisposeProvider.family<GamesTourModel?, String>((ref, gameId) {
      return _watchMergedLiveGame(
        ref: ref,
        params: LiveGameWatchParams(gameId: gameId),
        mode: _LiveGameMergeMode.full,
      );
    });

@immutable
class LiveGameWatchParams {
  const LiveGameWatchParams({
    required this.gameId,
    this.batchKey,
    this.streamEnabled = true,
  });

  final String gameId;
  final LiveGamesBatchKey? batchKey;
  final bool streamEnabled;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LiveGameWatchParams &&
            other.gameId == gameId &&
            other.batchKey == batchKey &&
            other.streamEnabled == streamEnabled;
  }

  @override
  int get hashCode => Object.hash(gameId, batchKey, streamEnabled);
}

/// Identifies one anomalous backward stream snapshot that needs an exact
/// server confirmation before replacing a retained live position.
@immutable
class LiveGameRegressionConfirmationKey {
  const LiveGameRegressionConfirmationKey({
    required this.gameId,
    required this.rejectedUpdate,
    required this.currentPgn,
    required this.currentFen,
    required this.currentLastMove,
    required this.currentLastMoveTime,
    required this.currentWhiteClockCentiseconds,
    required this.currentBlackClockCentiseconds,
    required this.currentWhiteClockSeconds,
    required this.currentBlackClockSeconds,
    required this.expectedWhitePlayer,
    required this.expectedBlackPlayer,
    required this.expectedGameStatus,
  });

  factory LiveGameRegressionConfirmationKey.from({
    required GamesTourModel current,
    required LiveGameUpdate rejectedUpdate,
    GamesTourModel? expectedCurrent,
  }) {
    final expected = expectedCurrent ?? current;
    return LiveGameRegressionConfirmationKey(
      gameId: current.gameId,
      rejectedUpdate: rejectedUpdate,
      currentPgn: current.pgn,
      currentFen: current.fen,
      currentLastMove: current.lastMove,
      currentLastMoveTime: current.lastMoveTime,
      currentWhiteClockCentiseconds: current.whiteClockCentiseconds,
      currentBlackClockCentiseconds: current.blackClockCentiseconds,
      currentWhiteClockSeconds: current.whiteClockSeconds,
      currentBlackClockSeconds: current.blackClockSeconds,
      expectedWhitePlayer: expected.whitePlayer,
      expectedBlackPlayer: expected.blackPlayer,
      expectedGameStatus: expected.gameStatus,
    );
  }

  final String gameId;
  final LiveGameUpdate rejectedUpdate;
  final String? currentPgn;
  final String? currentFen;
  final String? currentLastMove;
  final DateTime? currentLastMoveTime;
  final int currentWhiteClockCentiseconds;
  final int currentBlackClockCentiseconds;
  final int? currentWhiteClockSeconds;
  final int? currentBlackClockSeconds;
  final PlayerCard expectedWhitePlayer;
  final PlayerCard expectedBlackPlayer;
  final GameStatus expectedGameStatus;

  bool matchesCurrentPosition(GamesTourModel? game) {
    return game != null &&
        game.gameId == gameId &&
        game.pgn == currentPgn &&
        game.fen == currentFen &&
        game.lastMove == currentLastMove &&
        game.lastMoveTime == currentLastMoveTime &&
        game.whiteClockCentiseconds == currentWhiteClockCentiseconds &&
        game.blackClockCentiseconds == currentBlackClockCentiseconds &&
        game.whiteClockSeconds == currentWhiteClockSeconds &&
        game.blackClockSeconds == currentBlackClockSeconds &&
        game.whitePlayer == expectedWhitePlayer &&
        game.blackPlayer == expectedBlackPlayer &&
        game.gameStatus == expectedGameStatus;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LiveGameRegressionConfirmationKey &&
            other.gameId == gameId &&
            other.rejectedUpdate == rejectedUpdate &&
            other.currentPgn == currentPgn &&
            other.currentFen == currentFen &&
            other.currentLastMove == currentLastMove &&
            other.currentLastMoveTime == currentLastMoveTime &&
            other.currentWhiteClockCentiseconds ==
                currentWhiteClockCentiseconds &&
            other.currentBlackClockCentiseconds ==
                currentBlackClockCentiseconds &&
            other.currentWhiteClockSeconds == currentWhiteClockSeconds &&
            other.currentBlackClockSeconds == currentBlackClockSeconds &&
            other.expectedWhitePlayer == expectedWhitePlayer &&
            other.expectedBlackPlayer == expectedBlackPlayer &&
            other.expectedGameStatus == expectedGameStatus;
  }

  @override
  int get hashCode => Object.hash(
    gameId,
    rejectedUpdate,
    currentPgn,
    currentFen,
    currentLastMove,
    currentLastMoveTime,
    currentWhiteClockCentiseconds,
    currentBlackClockCentiseconds,
    currentWhiteClockSeconds,
    currentBlackClockSeconds,
    expectedWhitePlayer,
    expectedBlackPlayer,
    expectedGameStatus,
  );
}

/// Deduplicated exact-row confirmation shared by cards and the focused Board.
/// It runs only for a snapshot that would otherwise move a known position
/// backwards, so ordinary live moves never add REST traffic.
final liveGameRegressionConfirmationProvider = FutureProvider.autoDispose
    .family<LiveGameUpdate?, LiveGameRegressionConfirmationKey>((
      ref,
      key,
    ) async {
      var disposed = false;
      var lifecycleActive = ref.read(liveGameStreamingLifecycleProvider);
      Completer<void>? retryWaiter;
      Timer? retryTimer;
      void wakeRetryWaiter() {
        retryTimer?.cancel();
        retryTimer = null;
        final waiter = retryWaiter;
        retryWaiter = null;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      }

      void signalLifecycleChange() {
        wakeRetryWaiter();
      }

      Future<void> waitForRetrySignal({Duration? timeout}) {
        assert(retryWaiter == null && retryTimer == null);
        final waiter = Completer<void>();
        retryWaiter = waiter;
        if (timeout != null) {
          retryTimer = Timer(timeout, wakeRetryWaiter);
        }
        return waiter.future;
      }

      ref.listen<bool>(liveGameStreamingLifecycleProvider, (_, next) {
        lifecycleActive = next;
        signalLifecycleChange();
      });
      ref.onDispose(() {
        disposed = true;
        signalLifecycleChange();
      });
      final repository = ref.read(gameStreamRepositoryProvider);
      const retryDelays = <Duration>[
        Duration(milliseconds: 200),
        Duration(milliseconds: 600),
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 15),
      ];
      var attempt = 0;
      while (!disposed) {
        if (!lifecycleActive) {
          if (!disposed) {
            final resumedOrDisposed = waitForRetrySignal();
            // Lifecycle/disposal can change between the state check above and
            // installing the waiter. Re-check after installation so that an
            // already-delivered signal cannot strand this provider.
            if (disposed || lifecycleActive) wakeRetryWaiter();
            await resumedOrDisposed;
          }
          continue;
        }
        try {
          final current = await repository.fetchCurrentLiveGameUpdate(
            key.gameId,
          );
          if (current != null) return current;
        } catch (_) {
          // A transient exact-read failure must not permanently discard an
          // intentional takeback. Retry below with one shared, capped backoff
          // while the affected visible surface still retains this provider.
        }
        if (disposed) return null;
        final delayIndex =
            attempt < retryDelays.length ? attempt : retryDelays.length - 1;
        final delay = retryDelays[delayIndex];
        attempt++;
        final retryOrLifecycleChange = waitForRetrySignal(timeout: delay);
        // As above, close the check-to-listen gap. Pausing cancels the retry
        // delay immediately; resuming will start a fresh attempt from the top
        // of the loop without leaving a timer behind.
        if (disposed || !lifecycleActive) wakeRetryWaiter();
        await retryOrLifecycleChange;
      }
      return null;
    });

final scopedLiveGameCardProvider =
    AutoDisposeProvider.family<GamesTourModel?, LiveGameWatchParams>((
      ref,
      params,
    ) {
      return _watchMergedLiveGame(
        ref: ref,
        params: params,
        mode: _LiveGameMergeMode.full,
      );
    });

final liveGamePositionProvider =
    AutoDisposeProvider.family<GamesTourModel?, LiveGameWatchParams>((
      ref,
      params,
    ) {
      return _watchMergedLiveGame(
        ref: ref,
        params: params,
        mode: _LiveGameMergeMode.position,
      );
    });

final liveGameClockProvider =
    AutoDisposeProvider.family<GamesTourModel?, LiveGameWatchParams>((
      ref,
      params,
    ) {
      return _watchMergedLiveGame(
        ref: ref,
        params: params,
        mode: _LiveGameMergeMode.clock,
      );
    });

enum _LiveGameMergeMode { full, position, clock }

const int kLiveContextBatchSize = 25;

LiveGamesBatchKey? liveContextBatchKeyForGame({
  required GamesTourModel game,
  required List<GamesTourModel> contextGames,
  required String scopePrefix,
  int batchSize = kLiveContextBatchSize,
  bool includeFinishedGames = false,
}) {
  if (!_canRepresentLiveGame(game) ||
      (!includeFinishedGames && game.gameStatus.isFinished)) {
    return null;
  }
  return liveBatchKeysForGames(
    games: contextGames,
    scopePrefix: scopePrefix,
    batchSize: batchSize,
    includeFinishedGames: includeFinishedGames,
  )[game.gameId];
}

Map<String, LiveGamesBatchKey> liveBatchKeysForGames({
  required Iterable<GamesTourModel> games,
  required String scopePrefix,
  int batchSize = kLiveContextBatchSize,
  bool includeFinishedGames = false,
}) {
  final result = <String, LiveGamesBatchKey>{};
  if (batchSize <= 0) return result;

  final liveGames = games
      .where(
        (game) =>
            _canRepresentLiveGame(game) &&
            (includeFinishedGames || !game.gameStatus.isFinished),
      )
      .toList(growable: false);
  for (
    var chunkIndex = 0;
    chunkIndex * batchSize < liveGames.length;
    chunkIndex++
  ) {
    final start = chunkIndex * batchSize;
    final rawEnd = start + batchSize;
    final end = rawEnd > liveGames.length ? liveGames.length : rawEnd;
    final chunkGames = liveGames.sublist(start, end);
    if (chunkGames.isEmpty) continue;

    final key = LiveGamesBatchKey(
      scopeId:
          '$scopePrefix:$chunkIndex:${chunkGames.first.gameId}:${chunkGames.last.gameId}',
      gameIds: chunkGames.map((candidate) => candidate.gameId),
    );
    for (final game in chunkGames) {
      result[game.gameId] = key;
    }
  }
  return result;
}

GamesTourModel? _watchMergedLiveGame({
  required Ref ref,
  required LiveGameWatchParams params,
  required _LiveGameMergeMode mode,
}) {
  final baseGame = _watchBaseGame(ref, params.gameId, mode);
  if (baseGame == null) return null;
  final arrival = _watchLiveUpdate(ref, _resolveLiveWatchParams(params), mode);
  if (arrival == null) return baseGame;

  final mergedGame = _mergeLiveUpdate(
    baseGame: baseGame,
    update: arrival.update,
    mode: mode,
  );
  // A stream snapshot commonly equals the retained seed (initial select,
  // rebuild after write-back, or reconnect). Equality is not a regression and
  // must stay on the zero-REST fast path.
  if (!_hasLiveFieldChanges(baseGame, mergedGame)) return baseGame;

  final canUseWholeRow = shouldReplaceBaseGame(baseGame, mergedGame);
  LiveGameRegressionConfirmationKey? confirmedRegressionKey;
  late final GamesTourModel displayedGame;
  if (canUseWholeRow) {
    displayedGame = mergedGame;
  } else {
    // `SupabaseQueryBuilder.stream()` publishes full query snapshots and does
    // not expose whether an emission is a row mutation or an initial/reconnect
    // select. Arrival order therefore cannot safely distinguish a stale
    // snapshot from a legitimate takeback. Confirm only this anomalous
    // backward candidate with one exact current-row read.
    final safeMetadataGame = mergeIndependentLiveGameMetadata(
      baseGame,
      mergedGame,
    );
    final confirmationKey = LiveGameRegressionConfirmationKey.from(
      current: baseGame,
      rejectedUpdate: arrival.update,
      expectedCurrent: safeMetadataGame,
    );
    final confirmedUpdate =
        ref
            .watch(liveGameRegressionConfirmationProvider(confirmationKey))
            .valueOrNull;
    if (confirmedUpdate != null && confirmedUpdate.gameId == params.gameId) {
      displayedGame = _mergeLiveUpdate(
        baseGame: baseGame,
        update: confirmedUpdate,
        mode: mode,
      );
      confirmedRegressionKey = confirmationKey;
    } else {
      displayedGame = safeMetadataGame;
    }
  }
  if (_hasLiveFieldChanges(baseGame, displayedGame)) {
    _storeLatestBaseGame(
      ref,
      params.gameId,
      displayedGame,
      confirmedRegressionKey: confirmedRegressionKey,
      confirmedRegressionBaseline:
          confirmedRegressionKey == null ? null : baseGame,
    );
  }
  return displayedGame;
}

GamesTourModel? _watchBaseGame(
  Ref ref,
  String gameId,
  _LiveGameMergeMode mode,
) {
  return ref
      .watch(
        baseGameProvider(
          gameId,
        ).select((game) => _ProjectedBaseGame.forMode(game, mode)),
      )
      .game;
}

_LiveUpdateArrival? _watchLiveUpdate(
  Ref ref,
  LiveGameWatchParams params,
  _LiveGameMergeMode mode,
) {
  if (!params.streamEnabled || !ref.watch(shouldStreamProvider)) {
    return null;
  }

  final batchKey = params.batchKey;
  if (batchKey != null) {
    if (!batchKey.contains(params.gameId)) return null;
    final projectedArrivalAsync = ref.watch(
      gameUpdatesBatchArrivalStreamProvider(batchKey).select(
        (async) => async.whenData((arrival) {
          final update = arrival.value[params.gameId];
          return _ProjectedLiveGameUpdate.forMode(
            update == null ? null : _LiveUpdateArrival(update: update),
            mode,
          );
        }),
      ),
    );
    return projectedArrivalAsync.valueOrNull?.arrival;
  }
  return null;
}

@immutable
class _LiveUpdateArrival {
  const _LiveUpdateArrival({required this.update});

  final LiveGameUpdate update;
}

@immutable
class _ProjectedBaseGame {
  const _ProjectedBaseGame._({required this.game, required this.fields});

  factory _ProjectedBaseGame.forMode(
    GamesTourModel? game,
    _LiveGameMergeMode mode,
  ) {
    if (game == null) {
      return const _ProjectedBaseGame._(game: null, fields: <Object?>[null]);
    }

    return _ProjectedBaseGame._(
      game: game,
      fields: switch (mode) {
        _LiveGameMergeMode.position => <Object?>[
          game.gameId,
          game.whitePlayer,
          game.blackPlayer,
          game.pgn,
          game.fen,
          game.lastMove,
          game.lastMoveTime,
          game.gameStatus,
        ],
        _LiveGameMergeMode.clock => <Object?>[
          game.gameId,
          game.whitePlayer,
          game.blackPlayer,
          // Clock countdown depends on the live position, side-to-move, and
          // move timestamp. Keep this projection aligned with mobile so player
          // rows do not tick against a stale active side.
          game.pgn,
          game.fen,
          game.lastMove,
          game.lastMoveTime,
          game.whiteClockCentiseconds,
          game.blackClockCentiseconds,
          game.whiteClockSeconds,
          game.blackClockSeconds,
          game.gameStatus,
        ],
        _LiveGameMergeMode.full => <Object?>[game],
      },
    );
  }

  final GamesTourModel? game;
  final List<Object?> fields;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ProjectedBaseGame) return false;
    return _fieldsEqual(fields, other.fields);
  }

  @override
  int get hashCode => Object.hashAll(fields);
}

@immutable
class _ProjectedLiveGameUpdate {
  const _ProjectedLiveGameUpdate._({
    required this.arrival,
    required this.fields,
  });

  factory _ProjectedLiveGameUpdate.forMode(
    _LiveUpdateArrival? arrival,
    _LiveGameMergeMode mode,
  ) {
    if (arrival == null) {
      return const _ProjectedLiveGameUpdate._(
        arrival: null,
        fields: <Object?>[null],
      );
    }
    final update = arrival.update;

    return _ProjectedLiveGameUpdate._(
      arrival: arrival,
      fields: switch (mode) {
        _LiveGameMergeMode.position => <Object?>[
          update.gameId,
          _DeepFields(update.players),
          update.pgn,
          update.fen,
          update.lastMove,
          update.lastMoveTime,
          update.status,
        ],
        _LiveGameMergeMode.clock => <Object?>[
          update.gameId,
          _DeepFields(update.players),
          update.pgn,
          update.fen,
          update.lastMove,
          update.lastMoveTime,
          update.lastClockWhite,
          update.lastClockBlack,
          update.status,
        ],
        _LiveGameMergeMode.full => <Object?>[update],
      },
    );
  }

  final _LiveUpdateArrival? arrival;
  final List<Object?> fields;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ProjectedLiveGameUpdate) return false;
    return _fieldsEqual(fields, other.fields);
  }

  @override
  int get hashCode => Object.hashAll(fields);
}

bool _fieldsEqual(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

@immutable
class _DeepFields {
  const _DeepFields(this.value);

  static const DeepCollectionEquality _equality = DeepCollectionEquality();

  final Object? value;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _DeepFields && _equality.equals(value, other.value);
  }

  @override
  int get hashCode => _equality.hash(value);
}

bool shouldSubscribeToLiveGame(GamesTourModel game) {
  return _canRepresentLiveGame(game) && !game.gameStatus.isFinished;
}

bool _canRepresentLiveGame(GamesTourModel game) {
  return game.source == GameSource.supabase && game.gameId.isNotEmpty;
}

/// Merge a Supabase live-row update into a game model using the same
/// freshness rules as live tournament cards.
///
/// Desktop board tabs also subscribe to the current game's live stream. They
/// call this helper so the board, side rails, and any still-mounted game cards
/// share one coherent latest PGN/FEN/clock/status snapshot instead of each
/// surface carrying its own stale copy of the row.
GamesTourModel mergeLiveGameUpdateWithBase({
  required GamesTourModel baseGame,
  required LiveGameUpdate update,
}) {
  return _mergeLiveUpdate(
    baseGame: baseGame,
    update: update,
    mode: _LiveGameMergeMode.full,
  );
}

/// Whether [incoming] should replace the stored base-game snapshot for a game,
/// using the same freshness arbitration the live card merge applies before it
/// writes back to [baseGameProvider].
///
/// Desktop board surfaces share [baseGameProvider] with live cards. Two of them
/// used to write it *unconditionally*: the board's realtime row sync and the
/// open-tab `getGameById()` refresh. Both can carry a snapshot that is staler
/// than realtime already delivered (a one-shot REST read lags the stream; a
/// second channel can arrive out of order), so an unguarded write regressed the
/// card and the board to a stale position/clock. Routing those writes through
/// this predicate keeps the shared snapshot monotonically fresh.
bool shouldReplaceBaseGame(GamesTourModel? current, GamesTourModel incoming) =>
    _shouldUseIncomingGame(current, incoming, allowEqualFreshnessUpdate: true);

/// Selects the game snapshot to hand to a newly opened board.
///
/// A card can already hold a newer realtime position than a one-shot REST fetch,
/// while the REST fetch can carry a richer/full PGN than the card's list row.
/// This helper keeps navigation monotonic: use the incoming row only when it is
/// at least as fresh, or when it enriches PGN without moving the game backwards.
GamesTourModel selectFreshestNavigationGame({
  required GamesTourModel current,
  required GamesTourModel incoming,
}) {
  if (current.gameId != incoming.gameId) return current;
  if (_shouldUseIncomingGame(
    current,
    incoming,
    allowEqualFreshnessUpdate: true,
  )) {
    return incoming;
  }
  return _incomingHasRicherPgn(current, incoming) ? incoming : current;
}

GamesTourModel _mergeLiveUpdate({
  required GamesTourModel baseGame,
  required LiveGameUpdate update,
  required _LiveGameMergeMode mode,
}) {
  final includePosition =
      mode == _LiveGameMergeMode.full ||
      mode == _LiveGameMergeMode.position ||
      mode == _LiveGameMergeMode.clock;
  final includeClock =
      mode == _LiveGameMergeMode.full || mode == _LiveGameMergeMode.clock;
  final authoritativeFullRow = update.isFullRow;
  final livePlayers = _parseLivePlayerCards(
    update.players,
    baseWhite: baseGame.whitePlayer,
    baseBlack: baseGame.blackPlayer,
    authoritativeFullRow: authoritativeFullRow,
  );

  final mergedPgn =
      includePosition
          ? (authoritativeFullRow ? update.pgn : update.pgn ?? baseGame.pgn)
          : baseGame.pgn;
  final mergedLastMove =
      includePosition
          ? (authoritativeFullRow
              ? update.lastMove
              : update.lastMove ?? baseGame.lastMove)
          : baseGame.lastMove;
  final mergedStatus =
      includePosition || mode == _LiveGameMergeMode.clock
          ? _parseGameStatus(update.status, baseGame.gameStatus)
          : baseGame.gameStatus;
  final mergedFen =
      includePosition
          ? resolveFreshestGameFen(
            fen: authoritativeFullRow ? update.fen : update.fen ?? baseGame.fen,
            pgn: mergedPgn,
            lastMove: mergedLastMove,
          )
          : baseGame.fen;

  final normalizedWhiteClock =
      includeClock
          ? (authoritativeFullRow
              ? update.lastClockWhite?.round()
              : GamesTourModel.normalizeClockSeconds(
                clockSeconds: update.lastClockWhite?.round(),
                clockCentiseconds: baseGame.whiteClockCentiseconds,
              ))
          : baseGame.whiteClockSeconds;
  final normalizedBlackClock =
      includeClock
          ? (authoritativeFullRow
              ? update.lastClockBlack?.round()
              : GamesTourModel.normalizeClockSeconds(
                clockSeconds: update.lastClockBlack?.round(),
                clockCentiseconds: baseGame.blackClockCentiseconds,
              ))
          : baseGame.blackClockSeconds;
  final mergedLastMoveTime =
      includePosition
          ? (update.lastMoveTime == null
              ? (authoritativeFullRow ? null : baseGame.lastMoveTime)
              : DateTime.tryParse(update.lastMoveTime!))
          : baseGame.lastMoveTime;

  return baseGame.copyWith(
    whitePlayer: livePlayers?.white ?? baseGame.whitePlayer,
    blackPlayer: livePlayers?.black ?? baseGame.blackPlayer,
    whiteClockCentiseconds:
        includeClock
            ? (authoritativeFullRow
                ? livePlayers?.whiteClockCentiseconds ?? 0
                : livePlayers?.whiteClockCentiseconds ??
                    baseGame.whiteClockCentiseconds)
            : baseGame.whiteClockCentiseconds,
    blackClockCentiseconds:
        includeClock
            ? (authoritativeFullRow
                ? livePlayers?.blackClockCentiseconds ?? 0
                : livePlayers?.blackClockCentiseconds ??
                    baseGame.blackClockCentiseconds)
            : baseGame.blackClockCentiseconds,
    pgn: mergedPgn,
    clearPgn: includePosition && authoritativeFullRow && mergedPgn == null,
    fen: mergedFen,
    clearFen: includePosition && authoritativeFullRow && mergedFen == null,
    lastMove: mergedLastMove,
    clearLastMove:
        includePosition && authoritativeFullRow && mergedLastMove == null,
    lastMoveTime: mergedLastMoveTime,
    clearLastMoveTime:
        includePosition && authoritativeFullRow && mergedLastMoveTime == null,
    whiteClockSeconds: normalizedWhiteClock,
    clearWhiteClockSeconds:
        includeClock && authoritativeFullRow && normalizedWhiteClock == null,
    blackClockSeconds: normalizedBlackClock,
    clearBlackClockSeconds:
        includeClock && authoritativeFullRow && normalizedBlackClock == null,
    gameStatus: mergedStatus,
  );
}

GameStatus _parseGameStatus(String? status, GameStatus fallback) {
  final parsed = GameStatus.fromString(status);
  return parsed == GameStatus.unknown ? fallback : parsed;
}

/// Applies row fields whose correctness does not depend on position freshness.
///
/// A newly attached channel can initially return an older PGN/FEN snapshot
/// while still carrying a legitimate player correction or first terminal
/// result. Cards and the focused Board use this same merge so rejecting that
/// stale position never discards independent authoritative metadata.
GamesTourModel mergeIndependentLiveGameMetadata(
  GamesTourModel current,
  GamesTourModel incoming,
) {
  // Supabase does not identify reconnect/select rows versus mutations.
  // Players and results are unordered metadata too: a rejected stale position
  // can carry an older player pair, reopen a result, or swap terminal results.
  // Keep the complete retained snapshot until the exact current-row read
  // confirms the candidate.
  return current;
}

({
  PlayerCard white,
  PlayerCard black,
  int? whiteClockCentiseconds,
  int? blackClockCentiseconds,
})?
_parseLivePlayerCards(
  Object? raw, {
  required PlayerCard baseWhite,
  required PlayerCard baseBlack,
  required bool authoritativeFullRow,
}) {
  if (raw is! List || raw.length < 2) return null;
  try {
    final whiteRow = raw[0];
    final blackRow = raw[1];
    if (whiteRow is! Map || blackRow is! Map) return null;
    return (
      white: _mergeLivePlayerCard(
        baseWhite,
        Map<String, dynamic>.from(whiteRow),
        authoritativeFullRow: authoritativeFullRow,
      ),
      black: _mergeLivePlayerCard(
        baseBlack,
        Map<String, dynamic>.from(blackRow),
        authoritativeFullRow: authoritativeFullRow,
      ),
      whiteClockCentiseconds: _livePlayerClockCentiseconds(whiteRow),
      blackClockCentiseconds: _livePlayerClockCentiseconds(blackRow),
    );
  } catch (_) {
    // A malformed partial realtime payload must not erase the last complete
    // player pair already rendered by the card or focused Board.
    return null;
  }
}

int? _livePlayerClockCentiseconds(Map<dynamic, dynamic> row) {
  final value = row['clock'];
  final parsed = value is num ? value.toInt() : int.tryParse('$value');
  return parsed == null || parsed < 0 ? null : parsed;
}

PlayerCard _mergeLivePlayerCard(
  PlayerCard base,
  Map<String, dynamic> row, {
  required bool authoritativeFullRow,
}) {
  String? nonEmptyString(String key) {
    final value = row[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? positiveInt(String key, [String? alternateKey]) {
    final value = row[key] ?? (alternateKey == null ? null : row[alternateKey]);
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  final federation = nonEmptyString('fed') ?? base.federation;
  final customPointsValue = row['customPoints'] ?? row['custom_points'];
  final customPoints =
      customPointsValue is num ? customPointsValue.toDouble() : null;
  if (authoritativeFullRow) {
    final authoritativeFederation = nonEmptyString('fed') ?? '';
    return PlayerCard(
      // A malformed player object must not erase the only usable identity;
      // nullable/zero metadata fields remain authoritative clears.
      name: nonEmptyString('name') ?? base.name,
      federation: authoritativeFederation,
      title: nonEmptyString('title') ?? '',
      rating: positiveInt('rating') ?? 0,
      countryCode: authoritativeFederation,
      fideId: positiveInt('fideId', 'fide_id'),
      team: nonEmptyString('team'),
      gamebasePlayerId: base.gamebasePlayerId,
      customPoints: customPoints,
    );
  }
  return base.copyWith(
    name: nonEmptyString('name'),
    title: nonEmptyString('title'),
    rating: positiveInt('rating'),
    fideId: positiveInt('fideId', 'fide_id'),
    federation: federation,
    countryCode: federation.isNotEmpty ? federation : base.countryCode,
    team: nonEmptyString('team'),
    customPoints: customPoints,
  );
}

/// Helper that sets the base game and watches the live provider in one call.
/// Returns the live game data, falling back to the base game if not yet available.
GamesTourModel watchLiveGame(
  WidgetRef ref,
  GamesTourModel game, {
  LiveGamesBatchKey? batchKey,
  bool streamEnabled = true,
}) {
  final controller = ref.read(baseGameProvider(game.gameId).notifier);
  final current = controller.state;
  if (_shouldUseIncomingGame(current, game, allowEqualFreshnessUpdate: false)) {
    Future.microtask(() {
      if (!ref.context.mounted) return;
      try {
        if (_shouldUseIncomingGame(
          controller.state,
          game,
          allowEqualFreshnessUpdate: false,
        )) {
          controller.state = game;
        }
      } on StateError {
        // The card can be disposed while navigation is in flight.
      }
    });
  }
  final params = _liveWatchParamsForGame(
    game: game,
    batchKey: batchKey,
    streamEnabled: streamEnabled,
  );
  return ref.watch(scopedLiveGameCardProvider(params)) ?? game;
}

GamesTourModel watchLiveGamePosition(
  WidgetRef ref,
  GamesTourModel game, {
  LiveGamesBatchKey? batchKey,
  bool streamEnabled = true,
}) {
  _ensureBaseGame(ref, game);
  final params = _liveWatchParamsForGame(
    game: game,
    batchKey: batchKey,
    streamEnabled: streamEnabled,
  );
  return ref.watch(liveGamePositionProvider(params)) ?? game;
}

GamesTourModel watchLiveGameClock(
  WidgetRef ref,
  GamesTourModel game, {
  LiveGamesBatchKey? batchKey,
  bool streamEnabled = true,
}) {
  _ensureBaseGame(ref, game);
  final params = _liveWatchParamsForGame(
    game: game,
    batchKey: batchKey,
    streamEnabled: streamEnabled,
  );
  return ref.watch(liveGameClockProvider(params)) ?? game;
}

LiveGameWatchParams _liveWatchParamsForGame({
  required GamesTourModel game,
  required LiveGamesBatchKey? batchKey,
  required bool streamEnabled,
}) {
  final hasExplicitVisibleBatch = batchKey?.contains(game.gameId) ?? false;
  final canStream =
      _canRepresentLiveGame(game) &&
      (!game.gameStatus.isFinished || hasExplicitVisibleBatch);
  final resolvedBatchKey =
      canStream ? _resolveLiveBatchKey(game, batchKey) : null;
  return LiveGameWatchParams(
    gameId: game.gameId,
    batchKey: resolvedBatchKey,
    streamEnabled: streamEnabled && canStream && resolvedBatchKey != null,
  );
}

LiveGamesBatchKey? _resolveLiveBatchKey(
  GamesTourModel game,
  LiveGamesBatchKey? batchKey,
) {
  if (batchKey != null) return batchKey;
  return null;
}

LiveGameWatchParams _resolveLiveWatchParams(LiveGameWatchParams params) {
  // The host's canonical row decides batch membership. Do not unsubscribe the
  // leaf merely because Realtime just delivered a terminal status: broadcasts
  // commonly publish the result and final PGN/FEN in consecutive changes. The
  // parent snapshot will remove the key once it observes that terminal row;
  // until then the visible card must remain attached long enough to receive
  // final-move and result corrections.
  if (!params.streamEnabled || params.batchKey == null) {
    return LiveGameWatchParams(gameId: params.gameId, streamEnabled: false);
  }
  return params;
}

void _ensureBaseGame(WidgetRef ref, GamesTourModel game) {
  final controller = ref.read(baseGameProvider(game.gameId).notifier);
  final current = controller.state;
  if (!_shouldUseIncomingGame(
    current,
    game,
    allowEqualFreshnessUpdate: false,
  )) {
    return;
  }
  Future.microtask(() {
    if (!ref.context.mounted) return;
    try {
      if (_shouldUseIncomingGame(
        controller.state,
        game,
        allowEqualFreshnessUpdate: false,
      )) {
        controller.state = game;
      }
    } on StateError {
      // The card can be disposed while navigation is in flight.
    }
  });
}

void _storeLatestBaseGame(
  Ref ref,
  String gameId,
  GamesTourModel game, {
  required LiveGameRegressionConfirmationKey? confirmedRegressionKey,
  required GamesTourModel? confirmedRegressionBaseline,
}) {
  // Capture the controller while this provider build is current. Riverpod
  // invalidates `ref` as soon as a watched dependency changes; using that ref
  // from the write-back microtask would race the rebuild assertion. Reading
  // controller.state still gives us the commit-time snapshot needed for the
  // late-confirmation guard.
  final baseGameController = ref.read(baseGameProvider(gameId).notifier);
  Future.microtask(() {
    try {
      final current = baseGameController.state;
      final confirmedRegressionStillCurrent =
          confirmedRegressionKey != null &&
          (confirmedRegressionKey.matchesCurrentPosition(current) ||
              current == confirmedRegressionBaseline);
      if (confirmedRegressionStillCurrent ||
          (confirmedRegressionKey == null &&
              _shouldUseIncomingGame(
                current,
                game,
                allowEqualFreshnessUpdate: true,
              ))) {
        baseGameController.state = game;
      }
    } on StateError {
      // Provider/card was disposed while a stream event was being delivered.
    }
  });
}

bool _shouldUseIncomingGame(
  GamesTourModel? current,
  GamesTourModel incoming, {
  required bool allowEqualFreshnessUpdate,
}) {
  if (current == null) return true;
  if (current == incoming) return false;

  final currentTime = current.lastMoveTime;
  final incomingTime = incoming.lastMoveTime;
  if (currentTime != null && incomingTime != null) {
    if (incomingTime.isBefore(currentTime)) return false;
    if (incomingTime.isAfter(currentTime)) return true;
  } else if (currentTime != null && incomingTime == null) {
    return false;
  } else if (currentTime == null && incomingTime != null) {
    return true;
  }

  if (current.gameStatus == GameStatus.ongoing &&
      incoming.gameStatus != GameStatus.ongoing) {
    return true;
  }
  if (current.gameStatus != GameStatus.ongoing &&
      incoming.gameStatus == GameStatus.ongoing) {
    return false;
  }

  if ((current.lastMove?.isNotEmpty ?? false) &&
      (incoming.lastMove == null || incoming.lastMove!.isEmpty)) {
    return false;
  }

  if (!_hasPositionFieldChanges(current, incoming)) {
    if (!allowEqualFreshnessUpdate ||
        !_hasLiveFieldChanges(current, incoming)) {
      return false;
    }
    // Same-position player/result changes are unordered and need exact
    // confirmation. Clock-only updates can use the fast path when every known
    // value moves monotonically down (including a canonical zero); an upward
    // correction is valid but similarly ambiguous and is confirmed exactly.
    if (current.whitePlayer != incoming.whitePlayer ||
        current.blackPlayer != incoming.blackPlayer ||
        current.gameStatus != incoming.gameStatus) {
      return false;
    }
    return _clockChangesAreMonotonic(current, incoming);
  }

  final currentPly = _knownPly(current);
  final incomingPly = _knownPly(incoming);
  if (currentPly != null && incomingPly != null) {
    if (incomingPly < currentPly) return false;
    if (incomingPly > currentPly) return true;
  } else if (currentPly != null && incomingPly == null) {
    return false;
  } else if (currentPly == null && incomingPly != null) {
    return true;
  }

  // Equal-time/equal-ply positional divergence is ambiguous: Supabase table
  // streams do not label reconnect snapshots versus mutations, and arbiters
  // can correct a move without bumping `last_move_time`. Route this case
  // through exact-row confirmation instead of trusting arrival order.
  return false;
}

bool _hasPositionFieldChanges(GamesTourModel current, GamesTourModel incoming) {
  return current.pgn != incoming.pgn ||
      current.fen != incoming.fen ||
      current.lastMove != incoming.lastMove ||
      current.lastMoveTime != incoming.lastMoveTime;
}

bool _hasLiveFieldChanges(GamesTourModel current, GamesTourModel incoming) {
  return current.whitePlayer != incoming.whitePlayer ||
      current.blackPlayer != incoming.blackPlayer ||
      current.pgn != incoming.pgn ||
      current.fen != incoming.fen ||
      current.lastMove != incoming.lastMove ||
      current.lastMoveTime != incoming.lastMoveTime ||
      current.whiteClockCentiseconds != incoming.whiteClockCentiseconds ||
      current.blackClockCentiseconds != incoming.blackClockCentiseconds ||
      current.whiteClockSeconds != incoming.whiteClockSeconds ||
      current.blackClockSeconds != incoming.blackClockSeconds ||
      current.gameStatus != incoming.gameStatus;
}

bool _clockChangesAreMonotonic(
  GamesTourModel current,
  GamesTourModel incoming,
) {
  bool doesNotIncrease(int? previous, int? next) {
    if (previous == next) return true;
    if (next == null) return false;
    return previous == null || next <= previous;
  }

  return doesNotIncrease(
        current.whiteClockCentiseconds,
        incoming.whiteClockCentiseconds,
      ) &&
      doesNotIncrease(
        current.blackClockCentiseconds,
        incoming.blackClockCentiseconds,
      ) &&
      doesNotIncrease(current.whiteClockSeconds, incoming.whiteClockSeconds) &&
      doesNotIncrease(current.blackClockSeconds, incoming.blackClockSeconds);
}

bool _incomingHasRicherPgn(GamesTourModel current, GamesTourModel incoming) {
  final incomingPgnLength = incoming.pgn?.trim().length ?? 0;
  final currentPgnLength = current.pgn?.trim().length ?? 0;
  if (incomingPgnLength <= currentPgnLength) return false;

  final currentTime = current.lastMoveTime;
  final incomingTime = incoming.lastMoveTime;
  if (currentTime != null &&
      incomingTime != null &&
      incomingTime.isBefore(currentTime)) {
    return false;
  }

  final currentPly = _knownPly(current);
  final incomingPly = _knownPly(incoming);
  if (currentPly != null && incomingPly != null && incomingPly < currentPly) {
    return false;
  }
  if (currentPly != null && incomingPly == null) return false;

  return true;
}

int? _knownPly(GamesTourModel game) {
  final pgnPly = resolveFinalPositionFromPgn(game.pgn)?.moveCount;
  final fenPly = plyFromFen(game.fen);
  if (pgnPly == null) return fenPly;
  if (fenPly == null) return pgnPly;
  return pgnPly > fenPly ? pgnPly : fenPly;
}
