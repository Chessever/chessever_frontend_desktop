import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/services/local_chess_database_repository.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/player_workspace_repository.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/screens/gamebase/models/models.dart';

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

final playerWorkspaceProvider =
    StateNotifierProvider<PlayerWorkspaceNotifier, PlayerWorkspaceState>((ref) {
      return PlayerWorkspaceNotifier(
        workspaceRepository: ref.watch(playerWorkspaceRepositoryProvider),
        gamebaseRepository: ref.watch(gamebaseRepositoryProvider),
        localRepository: ref.watch(localChessDatabaseRepositoryProvider),
      );
    });

class PlayerWorkspaceNotifier extends StateNotifier<PlayerWorkspaceState> {
  PlayerWorkspaceNotifier({
    required PlayerWorkspaceRepository workspaceRepository,
    required GamebaseRepository gamebaseRepository,
    required LocalChessDatabaseRepository localRepository,
  }) : _workspaceRepository = workspaceRepository,
       _gamebaseRepository = gamebaseRepository,
       _localRepository = localRepository,
       super(const PlayerWorkspaceState(isLoading: true)) {
    unawaited(load());
  }

  final PlayerWorkspaceRepository _workspaceRepository;
  final GamebaseRepository _gamebaseRepository;
  final LocalChessDatabaseRepository _localRepository;
  var _combinedRebuildGeneration = 0;

  Future<void> load() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final snapshot = await _workspaceRepository.loadSnapshot();
      state = PlayerWorkspaceState(
        players: snapshot.players,
        selectedPlayerId: snapshot.selectedPlayerId,
      );
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

  Future<void> addManualPlayer(String name) async {
    final player = _workspaceRepository.manualPlayer(name);
    await _upsertPlayer(player, select: false);
  }

  Future<void> addChessEverPlayer(GamebasePlayer gamebasePlayer) async {
    final player = _workspaceRepository.playerFromChessEver(gamebasePlayer);
    await _upsertPlayer(player, select: false);
  }

  Future<void> connectChessEverPlayer(GamebasePlayer gamebasePlayer) async {
    final player = state.selectedPlayer;
    if (player == null) return;
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
            fideId: gamebasePlayer.fideId,
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
    final players =
        state.players.map((player) {
            if (player.id != playerId) return player;
            found = true;
            return player.copyWith(displayName: clean);
          }).toList()
          ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    if (!found) return;
    state = state.copyWith(
      players: List.unmodifiable(players),
      isLoading: false,
      clearError: true,
    );
    await _persist();
  }

