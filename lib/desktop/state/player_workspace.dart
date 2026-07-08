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

@immutable
class PlayerWorkspaceState {
  const PlayerWorkspaceState({
    this.players = const <PlayerWorkspacePlayer>[],
    this.selectedPlayerId,
    this.isLoading = false,
    this.error,
    this.operations = const <String, PlayerWorkspaceOperation>{},
  });

  final List<PlayerWorkspacePlayer> players;
  final String? selectedPlayerId;
  final bool isLoading;
  final String? error;
  final Map<String, PlayerWorkspaceOperation> operations;

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
    );
  }
}

final playerWorkspaceRepositoryProvider = Provider<PlayerWorkspaceRepository>(
  (_) => PlayerWorkspaceRepository(),
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

  @override
  void dispose() {
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
      await _registerPlayersGeneratedDatabasesBestEffort(snapshot.players);
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
    var latest = _latestPlayer(player);
    var added = 0;
    for (final account in accounts) {
      if (!account.source.allowsMultipleAccounts) continue;
      latest = latest.withAccount(account);
      added++;
    }
    if (added == 0) return 0;
    await _upsertPlayer(latest, select: true);
    return added;
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

  Future<void> selectPlayer(String playerId) async {
    if (!state.players.any((player) => player.id == playerId)) return;
    state = state.copyWith(selectedPlayerId: playerId);
    await _persist();
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
    final players = <PlayerWorkspacePlayer>[
      for (final player in state.players)
        if (player.id != playerId) player,
    ];
    if (players.length == state.players.length) return;
    final removedSelected = state.selectedPlayerId == playerId;
    state = state.copyWith(
      players: List.unmodifiable(players),
      clearSelectedPlayerId: removedSelected,
      isLoading: false,
      clearError: true,
      operations:
          removedSelected
              ? const <String, PlayerWorkspaceOperation>{}
              : _operationsWithoutPlayer(playerId),
    );
    await _persist();
    await _waitForScopes(canceledScopes);
    await _deletePlayerGeneratedData(player);
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
    final operationKey = _sourceOperationKey(source);
    _setOperation(
      operationKey,
      source,
      'Fetching ${source.label} profile...',
      null,
    );
    try {
      final account = switch (source) {
        PlayerWorkspaceSource.lichess => await _workspaceRepository
            .fetchLichessAccount(username),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .fetchChessComAccount(username),
        PlayerWorkspaceSource.chessever ||
        PlayerWorkspaceSource.manual ||
        PlayerWorkspaceSource
            .combined => throw StateError('Unsupported account source.'),
      };
      await _upsertPlayer(
        _latestPlayer(player).withAccount(account),
        select: true,
      );
      _clearOperation(operationKey);
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

    final source = existing.source;
    final operationKey = _accountOperationKey(existing);
    _setOperation(
      operationKey,
      source,
      'Fetching ${source.label} profile...',
      null,
    );
    try {
      final fetched = switch (source) {
        PlayerWorkspaceSource.lichess => await _workspaceRepository
            .fetchLichessAccount(username),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .fetchChessComAccount(username),
        PlayerWorkspaceSource.chessever ||
        PlayerWorkspaceSource.manual ||
        PlayerWorkspaceSource
            .combined => throw StateError('Unsupported account source.'),
      };
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
    var importedSuccessfully = false;
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
          path: imported.path,
          gameCount: imported.stats.gameCount,
          indexedAtMs: now,
        ),
      );
      _clearOperationForScope(scope);
      importedSuccessfully = true;
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
        if (importedSuccessfully && !_isPlayerDeleted(player.id)) {
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
    final paths = player.allAccounts
        .map((account) => account.pgnPath)
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return;
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
        sourcePaths: paths,
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
      unawaited(
        _registerPlayerDatabasePathBestEffort(
          player: nextPlayer,
          path: result.path,
          gameCount: result.stats.gameCount,
          indexedAtMs: now,
        ),
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

  Future<void> _deletePlayerGeneratedData(PlayerWorkspacePlayer player) async {
    final paths = <String>{
      for (final account in player.allAccounts)
        if (account.pgnPath?.trim().isNotEmpty == true) account.pgnPath!.trim(),
      if (player.combinedPgnPath?.trim().isNotEmpty == true)
        player.combinedPgnPath!.trim(),
    };
    await _unregisterPlayerWorkspaceBestEffort(player, extraPaths: paths);
    for (final path in paths) {
      await _deleteGeneratedDatabasePath(path);
    }
    await _workspaceRepository.deletePlayerWorkspaceDirectory(player.id);
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
        gameCount: account.gameCount,
        indexedAtMs: account.lastSyncAtMs,
      );
    }
    final combinedPath = player.combinedPgnPath?.trim();
    if (combinedPath != null && combinedPath.isNotEmpty) {
      metadataByPath[combinedPath] = _playerRegistryMetadata(
        player: player,
        gameCount: player.combinedGameCount,
        indexedAtMs: player.combinedBuiltAtMs,
      );
    }
    await _registerPlayerDatabaseMetadataBestEffort(metadataByPath);
  }

  Future<void> _registerPlayerDatabasePathBestEffort({
    required PlayerWorkspacePlayer player,
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
  required int gameCount,
  required int? indexedAtMs,
}) {
  return LocalLibraryEntryMetadata.playerWorkspace(
    playerId: player.id,
    playerName: player.displayName,
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
  if (lower.startsWith('importing') ||
      lower.startsWith('reinstalling') ||
      lower.contains('cache') ||
      lower.contains('scan') ||
      lower.contains('pgn') ||
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
  if (lower.startsWith('importing') ||
      lower.startsWith('reinstalling') ||
      lower.contains('cache')) {
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
  return <String>{
    player.displayName,
    if (player.title != null) '${player.title} ${player.displayName}',
    for (final sourceAccount in player.allAccounts) ...[
      sourceAccount.username,
      if (sourceAccount.displayName != null) sourceAccount.displayName!,
    ],
    if (account != null) ...[
      account.username,
      if (account.displayName != null) account.displayName!,
    ],
  }.where((alias) => alias.trim().isNotEmpty).toList(growable: false);
}
