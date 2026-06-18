import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';

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
  'tournamentTitle': args.tournamentTitle,
  'routeTitle': args.routeTitle,
  'databaseTitle': args.databaseTitle,
  'gameListSelectedId': args.gameListSelectedId,
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
    tournamentTitle: _string(json['tournamentTitle']),
    routeTitle: _string(json['routeTitle']),
    databaseTitle: _string(json['databaseTitle']),
    gameListSelectedId: _nullableString(json['gameListSelectedId']),
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

ChessboardView _viewSource(Object? value) {
  final name = value?.toString();
  for (final view in ChessboardView.values) {
    if (view.name == name) return view;
  }
  return ChessboardView.tour;
}

TabKind _kind(Object? value) {
  final name = value?.toString();
  for (final kind in TabKind.values) {
    if (kind.name == name) return kind;
  }
  return TabKind.board;
}
