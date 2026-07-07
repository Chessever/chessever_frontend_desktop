import 'package:flutter/foundation.dart';

enum PlayerWorkspaceSource {
  chessever,
  lichess,
  chesscom,
  manual,
  combined;

  String get label {
    return switch (this) {
      PlayerWorkspaceSource.chessever => 'ChessEver',
      PlayerWorkspaceSource.lichess => 'Lichess',
      PlayerWorkspaceSource.chesscom => 'Chess.com',
      PlayerWorkspaceSource.manual => 'Manual PGN',
      PlayerWorkspaceSource.combined => 'Combined',
    };
  }

  String get accountLabel {
    return switch (this) {
      PlayerWorkspaceSource.chessever => 'ChessEver player',
      PlayerWorkspaceSource.lichess => 'Lichess username',
      PlayerWorkspaceSource.chesscom => 'Chess.com username',
      PlayerWorkspaceSource.manual => 'PGN file',
      PlayerWorkspaceSource.combined => 'Combined database',
    };
  }

  String get storageKey {
    return switch (this) {
      PlayerWorkspaceSource.chessever => 'chessever',
      PlayerWorkspaceSource.lichess => 'lichess',
      PlayerWorkspaceSource.chesscom => 'chesscom',
      PlayerWorkspaceSource.manual => 'manual',
      PlayerWorkspaceSource.combined => 'combined',
    };
  }

  bool get allowsMultipleAccounts {
    return switch (this) {
      PlayerWorkspaceSource.lichess ||
      PlayerWorkspaceSource.chesscom ||
      PlayerWorkspaceSource.manual => true,
      PlayerWorkspaceSource.chessever ||
      PlayerWorkspaceSource.combined => false,
    };
  }

  static PlayerWorkspaceSource? fromStorageKey(String? key) {
    return switch (key) {
      'chessever' => PlayerWorkspaceSource.chessever,
      'lichess' => PlayerWorkspaceSource.lichess,
      'chesscom' => PlayerWorkspaceSource.chesscom,
      'manual' => PlayerWorkspaceSource.manual,
      'combined' => PlayerWorkspaceSource.combined,
      _ => null,
    };
  }
}

@immutable
class PlayerWorkspaceOperation {
  const PlayerWorkspaceOperation({
    required this.source,
    required this.message,
    this.progress,
  });

  final PlayerWorkspaceSource source;
  final String message;
  final double? progress;

  int? get percent =>
      progress == null ? null : (progress!.clamp(0, 1) * 100).round();
}

@immutable
class PlayerWorkspaceAccount {
  const PlayerWorkspaceAccount({
    required this.source,
    required this.username,
    this.externalId,
    this.displayName,
    this.avatarUrl,
    this.country,
    this.title,
    this.profileUrl,
    this.ratings = const <String, int>{},
    this.rawStats = const <String, Object?>{},
    this.profileFetchedAtMs,
    this.lastSyncAtMs,
    this.pgnPath,
    this.availableGameCount = 0,
    this.gameCount = 0,
    this.newGameCount = 0,
    this.winCount = 0,
    this.drawCount = 0,
    this.lossCount = 0,
    this.error,
  });

  final PlayerWorkspaceSource source;
  final String username;
  final String? externalId;
  final String? displayName;
  final String? avatarUrl;
  final String? country;
  final String? title;
  final String? profileUrl;
  final Map<String, int> ratings;
  final Map<String, Object?> rawStats;
  final int? profileFetchedAtMs;
  final int? lastSyncAtMs;
  final String? pgnPath;
  final int availableGameCount;
  final int gameCount;
  final int newGameCount;
  final int winCount;
  final int drawCount;
  final int lossCount;
  final String? error;

  bool get isConnected => username.trim().isNotEmpty || externalId != null;
  bool get hasDownloadedGames => gameCount > 0 && pgnPath != null;
  int get effectiveAvailableGameCount =>
      availableGameCount > gameCount ? availableGameCount : gameCount;
  int get remainingGameCount {
    final remaining = effectiveAvailableGameCount - gameCount;
    return remaining > 0 ? remaining : 0;
  }

  double? get downloadProgress {
    final available = effectiveAvailableGameCount;
    if (available <= 0) return null;
    return (gameCount / available).clamp(0, 1).toDouble();
  }

  int get decisiveCount => winCount + lossCount;
  double? get winRate {
    final total = winCount + drawCount + lossCount;
    if (total <= 0) return null;
    return winCount / total;
  }

