import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';

const double _standardDownloadPhaseSpan = 0.45;
const double _standardImportPhaseStart = 0.45;
const double _standardImportPhaseSpan = 0.50;
const double _chessEverDownloadPhaseSpan = 0.40;
const double _chessEverImportPhaseStart = 0.40;
const double _chessEverImportPhaseSpan = 0.55;
const Duration _downloadedStatsRepairTimeout = Duration(seconds: 8);

@immutable
class PlayerWorkspaceState {
  const PlayerWorkspaceState({
    this.players = const <PlayerWorkspacePlayer>[],
    this.selectedPlayerId,
    this.isLoading = false,
    this.error,
    this.operations = const <String, PlayerWorkspaceOperation>{},
    this.removals = const <String, PlayerWorkspaceRemoval>{},
  });

  final List<PlayerWorkspacePlayer> players;
  final String? selectedPlayerId;
  final bool isLoading;
  final String? error;
  final Map<String, PlayerWorkspaceOperation> operations;

  /// Players whose teardown is in flight, keyed by player id. A present entry
  /// means the row should render as removing (spinner + progress) rather than
  /// disappear, until its cache purge finishes.
  final Map<String, PlayerWorkspaceRemoval> removals;

  PlayerWorkspacePlayer? get selectedPlayer {
    final id = selectedPlayerId;
    if (id == null) return null;
    for (final player in players) {
      if (player.id == id) return player;
    }
    return null;
  }

  PlayerWorkspaceState copyWith({
    List<PlayerWorkspacePlayer>? players,
    String? selectedPlayerId,
    bool clearSelectedPlayerId = false,
    bool? isLoading,
    String? error,
    bool clearError = false,
    Map<String, PlayerWorkspaceOperation>? operations,
    Map<String, PlayerWorkspaceRemoval>? removals,
  }) {
    return PlayerWorkspaceState(
      players: players ?? this.players,
      selectedPlayerId:
          clearSelectedPlayerId
              ? null
              : (selectedPlayerId ?? this.selectedPlayerId),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      operations: operations ?? this.operations,
      removals: removals ?? this.removals,
    );
  }
}

final playerWorkspaceRepositoryProvider = Provider<PlayerWorkspaceRepository>(
  (ref) => PlayerWorkspaceRepository(
    gamebaseRepository: ref.watch(gamebaseRepositoryProvider),
  ),
);

typedef PlayerWorkspaceLocalDatabaseRegistrar =
    Future<void> Function(
      List<String> paths, {
      required Map<String, LocalLibraryEntryMetadata> metadataByPath,
    });

typedef PlayerWorkspaceLocalDatabaseUnregistrar =
    Future<void> Function(String path);

typedef PlayerWorkspaceLocalDatabasePlayerUnregistrar =
    Future<void> Function(String playerId, {required Iterable<String> paths});

final playerWorkspaceProvider =
    StateNotifierProvider<PlayerWorkspaceNotifier, PlayerWorkspaceState>((ref) {
      return PlayerWorkspaceNotifier(
        workspaceRepository: ref.watch(playerWorkspaceRepositoryProvider),
        gamebaseRepository: ref.watch(gamebaseRepositoryProvider),
        localRepository: ref.watch(localChessDatabaseRepositoryProvider),
        localDatabaseRegistrar:
            (paths, {required metadataByPath}) => ref
                .read(localLibraryRegistryProvider.notifier)
                .registerAll(paths, metadataByPath: metadataByPath),
        localDatabaseUnregistrar:
            (path) => ref
                .read(localLibraryRegistryProvider.notifier)
                .unregister(path),
        localDatabasePlayerUnregistrar:
            (playerId, {required paths}) => ref
                .read(localLibraryRegistryProvider.notifier)
                .unregisterPlayerWorkspace(playerId, paths: paths),
      );
    });

class _PlayerWorkspaceOperationScope {
  _PlayerWorkspaceOperationScope({
    required this.playerId,
    required this.key,
    required this.token,
  });

  final String playerId;
  final String key;
  final OperationCancellationToken token;
  final done = Completer<void>();

  void cancel() => token.cancel();

  void complete() {
    if (!done.isCompleted) done.complete();
  }
}

class PlayerWorkspaceNotifier extends StateNotifier<PlayerWorkspaceState> {
  PlayerWorkspaceNotifier({
    required PlayerWorkspaceRepository workspaceRepository,
    required GamebaseRepository gamebaseRepository,
    required LocalChessDatabaseRepository localRepository,
    PlayerWorkspaceLocalDatabaseRegistrar? localDatabaseRegistrar,
    PlayerWorkspaceLocalDatabaseUnregistrar? localDatabaseUnregistrar,
    PlayerWorkspaceLocalDatabasePlayerUnregistrar?
    localDatabasePlayerUnregistrar,
  }) : _workspaceRepository = workspaceRepository,
       _gamebaseRepository = gamebaseRepository,
       _localRepository = localRepository,
       _localDatabaseRegistrar = localDatabaseRegistrar,
       _localDatabaseUnregistrar = localDatabaseUnregistrar,
       _localDatabasePlayerUnregistrar = localDatabasePlayerUnregistrar,
       super(const PlayerWorkspaceState(isLoading: true)) {
    _initialLoadFuture = load();
  }

  final PlayerWorkspaceRepository _workspaceRepository;
  final GamebaseRepository _gamebaseRepository;
  final LocalChessDatabaseRepository _localRepository;
  final PlayerWorkspaceLocalDatabaseRegistrar? _localDatabaseRegistrar;
  final PlayerWorkspaceLocalDatabaseUnregistrar? _localDatabaseUnregistrar;
  final PlayerWorkspaceLocalDatabasePlayerUnregistrar?
  _localDatabasePlayerUnregistrar;
  var _combinedRebuildGeneration = 0;
  final Set<String> _activeAccountSyncOperationKeys = <String>{};
  final Set<String> _pendingCombinedRebuildPlayerIds = <String>{};
  final Map<String, _PlayerWorkspaceOperationScope> _operationScopes =
      <String, _PlayerWorkspaceOperationScope>{};
  final Set<String> _deletedPlayerIds = <String>{};
  late final Future<void> _initialLoadFuture;
  bool _isDrainingCombinedRebuilds = false;
  int _repairGeneration = 0;
  final List<Timer> _repairTimeoutTimers = <Timer>[];

  @override
  void dispose() {
    _repairGeneration++;
    for (final timer in _repairTimeoutTimers) {
      timer.cancel();
    }
    _repairTimeoutTimers.clear();
    unawaited(cancelAllOperations());
    super.dispose();
  }

  Future<void> cancelAllOperations({
    Duration timeout = const Duration(seconds: 8),
  }) {
    final scopes = _operationScopes.values.toList(growable: false);
    for (final scope in scopes) {
      scope.cancel();
    }
    _activeAccountSyncOperationKeys.clear();
    _pendingCombinedRebuildPlayerIds.clear();
    _combinedRebuildGeneration++;
    if (state.operations.isNotEmpty) {
      state = state.copyWith(
        operations: const <String, PlayerWorkspaceOperation>{},
      );
    }
    return _waitForScopes(scopes, timeout: timeout);
  }

