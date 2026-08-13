import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/player_profile/provider/player_profile_provider.dart';
import 'package:chessever/screens/premium_games/providers/premium_games_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

const String desktopBoardWindowPayloadType = 'board';
const String desktopTabWindowPayloadType = 'desktop-tab';

@immutable
class DesktopBoardWindowPayload {
  const DesktopBoardWindowPayload({
    required this.title,
    required this.kind,
    this.subtitle,
    this.args,
    this.metadata = const <String, Object?>{},
  });

  final String title;
  final TabKind kind;
  final String? subtitle;
  final BoardTabGameArgs? args;
  final Map<String, Object?> metadata;

  factory DesktopBoardWindowPayload.fromArgs(BoardTabGameArgs args) {
    return DesktopBoardWindowPayload(
      title: args.label,
      kind: TabKind.board,
      args: args,
    );
  }

  factory DesktopBoardWindowPayload.fromTab(
    DesktopTab tab, {
    BoardTabGameArgs? boardArgs,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return DesktopBoardWindowPayload(
      title: tab.title,
      kind: tab.kind,
      subtitle: tab.subtitle,
      args: boardArgs,
      metadata: metadata,
    );
  }

  factory DesktopBoardWindowPayload.fromJson(Map<String, Object?> json) {
    final argsJson = json['args'];
    final kind = _kind(json['kind']);
    final metadataJson = json['metadata'];
    return DesktopBoardWindowPayload(
      title:
          (json['title'] as String?)?.trim().isNotEmpty == true
              ? (json['title'] as String).trim()
              : kind.defaultTitle,
      kind: kind,
      subtitle: _nullableString(json['subtitle']),
      args:
          argsJson is Map
              ? _argsFromJson(argsJson.cast<String, Object?>())
              : null,
      metadata:
          metadataJson is Map
              ? metadataJson.cast<String, Object?>()
              : const <String, Object?>{},
    );
  }

  factory DesktopBoardWindowPayload.decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Board window payload must be an object');
    }
    final json = decoded.cast<String, Object?>();
    if (json['type'] != desktopBoardWindowPayloadType &&
        json['type'] != desktopTabWindowPayloadType) {
      throw FormatException('Unsupported window type: ${json['type']}');
    }
    if (json['type'] == desktopBoardWindowPayloadType) {
      json['kind'] ??= TabKind.board.name;
    }
    return DesktopBoardWindowPayload.fromJson(json);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'type': desktopTabWindowPayloadType,
    'title': title,
    'kind': kind.name,
    'subtitle': subtitle,
    if (args != null) 'args': _argsToJson(args!),
    if (metadata.isNotEmpty) 'metadata': metadata,
  };

  String encode() => jsonEncode(toJson());
}

Map<String, Object?> _argsToJson(BoardTabGameArgs args) => <String, Object?>{
  'gameId': args.gameId,
  'pgn': args.pgn,
  'label': args.label,
  'whiteName': args.whiteName,
  'blackName': args.blackName,
  'whiteFederation': args.whiteFederation,
  'blackFederation': args.blackFederation,
  'whiteTitle': args.whiteTitle,
  'blackTitle': args.blackTitle,
  'whiteRating': args.whiteRating,
  'blackRating': args.blackRating,
  'whiteFideId': args.whiteFideId,
  'blackFideId': args.blackFideId,
  'initialBoardFlipped': args.initialBoardFlipped,
  'fenSeed': args.fenSeed,
  'initialFen': args.initialFen,
  'viewSource': args.viewSource.name,
  'eventBroadcastId': args.eventBroadcastId,
  'tournamentTitle': args.tournamentTitle,
  'eventGames': _summariesToJson(args.eventGames),
  'eventGamesLoading': args.eventGamesLoading,
  'eventGamesKey': _eventGamesKeyToJson(args.eventGamesKey),
  'eventGamesContinuation': _continuationToJson(args.eventGamesContinuation),
  'routeTitle': args.routeTitle,
  'routeGames': _summariesToJson(args.routeGames),
  'routeGamesContinuation': _continuationToJson(args.routeGamesContinuation),
  'databaseTitle': args.databaseTitle,
  'databaseGames': _summariesToJson(args.databaseGames),
  'databaseGamesContinuation': _continuationToJson(
    args.databaseGamesContinuation,
  ),
  'gameListSelectedId': args.gameListSelectedId,
  'librarySaveOrigin': _librarySaveOriginToJson(args.librarySaveOrigin),
};