  String get identityKey {
    final external = externalId?.trim().toLowerCase();
    final user = username.trim().toLowerCase();
    final path = pgnPath?.trim().toLowerCase();
    final identity =
        external?.isNotEmpty == true
            ? 'id:$external'
            : user.isNotEmpty
            ? 'user:$user'
            : path?.isNotEmpty == true
            ? 'path:$path'
            : 'source';
    return '${source.storageKey}:$identity';
  }

  PlayerWorkspaceAccount copyWith({
    String? username,
    String? externalId,
    String? displayName,
    String? avatarUrl,
    String? country,
    String? title,
    String? profileUrl,
    Map<String, int>? ratings,
    Map<String, Object?>? rawStats,
    int? profileFetchedAtMs,
    int? lastSyncAtMs,
    String? pgnPath,
    int? availableGameCount,
    int? gameCount,
    int? newGameCount,
    int? winCount,
    int? drawCount,
    int? lossCount,
    String? error,
    bool clearError = false,
  }) {
    return PlayerWorkspaceAccount(
      source: source,
      username: username ?? this.username,
      externalId: externalId ?? this.externalId,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      country: country ?? this.country,
      title: title ?? this.title,
      profileUrl: profileUrl ?? this.profileUrl,
      ratings: ratings ?? this.ratings,
      rawStats: rawStats ?? this.rawStats,
      profileFetchedAtMs: profileFetchedAtMs ?? this.profileFetchedAtMs,
      lastSyncAtMs: lastSyncAtMs ?? this.lastSyncAtMs,
      pgnPath: pgnPath ?? this.pgnPath,
      availableGameCount: availableGameCount ?? this.availableGameCount,
      gameCount: gameCount ?? this.gameCount,
      newGameCount: newGameCount ?? this.newGameCount,
      winCount: winCount ?? this.winCount,
      drawCount: drawCount ?? this.drawCount,
      lossCount: lossCount ?? this.lossCount,
      error: clearError ? null : (error ?? this.error),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'source': source.storageKey,
      'username': username,
      'externalId': externalId,
      'displayName': displayName,
      'avatarUrl': avatarUrl,
      'country': country,
      'title': title,
      'profileUrl': profileUrl,
      'ratings': ratings,
      'rawStats': rawStats,
      'profileFetchedAtMs': profileFetchedAtMs,
      'lastSyncAtMs': lastSyncAtMs,
      'pgnPath': pgnPath,
      'availableGameCount': availableGameCount,
      'gameCount': gameCount,
      'newGameCount': newGameCount,
      'winCount': winCount,
      'drawCount': drawCount,
      'lossCount': lossCount,
      'error': error,
    };
  }

  static PlayerWorkspaceAccount? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final source = PlayerWorkspaceSource.fromStorageKey(
      json['source']?.toString(),
    );
    if (source == null || source == PlayerWorkspaceSource.combined) {
      return null;
    }
    final pgnPath = _stringOrNull(json['pgnPath']);
    final legacyGameCount = _intOrNull(json['gameCount']) ?? 0;
    final availableGameCount = _intOrNull(json['availableGameCount']);
    return PlayerWorkspaceAccount(
      source: source,
      username: json['username']?.toString() ?? '',
      externalId: _stringOrNull(json['externalId']),
      displayName: _stringOrNull(json['displayName']),
      avatarUrl: _stringOrNull(json['avatarUrl']),
      country: _stringOrNull(json['country']),
      title: _stringOrNull(json['title']),
      profileUrl: _stringOrNull(json['profileUrl']),
      ratings: _intMap(json['ratings']),
      rawStats: _objectMap(json['rawStats']),
      profileFetchedAtMs: _intOrNull(json['profileFetchedAtMs']),
      lastSyncAtMs: _intOrNull(json['lastSyncAtMs']),
      pgnPath: pgnPath,
      availableGameCount: availableGameCount ?? legacyGameCount,
      gameCount:
          availableGameCount == null && pgnPath == null ? 0 : legacyGameCount,
      newGameCount: _intOrNull(json['newGameCount']) ?? 0,
      winCount: _intOrNull(json['winCount']) ?? 0,
      drawCount: _intOrNull(json['drawCount']) ?? 0,
      lossCount: _intOrNull(json['lossCount']) ?? 0,
      error: _stringOrNull(json['error']),
    );
  }
}