  Future<void> cancelAccountOperation(
    PlayerWorkspaceAccount account, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final existing = _matchingAccount(player, account);
    if (existing == null) return;
    final operationKey = _accountOperationKey(existing);
    final scopes = _cancelOperation(operationKey);
    _activeAccountSyncOperationKeys.remove(operationKey);
    await _waitForScopes(scopes, timeout: timeout);
  }

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final snapshot = await _workspaceRepository.loadSnapshot();
      state = PlayerWorkspaceState(
        players: snapshot.players,
        selectedPlayerId: snapshot.selectedPlayerId,
      );
      await _repairPersistedDownloadedStatsBestEffort();
      await _registerPlayersGeneratedDatabasesBestEffort(state.players);
      await _rebuildSelectedCombinedIfStaleBestEffort();
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Could not load Player workspace: $error',
      );
    }
  }

  Future<List<GamebasePlayer>> searchChessEverPlayers(String query) {
    return _workspaceRepository.searchChessEverPlayers(
      _gamebaseRepository,
      query,
    );
  }

  /// Adds a free-text prep target and returns its new player id so callers can
  /// open it and chain straight into connecting online usernames.
  Future<String> addManualPlayer(String name) async {
    final player = _workspaceRepository.manualPlayer(name);
    await _upsertPlayer(player, select: false);
    return player.id;
  }

  /// Adds a ChessEver-indexed player and returns its new player id (see
  /// [addManualPlayer]).
  Future<String> addChessEverPlayer(GamebasePlayer gamebasePlayer) async {
    final existing = _canonicalChessEverPlayer(gamebasePlayer);
    if (existing != null) {
      await selectPlayer(existing.id);
      return existing.id;
    }
    final player = _workspaceRepository.playerFromChessEver(gamebasePlayer);
    await _upsertPlayer(player, select: false);
    return player.id;
  }

  /// Attaches one or more already-fetched external accounts (validated up front
  /// by the connect-usernames dialog) to the selected player in a single write.
  ///
  /// This is the batch counterpart to [connectExternalAccount]: the dialog
  /// verifies each username against Lichess/Chess.com as it is typed, so here we
  /// only append the confirmed accounts — no re-fetch, no per-error placeholder.
  /// Sources that can't carry a username ([PlayerWorkspaceSource.chessever],
  /// [PlayerWorkspaceSource.manual], [PlayerWorkspaceSource.combined]) are
  /// skipped. Returns how many accounts were attached.
  Future<int> attachFetchedAccounts(
    List<PlayerWorkspaceAccount> accounts,
  ) async {
    if (accounts.isEmpty) return 0;
    final player = state.selectedPlayer;
    if (player == null) return 0;
    final latest = _latestPlayer(player);
    final knownIdentityKeys = <String>{
      for (final account in latest.allAccounts) account.identityKey,
    };
    final newAccounts = <PlayerWorkspaceAccount>[];
    for (final account in accounts) {
      if (!_isExternalPlayerAccountSource(account.source)) continue;
      _ensureExternalAccountCanAttach(account, playerId: latest.id);
      if (!knownIdentityKeys.add(account.identityKey)) continue;
      newAccounts.add(account);
    }
    if (newAccounts.isEmpty) return 0;
    var updated = latest;
    for (final account in newAccounts) {
      updated = updated.withAccount(account);
    }
    await _upsertPlayer(updated, select: true);
    return newAccounts.length;
  }

  Future<void> connectChessEverPlayer(GamebasePlayer gamebasePlayer) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final lockedFideId = _normalizedPlayerFideId(player.fideId);
    final incomingFideId = _normalizedPlayerFideId(gamebasePlayer.fideId);
    if (lockedFideId != null && incomingFideId != lockedFideId) {
      throw StateError(
        'This player workspace is locked to FIDE $lockedFideId. '
        '${gamebasePlayer.titleAndName} has '
        '${incomingFideId == null ? 'no FIDE id' : 'FIDE $incomingFideId'}, '
        'so create a separate player profile instead.',
      );
    }
    final gamebasePlayerWorkspace = _workspaceRepository.playerFromChessEver(
      gamebasePlayer,
    );
    final account = gamebasePlayerWorkspace.account(
      PlayerWorkspaceSource.chessever,
    );
    if (account == null) return;
    await _upsertPlayer(
      player
          .copyWith(
            chesseverPlayerId: gamebasePlayer.id,
            fideId: incomingFideId ?? player.fideId,
            country: gamebasePlayer.fed,
            title: gamebasePlayer.title,
          )
          .withAccount(account),
      select: true,
    );
  }

  /// Reconnects the only ChessEver identity permitted by this workspace and
  /// immediately downloads its games. FIDE-less workspaces intentionally keep
  /// using the searchable connect dialog instead.
  Future<void> reconnectLockedChessEverSource() async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final lockedFideId = _normalizedPlayerFideId(player.fideId);
    if (lockedFideId == null) {
      throw StateError(
        'ChessEver automatic reconnect requires a locked FIDE ID.',
      );
    }
    final existing = player.account(PlayerWorkspaceSource.chessever);
    if (existing != null) {
      await syncAccount(existing);
      return;
    }

    const source = PlayerWorkspaceSource.chessever;
    final operationKey = _sourceOperationKey(source);
    _setOperation(
      operationKey,
      source,
      'Finding ChessEver player for FIDE $lockedFideId...',
      null,
    );
    try {
      final match = await _workspaceRepository.findChessEverPlayerByFideId(
        _gamebaseRepository,
        lockedFideId,
      );
      if (match == null) {
        throw StateError(
          'No ChessEver player was found for FIDE $lockedFideId.',
        );
      }
      if (state.selectedPlayer?.id != player.id) return;
      await connectChessEverPlayer(match);
    } finally {
      _clearOperation(operationKey);
    }

    if (state.selectedPlayer?.id != player.id) return;
    final connected = state.selectedPlayer?.account(source);
    if (connected == null) {
      throw StateError('ChessEver player could not be connected.');
    }
    await syncAccount(connected);
  }

  Future<void> selectPlayer(String playerId) async {
    if (!state.players.any((player) => player.id == playerId)) return;
    state = state.copyWith(selectedPlayerId: playerId);
    await _persist();
    await _rebuildSelectedCombinedIfStaleBestEffort();
  }

  Future<void> _rebuildSelectedCombinedIfStaleBestEffort() async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final combinedPath = player.combinedPgnPath?.trim();
    if (combinedPath == null || combinedPath.isEmpty) return;
    if (await _workspaceRepository.isCombinedDatabaseCurrent(combinedPath)) {
      return;
    }
    var hasReadableSource = false;
    for (final account in player.allAccounts) {
      final path = account.pgnPath?.trim();
      if (path == null || path.isEmpty) continue;
      if (await _fileExistsBestEffort(path)) {
        hasReadableSource = true;
        break;
      }
    }
    if (!hasReadableSource) return;
    try {
      await _rebuildCombinedDatabaseForPlayer(player);
    } catch (_) {
      // The rebuild path already exposes its error in state. Keep the last
      // readable Combined file available rather than failing workspace load.
    }
  }

  Future<void> renamePlayer(String playerId, String displayName) async {
    final clean = displayName.trim();
    if (clean.isEmpty) throw ArgumentError('Player name is required.');
    var found = false;
    PlayerWorkspacePlayer? renamedPlayer;
    final players =
        state.players.map((player) {
            if (player.id != playerId) return player;
            found = true;
            renamedPlayer = player.copyWith(displayName: clean);
            return renamedPlayer!;
          }).toList()
          ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    if (!found) return;
    state = state.copyWith(
      players: List.unmodifiable(players),
      isLoading: false,
      clearError: true,
    );
    await _persist();
    final updated = renamedPlayer;
    if (updated != null) {
      await _registerPlayerGeneratedDatabasesBestEffort(updated);
    }
  }

  Future<void> removePlayer(String playerId) async {
    final index = state.players.indexWhere((player) => player.id == playerId);
    if (index < 0) return;
    final player = state.players[index];
    _deletedPlayerIds.add(playerId);
    _pendingCombinedRebuildPlayerIds.remove(playerId);
    _combinedRebuildGeneration++;
    final canceledScopes = _cancelPlayerOperations(playerId);
    final remaining = <PlayerWorkspacePlayer>[
      for (final candidate in state.players)
        if (candidate.id != playerId) candidate,
    ];
    if (remaining.length == state.players.length) return;
    final removedSelected = state.selectedPlayerId == playerId;

    // Keep the row on screen with a removing indicator instead of yanking it
    // optimistically. The cache purge below can run for seconds when a player
    // owns several downloaded sources, and a silent disappear-then-jank reads
    // as a freeze. The *persisted* snapshot, however, drops the player right
    // now so a crash mid-purge can never resurrect a half-deleted player.
    state = state.copyWith(
      clearSelectedPlayerId: removedSelected,
      isLoading: false,
      clearError: true,
      operations:
          removedSelected
              ? const <String, PlayerWorkspaceOperation>{}
              : _operationsWithoutPlayer(playerId),
      removals: <String, PlayerWorkspaceRemoval>{
        ...state.removals,
        playerId: const PlayerWorkspaceRemoval(),
      },
    );
    await _workspaceRepository.saveSnapshot(
      PlayerWorkspaceSnapshot(
        players: remaining,
        selectedPlayerId: state.selectedPlayerId,
      ),
    );
    await _waitForScopes(canceledScopes);
    try {
      await _deletePlayerGeneratedData(
        player,
        onProgress: (progress) => _updateRemovalProgress(playerId, progress),
      );
    } finally {
      _finishRemoval(playerId);
    }
  }

  void _updateRemovalProgress(
    String playerId,
    LocalChessScanProgress progress,
  ) {
    if (!mounted) return;
    final current = state.removals[playerId];
    if (current == null) return;
    state = state.copyWith(
      removals: <String, PlayerWorkspaceRemoval>{
        ...state.removals,
        playerId: current.copyWith(
          message: progress.message,
          progress: progress.fraction,
        ),
      },
    );
  }

  void _finishRemoval(String playerId) {
    if (!mounted) return;
    final stillListed = state.players.any((p) => p.id == playerId);
    final stillRemoving = state.removals.containsKey(playerId);
    if (!stillListed && !stillRemoving) return;
    final removals = <String, PlayerWorkspaceRemoval>{...state.removals}
      ..remove(playerId);
    state = state.copyWith(
      players: List.unmodifiable(<PlayerWorkspacePlayer>[
        for (final candidate in state.players)
          if (candidate.id != playerId) candidate,
      ]),
      removals: removals,
    );
  }

  Future<void> syncDeletedLibraryPlayerFolder(
    String playerId, {
    Iterable<String> deletedPaths = const <String>[],
  }) async {
    await _waitForInitialLoadIfNeeded();
    final clean = playerId.trim();
    final player =
        clean.isEmpty
            ? _playerForGeneratedPaths(deletedPaths)
            : _playerById(clean) ?? _playerForGeneratedPaths(deletedPaths);
    if (player == null) return;
    await _removePlayerAfterExternalLibraryDelete(
      player,
      deletedPaths: deletedPaths,
    );
  }

  Future<void> syncDeletedLibraryDatabasePath(
    String path, {
    String? playerId,
  }) async {
    await _waitForInitialLoadIfNeeded();
    final cleanPath = path.trim();
    if (cleanPath.isEmpty) return;
    await _unregisterPlayerDatabasePathBestEffort(cleanPath);
    final requestedPlayer =
        playerId == null || playerId.trim().isEmpty
            ? null
            : _playerById(playerId.trim());
    final playerCandidates =
        requestedPlayer == null
            ? state.players
            : <PlayerWorkspacePlayer>[requestedPlayer];
    for (final candidate in playerCandidates) {
      final latest = _latestPlayer(candidate);
      if (_pathMatches(latest.combinedPgnPath, cleanPath)) {
        await _clearCombinedDatabaseAfterExternalLibraryDelete(
          latest,
          cleanPath,
        );
        return;
      }
      final account = _accountForGeneratedPath(latest, cleanPath);
      if (account == null) continue;
      await _removeAccountAfterExternalLibraryDelete(latest, account);
      return;
    }
  }

  Future<void> connectExternalAccount({
    required PlayerWorkspaceSource source,
    required String username,
  }) async {
    if (source == PlayerWorkspaceSource.chessever ||
        source == PlayerWorkspaceSource.manual ||
        source == PlayerWorkspaceSource.combined) {
      return;
    }
    final player = state.selectedPlayer;
    if (player == null) return;
    _ensureExternalAccountCanAttach(
      PlayerWorkspaceAccount(source: source, username: username.trim()),
      playerId: player.id,
    );
    final operationKey = _sourceOperationKey(source);
    _setOperation(
      operationKey,
      source,
      'Fetching ${source.label} profile...',
      null,
    );
    late final PlayerWorkspaceAccount account;
    try {
      account = switch (source) {
        PlayerWorkspaceSource.lichess => await _workspaceRepository
            .fetchLichessAccount(username),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .fetchChessComAccount(username),
        PlayerWorkspaceSource.chessever ||
        PlayerWorkspaceSource.manual ||
        PlayerWorkspaceSource
            .combined => throw StateError('Unsupported account source.'),
      };
    } catch (error) {
      _clearOperation(operationKey);
      await _upsertPlayer(
        _latestPlayer(player).withAccount(
          PlayerWorkspaceAccount(
            source: source,
            username: username.trim(),
            error: error.toString(),
          ),
        ),
        select: true,
      );
      rethrow;
    }
    try {
      _ensureExternalAccountCanAttach(account, playerId: player.id);
      await _upsertPlayer(
        _latestPlayer(player).withAccount(account),
        select: true,
      );
    } finally {
      _clearOperation(operationKey);
    }
  }

  Future<void> editExternalAccount({
    required PlayerWorkspaceAccount account,
    required String username,
  }) async {
    if (account.source != PlayerWorkspaceSource.lichess &&
        account.source != PlayerWorkspaceSource.chesscom) {
      throw StateError('Only online usernames can be edited here.');
    }
    final player = state.selectedPlayer;
    if (player == null) return;
    final existing = _matchingAccount(player, account);
    if (existing == null) return;
    _ensureExternalAccountCanAttach(
      PlayerWorkspaceAccount(
        source: existing.source,
        username: username.trim(),
      ),
      playerId: player.id,
    );

    final source = existing.source;
    final operationKey = _accountOperationKey(existing);
    _setOperation(
      operationKey,
      source,
      'Fetching ${source.label} profile...',
      null,
    );
    late final PlayerWorkspaceAccount fetched;
    try {
      fetched = switch (source) {
        PlayerWorkspaceSource.lichess => await _workspaceRepository
            .fetchLichessAccount(username),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .fetchChessComAccount(username),
        PlayerWorkspaceSource.chessever ||
        PlayerWorkspaceSource.manual ||
        PlayerWorkspaceSource
            .combined => throw StateError('Unsupported account source.'),
      };
    } catch (error) {
      _clearOperation(operationKey);
      final latest = state.selectedPlayer ?? player;
      await _upsertPlayer(
        latest.withAccount(existing.copyWith(error: error.toString())),
        select: true,
      );
      rethrow;
    }
    try {
      _ensureExternalAccountCanAttach(fetched, playerId: player.id);
    } catch (_) {
      _clearOperation(operationKey);
      rethrow;
    }
    try {
      final sameIdentity =
          fetched.identityKey == existing.identityKey ||
          fetched.username.trim().toLowerCase() ==
              existing.username.trim().toLowerCase();
      final nextAccount =
          sameIdentity
              ? fetched.copyWith(
                pgnPath: existing.pgnPath,
                lastSyncAtMs: existing.lastSyncAtMs,
                availableGameCount: _maxGameCount(<int>[
                  fetched.availableGameCount,
                  existing.availableGameCount,
                  existing.gameCount,
                ]),
                gameCount: existing.gameCount,
                newGameCount: existing.newGameCount,
                winCount: existing.winCount,
                drawCount: existing.drawCount,
                lossCount: existing.lossCount,
                clearError: true,
              )
              : fetched;
      final latestBeforeEdit = _latestPlayer(player);
      if (!sameIdentity) {
        await _deleteCombinedGeneratedData(latestBeforeEdit);
        await _deleteAccountGeneratedData(existing);
      }
      final latest = latestBeforeEdit.withoutAccountEntry(existing);
      await _upsertPlayer(latest.withAccount(nextAccount), select: true);
      _clearOperation(operationKey);
      if (!sameIdentity) await rebuildCombinedDatabase();
    } catch (error) {
      _clearOperation(operationKey);
      final latest = state.selectedPlayer ?? player;
      await _upsertPlayer(
        latest.withAccount(existing.copyWith(error: error.toString())),
        select: true,
      );
      rethrow;
    }
  }

  Future<void> refreshAccount(PlayerWorkspaceSource source) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    if (source == PlayerWorkspaceSource.combined) {
      await rebuildCombinedDatabase();
      return;
    }
    final account = player.account(source);
    if (account == null) {
      throw StateError('${source.label} is not connected.');
    }
    await refreshAccountEntry(account);
  }

  Future<void> refreshAccountEntry(PlayerWorkspaceAccount account) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final existing = _matchingAccount(player, account);
    if (existing == null) return;
    final source = existing.source;
    if (source == PlayerWorkspaceSource.manual) {
      throw StateError('Manual PGN imports do not have online stats.');
    }
    final operationKey = _accountOperationKey(existing);
    _setOperation(
      operationKey,
      source,
      'Refreshing ${source.label} stats...',
      null,
    );
    try {
      final fetched = switch (source) {
        PlayerWorkspaceSource.lichess => await _workspaceRepository
            .fetchLichessAccount(existing.username),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .fetchChessComAccount(existing.username),
        PlayerWorkspaceSource.chessever => await _refreshChessEverAccount(
          player,
          existing,
        ),
        PlayerWorkspaceSource.manual =>
          throw StateError('Manual PGN imports do not have online stats.'),
        PlayerWorkspaceSource.combined =>
          throw StateError('Combined database has no source profile.'),
      };
      final preserveDownloadedStats = existing.hasDownloadedGames;
      final nextAccount = fetched.copyWith(
        pgnPath: existing.pgnPath,
        lastSyncAtMs: existing.lastSyncAtMs,
        availableGameCount: _maxGameCount(<int>[
          fetched.availableGameCount,
          fetched.gameCount,
          existing.availableGameCount,
          existing.gameCount,
        ]),
        gameCount:
            preserveDownloadedStats ? existing.gameCount : fetched.gameCount,
        newGameCount: existing.newGameCount,
        winCount:
            preserveDownloadedStats ? existing.winCount : fetched.winCount,
        drawCount:
            preserveDownloadedStats ? existing.drawCount : fetched.drawCount,
        lossCount:
            preserveDownloadedStats ? existing.lossCount : fetched.lossCount,
        clearError: true,
      );
      final latest = _latestPlayer(player);
      final refreshedPlayer =
          source == PlayerWorkspaceSource.chessever
              ? latest.copyWith(
                chesseverPlayerId:
                    nextAccount.externalId ?? latest.chesseverPlayerId,
                country: nextAccount.country,
                title: nextAccount.title,
              )
              : latest;
      await _upsertPlayer(
        refreshedPlayer.withAccount(nextAccount),
        select: true,
      );
      _clearOperation(operationKey);
    } catch (error) {
      _clearOperation(operationKey);
      final latest = state.selectedPlayer ?? player;
      await _upsertPlayer(
        latest.withAccount(existing.copyWith(error: error.toString())),
        select: true,
      );
      rethrow;
    }
  }

  Future<void> removeAccount(PlayerWorkspaceSource source) async {
    if (source == PlayerWorkspaceSource.combined) return;
    final player = state.selectedPlayer;
    if (player == null) return;
    final accounts = player.accountsFor(source);
    if (accounts.isEmpty) return;
    for (final account in accounts) {
      await removeAccountEntry(account);
    }
  }

  Future<void> removeAccountEntry(PlayerWorkspaceAccount account) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final existing = _matchingAccount(player, account);
    if (existing == null) return;
    final operationKey = _accountOperationKey(existing);
    final canceledScopes = _cancelOperation(operationKey);
    _setOperation(
      operationKey,
      existing.source,
      'Deleting local source files...',
      null,
    );
    try {
      await _waitForScopes(canceledScopes);
      final latest = _latestPlayer(player);
      await _deleteCombinedGeneratedData(latest);
      await _deleteAccountGeneratedData(existing);
      final nextPlayer = _latestPlayer(player).withoutAccountEntry(existing);
      await _upsertPlayer(nextPlayer, select: true);
      _clearOperation(operationKey);
      if (_playerHasSourcePgns(nextPlayer)) {
        await rebuildCombinedDatabase();
      }
    } catch (_) {
      _clearOperation(operationKey);
      rethrow;
    }
  }

  Future<void> syncSource(PlayerWorkspaceSource source) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    if (source == PlayerWorkspaceSource.combined) {
      await rebuildCombinedDatabase();
      return;
    }
    final account = player.account(source);
    if (account == null) {
      throw StateError('${source.label} is not connected.');
    }
    await syncAccount(account);
  }

  Future<void> reinstallAccount(PlayerWorkspaceAccount account) {
    return syncAccount(account, reinstall: true);
  }

  Future<void> syncAccount(
    PlayerWorkspaceAccount account, {
    bool reinstall = false,
  }) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final existing = _matchingAccount(player, account);
    if (existing == null) return;
    final source = existing.source;
    if (source == PlayerWorkspaceSource.manual) {
      throw StateError('Use Import PGN to add more manual games.');
    }
    final operationKey = _accountOperationKey(existing);
    _cancelCombinedRebuildForPlayer(player.id);
    final scope = _startOperationScope(player.id, operationKey);
    _activeAccountSyncOperationKeys.add(operationKey);
    _setOperation(
      operationKey,
      source,
      reinstall
          ? 'Preparing ${source.label} reinstall...'
          : 'Preparing ${source.label} sync...',
      0,
    );
    var sourceChanged = false;
    Object? caughtError;
    StackTrace? caughtStackTrace;
    try {
      scope.token.throwIfCanceled();
      final latestStoredGameDate =
          reinstall ? null : await _latestStoredGameDate(existing);
      scope.token.throwIfCanceled();
      final sinceMs = _sinceMsFromGameDate(latestStoredGameDate);
      final downloaded = switch (source) {
        PlayerWorkspaceSource.lichess => await _workspaceRepository
            .downloadLichessGames(
              username: existing.username,
              sinceMs: sinceMs,
              expectedGameCount: _expectedDownloadGameCount(
                existing,
                reinstall: reinstall,
              ),
              onProgress:
                  (message, progress) => _setScopedOperationPhaseProgress(
                    scope,
                    operationKey,
                    source,
                    message,
                    progress,
                    start: 0,
                    span: _standardDownloadPhaseSpan,
                  ),
              cancellationToken: scope.token,
            ),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .downloadChessComGames(
              username: existing.username,
              sinceMs: sinceMs,
              onProgress:
                  (message, progress) => _setScopedOperationPhaseProgress(
                    scope,
                    operationKey,
                    source,
                    message,
                    progress,
                    start: 0,
                    span: _standardDownloadPhaseSpan,
                  ),
              cancellationToken: scope.token,
            ),
        PlayerWorkspaceSource.chessever => await _workspaceRepository
            .downloadChessEverGames(
              repository: _gamebaseRepository,
              playerId: existing.externalId ?? player.chesseverPlayerId ?? '',
              fideId: player.fideId,
              sinceDate: latestStoredGameDate,
              expectedGameCount: _expectedChessEverDownloadGameCount(existing),
              onProgress:
                  (message, progress) => _setScopedOperationPhaseProgress(
                    scope,
                    operationKey,
                    source,
                    message,
                    progress,
                    start: 0,
                    span: _chessEverDownloadPhaseSpan,
                  ),
              cancellationToken: scope.token,
            ),
        PlayerWorkspaceSource.manual =>
          throw StateError('Use Import PGN to add more manual games.'),
        PlayerWorkspaceSource.combined =>
          throw StateError('Combined database is built from source databases.'),
      };

      scope.token.throwIfCanceled();
      if (!reinstall &&
          await _canSkipUnchangedRemoteImport(
            existing: existing,
            downloaded: downloaded,
          )) {
        _setScopedOperation(
          scope,
          operationKey,
          source,
          '${source.label} is already current.',
          1,
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        final nextAccount = existing.copyWith(
          lastSyncAtMs: now,
          availableGameCount: _maxGameCount(<int>[
            existing.availableGameCount,
            existing.gameCount,
            downloaded.gameCount,
          ]),
          clearError: true,
        );
        final latest = _latestPlayer(player);
        if (_isPlayerDeleted(player.id)) return;
        final nextPlayer = latest.withAccount(nextAccount);
        await _upsertPlayer(nextPlayer, select: true);
        if (!_scopeCanUpdateOperation(scope) || _isPlayerDeleted(player.id)) {
          return;
        }
        _clearOperationForScope(scope);
      } else {
        final importPhaseStart =
            source == PlayerWorkspaceSource.chessever
                ? _chessEverImportPhaseStart
                : _standardImportPhaseStart;
        final importPhaseSpan =
            source == PlayerWorkspaceSource.chessever
                ? _chessEverImportPhaseSpan
                : _standardImportPhaseSpan;
        _setScopedOperation(
          scope,
          operationKey,
          source,
          'Importing ${source.label} games...',
          importPhaseStart,
        );
        final path = await _workspaceRepository.sourcePgnPath(
          playerId: player.id,
          playerName: player.displayName,
          fideId: player.fideId,
          source: source,
          username: existing.username,
        );
        scope.token.throwIfCanceled();
        final imported = await _workspaceRepository.mergeIntoLocalDatabase(
          localRepository: _localRepository,
          path: path,
          sourceLabel: '${player.displayName} ${source.label}',
          pgn: downloaded.pgn,
          playerAliases: _aliasesFor(player, account),
          playerFideId: player.fideId,
          replaceExisting: reinstall || downloaded.replaceExistingSource,
          onProgress:
              (message, progress) => _setScopedOperationPhaseProgress(
                scope,
                operationKey,
                source,
                message,
                progress,
                start: importPhaseStart,
                span: importPhaseSpan,
              ),
          cancellationToken: scope.token,
        );
        scope.token.throwIfCanceled();
        if (!_scopeCanUpdateOperation(scope) || _isPlayerDeleted(player.id)) {
          return;
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        final nextAccount = existing.copyWith(
          pgnPath: imported.path,
          lastSyncAtMs: now,
          availableGameCount: _maxGameCount(<int>[
            existing.availableGameCount,
            existing.gameCount,
            downloaded.gameCount,
            imported.stats.gameCount,
          ]),
          gameCount: imported.stats.gameCount,
          newGameCount: imported.stats.newGameCount,
          winCount: imported.stats.winCount,
          drawCount: imported.stats.drawCount,
          lossCount: imported.stats.lossCount,
          clearError: true,
        );
        final latest = _latestPlayer(player);
        if (_isPlayerDeleted(player.id)) return;
        final nextPlayer = latest.withAccount(nextAccount);
        await _upsertPlayer(nextPlayer, select: true);
        if (!_scopeCanUpdateOperation(scope) || _isPlayerDeleted(player.id)) {
          return;
        }
        unawaited(
          _registerPlayerDatabasePathBestEffort(
            player: nextPlayer,
            source: source,
            path: imported.path,
            gameCount: imported.stats.gameCount,
            indexedAtMs: now,
          ),
        );
        _clearOperationForScope(scope);
        sourceChanged = true;
      }
    } catch (error, stackTrace) {
      _clearOperationForScope(scope);
      if (isOperationCanceled(error) || _isPlayerDeleted(player.id)) {
        caughtError = null;
        caughtStackTrace = null;
      } else {
        final latest = state.selectedPlayer ?? player;
        await _upsertPlayer(
          latest.withAccount(existing.copyWith(error: error.toString())),
          select: true,
        );
        caughtError = error;
        caughtStackTrace = stackTrace;
      }
    } finally {
      if (_scopeOwnsOperationKey(scope)) {
        _activeAccountSyncOperationKeys.remove(operationKey);
        if (sourceChanged && !_isPlayerDeleted(player.id)) {
          _pendingCombinedRebuildPlayerIds.add(player.id);
        }
      }
      _finishOperationScope(scope);
    }

    if (_activeAccountSyncOperationKeys.isEmpty &&
        !_isPlayerDeleted(player.id)) {
      try {
        await _drainPendingCombinedRebuilds();
      } catch (error, stackTrace) {
        caughtError ??= error;
        caughtStackTrace ??= stackTrace;
      }
    }

    if (caughtError != null) {
      Error.throwWithStackTrace(caughtError, caughtStackTrace!);
    }
  }

  Future<bool> _canSkipUnchangedRemoteImport({
    required PlayerWorkspaceAccount existing,
    required PlayerWorkspaceDownloadedPgn downloaded,
  }) async {
    if (!downloaded.remoteUnchanged) return false;
    final path = existing.pgnPath;
    if (path == null || path.trim().isEmpty) return false;
    if (existing.gameCount < downloaded.gameCount) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> importManualPgn({
    required String label,
    required String pgn,
  }) async {
    final cleanLabel = label.trim().isEmpty ? 'Manual PGN' : label.trim();
    await _importManualDownloadedPgn(
      label: cleanLabel,
      downloaded: PlayerWorkspaceDownloadedPgn(
        source: PlayerWorkspaceSource.manual,
        pgn: pgn,
        gameCount: countPgnGames(pgn),
      ),
    );
  }

  Future<void> importManualPgnPaths({required List<String> paths}) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final cleanLabel = localChessDatabaseDisplayNameForPaths(paths);
    const source = PlayerWorkspaceSource.manual;
    final operationKey = _sourceOperationKey(source);
    _cancelCombinedRebuildForPlayer(player.id);
    final scope = _startOperationScope(player.id, operationKey);
    _setOperation(operationKey, source, 'Scanning manual PGN...', null);
    try {
      final downloaded = await _workspaceRepository.readManualPgnPaths(
        paths: paths,
        cancellationToken: scope.token,
        onProgress:
            (message, progress) =>
                _setOperation(operationKey, source, message, progress),
      );
      scope.token.throwIfCanceled();
      await _importManualDownloadedPgn(
        label: cleanLabel,
        downloaded: downloaded,
        existingScope: scope,
      );
    } catch (error) {
      _clearOperation(operationKey);
      if (!isOperationCanceled(error)) rethrow;
    } finally {
      _finishOperationScope(scope);
      if (!_hasActiveSourceOperations(player.id)) {
        await _drainPendingCombinedRebuilds();
      }
    }
  }

  Future<void> _importManualDownloadedPgn({
    required String label,
    required PlayerWorkspaceDownloadedPgn downloaded,
    _PlayerWorkspaceOperationScope? existingScope,
  }) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    const source = PlayerWorkspaceSource.manual;
    final operationKey = _sourceOperationKey(source);
    final scope =
        existingScope ?? _startOperationScope(player.id, operationKey);
    _setOperation(operationKey, source, 'Importing manual PGN...', null);
    final account = PlayerWorkspaceAccount(
      source: source,
      username: label,
      displayName: label,
      availableGameCount: downloaded.gameCount,
    );
    var importedSuccessfully = false;
    try {
      scope.token.throwIfCanceled();
      final path = await _workspaceRepository.sourcePgnPath(
        playerId: player.id,
        playerName: player.displayName,
        fideId: player.fideId,
        source: source,
        username: label,
      );
      scope.token.throwIfCanceled();
      final imported = await _workspaceRepository.mergeIntoLocalDatabase(
        localRepository: _localRepository,
        path: path,
        sourceLabel: '${player.displayName} $label',
        pgn: downloaded.pgn,
        playerAliases: _aliasesFor(player, account),
        playerFideId: player.fideId,
        onProgress:
            (message, progress) =>
                _setOperation(operationKey, source, message, progress),
        cancellationToken: scope.token,
      );
      scope.token.throwIfCanceled();
      final now = DateTime.now().millisecondsSinceEpoch;
      final nextAccount = account.copyWith(
        pgnPath: imported.path,
        lastSyncAtMs: now,
        availableGameCount: imported.stats.gameCount,
        gameCount: imported.stats.gameCount,
        newGameCount: imported.stats.newGameCount,
        winCount: imported.stats.winCount,
        drawCount: imported.stats.drawCount,
        lossCount: imported.stats.lossCount,
        clearError: true,
      );
      if (_isPlayerDeleted(player.id)) return;
      final nextPlayer = _latestPlayer(player).withAccount(nextAccount);
      await _upsertPlayer(nextPlayer, select: true);
      unawaited(
        _registerPlayerDatabasePathBestEffort(
          player: nextPlayer,
          source: source,
          path: imported.path,
          gameCount: imported.stats.gameCount,
          indexedAtMs: now,
        ),
      );
      _clearOperation(operationKey);
      _pendingCombinedRebuildPlayerIds.add(player.id);
      importedSuccessfully = true;
    } catch (error) {
      _clearOperation(operationKey);
      if (!isOperationCanceled(error) && !_isPlayerDeleted(player.id)) {
        await _upsertPlayer(
          _latestPlayer(
            player,
          ).withAccount(account.copyWith(error: error.toString())),
          select: true,
        );
        rethrow;
      }
    } finally {
      if (existingScope == null) _finishOperationScope(scope);
    }
    if (importedSuccessfully &&
        !_isPlayerDeleted(player.id) &&
        !_hasActiveSourceOperations(player.id)) {
      await _drainPendingCombinedRebuilds();
    }
  }

  Future<void> rebuildCombinedDatabase() async {
    final player = state.selectedPlayer;
    if (player == null) return;
    if (_hasActiveSourceOperations(player.id)) {
      _pendingCombinedRebuildPlayerIds.add(player.id);
      _setOperation(
        _sourceOperationKey(PlayerWorkspaceSource.combined),
        PlayerWorkspaceSource.combined,
        'Waiting for source imports to finish...',
        null,
      );
      return;
    }
    await _rebuildCombinedDatabaseForPlayer(player);
  }

  Future<void> _drainPendingCombinedRebuilds() async {
    if (_isDrainingCombinedRebuilds) return;
    _isDrainingCombinedRebuilds = true;
    try {
      while (_activeAccountSyncOperationKeys.isEmpty &&
          _pendingCombinedRebuildPlayerIds.isNotEmpty) {
        final playerIds = _pendingCombinedRebuildPlayerIds.toList(
          growable: false,
        );
        _pendingCombinedRebuildPlayerIds.clear();
        for (final playerId in playerIds) {
          if (_activeAccountSyncOperationKeys.isNotEmpty) {
            _pendingCombinedRebuildPlayerIds.add(playerId);
            continue;
          }
          final player = _playerById(playerId);
          if (player == null) continue;
          await _rebuildCombinedDatabaseForPlayer(player);
        }
      }
    } finally {
      _isDrainingCombinedRebuilds = false;
    }
  }

  Future<void> _rebuildCombinedDatabaseForPlayer(
    PlayerWorkspacePlayer player,
  ) async {
    if (_isPlayerDeleted(player.id)) return;
    if (_hasActiveSourceOperations(player.id)) {
      _pendingCombinedRebuildPlayerIds.add(player.id);
      return;
    }
    final combinedSources = player.allAccounts
        .where((account) => account.pgnPath?.trim().isNotEmpty == true)
        .map(
          (account) => PlayerWorkspaceCombinedSource(
            path: account.pgnPath!.trim(),
            source: account.source,
          ),
        )
        .toList(growable: false);
    if (combinedSources.isEmpty) return;
    const source = PlayerWorkspaceSource.combined;
    final generation = ++_combinedRebuildGeneration;
    final operationKey = _sourceOperationKey(source);
    final scope = _startOperationScope(player.id, operationKey);
    _setOperation(
      operationKey,
      source,
      'Combining and deduplicating games...',
      null,
    );
    try {
      scope.token.throwIfCanceled();
      final result = await _workspaceRepository.rebuildCombinedDatabase(
        localRepository: _localRepository,
        playerId: player.id,
        playerName: player.displayName,
        playerFideId: player.fideId,
        sourcePaths: combinedSources.map((source) => source.path),
        sources: combinedSources,
        playerAliases: _aliasesFor(player, null),
        onProgress:
            (message, progress) =>
                _setOperation(operationKey, source, message, progress),
        cancellationToken: scope.token,
      );
      scope.token.throwIfCanceled();
      if (generation != _combinedRebuildGeneration) return;
      if (_isPlayerDeleted(player.id)) return;
      final latest = state.players.firstWhere(
        (candidate) => candidate.id == player.id,
        orElse: () => player,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final nextPlayer = latest.copyWith(
        combinedPgnPath: result.path,
        combinedGameCount: result.stats.gameCount,
        combinedWinCount: result.stats.winCount,
        combinedDrawCount: result.stats.drawCount,
        combinedLossCount: result.stats.lossCount,
        combinedBuiltAtMs: now,
      );
      await _upsertPlayer(nextPlayer, select: true);
      await _registerPlayerDatabasePathBestEffort(
        player: nextPlayer,
        source: source,
        path: result.path,
        gameCount: result.stats.gameCount,
        indexedAtMs: now,
      );
      _clearOperation(operationKey);
    } catch (error) {
      if (generation != _combinedRebuildGeneration) return;
      _clearOperation(operationKey);
      if (isOperationCanceled(error) || _isPlayerDeleted(player.id)) return;
      state = state.copyWith(
        error: 'Could not build combined database: $error',
      );
      rethrow;
    } finally {
      _finishOperationScope(scope);
    }
  }

  Future<PlayerWorkspaceAccount> _refreshChessEverAccount(
    PlayerWorkspacePlayer owner,
    PlayerWorkspaceAccount account,
  ) async {
    final playerId = account.externalId?.trim();
    if (playerId == null || playerId.isEmpty) {
      throw StateError('ChessEver player id is unavailable.');
    }
    final player = await _gamebaseRepository.getPlayerById(playerId);
    if (player == null) {
      throw StateError('ChessEver player was not found.');
    }
    final lockedFideId = _normalizedPlayerFideId(owner.fideId);
    final fetchedFideId = _normalizedPlayerFideId(player.fideId);
    if (lockedFideId != null && fetchedFideId != lockedFideId) {
      throw StateError(
        'This player workspace is locked to FIDE $lockedFideId. '
        '${player.titleAndName} resolved from ChessEver as '
        '${fetchedFideId == null ? 'no FIDE id' : 'FIDE $fetchedFideId'}, '
        'so refresh was blocked to protect this player profile.',
      );
    }
    final workspacePlayer = _workspaceRepository.playerFromChessEver(player);
    final refreshed = workspacePlayer.account(PlayerWorkspaceSource.chessever);
    if (refreshed == null) {
      throw StateError('ChessEver profile could not be refreshed.');
    }
    return refreshed;
  }

  Future<void> _upsertPlayer(
    PlayerWorkspacePlayer player, {
    required bool select,
  }) async {
    if (_isPlayerDeleted(player.id)) return;
    final players = <PlayerWorkspacePlayer>[
      for (final existing in state.players)
        if (existing.id != player.id) existing,
      player,
    ]..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    state = state.copyWith(
      players: List.unmodifiable(players),
      selectedPlayerId: select ? player.id : state.selectedPlayerId,
      isLoading: false,
      clearError: true,
    );
    await _persist();
  }

  Future<void> _persist() async {
    await _workspaceRepository.saveSnapshot(
      PlayerWorkspaceSnapshot(
        players: state.players,
        selectedPlayerId: state.selectedPlayerId,
      ),
    );
  }

  PlayerWorkspacePlayer _latestPlayer(PlayerWorkspacePlayer fallback) {
    return _playerById(fallback.id) ?? fallback;
  }

  PlayerWorkspacePlayer? _canonicalChessEverPlayer(GamebasePlayer player) {
    final fideId = _normalizedPlayerFideId(player.fideId);
    if (fideId != null) {
      for (final candidate in state.players) {
        if (_normalizedPlayerFideId(candidate.fideId) == fideId) {
          return candidate;
        }
      }
    }

    final chessEverPlayerId = _normalizedPlayerExternalId(player.id);
    if (chessEverPlayerId == null) return null;
    for (final candidate in state.players) {
      if (_normalizedPlayerExternalId(candidate.chesseverPlayerId) ==
          chessEverPlayerId) {
        return candidate;
      }
      for (final account in candidate.accountsFor(
        PlayerWorkspaceSource.chessever,
      )) {
        if (_normalizedPlayerExternalId(account.externalId) ==
            chessEverPlayerId) {
          return candidate;
        }
      }
    }
    return null;
  }

  void _ensureExternalAccountCanAttach(
    PlayerWorkspaceAccount account, {
    required String playerId,
  }) {
    if (!_isExternalPlayerAccountSource(account.source)) return;
    for (final candidate in state.players) {
      if (candidate.id == playerId) continue;
      final ownsIdentity = candidate
          .accountsFor(account.source)
          .any((existing) => existing.identityKey == account.identityKey);
      if (!ownsIdentity) continue;
      final username = account.username.trim();
      final accountDescription =
          username.isEmpty
              ? '${account.source.label} account'
              : '${account.source.label} account "$username"';
      final ownerFideId = _normalizedPlayerFideId(candidate.fideId);
      final ownerDescription =
          '"${candidate.displayName}"'
          '${ownerFideId == null ? '' : ' (FIDE $ownerFideId)'}';
      throw StateError(
        'The $accountDescription is already attached to $ownerDescription. '
        'Open that player workspace to manage it.',
      );
    }
  }

  PlayerWorkspacePlayer? _playerById(String playerId) {
    for (final candidate in state.players) {
      if (candidate.id == playerId) return candidate;
    }
    return null;
  }

  bool _isPlayerDeleted(String playerId) =>
      _deletedPlayerIds.contains(playerId);

  bool _hasActiveSourceOperations(String playerId) {
    return _operationScopes.values.any(
      (scope) =>
          scope.playerId == playerId &&
          scope.key != _sourceOperationKey(PlayerWorkspaceSource.combined),
    );
  }

  void _cancelCombinedRebuildForPlayer(String playerId) {
    final key = _sourceOperationKey(PlayerWorkspaceSource.combined);
    final scope = _operationScopes[key];
    if (scope == null || scope.playerId != playerId) return;
    _combinedRebuildGeneration++;
    scope.cancel();
    _clearOperation(key);
  }

  _PlayerWorkspaceOperationScope _startOperationScope(
    String playerId,
    String key,
  ) {
    final previous = _operationScopes[key];
    previous?.cancel();
    final scope = _PlayerWorkspaceOperationScope(
      playerId: playerId,
      key: key,
      token: OperationCancellationToken(),
    );
    _operationScopes[key] = scope;
    return scope;
  }

  void _finishOperationScope(_PlayerWorkspaceOperationScope scope) {
    if (identical(_operationScopes[scope.key], scope)) {
      _operationScopes.remove(scope.key);
    }
    scope.complete();
  }

  List<_PlayerWorkspaceOperationScope> _cancelPlayerOperations(
    String playerId,
  ) {
    final scopes = <_PlayerWorkspaceOperationScope>[
      for (final scope in _operationScopes.values)
        if (scope.playerId == playerId) scope,
    ];
    for (final scope in scopes) {
      scope.cancel();
      _clearOperation(scope.key);
    }
    return scopes;
  }

  List<_PlayerWorkspaceOperationScope> _cancelOperation(String key) {
    final scope = _operationScopes[key];
    if (scope == null) return const <_PlayerWorkspaceOperationScope>[];
    scope.cancel();
    _clearOperation(key);
    return <_PlayerWorkspaceOperationScope>[scope];
  }

  Future<void> _waitForScopes(
    List<_PlayerWorkspaceOperationScope> scopes, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (scopes.isEmpty) return;
    try {
      await Future.wait<void>(
        scopes.map((scope) => scope.done.future),
      ).timeout(timeout);
    } on TimeoutException {
      // Deletion and app close must continue even if a third-party request does
      // not observe cancellation promptly. Late writes are still ignored by the
      // deleted-player guard.
    }
  }

  Map<String, PlayerWorkspaceOperation> _operationsWithoutPlayer(
    String playerId,
  ) {
    if (state.operations.isEmpty) return state.operations;
    final blockedKeys = <String>{
      for (final scope in _operationScopes.values)
        if (scope.playerId == playerId) scope.key,
    };
    if (blockedKeys.isEmpty) return state.operations;
    return Map.unmodifiable(<String, PlayerWorkspaceOperation>{
      for (final entry in state.operations.entries)
        if (!blockedKeys.contains(entry.key)) entry.key: entry.value,
    });
  }

  PlayerWorkspaceAccount? _matchingAccount(
    PlayerWorkspacePlayer player,
    PlayerWorkspaceAccount account,
  ) {
    for (final candidate in _latestPlayer(player).accountsFor(account.source)) {
      if (candidate.identityKey == account.identityKey) return candidate;
    }
    return null;
  }

  PlayerWorkspaceAccount? _accountForGeneratedPath(
    PlayerWorkspacePlayer player,
    String path,
  ) {
    for (final account in _latestPlayer(player).allAccounts) {
      if (_pathMatches(account.pgnPath, path)) return account;
    }
    return null;
  }

  PlayerWorkspacePlayer? _playerForGeneratedPaths(Iterable<String> paths) {
    final canonicalPaths =
        paths
            .map(_canonicalWorkspacePath)
            .where((path) => path.isNotEmpty)
            .toSet();
    if (canonicalPaths.isEmpty) return null;
    for (final player in state.players) {
      for (final path in _generatedDatabasePaths(player)) {
        if (canonicalPaths.contains(_canonicalWorkspacePath(path))) {
          return player;
        }
      }
    }
    return null;
  }

  Future<void> _removePlayerAfterExternalLibraryDelete(
    PlayerWorkspacePlayer player, {
    Iterable<String> deletedPaths = const <String>[],
  }) async {
    if (_isPlayerDeleted(player.id)) return;
    _deletedPlayerIds.add(player.id);
    _pendingCombinedRebuildPlayerIds.remove(player.id);
    _combinedRebuildGeneration++;
    final canceledScopes = _cancelPlayerOperations(player.id);
    final players = <PlayerWorkspacePlayer>[
      for (final candidate in state.players)
        if (candidate.id != player.id) candidate,
    ];
    if (players.length == state.players.length) return;
    final removedSelected = state.selectedPlayerId == player.id;
    state = state.copyWith(
      players: List.unmodifiable(players),
      clearSelectedPlayerId: removedSelected,
      isLoading: false,
      clearError: true,
      operations:
          removedSelected
              ? const <String, PlayerWorkspaceOperation>{}
              : _operationsWithoutPlayer(player.id),
    );
    await _persist();
    await _waitForScopes(canceledScopes);
    await _unregisterPlayerWorkspaceBestEffort(
      player,
      extraPaths: <String>{
        ..._generatedDatabasePaths(player),
        for (final path in deletedPaths)
          if (path.trim().isNotEmpty) path.trim(),
      },
    );
    for (final path in _generatedDatabasePaths(player)) {
      await _deleteGeneratedDatabasePathBestEffort(path);
    }
    await _deletePlayerWorkspaceDirectoryBestEffort(player.id);
  }

  Future<void> _removeAccountAfterExternalLibraryDelete(
    PlayerWorkspacePlayer player,
    PlayerWorkspaceAccount account,
  ) async {
    final latest = _latestPlayer(player);
    final existing = _matchingAccount(latest, account);
    if (existing == null) return;
    _pendingCombinedRebuildPlayerIds.remove(latest.id);
    _combinedRebuildGeneration++;
    _cancelCombinedRebuildForPlayer(latest.id);
    final canceledScopes = _cancelOperation(_accountOperationKey(existing));
    await _waitForScopes(canceledScopes);
    final combinedPath = latest.combinedPgnPath?.trim();
    if (combinedPath != null && combinedPath.isNotEmpty) {
      await _deleteGeneratedDatabasePathBestEffort(combinedPath);
    }
    final nextPlayer =
        _latestPlayer(
          latest,
        ).withoutAccountEntry(existing).withoutCombinedDatabase();
    await _upsertPlayer(
      nextPlayer,
      select: state.selectedPlayerId == latest.id,
    );
  }

  Future<void> _clearCombinedDatabaseAfterExternalLibraryDelete(
    PlayerWorkspacePlayer player,
    String deletedPath,
  ) async {
    final latest = _latestPlayer(player);
    if (!_pathMatches(latest.combinedPgnPath, deletedPath)) {
      return;
    }
    _pendingCombinedRebuildPlayerIds.remove(latest.id);
    _combinedRebuildGeneration++;
    _cancelCombinedRebuildForPlayer(latest.id);
    final nextPlayer = latest.withoutCombinedDatabase();
    if (identical(nextPlayer, latest)) return;
    await _upsertPlayer(
      nextPlayer,
      select: state.selectedPlayerId == latest.id,
    );
  }

  Future<DateTime?> _latestStoredGameDate(
    PlayerWorkspaceAccount account,
  ) async {
    final path = account.pgnPath?.trim();
    if (path == null || path.isEmpty) return null;
    return _localRepository.latestLocalGameDate(databasePath: path);
  }

  Future<void> _deletePlayerGeneratedData(
    PlayerWorkspacePlayer player, {
    void Function(LocalChessScanProgress progress)? onProgress,
  }) async {
    final paths = <String>{
      for (final account in player.allAccounts)
        if (account.pgnPath?.trim().isNotEmpty == true) account.pgnPath!.trim(),
      if (player.combinedPgnPath?.trim().isNotEmpty == true)
        player.combinedPgnPath!.trim(),
    };
    await _unregisterPlayerWorkspaceBestEffort(player, extraPaths: paths);
    // Delete the generated PGN files first (cheap, dart:io thread pool), then
    // clear their SQLite cache in one consolidated purge below.
    for (final path in paths) {
      await _deleteGeneratedSourceFile(path);
    }
    await _workspaceRepository.deletePlayerWorkspaceDirectory(player.id);
    // One marked-then-purged pass over every source this player owns: a single
    // dedicated connection instead of one per source, awaited so the removing
    // indicator can track real progress and drop the row only when it is done.
    await _localRepository.deleteCachedSourcesAwaitingPurge(
      sourcePaths: paths,
      onProgress: onProgress,
    );
  }

  Future<void> _deleteGeneratedSourceFile(String? path) async {
    final clean = path?.trim();
    if (clean == null || clean.isEmpty) return;
    try {
      await _workspaceRepository.deleteSourcePgnFile(clean);
    } finally {
      await _unregisterPlayerDatabasePathBestEffort(clean);
    }
  }

  Future<void> _deleteAccountGeneratedData(
    PlayerWorkspaceAccount account,
  ) async {
    await _deleteGeneratedDatabasePath(account.pgnPath);
  }

  Future<void> _deleteCombinedGeneratedData(
    PlayerWorkspacePlayer player,
  ) async {
    await _deleteGeneratedDatabasePath(player.combinedPgnPath);
  }

  Future<void> _deleteGeneratedDatabasePath(String? path) async {
    final clean = path?.trim();
    if (clean == null || clean.isEmpty) return;
    try {
      await _workspaceRepository.deleteSourcePgnFile(clean);
      _localRepository.scheduleCachedSourceDelete(sourcePath: clean);
    } finally {
      await _unregisterPlayerDatabasePathBestEffort(clean);
    }
  }

  Future<void> _deleteGeneratedDatabasePathBestEffort(String? path) async {
    final clean = path?.trim();
    if (clean == null || clean.isEmpty) return;
    try {
      await _workspaceRepository.deleteSourcePgnFile(clean);
      _localRepository.scheduleCachedSourceDelete(sourcePath: clean);
    } catch (error, stackTrace) {
      _debugPlayerWorkspaceFailure(
        'delete generated player database',
        error,
        stackTrace,
      );
    } finally {
      await _unregisterPlayerDatabasePathBestEffort(clean);
    }
  }

  Future<void> _deletePlayerWorkspaceDirectoryBestEffort(
    String playerId,
  ) async {
    try {
      await _workspaceRepository.deletePlayerWorkspaceDirectory(playerId);
    } catch (error, stackTrace) {
      _debugPlayerWorkspaceFailure(
        'delete player workspace directory',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _waitForInitialLoadIfNeeded() async {
    if (!state.isLoading) return;
    try {
      await _initialLoadFuture;
    } catch (_) {
      // load() records the visible error in state. External Library sync should
      // then no-op against the current state instead of throwing from a delete.
    }
  }

  bool _playerHasSourcePgns(PlayerWorkspacePlayer player) {
    return player.allAccounts.any(
      (account) => account.pgnPath?.trim().isNotEmpty == true,
    );
  }

  Iterable<String> _generatedDatabasePaths(PlayerWorkspacePlayer player) sync* {
    for (final account in player.allAccounts) {
      final path = account.pgnPath?.trim();
      if (path != null && path.isNotEmpty) yield path;
    }
    final combinedPath = player.combinedPgnPath?.trim();
    if (combinedPath != null && combinedPath.isNotEmpty) yield combinedPath;
  }

  void _setOperation(
    String key,
    PlayerWorkspaceSource source,
    String message,
    double? progress,
  ) {
    final displayMessage = _operationMessageForDisplay(source, message);
    final current = state.operations[key];
    if (current != null &&
        current.source == source &&
        current.message == displayMessage &&
        current.progress == progress) {
      return;
    }
    final next = Map<String, PlayerWorkspaceOperation>.of(state.operations);
    next[key] = PlayerWorkspaceOperation(
      source: source,
      message: displayMessage,
      progress: progress,
    );
    state = state.copyWith(operations: Map.unmodifiable(next));
  }

  void _setScopedOperation(
    _PlayerWorkspaceOperationScope scope,
    String key,
    PlayerWorkspaceSource source,
    String message,
    double? progress,
  ) {
    if (!_scopeCanUpdateOperation(scope)) return;
    _setOperation(key, source, message, progress);
  }

  void _setOperationPhaseProgress(
    String key,
    PlayerWorkspaceSource source,
    String message,
    double? progress, {
    required double start,
    required double span,
  }) {
    final mapped =
        progress == null
            ? start.clamp(0.0, 1.0).toDouble()
            : (start + (progress.clamp(0.0, 1.0) * span))
                .clamp(0.0, 1.0)
                .toDouble();
    final currentProgress = state.operations[key]?.progress;
    final nextProgress =
        currentProgress == null || mapped > currentProgress
            ? mapped
            : currentProgress;
    _setOperation(key, source, message, nextProgress);
  }

  void _setScopedOperationPhaseProgress(
    _PlayerWorkspaceOperationScope scope,
    String key,
    PlayerWorkspaceSource source,
    String message,
    double? progress, {
    required double start,
    required double span,
  }) {
    if (!_scopeCanUpdateOperation(scope)) return;
    _setOperationPhaseProgress(
      key,
      source,
      message,
      progress,
      start: start,
      span: span,
    );
  }

  void _clearOperation(String key) {
    if (!state.operations.containsKey(key)) return;
    final next = Map<String, PlayerWorkspaceOperation>.of(state.operations)
      ..remove(key);
    state = state.copyWith(operations: Map.unmodifiable(next));
  }

  void _clearOperationForScope(_PlayerWorkspaceOperationScope scope) {
    if (!_scopeOwnsOperationKey(scope)) return;
    _clearOperation(scope.key);
  }

  bool _scopeCanUpdateOperation(_PlayerWorkspaceOperationScope scope) {
    return _scopeOwnsOperationKey(scope) && !scope.token.isCanceled;
  }

  bool _scopeOwnsOperationKey(_PlayerWorkspaceOperationScope scope) {
    return identical(_operationScopes[scope.key], scope);
  }

  Future<void> _registerPlayersGeneratedDatabasesBestEffort(
    Iterable<PlayerWorkspacePlayer> players,
  ) async {
    for (final player in players) {
      await _registerPlayerGeneratedDatabasesBestEffort(player);
    }
  }

  Future<void> _registerPlayerGeneratedDatabasesBestEffort(
    PlayerWorkspacePlayer player,
  ) async {
    final metadataByPath = <String, LocalLibraryEntryMetadata>{};
    for (final account in player.allAccounts) {
      final path = account.pgnPath?.trim();
      if (path == null || path.isEmpty) continue;
      metadataByPath[path] = _playerRegistryMetadata(
        player: player,
        source: account.source,
        gameCount: account.gameCount,
        indexedAtMs: account.lastSyncAtMs,
      );
    }
    final combinedPath = player.combinedPgnPath?.trim();
    if (combinedPath != null && combinedPath.isNotEmpty) {
      metadataByPath[combinedPath] = _playerRegistryMetadata(
        player: player,
        source: PlayerWorkspaceSource.combined,
        gameCount: player.combinedGameCount,
        indexedAtMs: player.combinedBuiltAtMs,
      );
    }
    await _registerPlayerDatabaseMetadataBestEffort(metadataByPath);
  }

  Future<void> _repairPersistedDownloadedStatsBestEffort() async {
    var changed = false;
    final repairedPlayers = <PlayerWorkspacePlayer>[];
    for (final player in state.players) {
      var nextPlayer = player;
      for (final account in player.allAccounts) {
        final repaired = await _repairedDownloadedAccountStats(
          nextPlayer,
          account,
        );
        if (repaired == null) continue;
        nextPlayer = nextPlayer.withAccount(repaired);
        changed = true;
      }
      final repairedCombined = await _repairedCombinedStats(nextPlayer);
      if (!identical(repairedCombined, nextPlayer)) {
        nextPlayer = repairedCombined;
        changed = true;
      }
      repairedPlayers.add(nextPlayer);
    }
    if (!changed) return;
    state = state.copyWith(players: List.unmodifiable(repairedPlayers));
    await _persist();
  }

  Future<PlayerWorkspaceAccount?> _repairedDownloadedAccountStats(
    PlayerWorkspacePlayer player,
    PlayerWorkspaceAccount account,
  ) async {
    final path = account.pgnPath?.trim();
    if (path == null || path.isEmpty) return null;
    if (!await _fileExistsBestEffort(path)) return null;
    final gen = _repairGeneration;
    try {
      final stats = await _awaitWithRepairTimeout(
        _localRepository.localDatabaseResultStats(
          databasePath: path,
          playerAliases: _aliasesFor(player, account),
          playerFideId: player.fideId,
        ),
      );
      if (gen != _repairGeneration || stats == null) return null;
      if (stats.gameCount <= 0) return null;
      if (stats.gameCount == account.gameCount &&
          stats.winCount == account.winCount &&
          stats.drawCount == account.drawCount &&
          stats.lossCount == account.lossCount) {
        return null;
      }
      return account.copyWith(
        availableGameCount: _maxGameCount(<int>[
          account.availableGameCount,
          stats.gameCount,
        ]),
        gameCount: stats.gameCount,
        winCount: stats.winCount,
        drawCount: stats.drawCount,
        lossCount: stats.lossCount,
        clearError: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<PlayerWorkspacePlayer> _repairedCombinedStats(
    PlayerWorkspacePlayer player,
  ) async {
    final combinedPath = player.combinedPgnPath?.trim();
    if (combinedPath == null || combinedPath.isEmpty) return player;
    if (!await _fileExistsBestEffort(combinedPath)) return player;
    final gen = _repairGeneration;
    try {
      final stats = await _awaitWithRepairTimeout(
        _localRepository.localDatabaseResultStats(
          databasePath: combinedPath,
          playerAliases: _aliasesFor(player, null),
          playerFideId: player.fideId,
        ),
      );
      if (gen != _repairGeneration || stats == null) return player;
      if (stats.gameCount <= 0) return player;
      if (stats.gameCount == player.combinedGameCount &&
          stats.winCount == player.combinedWinCount &&
          stats.drawCount == player.combinedDrawCount &&
          stats.lossCount == player.combinedLossCount) {
        return player;
      }
      return player.copyWith(
        combinedGameCount: stats.gameCount,
        combinedWinCount: stats.winCount,
        combinedDrawCount: stats.drawCount,
        combinedLossCount: stats.lossCount,
      );
    } catch (_) {
      return player;
    }
  }

  /// Soft timeout for stats repair that cancels its timer on [dispose] so
  /// widget tests with FakeAsync never leave a pending 8s timer.
  Future<T?> _awaitWithRepairTimeout<T>(Future<T> future) {
    final completer = Completer<T?>();
    late final Timer timer;
    timer = Timer(_downloadedStatsRepairTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    _repairTimeoutTimers.add(timer);

    future.then(
      (value) {
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object _, StackTrace __) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    return completer.future.whenComplete(() {
      timer.cancel();
      _repairTimeoutTimers.remove(timer);
    });
  }

  Future<bool> _fileExistsBestEffort(String path) async {
    try {
      return File(path).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _registerPlayerDatabasePathBestEffort({
    required PlayerWorkspacePlayer player,
    required PlayerWorkspaceSource source,
    required String path,
    required int gameCount,
    required int? indexedAtMs,
  }) {
    final clean = path.trim();
    if (clean.isEmpty) return Future<void>.value();
    return _registerPlayerDatabaseMetadataBestEffort(
      <String, LocalLibraryEntryMetadata>{
        clean: _playerRegistryMetadata(
          player: player,
          source: source,
          gameCount: gameCount,
          indexedAtMs: indexedAtMs,
        ),
      },
    );
  }

  Future<void> _registerPlayerDatabaseMetadataBestEffort(
    Map<String, LocalLibraryEntryMetadata> metadataByPath,
  ) async {
    final registrar = _localDatabaseRegistrar;
    if (registrar == null || metadataByPath.isEmpty) return;
    try {
      await registrar(
        metadataByPath.keys.toList(growable: false),
        metadataByPath: metadataByPath,
      );
    } catch (error, stackTrace) {
      _debugPlayerWorkspaceRegistryFailure(
        'register generated player databases',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _unregisterPlayerDatabasePathBestEffort(String path) async {
    final unregistrar = _localDatabaseUnregistrar;
    if (unregistrar == null) return;
    try {
      await unregistrar(path);
    } catch (error, stackTrace) {
      _debugPlayerWorkspaceRegistryFailure(
        'unregister generated player database',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _unregisterPlayerWorkspaceBestEffort(
    PlayerWorkspacePlayer player, {
    Iterable<String> extraPaths = const <String>[],
  }) async {
    final unregistrar = _localDatabasePlayerUnregistrar;
    if (unregistrar == null) return;
    final paths = <String>{
      ..._generatedDatabasePaths(player),
      for (final path in extraPaths)
        if (path.trim().isNotEmpty) path.trim(),
    };
    try {
      await unregistrar(player.id, paths: paths);
    } catch (error, stackTrace) {
      _debugPlayerWorkspaceRegistryFailure(
        'unregister generated player workspace',
        error,
        stackTrace,
      );
    }
  }
}

LocalLibraryEntryMetadata _playerRegistryMetadata({
  required PlayerWorkspacePlayer player,
  required PlayerWorkspaceSource source,
  required int gameCount,
  required int? indexedAtMs,
}) {
  return LocalLibraryEntryMetadata.playerWorkspace(
    playerId: player.id,
    playerName: player.displayName,
    playerWorkspaceSource: source.storageKey,
    gameCount: gameCount > 0 ? gameCount : null,
    indexedAt:
        indexedAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(indexedAtMs),
  );
}

void _debugPlayerWorkspaceRegistryFailure(
  String operation,
  Object error,
  StackTrace stackTrace,
) {
  _debugPlayerWorkspaceFailure(operation, error, stackTrace);
}

void _debugPlayerWorkspaceFailure(
  String operation,
  Object error,
  StackTrace stackTrace,
) {
  if (!kDebugMode) return;
  debugPrint('Player workspace $operation failed: $error\n$stackTrace');
}

String playerWorkspaceSourceOperationKey(PlayerWorkspaceSource source) =>
    _sourceOperationKey(source);

String _operationMessageForDisplay(
  PlayerWorkspaceSource source,
  String message,
) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) return 'Working...';
  final lower = message.toLowerCase();
  if (source == PlayerWorkspaceSource.chessever) {
    return _chessEverOperationMessageForDisplay(trimmed);
  }
  if (lower.contains('delet')) {
    return 'Deleting local source files...';
  }
  if (source == PlayerWorkspaceSource.combined) {
    if (lower.contains('waiting')) return trimmed;
    return 'Building combined database...';
  }
  if (source == PlayerWorkspaceSource.manual) {
    if (lower.contains('scan')) return 'Scanning manual PGN...';
    return 'Importing manual PGN...';
  }
  if (lower.startsWith('preparing') && lower.contains('reinstall')) {
    return 'Preparing ${source.label} reinstall...';
  }
  if (lower.startsWith('preparing') && lower.contains('sync')) {
    return 'Preparing ${source.label} sync...';
  }
  // Only collapse true cache/snapshot noise. Detailed Lichess/Chess.com
  // progress ("Chess.com: 1/2 archives done; 42 games received...") must
  // pass through so determinate download UI can show archive progress.
  if (lower.contains('source cache') || lower.contains('source snapshot')) {
    return 'Downloading ${source.label} games...';
  }
  if (lower.startsWith('importing') ||
      lower.startsWith('reinstalling') ||
      lower.startsWith('saving') ||
      lower.startsWith('merging') ||
      lower.startsWith('preparing downloaded') ||
      lower.contains('downloaded pgn') ||
      lower.contains('local database') ||
      lower.contains('local cache') ||
      lower.contains('scan') ||
      lower.contains('finaliz')) {
    return 'Importing ${source.label} games...';
  }
  return trimmed;
}

String _chessEverOperationMessageForDisplay(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('delet')) {
    return 'Deleting local source files...';
  }
  if (lower.startsWith('preparing') && lower.contains('reinstall')) {
    return 'Preparing ChessEver reinstall...';
  }
  if (lower.startsWith('preparing') && lower.contains('sync')) {
    return 'Preparing ChessEver sync...';
  }
  // Post-download local work: saving PGN, opening/migrating the local cache,
  // scanning, and finalizing. Keep these under "Importing..." so the UI does
  // not flip back to "Downloading..." while the bar is past the download phase.
  if (lower.startsWith('importing') ||
      lower.startsWith('reinstalling') ||
      lower.startsWith('saving') ||
      lower.startsWith('merging') ||
      lower.startsWith('preparing downloaded') ||
      lower.contains('downloaded pgn') ||
      lower.contains('local database') ||
      lower.contains('cache') ||
      lower.contains('scan') ||
      lower.contains('finaliz')) {
    return 'Importing ChessEver games...';
  }
  return 'Downloading ChessEver games...';
}

String playerWorkspaceAccountOperationKey(PlayerWorkspaceAccount account) =>
    _accountOperationKey(account);

String _sourceOperationKey(PlayerWorkspaceSource source) =>
    'source:${source.storageKey}';

String _accountOperationKey(PlayerWorkspaceAccount account) =>
    'account:${account.identityKey}';

bool _pathMatches(String? left, String right) {
  final a = _canonicalWorkspacePath(left);
  final b = _canonicalWorkspacePath(right);
  return a.isNotEmpty && a == b;
}

String _canonicalWorkspacePath(String? path) {
  final clean = path?.trim();
  if (clean == null || clean.isEmpty) return '';
  final normalized = p.normalize(clean);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String? _normalizedPlayerFideId(String? fideId) {
  final clean = fideId?.trim();
  if (clean == null || clean.isEmpty || clean == '?') return null;
  return clean;
}

String? _normalizedPlayerExternalId(String? externalId) {
  final clean = externalId?.trim().toLowerCase();
  if (clean == null || clean.isEmpty) return null;
  return clean;
}

bool _isExternalPlayerAccountSource(PlayerWorkspaceSource source) {
  return source == PlayerWorkspaceSource.lichess ||
      source == PlayerWorkspaceSource.chesscom;
}

int? _sinceMsFromGameDate(DateTime? date) {
  if (date == null) return null;
  return DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch;
}

int? _expectedDownloadGameCount(
  PlayerWorkspaceAccount account, {
  required bool reinstall,
}) {
  if (reinstall) {
    final available = account.effectiveAvailableGameCount;
    return available > 0 ? available : null;
  }
  final remaining = account.remainingGameCount;
  if (remaining > 0) return remaining;
  if (account.gameCount <= 0 && account.effectiveAvailableGameCount > 0) {
    return account.effectiveAvailableGameCount;
  }
  return null;
}

int? _expectedChessEverDownloadGameCount(PlayerWorkspaceAccount account) {
  final available = account.effectiveAvailableGameCount;
  return available > 0 ? available : null;
}

int _maxGameCount(Iterable<int> counts) {
  var max = 0;
  for (final count in counts) {
    if (count > max) max = count;
  }
  return max;
}

List<String> _aliasesFor(
  PlayerWorkspacePlayer player,
  PlayerWorkspaceAccount? account,
) {
  final aliases = <String>{};

  void addAlias(String alias) {
    for (final variant in _playerNameAliasVariants(alias)) {
      aliases.add(variant);
    }
  }

  addAlias(player.displayName);
  if (player.title != null) addAlias('${player.title} ${player.displayName}');
  for (final sourceAccount in player.allAccounts) {
    addAlias(sourceAccount.username);
    final displayName = sourceAccount.displayName;
    if (displayName != null) addAlias(displayName);
  }
  if (account != null) {
    addAlias(account.username);
    final displayName = account.displayName;
    if (displayName != null) addAlias(displayName);
  }

  return aliases
      .where((alias) => alias.trim().isNotEmpty)
      .toList(growable: false);
}

Iterable<String> _playerNameAliasVariants(String raw) sync* {
  final clean = raw.trim();
  if (clean.isEmpty) return;

  final withoutTitle = _stripLeadingChessTitles(clean);
  final bases = <String>{clean, withoutTitle};
  for (final base in bases) {
    if (base.trim().isEmpty) continue;
    yield base;

    final commaInverted = _invertCommaName(base);
    if (commaInverted != null) yield commaInverted;

    final plainInverted = _invertPlainName(base);
    if (plainInverted != null) yield plainInverted;
  }
}

String _stripLeadingChessTitles(String raw) {
  var clean = raw.trim();
  final titlePattern = RegExp(
    r'^(?:GM|WGM|IM|WIM|FM|WFM|CM|WCM|NM|WNM|AGM|AIM|AFM|ACM)\.?\s+',
    caseSensitive: false,
  );
  while (true) {
    final next = clean.replaceFirst(titlePattern, '').trim();
    if (next == clean) return clean;
    clean = next;
  }
}

String? _invertCommaName(String raw) {
  final parts = raw
      .split(',')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.length < 2) return null;
  final last = parts.first;
  final first = parts.skip(1).join(' ');
  if (first.isEmpty || last.isEmpty) return null;
  return '$first $last';
}

String? _invertPlainName(String raw) {
  if (raw.contains(',')) return null;
  final parts = raw
      .split(RegExp(r'\s+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.length < 2) return null;
  return '${parts.last} ${parts.take(parts.length - 1).join(' ')}';
}