BoardTabGameArgs _argsFromJson(Map<String, Object?> json) {
  final label = _string(json['label']);
  return BoardTabGameArgs(
    gameId: _nullableString(json['gameId']),
    pgn: _string(json['pgn']),
    label: label.isEmpty ? 'Board' : label,
    whiteName: _string(json['whiteName']),
    blackName: _string(json['blackName']),
    whiteFederation: _string(json['whiteFederation']),
    blackFederation: _string(json['blackFederation']),
    whiteTitle: _string(json['whiteTitle']),
    blackTitle: _string(json['blackTitle']),
    whiteRating: _int(json['whiteRating']),
    blackRating: _int(json['blackRating']),
    whiteFideId: _nullableInt(json['whiteFideId']),
    blackFideId: _nullableInt(json['blackFideId']),
    initialBoardFlipped: json['initialBoardFlipped'] == true,
    fenSeed: _nullableString(json['fenSeed']),
    initialFen: _nullableString(json['initialFen']),
    viewSource: _viewSource(json['viewSource']),
    eventBroadcastId: _nullableString(json['eventBroadcastId']),
    tournamentTitle: _string(json['tournamentTitle']),
    eventGames: _summariesFromJson(json['eventGames']),
    eventGamesLoading: json['eventGamesLoading'] == true,
    eventGamesKey: _eventGamesKeyFromJson(json['eventGamesKey']),
    eventGamesContinuation: _continuationFromJson(
      json['eventGamesContinuation'],
    ),
    routeTitle: _string(json['routeTitle']),
    routeGames: _summariesFromJson(json['routeGames']),
    routeGamesContinuation: _continuationFromJson(
      json['routeGamesContinuation'],
    ),
    databaseTitle: _string(json['databaseTitle']),
    databaseGames: _summariesFromJson(json['databaseGames']),
    databaseGamesContinuation: _continuationFromJson(
      json['databaseGamesContinuation'],
    ),
    gameListSelectedId: _nullableString(json['gameListSelectedId']),
    librarySaveOrigin: _librarySaveOriginFromJson(json['librarySaveOrigin']),
  );
}

Map<String, Object?>? _eventGamesKeyToJson(BoardTabEventGamesKey? key) {
  if (key == null) return null;
  return <String, Object?>{
    'tourId': key.tourId,
    'selectedGameId': key.selectedGameId,
    'selectedRoundId': key.selectedRoundId,
    'selectedBoardNumber': key.selectedBoardNumber,
  };
}

BoardTabEventGamesKey? _eventGamesKeyFromJson(Object? value) {
  if (value is! Map) return null;
  final json = value.cast<String, Object?>();
  final tourId = _string(json['tourId']).trim();
  if (tourId.isEmpty) return null;
  return BoardTabEventGamesKey(
    tourId: tourId,
    selectedGameId: _string(json['selectedGameId']),
    selectedRoundId: _string(json['selectedRoundId']),
    selectedBoardNumber: _nullableInt(json['selectedBoardNumber']),
  );
}

List<Object?> _summariesToJson(List<TournamentGameSummary> games) {
  return [for (final game in games) _summaryToJson(game)];
}

Map<String, Object?> _summaryToJson(TournamentGameSummary game) {
  return <String, Object?>{
    'id': game.id,
    'name': game.name,
    'whitePlayer': game.whitePlayer,
    'blackPlayer': game.blackPlayer,
    'hasPgn': game.hasPgn,
    'tourId': game.tourId,
    'tourSlug': game.tourSlug,
    'whiteFederation': game.whiteFederation,
    'blackFederation': game.blackFederation,
    'whiteTitle': game.whiteTitle,
    'blackTitle': game.blackTitle,
    'whiteRating': game.whiteRating,
    'blackRating': game.blackRating,
    'whiteFideId': game.whiteFideId,
    'blackFideId': game.blackFideId,
    'fen': game.fen,
    'roundId': game.roundId,
    'roundSlug': game.roundSlug,
    'roundLabel': game.roundLabel,
    'roundName': game.roundName,
    'boardNumber': game.boardNumber,
    'status': game.status.name,
    'openingName': game.openingName,
    'lastMoveTime': game.lastMoveTime?.toIso8601String(),
    'startsAt': game.startsAt?.toIso8601String(),
    'roundStartsAt': game.roundStartsAt?.toIso8601String(),
    'hasStarted': game.hasStarted,
    'pgn': game.pgn,
    'localPgnSource': _localPgnSourceToJson(game.localPgnSource),
  };
}