@immutable
class PlayerWorkspacePlayer {
  const PlayerWorkspacePlayer({
    required this.id,
    required this.displayName,
    required this.createdAtMs,
    this.fideId,
    this.chesseverPlayerId,
    this.country,
    this.title,
    this.avatarUrl,
    this.accounts = const <PlayerWorkspaceSource, PlayerWorkspaceAccount>{},
    this.additionalAccounts = const <PlayerWorkspaceAccount>[],
    this.combinedPgnPath,
    this.combinedGameCount = 0,
    this.combinedWinCount = 0,
    this.combinedDrawCount = 0,
    this.combinedLossCount = 0,
    this.combinedBuiltAtMs,
  });

  final String id;
  final String displayName;
  final int createdAtMs;
  final String? fideId;
  final String? chesseverPlayerId;
  final String? country;
  final String? title;
  final String? avatarUrl;
  final Map<PlayerWorkspaceSource, PlayerWorkspaceAccount> accounts;
  final List<PlayerWorkspaceAccount> additionalAccounts;
  final String? combinedPgnPath;
  final int combinedGameCount;
  final int combinedWinCount;
  final int combinedDrawCount;
  final int combinedLossCount;
  final int? combinedBuiltAtMs;

  PlayerWorkspaceAccount? account(PlayerWorkspaceSource source) {
    final account = accounts[source];
    if (account != null) return account;
    for (final extra in additionalAccounts) {
      if (extra.source == source) return extra;
    }
    return null;
  }

  List<PlayerWorkspaceAccount> accountsFor(PlayerWorkspaceSource source) {
    return <PlayerWorkspaceAccount>[
      if (accounts[source] != null) accounts[source]!,
      for (final account in additionalAccounts)
        if (account.source == source) account,
    ];
  }

  List<PlayerWorkspaceAccount> get allAccounts {
    return List.unmodifiable(<PlayerWorkspaceAccount>[
      ...accounts.values,
      ...additionalAccounts,
    ]);
  }

  int get connectedSourceCount =>
      allAccounts.where((account) => account.isConnected).length;

  int get totalSourceGames {
    return allAccounts.fold<int>(0, (sum, account) => sum + account.gameCount);
  }

  int get totalGames =>
      combinedGameCount > 0 ? combinedGameCount : totalSourceGames;

  int get winCount {
    if (combinedGameCount > 0) return combinedWinCount;
    return allAccounts.fold<int>(0, (sum, account) => sum + account.winCount);
  }

  int get drawCount {
    if (combinedGameCount > 0) return combinedDrawCount;
    return allAccounts.fold<int>(0, (sum, account) => sum + account.drawCount);
  }

  int get lossCount {
    if (combinedGameCount > 0) return combinedLossCount;
    return allAccounts.fold<int>(0, (sum, account) => sum + account.lossCount);
  }

  int? get lastSyncAtMs {
    final values = <int>[
      if (combinedBuiltAtMs != null) combinedBuiltAtMs!,
      for (final account in allAccounts)
        if (account.lastSyncAtMs != null) account.lastSyncAtMs!,
    ];
    if (values.isEmpty) return null;
    values.sort();
    return values.last;
  }

  double? get winRate {
    final total = winCount + drawCount + lossCount;
    if (total <= 0) return null;
    return winCount / total;
  }

  String? get bestAvatarUrl {
    final own = avatarUrl?.trim();
    if (own != null && own.isNotEmpty) return own;
    for (final account in allAccounts) {
      final avatar = account.avatarUrl?.trim();
      if (avatar != null && avatar.isNotEmpty) return avatar;
    }
    return null;
  }

  PlayerWorkspacePlayer copyWith({
    String? displayName,
    String? fideId,
    String? chesseverPlayerId,
    String? country,
    String? title,
    String? avatarUrl,
    Map<PlayerWorkspaceSource, PlayerWorkspaceAccount>? accounts,
    List<PlayerWorkspaceAccount>? additionalAccounts,
    String? combinedPgnPath,
    int? combinedGameCount,
    int? combinedWinCount,
    int? combinedDrawCount,
    int? combinedLossCount,
    int? combinedBuiltAtMs,
  }) {
    return PlayerWorkspacePlayer(
      id: id,
      displayName: displayName ?? this.displayName,
      createdAtMs: createdAtMs,
      fideId: fideId ?? this.fideId,
      chesseverPlayerId: chesseverPlayerId ?? this.chesseverPlayerId,
      country: country ?? this.country,
      title: title ?? this.title,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      accounts: accounts ?? this.accounts,
      additionalAccounts: additionalAccounts ?? this.additionalAccounts,
      combinedPgnPath: combinedPgnPath ?? this.combinedPgnPath,
      combinedGameCount: combinedGameCount ?? this.combinedGameCount,
      combinedWinCount: combinedWinCount ?? this.combinedWinCount,
      combinedDrawCount: combinedDrawCount ?? this.combinedDrawCount,
      combinedLossCount: combinedLossCount ?? this.combinedLossCount,
      combinedBuiltAtMs: combinedBuiltAtMs ?? this.combinedBuiltAtMs,
    );
  }