  Future<void> removePlayer(String playerId) async {
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
              : state.operations,
    );
    await _persist();
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
      final latest = _latestPlayer(player).withoutAccountEntry(existing);
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
    if (player == null || player.account(source) == null) return;
    _clearOperation(_sourceOperationKey(source));
    await _upsertPlayer(player.withoutAccount(source), select: true);
  }

  Future<void> removeAccountEntry(PlayerWorkspaceAccount account) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final existing = _matchingAccount(player, account);
    if (existing == null) return;
    _clearOperation(_accountOperationKey(existing));
    await _upsertPlayer(player.withoutAccountEntry(existing), select: true);
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
    _setOperation(
      operationKey,
      source,
      reinstall
          ? 'Preparing ${source.label} reinstall...'
          : 'Preparing ${source.label} sync...',
      null,
    );
    try {
      final latestStoredGameDate =
          reinstall ? null : await _latestStoredGameDate(existing);
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
                  (message, progress) =>
                      _setOperation(operationKey, source, message, progress),
            ),
        PlayerWorkspaceSource.chesscom => await _workspaceRepository
            .downloadChessComGames(
              username: existing.username,
              sinceMs: sinceMs,
              onProgress:
                  (message, progress) =>
                      _setOperation(operationKey, source, message, progress),
            ),
        PlayerWorkspaceSource.chessever => await _workspaceRepository
            .downloadChessEverGames(
              repository: _gamebaseRepository,
              playerId: existing.externalId ?? player.chesseverPlayerId ?? '',
              sinceDate: latestStoredGameDate,
              onProgress:
                  (message, progress) =>
                      _setOperation(operationKey, source, message, progress),
            ),
        PlayerWorkspaceSource.manual =>
          throw StateError('Use Import PGN to add more manual games.'),
        PlayerWorkspaceSource.combined =>
          throw StateError('Combined database is built from source databases.'),
      };

      final path = await _workspaceRepository.sourcePgnPath(
        playerId: player.id,
        source: source,
        username: existing.username,
      );
      final imported = await _workspaceRepository.mergeIntoLocalDatabase(
        localRepository: _localRepository,
        path: path,
        sourceLabel: '${player.displayName} ${source.label}',
        pgn: downloaded.pgn,
        playerAliases: _aliasesFor(player, account),
        replaceExisting: reinstall,
        onProgress:
            (message, progress) =>
                _setOperation(operationKey, source, message, progress),
      );
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
      await _upsertPlayer(latest.withAccount(nextAccount), select: true);
      _clearOperation(operationKey);
      await rebuildCombinedDatabase();
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
        gameCount: splitPgnGames(pgn).length,
      ),
    );
  }

  Future<void> importManualPgnPaths({required List<String> paths}) async {
    final cleanLabel = localChessDatabaseDisplayNameForPaths(paths);
    const source = PlayerWorkspaceSource.manual;
    final operationKey = _sourceOperationKey(source);
    _setOperation(operationKey, source, 'Scanning manual PGN...', null);
    final downloaded = await _workspaceRepository.readManualPgnPaths(
      paths: paths,
      onProgress:
          (message, progress) =>
              _setOperation(operationKey, source, message, progress),
    );
    await _importManualDownloadedPgn(label: cleanLabel, downloaded: downloaded);
  }

  Future<void> _importManualDownloadedPgn({
    required String label,
    required PlayerWorkspaceDownloadedPgn downloaded,
  }) async {
    final player = state.selectedPlayer;
    if (player == null) return;
    const source = PlayerWorkspaceSource.manual;
    final operationKey = _sourceOperationKey(source);
    _setOperation(operationKey, source, 'Importing manual PGN...', null);
    final account = PlayerWorkspaceAccount(
      source: source,
      username: label,
      displayName: label,
      availableGameCount: downloaded.gameCount,
    );
    try {
      final path = await _workspaceRepository.sourcePgnPath(
        playerId: player.id,
        source: source,
        username: label,
      );
      final imported = await _workspaceRepository.mergeIntoLocalDatabase(
        localRepository: _localRepository,
        path: path,
        sourceLabel: '${player.displayName} $label',
        pgn: downloaded.pgn,
        playerAliases: _aliasesFor(player, account),
        onProgress:
            (message, progress) =>
                _setOperation(operationKey, source, message, progress),
      );
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
      await _upsertPlayer(
        _latestPlayer(player).withAccount(nextAccount),
        select: true,
      );
      _clearOperation(operationKey);
      await rebuildCombinedDatabase();
    } catch (error) {
      _clearOperation(operationKey);
      await _upsertPlayer(
        _latestPlayer(
          player,
        ).withAccount(account.copyWith(error: error.toString())),
        select: true,
      );
      rethrow;
    }
  }

  Future<void> rebuildCombinedDatabase() async {
    final player = state.selectedPlayer;
    if (player == null) return;
    final paths = player.allAccounts
        .map((account) => account.pgnPath)
        .whereType<String>()
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return;
    const source = PlayerWorkspaceSource.combined;
    final generation = ++_combinedRebuildGeneration;
    final operationKey = _sourceOperationKey(source);
    _setOperation(
      operationKey,
      source,
      'Combining and deduplicating games...',
      null,
    );
    try {
      final result = await _workspaceRepository.rebuildCombinedDatabase(
        localRepository: _localRepository,
        playerId: player.id,
        playerName: player.displayName,
        sourcePaths: paths,
        playerAliases: _aliasesFor(player, null),
        onProgress:
            (message, progress) =>
                _setOperation(operationKey, source, message, progress),
      );
      if (generation != _combinedRebuildGeneration) return;
      final latest = state.players.firstWhere(
        (candidate) => candidate.id == player.id,
        orElse: () => player,
      );
      await _upsertPlayer(
        latest.copyWith(
          combinedPgnPath: result.path,
          combinedGameCount: result.stats.gameCount,
          combinedWinCount: result.stats.winCount,
          combinedDrawCount: result.stats.drawCount,
          combinedLossCount: result.stats.lossCount,
          combinedBuiltAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        select: true,
      );
      _clearOperation(operationKey);
    } catch (error) {
      if (generation != _combinedRebuildGeneration) return;
      _clearOperation(operationKey);
      state = state.copyWith(
        error: 'Could not build combined database: $error',
      );
      rethrow;
    }
  }

  Future<PlayerWorkspaceAccount> _refreshChessEverAccount(
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
    return state.players.firstWhere(
      (candidate) => candidate.id == fallback.id,
      orElse: () => fallback,
    );
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

  Future<DateTime?> _latestStoredGameDate(
    PlayerWorkspaceAccount account,
  ) async {
    final path = account.pgnPath?.trim();
    if (path == null || path.isEmpty) return null;
    return _localRepository.latestLocalGameDate(databasePath: path);
  }

  void _setOperation(
    String key,
    PlayerWorkspaceSource source,
    String message,
    double? progress,
  ) {
    final next = Map<String, PlayerWorkspaceOperation>.of(state.operations);
    next[key] = PlayerWorkspaceOperation(
      source: source,
      message: message,
      progress: progress,
    );
    state = state.copyWith(operations: Map.unmodifiable(next));
  }

  void _clearOperation(String key) {
    if (!state.operations.containsKey(key)) return;
    final next = Map<String, PlayerWorkspaceOperation>.of(state.operations)
      ..remove(key);
    state = state.copyWith(operations: Map.unmodifiable(next));
  }
}

String playerWorkspaceSourceOperationKey(PlayerWorkspaceSource source) =>
    _sourceOperationKey(source);

String playerWorkspaceAccountOperationKey(PlayerWorkspaceAccount account) =>
    _accountOperationKey(account);

String _sourceOperationKey(PlayerWorkspaceSource source) =>
    'source:${source.storageKey}';

String _accountOperationKey(PlayerWorkspaceAccount account) =>
    'account:${account.identityKey}';

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