List<TournamentGameSummary> _summariesFromJson(Object? value) {
  if (value is! List) return const <TournamentGameSummary>[];
  return [
    for (final item in value)
      if (item is Map) _summaryFromJson(item.cast<String, Object?>()),
  ];
}

TournamentGameSummary _summaryFromJson(Map<String, Object?> json) {
  return TournamentGameSummary(
    id: _string(json['id']),
    name: _string(json['name']),
    whitePlayer: _string(json['whitePlayer']),
    blackPlayer: _string(json['blackPlayer']),
    hasPgn: json['hasPgn'] == true,
    tourId: _string(json['tourId']),
    tourSlug: _string(json['tourSlug']),
    whiteFederation: _string(json['whiteFederation']),
    blackFederation: _string(json['blackFederation']),
    whiteTitle: _string(json['whiteTitle']),
    blackTitle: _string(json['blackTitle']),
    whiteRating: _int(json['whiteRating']),
    blackRating: _int(json['blackRating']),
    whiteFideId: _nullableInt(json['whiteFideId']),
    blackFideId: _nullableInt(json['blackFideId']),
    fen: _nullableString(json['fen']),
    roundId: _string(json['roundId']),
    roundSlug: _string(json['roundSlug']),
    roundLabel: _string(json['roundLabel']),
    roundName: _string(json['roundName']),
    boardNumber: _nullableInt(json['boardNumber']),
    status: _gameStatus(json['status']),
    openingName: _nullableString(json['openingName']),
    lastMoveTime: _date(json['lastMoveTime']),
    startsAt: _date(json['startsAt']),
    roundStartsAt: _date(json['roundStartsAt']),
    hasStarted: json['hasStarted'] == true,
    pgn: _nullableString(json['pgn']),
    localPgnSource: _localPgnSourceFromJson(json['localPgnSource']),
  );
}

Map<String, Object?>? _localPgnSourceToJson(
  TournamentGameLocalPgnSource? source,
) {
  if (source == null) return null;
  return <String, Object?>{
    'sourcePath': source.sourcePath,
    'sourceIndex': source.sourceIndex,
    'sourceFileGameCount': source.sourceFileGameCount,
    'pgnFingerprint': source.pgnFingerprint,
    'title': source.title,
  };
}

TournamentGameLocalPgnSource? _localPgnSourceFromJson(Object? value) {
  if (value is! Map) return null;
  final json = value.cast<String, Object?>();
  final sourcePath = _string(json['sourcePath']);
  if (sourcePath.isEmpty) return null;
  return TournamentGameLocalPgnSource(
    sourcePath: sourcePath,
    sourceIndex: _int(json['sourceIndex']),
    sourceFileGameCount: _int(json['sourceFileGameCount']),
    pgnFingerprint: _string(json['pgnFingerprint']),
    title: _string(json['title']),
  );
}

Map<String, Object?>? _librarySaveOriginToJson(
  BoardTabLibrarySaveOrigin? origin,
) {
  if (origin == null) return null;
  return <String, Object?>{
    'kind': origin.kind.name,
    'analysisId': origin.analysisId,
    'sourcePath': origin.sourcePath,
    'sourceIndex': origin.sourceIndex,
    'sourceFileGameCount': origin.sourceFileGameCount,
    'sourcePgnFingerprint': origin.sourcePgnFingerprint,
    'title': origin.title,
  };
}