  PlayerWorkspacePlayer withAccount(PlayerWorkspaceAccount account) {
    if (account.source == PlayerWorkspaceSource.combined) return this;
    final next = _upsertPrimaryAccount(accounts, additionalAccounts, account);
    return copyWith(accounts: next.primary, additionalAccounts: next.extra);
  }

  PlayerWorkspacePlayer withoutAccount(PlayerWorkspaceSource source) {
    final nextAccounts = <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
      ...accounts,
    }..remove(source);
    final nextAdditional = additionalAccounts
        .where((account) => account.source != source)
        .toList(growable: false);
    return PlayerWorkspacePlayer(
      id: id,
      displayName: displayName,
      createdAtMs: createdAtMs,
      fideId: fideId,
      chesseverPlayerId:
          source == PlayerWorkspaceSource.chessever ? null : chesseverPlayerId,
      country: country,
      title: title,
      avatarUrl: avatarUrl,
      accounts: Map.unmodifiable(nextAccounts),
      additionalAccounts: List.unmodifiable(nextAdditional),
    );
  }

  PlayerWorkspacePlayer withoutAccountEntry(PlayerWorkspaceAccount account) {
    final nextAccounts = <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
      ...accounts,
    };
    final nextAdditional = additionalAccounts.toList(growable: true);
    final key = account.identityKey;
    var removedPrimary = false;
    final primary = nextAccounts[account.source];
    if (primary?.identityKey == key) {
      nextAccounts.remove(account.source);
      removedPrimary = true;
    }
    nextAdditional.removeWhere((candidate) => candidate.identityKey == key);
    if (removedPrimary) {
      final promoteIndex = nextAdditional.indexWhere(
        (candidate) => candidate.source == account.source,
      );
      if (promoteIndex >= 0) {
        nextAccounts[account.source] = nextAdditional.removeAt(promoteIndex);
      }
    }
    return PlayerWorkspacePlayer(
      id: id,
      displayName: displayName,
      createdAtMs: createdAtMs,
      fideId: fideId,
      chesseverPlayerId:
          account.source == PlayerWorkspaceSource.chessever &&
                  !nextAccounts.containsKey(PlayerWorkspaceSource.chessever)
              ? null
              : chesseverPlayerId,
      country: country,
      title: title,
      avatarUrl: avatarUrl,
      accounts: Map.unmodifiable(nextAccounts),
      additionalAccounts: List.unmodifiable(nextAdditional),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'displayName': displayName,
      'createdAtMs': createdAtMs,
      'fideId': fideId,
      'chesseverPlayerId': chesseverPlayerId,
      'country': country,
      'title': title,
      'avatarUrl': avatarUrl,
      'accounts': allAccounts.map((account) => account.toJson()).toList(),
      'combinedPgnPath': combinedPgnPath,
      'combinedGameCount': combinedGameCount,
      'combinedWinCount': combinedWinCount,
      'combinedDrawCount': combinedDrawCount,
      'combinedLossCount': combinedLossCount,
      'combinedBuiltAtMs': combinedBuiltAtMs,
    };
  }

  static PlayerWorkspacePlayer? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final id = json['id']?.toString().trim() ?? '';
    final displayName = json['displayName']?.toString().trim() ?? '';
    if (id.isEmpty || displayName.isEmpty) return null;

    final accounts = <PlayerWorkspaceSource, PlayerWorkspaceAccount>{};
    final additionalAccounts = <PlayerWorkspaceAccount>[];
    final rawAccounts = json['accounts'];
    if (rawAccounts is List) {
      for (final rawAccount in rawAccounts) {
        final account = PlayerWorkspaceAccount.fromJson(rawAccount);
        if (account == null) continue;
        if (!account.source.allowsMultipleAccounts ||
            !accounts.containsKey(account.source)) {
          accounts[account.source] = account;
        } else {
          additionalAccounts.add(account);
        }
      }
    }

    return PlayerWorkspacePlayer(
      id: id,
      displayName: displayName,
      createdAtMs:
          _intOrNull(json['createdAtMs']) ??
          DateTime.now().millisecondsSinceEpoch,
      fideId: _stringOrNull(json['fideId']),
      chesseverPlayerId: _stringOrNull(json['chesseverPlayerId']),
      country: _stringOrNull(json['country']),
      title: _stringOrNull(json['title']),
      avatarUrl: _stringOrNull(json['avatarUrl']),
      accounts: Map.unmodifiable(accounts),
      additionalAccounts: List.unmodifiable(additionalAccounts),
      combinedPgnPath: _stringOrNull(json['combinedPgnPath']),
      combinedGameCount: _intOrNull(json['combinedGameCount']) ?? 0,
      combinedWinCount: _intOrNull(json['combinedWinCount']) ?? 0,
      combinedDrawCount: _intOrNull(json['combinedDrawCount']) ?? 0,
      combinedLossCount: _intOrNull(json['combinedLossCount']) ?? 0,
      combinedBuiltAtMs: _intOrNull(json['combinedBuiltAtMs']),
    );
  }
}

({
  Map<PlayerWorkspaceSource, PlayerWorkspaceAccount> primary,
  List<PlayerWorkspaceAccount> extra,
})
_upsertPrimaryAccount(
  Map<PlayerWorkspaceSource, PlayerWorkspaceAccount> currentPrimary,
  List<PlayerWorkspaceAccount> currentExtra,
  PlayerWorkspaceAccount account,
) {
  final primary = <PlayerWorkspaceSource, PlayerWorkspaceAccount>{
    ...currentPrimary,
  };
  final extra = currentExtra.toList(growable: true);
  if (!account.source.allowsMultipleAccounts) {
    primary[account.source] = account;
    extra.removeWhere((candidate) => candidate.source == account.source);
    return (
      primary: Map.unmodifiable(primary),
      extra: List.unmodifiable(extra),
    );
  }

  final key = account.identityKey;
  final existingPrimary = primary[account.source];
  if (existingPrimary == null) {
    primary[account.source] = account;
    return (
      primary: Map.unmodifiable(primary),
      extra: List.unmodifiable(extra),
    );
  }
  if (existingPrimary.identityKey == key) {
    primary[account.source] = account;
    return (
      primary: Map.unmodifiable(primary),
      extra: List.unmodifiable(extra),
    );
  }

  for (var i = 0; i < extra.length; i++) {
    if (extra[i].identityKey == key) {
      extra[i] = account;
      return (
        primary: Map.unmodifiable(primary),
        extra: List.unmodifiable(extra),
      );
    }
  }
  extra.add(account);
  return (primary: Map.unmodifiable(primary), extra: List.unmodifiable(extra));
}

@immutable
class PlayerWorkspaceSnapshot {
  const PlayerWorkspaceSnapshot({
    this.players = const <PlayerWorkspacePlayer>[],
    this.selectedPlayerId,
  });

  final List<PlayerWorkspacePlayer> players;
  final String? selectedPlayerId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'players': players.map((player) => player.toJson()).toList(),
      'selectedPlayerId': selectedPlayerId,
    };
  }

  static PlayerWorkspaceSnapshot fromJson(Object? raw) {
    if (raw is! Map) return const PlayerWorkspaceSnapshot();
    final json = raw.cast<String, Object?>();
    final players = <PlayerWorkspacePlayer>[];
    final rawPlayers = json['players'];
    if (rawPlayers is List) {
      for (final rawPlayer in rawPlayers) {
        final player = PlayerWorkspacePlayer.fromJson(rawPlayer);
        if (player != null) players.add(player);
      }
    }
    final selectedId = _stringOrNull(json['selectedPlayerId']);
    return PlayerWorkspaceSnapshot(
      players: List.unmodifiable(players),
      selectedPlayerId:
          players.any((player) => player.id == selectedId) ? selectedId : null,
    );
  }
}

@immutable
class PlayerWorkspaceImportStats {
  const PlayerWorkspaceImportStats({
    required this.gameCount,
    this.newGameCount = 0,
    this.winCount = 0,
    this.drawCount = 0,
    this.lossCount = 0,
  });

  final int gameCount;
  final int newGameCount;
  final int winCount;
  final int drawCount;
  final int lossCount;
}

String? _stringOrNull(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return text;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

Map<String, int> _intMap(Object? value) {
  if (value is! Map) return const <String, int>{};
  final map = <String, int>{};
  for (final entry in value.entries) {
    final key = entry.key?.toString().trim() ?? '';
    final parsed = _intOrNull(entry.value);
    if (key.isNotEmpty && parsed != null) map[key] = parsed;
  }
  return Map.unmodifiable(map);
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return Map.unmodifiable(
    value.map((key, value) => MapEntry(key.toString(), value)),
  );
}