BoardTabLibrarySaveOrigin? _librarySaveOriginFromJson(Object? value) {
  if (value is! Map) return null;
  final json = value.cast<String, Object?>();
  final kind = _string(json['kind']);
  final title = _string(json['title']);
  switch (kind) {
    case 'cloudSavedAnalysis':
      final analysisId = _string(json['analysisId']);
      if (analysisId.isEmpty) return null;
      return BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
        analysisId: analysisId,
        title: title,
      );
    case 'localPgnFile':
      final sourcePath = _string(json['sourcePath']);
      if (sourcePath.isEmpty) return null;
      return BoardTabLibrarySaveOrigin.localPgnFile(
        sourcePath: sourcePath,
        sourceIndex: _int(json['sourceIndex']),
        sourceFileGameCount: _int(json['sourceFileGameCount']),
        sourcePgnFingerprint: _string(json['sourcePgnFingerprint']),
        title: title,
      );
  }
  return null;
}

Map<String, Object?>? _continuationToJson(
  BoardTabGamesContinuation? continuation,
) {
  if (continuation == null) return null;
  return <String, Object?>{
    'kind': continuation.kind.name,
    if (continuation.argument is PremiumGamesType)
      'premiumGamesType': (continuation.argument! as PremiumGamesType).name,
    if (continuation.argument is PlayerProfileKey)
      'playerProfileKey': _playerProfileKeyToJson(
        continuation.argument! as PlayerProfileKey,
      ),
  };
}

Map<String, Object?> _playerProfileKeyToJson(PlayerProfileKey key) {
  return <String, Object?>{
    'fideId': key.fideId,
    'playerName': key.playerName,
    'source': key.source.name,
    'gamebasePlayerId': key.gamebasePlayerId,
  };
}

BoardTabGamesContinuation? _continuationFromJson(Object? value) {
  if (value is! Map) return null;
  final json = value.cast<String, Object?>();
  final kindName = json['kind']?.toString();
  final kind =
      BoardTabGamesContinuationKind.values
          .where((kind) => kind.name == kindName)
          .firstOrNull;
  if (kind == null) return null;
  switch (kind) {
    case BoardTabGamesContinuationKind.smartGames:
      final typeName = json['premiumGamesType']?.toString();
      final type =
          PremiumGamesType.values
              .where((type) => type.name == typeName)
              .firstOrNull;
      return type == null ? null : BoardTabGamesContinuation.smartGames(type);
    case BoardTabGamesContinuationKind.favorites:
      return const BoardTabGamesContinuation.favorites();
    case BoardTabGamesContinuationKind.countrymen:
      return const BoardTabGamesContinuation.countrymen();
    case BoardTabGamesContinuationKind.twicDatabase:
      return const BoardTabGamesContinuation.twicDatabase();
    case BoardTabGamesContinuationKind.playerProfile:
      final keyJson = json['playerProfileKey'];
      if (keyJson is! Map) return null;
      return BoardTabGamesContinuation.playerProfile(
        _playerProfileKeyFromJson(keyJson.cast<String, Object?>()),
      );
  }
}

PlayerProfileKey _playerProfileKeyFromJson(Map<String, Object?> json) {
  return PlayerProfileKey(
    fideId: _nullableInt(json['fideId']),
    playerName: _string(json['playerName']),
    source: _playerProfileDataSource(json['source']),
    gamebasePlayerId: _nullableString(json['gamebasePlayerId']),
  );
}

String _string(Object? value) => value?.toString() ?? '';

String? _nullableString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int _int(Object? value) => _nullableInt(value) ?? 0;

int? _nullableInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _date(Object? value) {
  final text = value?.toString();
  return text == null || text.isEmpty ? null : DateTime.tryParse(text);
}

ChessboardView _viewSource(Object? value) {
  final name = value?.toString();
  for (final view in ChessboardView.values) {
    if (view.name == name) return view;
  }
  return ChessboardView.tour;
}

GameStatus _gameStatus(Object? value) {
  final name = value?.toString();
  for (final status in GameStatus.values) {
    if (status.name == name) return status;
  }
  return GameStatus.fromString(name);
}

PlayerProfileDataSource _playerProfileDataSource(Object? value) {
  final name = value?.toString();
  for (final source in PlayerProfileDataSource.values) {
    if (source.name == name) return source;
  }
  return PlayerProfileDataSource.supabase;
}

TabKind _kind(Object? value) {
  final name = value?.toString();
  for (final kind in TabKind.values) {
    if (kind.name == name) return kind;
  }
  return TabKind.board;
}
