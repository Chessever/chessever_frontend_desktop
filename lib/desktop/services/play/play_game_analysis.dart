import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/desktop/services/engine/uci_engine.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/tournament_server/tournament_models.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';

enum PlayGameSource {
  singlePlay('single_play'),
  playFromHere('play_from_here'),
  tournament('tournament');

  const PlayGameSource(this.value);
  final String value;

  static PlayGameSource fromValue(String value) {
    return PlayGameSource.values.firstWhere(
      (source) => source.value == value,
      orElse: () => PlayGameSource.singlePlay,
    );
  }
}

@immutable
class PlayOpeningSummary {
  const PlayOpeningSummary({this.eco, this.name});

  final String? eco;
  final String? name;

  bool get isCaroKann => name?.toLowerCase().contains('caro-kann') == true;
  bool get isSicilian => name?.toLowerCase().contains('sicilian') == true;
  bool get isFrench => name?.toLowerCase().contains('french') == true;
  bool get isQueenGambit =>
      name?.toLowerCase().contains('queen\'s gambit') == true;
  bool get isRuyLopez => name?.toLowerCase().contains('ruy lopez') == true;
  bool get isLondon => name?.toLowerCase().contains('london') == true;
  bool get isKingsIndian =>
      name?.toLowerCase().contains('king\'s indian') == true ||
      name?.toLowerCase().contains('kings indian') == true;
  bool get isNimzoIndian =>
      name?.toLowerCase().contains('nimzo-indian') == true ||
      name?.toLowerCase().contains('nimzo indian') == true;
  bool get isSlav => name?.toLowerCase().contains('slav') == true;
  bool get isEnglish => name?.toLowerCase().contains('english') == true;
  bool get isPircOrModern =>
      name?.toLowerCase().contains('pirc') == true ||
      name?.toLowerCase().contains('modern defense') == true;
  bool get isScandinavian =>
      name?.toLowerCase().contains('scandinavian') == true;

  Map<String, dynamic> toJson() => {
    if (eco != null) 'eco': eco,
    if (name != null) 'name': name,
  };
}

@immutable
class PlayAnalysisPoint {
  const PlayAnalysisPoint({
    required this.ply,
    required this.fen,
    required this.humanCentipawns,
    this.bestMove,
    this.mateIn,
  });

  final int ply;
  final String fen;
  final int humanCentipawns;
  final String? bestMove;
  final int? mateIn;

  Map<String, dynamic> toJson() => {
    'ply': ply,
    'fen': fen,
    'humanCentipawns': humanCentipawns,
    if (bestMove != null) 'bestMove': bestMove,
    if (mateIn != null) 'mateIn': mateIn,
  };
}

@immutable
class PlayGameRecord {
  const PlayGameRecord({
    required this.localGameKey,
    required this.source,
    required this.playedAt,
    required this.result,
    required this.endReason,
    required this.startingFen,
    required this.finalFen,
    required this.movesUci,
    required this.pgn,
    required this.pgnHeaders,
    required this.metadata,
    required this.analysis,
    required this.badgeContributions,
    this.eco,
    this.openingName,
    this.timeCategory,
    this.baseSeconds,
    this.incrementSeconds,
    this.humanColor,
    this.opponentEngine,
    this.opponentElo,
    this.whiteName = 'White',
    this.blackName = 'Black',
    this.whiteTitle,
    this.blackTitle,
    this.whiteCountry,
    this.blackCountry,
    this.whiteElo,
    this.blackElo,
    this.whiteEngine,
    this.blackEngine,
    this.ratingBefore,
    this.ratingAfter,
  });

  final String localGameKey;
  final PlayGameSource source;
  final DateTime playedAt;
  final String result;
  final String endReason;
  final String startingFen;
  final String finalFen;
  final List<String> movesUci;
  final String pgn;
  final Map<String, String> pgnHeaders;
  final Map<String, dynamic> metadata;
  final Map<String, dynamic> analysis;
  final List<PlayBadgeContribution> badgeContributions;
  final String? eco;
  final String? openingName;
  final String? timeCategory;
  final int? baseSeconds;
  final int? incrementSeconds;
  final String? humanColor;
  final String? opponentEngine;
  final int? opponentElo;
  final String whiteName;
  final String blackName;
  final String? whiteTitle;
  final String? blackTitle;
  final String? whiteCountry;
  final String? blackCountry;
  final int? whiteElo;
  final int? blackElo;
  final String? whiteEngine;
  final String? blackEngine;
  final int? ratingBefore;
  final int? ratingAfter;

  List<String> get badgeIds =>
      badgeContributions.map((c) => c.id.name).toSet().toList();

  double? get userScore {
    if (humanColor == null) return null;
    return switch (result) {
      '1-0' => humanColor == 'white' ? 1 : 0,
      '0-1' => humanColor == 'black' ? 1 : 0,
      '1/2-1/2' => 0.5,
      _ => null,
    };
  }

  PlayGameRecord copyWith({int? ratingBefore, int? ratingAfter}) {
    return PlayGameRecord(
      localGameKey: localGameKey,
      source: source,
      playedAt: playedAt,
      result: result,
      endReason: endReason,
      startingFen: startingFen,
      finalFen: finalFen,
      movesUci: movesUci,
      pgn: pgn,
      pgnHeaders: pgnHeaders,
      metadata: metadata,
      analysis: analysis,
      badgeContributions: badgeContributions,
      eco: eco,
      openingName: openingName,
      timeCategory: timeCategory,
      baseSeconds: baseSeconds,
      incrementSeconds: incrementSeconds,
      humanColor: humanColor,
      opponentEngine: opponentEngine,
      opponentElo: opponentElo,
      whiteName: whiteName,
      blackName: blackName,
      whiteTitle: whiteTitle,
      blackTitle: blackTitle,
      whiteCountry: whiteCountry,
      blackCountry: blackCountry,
      whiteElo: whiteElo,
      blackElo: blackElo,
      whiteEngine: whiteEngine,
      blackEngine: blackEngine,
      ratingBefore: ratingBefore ?? this.ratingBefore,
      ratingAfter: ratingAfter ?? this.ratingAfter,
    );
  }

  Map<String, dynamic> toLocalJson() => {
    'localGameKey': localGameKey,
    'gameSource': source.value,
    'playedAt': playedAt.toUtc().toIso8601String(),
    'result': result,
    'endReason': endReason,
    'startingFen': startingFen,
    'finalFen': finalFen,
    'movesUci': movesUci,
    'pgn': pgn,
    'pgnHeaders': pgnHeaders,
    'eco': eco,
    'openingName': openingName,
    'timeCategory': timeCategory,
    'baseSeconds': baseSeconds,
    'incrementSeconds': incrementSeconds,
    'humanColor': humanColor,
    'opponentEngine': opponentEngine,
    'opponentElo': opponentElo,
    'whiteName': whiteName,
    'blackName': blackName,
    'whiteTitle': whiteTitle,
    'blackTitle': blackTitle,
    'whiteCountry': whiteCountry,
    'blackCountry': blackCountry,
    'whiteElo': whiteElo,
    'blackElo': blackElo,
    'whiteEngine': whiteEngine,
    'blackEngine': blackEngine,
    'ratingBefore': ratingBefore,
    'ratingAfter': ratingAfter,
    'badgeIds': badgeIds,
    'badgeReasons': badgeContributions.map((c) => c.toJson()).toList(),
    'analysis': analysis,
    'metadata': metadata,
  };

  Map<String, dynamic> toSupabaseJson(String userId) => {
    'user_id': userId,
    'local_game_key': localGameKey,
    'game_source': source.value,
    'played_at': playedAt.toUtc().toIso8601String(),
    'result': result,
    'end_reason': endReason,
    'starting_fen': startingFen,
    'final_fen': finalFen,
    'moves_uci': movesUci,
    'pgn': pgn,
    'pgn_headers': pgnHeaders,
    'eco': eco,
    'opening_name': openingName,
    'time_category': timeCategory,
    'base_seconds': baseSeconds,
    'increment_seconds': incrementSeconds,
    'human_color': humanColor,
    'opponent_engine': opponentEngine,
    'opponent_elo': opponentElo,
    'white_name': whiteName,
    'black_name': blackName,
    'white_title': whiteTitle,
    'black_title': blackTitle,
    'white_country': whiteCountry,
    'black_country': blackCountry,
    'white_elo': whiteElo,
    'black_elo': blackElo,
    'white_engine': whiteEngine,
    'black_engine': blackEngine,
    'rating_before': ratingBefore,
    'rating_after': ratingAfter,
    'badge_ids': badgeIds,
    'badge_reasons': badgeContributions.map((c) => c.toJson()).toList(),
    'analysis': analysis,
    'metadata': metadata,
  };

  static PlayGameRecord fromJson(Map<String, dynamic> json) {
    T? read<T>(String camel, String snake) {
      final value = json[camel] ?? json[snake];
      return value is T ? value : null;
    }

    int? readInt(String camel, String snake) {
      final value = json[camel] ?? json[snake];
      return value is num
          ? value.toInt()
          : int.tryParse(value?.toString() ?? '');
    }

    final badgeReasonsRaw = json['badgeReasons'] ?? json['badge_reasons'];
    final badgeContributions = <PlayBadgeContribution>[];
    if (badgeReasonsRaw is List) {
      for (final raw in badgeReasonsRaw) {
        if (raw is! Map) continue;
        final idName = raw['id']?.toString();
        if (idName == null) continue;
        try {
          badgeContributions.add(
            PlayBadgeContribution(
              id: PlayAchievementId.values.byName(idName),
              reason:
                  raw['reason']?.toString() ??
                  achievementDefinition(
                    PlayAchievementId.values.byName(idName),
                  ).title,
              detail: raw['detail']?.toString(),
              metadata:
                  (raw['metadata'] as Map?)?.cast<String, dynamic>() ??
                  const <String, dynamic>{},
            ),
          );
        } catch (_) {}
      }
    }

    final playedRaw = json['playedAt'] ?? json['played_at'];
    return PlayGameRecord(
      localGameKey:
          read<String>('localGameKey', 'local_game_key') ?? 'unknown-game',
      source: PlayGameSource.fromValue(
        read<String>('gameSource', 'game_source') ??
            PlayGameSource.singlePlay.value,
      ),
      playedAt:
          DateTime.tryParse(playedRaw?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      result: read<String>('result', 'result') ?? '*',
      endReason: read<String>('endReason', 'end_reason') ?? '',
      startingFen:
          read<String>('startingFen', 'starting_fen') ?? Chess.initial.fen,
      finalFen: read<String>('finalFen', 'final_fen') ?? Chess.initial.fen,
      movesUci: ((json['movesUci'] ?? json['moves_uci']) as List<dynamic>? ??
              const <dynamic>[])
          .map((e) => e.toString())
          .toList(growable: false),
      pgn: read<String>('pgn', 'pgn') ?? '',
      pgnHeaders: ((json['pgnHeaders'] ?? json['pgn_headers']) as Map? ??
              const {})
          .map((key, value) => MapEntry(key.toString(), value.toString())),
      metadata:
          ((json['metadata'] as Map?) ?? const {}).cast<String, dynamic>(),
      analysis:
          ((json['analysis'] as Map?) ?? const {}).cast<String, dynamic>(),
      badgeContributions: badgeContributions,
      eco: read<String>('eco', 'eco'),
      openingName: read<String>('openingName', 'opening_name'),
      timeCategory: read<String>('timeCategory', 'time_category'),
      baseSeconds: readInt('baseSeconds', 'base_seconds'),
      incrementSeconds: readInt('incrementSeconds', 'increment_seconds'),
      humanColor: read<String>('humanColor', 'human_color'),
      opponentEngine: read<String>('opponentEngine', 'opponent_engine'),
      opponentElo: readInt('opponentElo', 'opponent_elo'),
      whiteName: read<String>('whiteName', 'white_name') ?? 'White',
      blackName: read<String>('blackName', 'black_name') ?? 'Black',
      whiteTitle: read<String>('whiteTitle', 'white_title'),
      blackTitle: read<String>('blackTitle', 'black_title'),
      whiteCountry: read<String>('whiteCountry', 'white_country'),
      blackCountry: read<String>('blackCountry', 'black_country'),
      whiteElo: readInt('whiteElo', 'white_elo'),
      blackElo: readInt('blackElo', 'black_elo'),
      whiteEngine: read<String>('whiteEngine', 'white_engine'),
      blackEngine: read<String>('blackEngine', 'black_engine'),
      ratingBefore: readInt('ratingBefore', 'rating_before'),
      ratingAfter: readInt('ratingAfter', 'rating_after'),
    );
  }
}

class PlayGameAnalyzer {
  const PlayGameAnalyzer();

  Future<PlayGameRecord> analyzeSession(
    PlaySessionState session, {
    String? analyzerBinaryPath,
    BotEngineKind? analyzerEngine,
    String userDisplayName = 'You',
    PlayGameSource? sourceOverride,
    String? eventTitle,
    int? eventRound,
    String? tournamentGameId,
  }) async {
    final playedAt = DateTime.now();
    final opening = classifyOpening(session.startingFen, session.history);
    final mainline = _buildMainline(session.startingFen, session.history);
    final result = _resultForOutcome(session.outcome);
    final humanColor = session.humanSide == Side.white ? 'white' : 'black';
    final bot = session.botIdentity;
    final inferredSource =
        session.config.hasStartingPositionSeed
            ? PlayGameSource.playFromHere
            : PlayGameSource.singlePlay;
    final source = sourceOverride ?? inferredSource;
    final whiteIsHuman = session.humanSide == Side.white;
    final localKey = _gameKey(
      source == PlayGameSource.tournament
          ? 'tournament-${eventTitle ?? 'local'}-${tournamentGameId ?? ''}'
          : 'play',
      session.startingFen,
      session.history,
    );
    final shareUrl = _gameShareUrl(localKey);
    final headers = _sessionHeaders(
      session: session,
      bot: bot,
      playedAt: playedAt,
      result: result,
      opening: opening,
      userDisplayName: userDisplayName,
      source: source,
      eventTitle: eventTitle,
      eventRound: eventRound,
      tournamentGameId: tournamentGameId,
      shareUrl: shareUrl,
    );
    final chessGame = ChessGame(
      gameId: localKey,
      startingFen: session.startingFen,
      metadata: headers,
      mainline: mainline,
    );
    final analysis = await _analyzeCourse(
      startingFen: session.startingFen,
      movesUci: session.history,
      humanSide: session.humanSide,
      analyzerBinaryPath: analyzerBinaryPath,
      analyzerEngine: analyzerEngine ?? session.config.engine,
    );
    final contributions = _badgeContributions(
      source: source,
      startingFen: session.startingFen,
      humanSide: session.humanSide,
      result: result,
      endReason: session.endReason.name,
      opening: opening,
      movesUci: session.history,
      analysis: analysis,
      timeCategory: session.config.category,
      opponentEngine: session.config.engine,
      humanMillisRemaining:
          session.humanSide == Side.white
              ? session.whiteMillis
              : session.blackMillis,
    );
    final pgn = exportGameToPgn(chessGame);
    return PlayGameRecord(
      localGameKey: chessGame.gameId,
      source: source,
      playedAt: playedAt,
      result: result,
      endReason: session.endReason.name,
      startingFen: session.startingFen,
      finalFen: session.position.fen,
      movesUci: session.history,
      pgn: pgn,
      pgnHeaders: headers,
      metadata: {
        'headers': headers,
        'botIdentity': _botJson(bot),
        'timeControl': {
          'category': session.config.category.name,
          'baseSeconds': session.config.baseSeconds,
          'incrementSeconds': session.config.incrementSeconds,
          'shorthand': session.config.timeControlShorthand,
        },
        'clocks': {
          'whiteMillis': session.whiteMillis,
          'blackMillis': session.blackMillis,
        },
        'playFromHere': source == PlayGameSource.playFromHere,
        if (source == PlayGameSource.tournament)
          'tournament': {
            'title': eventTitle,
            'round': eventRound,
            'gameId': tournamentGameId,
          },
      },
      analysis: analysis,
      badgeContributions: contributions,
      eco: opening.eco,
      openingName: opening.name,
      timeCategory: session.config.category.name,
      baseSeconds: session.config.baseSeconds,
      incrementSeconds: session.config.incrementSeconds,
      humanColor: humanColor,
      opponentEngine: session.config.engine.name,
      opponentElo: session.config.elo,
      whiteName: whiteIsHuman ? userDisplayName : bot.fullName,
      blackName: whiteIsHuman ? bot.fullName : userDisplayName,
      whiteTitle: whiteIsHuman ? null : bot.title,
      blackTitle: whiteIsHuman ? bot.title : null,
      whiteCountry: whiteIsHuman ? null : bot.countryCode,
      blackCountry: whiteIsHuman ? bot.countryCode : null,
      whiteElo: whiteIsHuman ? null : bot.elo,
      blackElo: whiteIsHuman ? bot.elo : null,
      whiteEngine: whiteIsHuman ? null : session.config.engine.name,
      blackEngine: whiteIsHuman ? session.config.engine.name : null,
    );
  }

  PlayGameRecord buildTournamentRecord({
    required TournamentSnapshot snapshot,
    required TournamentGame game,
  }) {
    final playedAt = DateTime.now();
    final white = snapshot.participantById(game.whiteId);
    final black = snapshot.participantById(game.blackId);
    final humanId = snapshot.humanParticipantId;
    final humanIsWhite = humanId != null && game.whiteId == humanId;
    final humanIsBlack = humanId != null && game.blackId == humanId;
    final opponent = humanIsWhite ? black : (humanIsBlack ? white : null);
    final boardStartFen = game.startingFen ?? Chess.initial.fen;
    final startFen =
        _canReplay(Chess.initial.fen, game.movesUci)
            ? Chess.initial.fen
            : boardStartFen;
    final opening =
        _openingFromTournamentGame(game) ??
        classifyOpening(startFen, game.movesUci);
    final result = game.result ?? '*';
    final localKey = _gameKey(
      'tournament-${snapshot.config.title}-${game.id}',
      startFen,
      game.movesUci,
    );
    final shareUrl = _gameShareUrl(localKey);
    final headers = _tournamentHeaders(
      snapshot: snapshot,
      game: game,
      white: white,
      black: black,
      playedAt: playedAt,
      result: result,
      opening: opening,
      shareUrl: shareUrl,
    );
    final mainline = _buildMainline(startFen, game.movesUci);
    final chessGame = ChessGame(
      gameId: localKey,
      startingFen: startFen,
      metadata: headers,
      mainline: mainline,
    );
    return PlayGameRecord(
      localGameKey: localKey,
      source: PlayGameSource.tournament,
      playedAt: playedAt,
      result: result,
      endReason: game.endReason ?? '',
      startingFen: startFen,
      finalFen: game.fen ?? startFen,
      movesUci: game.movesUci,
      pgn: exportGameToPgn(chessGame),
      pgnHeaders: headers,
      metadata: {
        'headers': headers,
        'tournament': {
          'title': snapshot.config.title,
          'format': snapshot.config.format.name,
          'round': game.round,
          'gameId': game.id,
          'totalRounds': snapshot.totalRounds,
          'baseSeconds': snapshot.config.baseSeconds,
          'incrementSeconds': snapshot.config.incrementSeconds,
        },
        'whiteParticipant': white == null ? null : _participantJson(white),
        'blackParticipant': black == null ? null : _participantJson(black),
      },
      analysis: {
        'kind': 'tournament_metadata',
        'engineLookup': 'skipped_for_batch_tournament_save',
      },
      badgeContributions: const <PlayBadgeContribution>[],
      eco: opening.eco,
      openingName: opening.name,
      timeCategory: _categoryForSeconds(snapshot.config.baseSeconds).name,
      baseSeconds: snapshot.config.baseSeconds,
      incrementSeconds: snapshot.config.incrementSeconds,
      humanColor:
          humanIsWhite
              ? 'white'
              : humanIsBlack
              ? 'black'
              : null,
      opponentEngine: opponent?.engine.name,
      opponentElo: opponent?.identity.elo,
      whiteName: white?.identity.fullName ?? 'White',
      blackName: black?.identity.fullName ?? 'Black',
      whiteTitle: white?.identity.title,
      blackTitle: black?.identity.title,
      whiteCountry: white?.identity.countryCode,
      blackCountry: black?.identity.countryCode,
      whiteElo: white?.identity.elo,
      blackElo: black?.identity.elo,
      whiteEngine: white?.engine.name,
      blackEngine: black?.engine.name,
    );
  }

  Future<Map<String, dynamic>> _analyzeCourse({
    required String startingFen,
    required List<String> movesUci,
    required Side humanSide,
    required String? analyzerBinaryPath,
    required BotEngineKind analyzerEngine,
  }) async {
    final samples = _samplePositions(startingFen, movesUci, maxSamples: 14);
    if (samples.isEmpty) {
      return const {'kind': 'empty', 'points': <dynamic>[]};
    }

    if (analyzerBinaryPath != null &&
        analyzerBinaryPath.trim().isNotEmpty &&
        !isMaia3ModelPath(analyzerBinaryPath)) {
      try {
        final engine = await UciEngine.spawn(
          analyzerBinaryPath,
          arguments: engineLaunchArguments(
            analyzerEngine,
            analyzerBinaryPath,
            2000,
          ),
          workingDirectory: engineWorkingDirectory(analyzerBinaryPath),
        );
        try {
          final ok = await engine.initialize(
            threads: 1,
            hashMb: 32,
            multiPv: 1,
          );
          if (ok) {
            engine.send('ucinewgame');
            final points = <PlayAnalysisPoint>[];
            for (final sample in samples) {
              final point = await _evalWithUci(
                engine,
                sample,
                humanSide: humanSide,
              );
              points.add(point ?? _heuristicPoint(sample, humanSide));
            }
            return _analysisPayload(
              kind: 'uci_quick',
              evaluator: 'stockfish-compatible',
              points: points,
            );
          }
        } finally {
          await engine.dispose();
        }
      } catch (e, st) {
        if (kDebugMode) debugPrint('Play quick analysis fallback: $e\n$st');
      }
    }

    return _analysisPayload(
      kind: 'material_heuristic',
      evaluator: 'local material balance',
      points: [
        for (final sample in samples) _heuristicPoint(sample, humanSide),
      ],
    );
  }

  Future<PlayAnalysisPoint?> _evalWithUci(
    UciEngine engine,
    _PositionSample sample, {
    required Side humanSide,
  }) async {
    int? latestCp;
    int? latestMate;
    String? bestMove;
    final completer = Completer<void>();
    late final StreamSubscription<String> sub;
    sub = engine.lines.listen((line) {
      final score = _parseScore(line);
      if (score != null) {
        latestCp = score.cp;
        latestMate = score.mate;
      }
      if (line.startsWith('bestmove')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) bestMove = parts[1];
        if (!completer.isCompleted) completer.complete();
      }
    });
    engine.send('position fen ${sample.position.fen}');
    engine.send('go movetime 70');
    await completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    await sub.cancel();
    final cp = latestCp;
    final mate = latestMate;
    if (cp == null && mate == null) return null;
    final raw = mate != null ? (mate.sign * 100000) : cp!;
    final whiteCp = sample.position.turn == Side.white ? raw : -raw;
    final humanCp = humanSide == Side.white ? whiteCp : -whiteCp;
    return PlayAnalysisPoint(
      ply: sample.ply,
      fen: sample.position.fen,
      humanCentipawns: humanCp.clamp(-100000, 100000),
      bestMove: bestMove,
      mateIn: mate,
    );
  }

  _UciScore? _parseScore(String line) {
    if (!line.startsWith('info ') || !line.contains(' score ')) return null;
    final parts = line.split(RegExp(r'\s+'));
    for (var i = 0; i + 2 < parts.length; i++) {
      if (parts[i] != 'score') continue;
      final kind = parts[i + 1];
      final value = int.tryParse(parts[i + 2]);
      if (value == null) return null;
      if (kind == 'cp') return _UciScore(cp: value);
      if (kind == 'mate') return _UciScore(mate: value);
    }
    return null;
  }

  PlayAnalysisPoint _heuristicPoint(_PositionSample sample, Side humanSide) {
    final whiteCp = _materialCentipawns(sample.position);
    return PlayAnalysisPoint(
      ply: sample.ply,
      fen: sample.position.fen,
      humanCentipawns: humanSide == Side.white ? whiteCp : -whiteCp,
    );
  }

  int _materialCentipawns(Position position) {
    var white = 0;
    var black = 0;
    for (final square in Square.values) {
      final piece = position.board.pieceAt(square);
      if (piece == null) continue;
      final value = switch (piece.role) {
        Role.pawn => 100,
        Role.knight => 320,
        Role.bishop => 330,
        Role.rook => 500,
        Role.queen => 900,
        Role.king => 0,
      };
      if (piece.color == Side.white) {
        white += value;
      } else {
        black += value;
      }
    }
    return white - black;
  }
}

Map<String, dynamic> _analysisPayload({
  required String kind,
  required String evaluator,
  required List<PlayAnalysisPoint> points,
}) {
  final values = points.map((p) => p.humanCentipawns).toList(growable: false);
  var largestDrop = 0;
  var largestRecovery = 0;
  for (var i = 1; i < values.length; i++) {
    largestDrop = max(largestDrop, values[i - 1] - values[i]);
    largestRecovery = max(largestRecovery, values[i] - values[i - 1]);
  }
  return {
    'kind': kind,
    'evaluator': evaluator,
    'sampledPlies': points.map((p) => p.ply).toList(),
    'minHumanCentipawns': values.isEmpty ? 0 : values.reduce(min),
    'maxHumanCentipawns': values.isEmpty ? 0 : values.reduce(max),
    'largestDropCentipawns': largestDrop,
    'largestRecoveryCentipawns': largestRecovery,
    'points': points.map((p) => p.toJson()).toList(),
  };
}

@immutable
class _GameShape {
  const _GameShape({
    required this.humanCapturedQueens,
    required this.humanCapturedRooks,
    required this.humanCapturedMinors,
    required this.humanPromoted,
    required this.humanCastled,
    required this.pawnEnding,
    required this.rookEnding,
    required this.minorPieceEnding,
  });

  final int humanCapturedQueens;
  final int humanCapturedRooks;
  final int humanCapturedMinors;
  final bool humanPromoted;
  final bool humanCastled;
  final bool pawnEnding;
  final bool rookEnding;
  final bool minorPieceEnding;
}

_GameShape _inspectGameShape({
  required String startingFen,
  required List<String> movesUci,
  required Side humanSide,
}) {
  var position = Position.setupPosition(
    Rule.chess,
    Setup.parseFen(startingFen),
  );
  var humanCapturedQueens = 0;
  var humanCapturedRooks = 0;
  var humanCapturedMinors = 0;
  var humanPromoted = false;
  var humanCastled = false;

  for (final uci in movesUci) {
    final move = NormalMove.fromUci(uci);
    if (!position.isLegal(move)) break;
    final mover = position.turn;
    final movingPiece = position.board.pieceAt(move.from);
    final captured = position.board.pieceAt(move.to);
    if (mover == humanSide) {
      if (captured != null && captured.color != mover) {
        switch (captured.role) {
          case Role.queen:
            humanCapturedQueens++;
          case Role.rook:
            humanCapturedRooks++;
          case Role.knight:
          case Role.bishop:
            humanCapturedMinors++;
          case Role.pawn:
          case Role.king:
            break;
        }
      }
      if (move.promotion != null) humanPromoted = true;
      if (movingPiece?.role == Role.king &&
          (move.to.file - move.from.file).abs() == 2) {
        humanCastled = true;
      }
    }
    position = position.play(move);
  }

  final nonPawnRoles = <Role>[];
  for (final square in Square.values) {
    final piece = position.board.pieceAt(square);
    if (piece == null) continue;
    if (piece.role == Role.king || piece.role == Role.pawn) continue;
    nonPawnRoles.add(piece.role);
  }
  final pawnEnding = nonPawnRoles.isEmpty;
  final rookEnding =
      nonPawnRoles.isNotEmpty && nonPawnRoles.every((r) => r == Role.rook);
  final minorPieceEnding =
      nonPawnRoles.isNotEmpty &&
      nonPawnRoles.every((r) => r == Role.knight || r == Role.bishop);

  return _GameShape(
    humanCapturedQueens: humanCapturedQueens,
    humanCapturedRooks: humanCapturedRooks,
    humanCapturedMinors: humanCapturedMinors,
    humanPromoted: humanPromoted,
    humanCastled: humanCastled,
    pawnEnding: pawnEnding,
    rookEnding: rookEnding,
    minorPieceEnding: minorPieceEnding,
  );
}

List<PlayBadgeContribution> _badgeContributions({
  required PlayGameSource source,
  required String startingFen,
  required Side humanSide,
  required String result,
  required String endReason,
  required PlayOpeningSummary opening,
  required List<String> movesUci,
  required Map<String, dynamic> analysis,
  required TimeControlCategory timeCategory,
  required BotEngineKind opponentEngine,
  required int humanMillisRemaining,
}) {
  final score = switch (result) {
    '1-0' => humanSide == Side.white ? 1.0 : 0.0,
    '0-1' => humanSide == Side.black ? 1.0 : 0.0,
    '1/2-1/2' => 0.5,
    _ => 0.0,
  };
  final won = score == 1.0;
  final drew = score == 0.5;
  final minCp = (analysis['minHumanCentipawns'] as num?)?.toInt() ?? 0;
  final maxCp = (analysis['maxHumanCentipawns'] as num?)?.toInt() ?? 0;
  final recovery =
      (analysis['largestRecoveryCentipawns'] as num?)?.toInt() ?? 0;
  final drop = (analysis['largestDropCentipawns'] as num?)?.toInt() ?? 0;
  final gameShape = _inspectGameShape(
    startingFen: startingFen,
    movesUci: movesUci,
    humanSide: humanSide,
  );
  final badges = <PlayBadgeContribution>[];

  void add(PlayAchievementId id, String reason, [String? detail]) {
    badges.add(
      PlayBadgeContribution(
        id: id,
        reason: reason,
        detail: detail,
        metadata: {
          'minCp': minCp,
          'maxCp': maxCp,
          'largestRecoveryCp': recovery,
          'largestDropCp': drop,
          'openingEco': opening.eco,
          'openingName': opening.name,
        },
      ),
    );
  }

  if (won && humanSide == Side.black) {
    add(PlayAchievementId.blackWin, 'Winning with Black');
  }
  if (won && humanSide == Side.white) {
    add(PlayAchievementId.whiteWin, 'Winning with White');
  }
  if (won) {
    switch (timeCategory) {
      case TimeControlCategory.bullet:
        add(PlayAchievementId.bulletWinner, 'Bullet win');
      case TimeControlCategory.blitz:
        add(PlayAchievementId.blitzWinner, 'Blitz win');
      case TimeControlCategory.rapid:
        add(PlayAchievementId.rapidWinner, 'Rapid win');
      case TimeControlCategory.classical:
        add(PlayAchievementId.classicalWinner, 'Classical win');
      case TimeControlCategory.custom:
        break;
    }
  }
  if (won && source == PlayGameSource.tournament) {
    add(PlayAchievementId.tournamentPoint, 'Scored in tournament play');
  }
  if (won) {
    switch (opponentEngine) {
      case BotEngineKind.stockfish:
        add(PlayAchievementId.stockfishSlayer, 'Beat Stockfish');
      case BotEngineKind.leela:
        add(PlayAchievementId.leelaBreaker, 'Beat Leela');
      case BotEngineKind.maia:
        add(PlayAchievementId.maiaMatch, 'Beat Maia');
    }
  }
  if ((won || drew) && minCp <= -220) {
    add(
      PlayAchievementId.defensiveHold,
      'Defended an unfavorable position',
      'Lowest quick-eval view: ${_cpLabel(minCp)}.',
    );
  }
  if (drew && minCp <= -350) {
    add(
      PlayAchievementId.resourcefulDraw,
      'Saved a difficult draw',
      'The engine saw you down ${_cpLabel(minCp)} before you held.',
    );
  }
  if (won && minCp <= -260) {
    add(
      PlayAchievementId.comebackWin,
      'Comeback win',
      'You recovered from ${_cpLabel(minCp)}.',
    );
  }
  if (won && minCp <= -650 && recovery >= 600) {
    add(
      PlayAchievementId.swindleWin,
      'Swindled a nearly lost game',
      'Largest recovery: ${_cpLabel(recovery)}.',
    );
  }
  if (won && maxCp >= 550 && endReason.toLowerCase().contains('checkmated')) {
    add(
      PlayAchievementId.attackFinish,
      'Attack finished the game',
      'Peak quick-eval pressure: ${_cpLabel(maxCp)}.',
    );
  }
  if (won && maxCp >= 350 && drop <= 260) {
    add(
      PlayAchievementId.cleanConversion,
      'Converted without giving the edge back',
      'Largest slip after gaining control: ${_cpLabel(drop)}.',
    );
  }
  if (won && gameShape.humanCapturedQueens > 0) {
    add(PlayAchievementId.queenHunter, 'Captured the queen');
  }
  if (won && gameShape.humanCapturedRooks >= 2) {
    add(PlayAchievementId.rookRaider, 'Captured both rooks');
  }
  if (won && gameShape.humanCapturedMinors >= 3) {
    add(PlayAchievementId.minorPieceCollector, 'Collected minor pieces');
  }
  if (won && gameShape.humanPromoted) {
    add(PlayAchievementId.promotionPoint, 'Promoted a pawn');
  }
  if (won && gameShape.humanCastled) {
    add(PlayAchievementId.castleAndWin, 'Castled and converted');
  }
  if (won && movesUci.length >= 100) {
    add(PlayAchievementId.endgameGrind, 'Won a long endgame grind');
  }
  if (won && gameShape.pawnEnding) {
    add(PlayAchievementId.pawnEnding, 'Won a pure pawn ending');
  }
  if (won && gameShape.rookEnding) {
    add(PlayAchievementId.rookEnding, 'Won through a rook ending');
  }
  if (won && gameShape.minorPieceEnding) {
    add(PlayAchievementId.minorPieceEnding, 'Won a minor-piece ending');
  }
  if (won && source == PlayGameSource.playFromHere) {
    add(PlayAchievementId.playFromHereWin, 'Won from an existing board');
  }
  if ((won || drew) && humanMillisRemaining <= 10000) {
    add(
      PlayAchievementId.lowTimeSave,
      'Survived the clock',
      'Finished with ${(humanMillisRemaining / 1000).toStringAsFixed(1)} seconds left.',
    );
  }
  if (movesUci.length >= 80) {
    add(PlayAchievementId.marathonSurvivor, 'Finished a marathon game');
  }
  if (won && movesUci.length <= 40) {
    add(PlayAchievementId.miniatureWin, 'Won a miniature');
  }
  if (won && opening.isCaroKann) {
    add(PlayAchievementId.caroKannWin, 'Caro-Kann Win', opening.name);
  }
  if (won && opening.isSicilian) {
    add(PlayAchievementId.sicilianWin, 'Sicilian Defense Win', opening.name);
  }
  if (won && opening.isFrench) {
    add(PlayAchievementId.frenchWin, 'French Defense Win', opening.name);
  }
  if (won && opening.isQueenGambit) {
    add(PlayAchievementId.queenGambitWin, 'Queen\'s Gambit Win', opening.name);
  }
  if (won && opening.isRuyLopez) {
    add(PlayAchievementId.ruyLopezWin, 'Ruy Lopez Win', opening.name);
  }
  if (won && opening.isLondon) {
    add(PlayAchievementId.londonSystemWin, 'London System Win', opening.name);
  }
  if (won && opening.isKingsIndian) {
    add(PlayAchievementId.kingsIndianWin, 'King\'s Indian Win', opening.name);
  }
  if (won && opening.isNimzoIndian) {
    add(PlayAchievementId.nimzoIndianWin, 'Nimzo-Indian Win', opening.name);
  }
  if (won && opening.isSlav) {
    add(PlayAchievementId.slavWin, 'Slav Defense Win', opening.name);
  }
  if (won && opening.isEnglish) {
    add(PlayAchievementId.englishWin, 'English Opening Win', opening.name);
  }
  if (won && opening.isPircOrModern) {
    add(PlayAchievementId.pircWin, 'Pirc/Modern Win', opening.name);
  }
  if (won && opening.isScandinavian) {
    add(PlayAchievementId.scandinavianWin, 'Scandinavian Win', opening.name);
  }

  return badges;
}

String _cpLabel(int cp) {
  if (cp.abs() >= 100000) return cp > 0 ? 'mate advantage' : 'mating danger';
  final pawns = (cp.abs() / 100).toStringAsFixed(1);
  return cp < 0 ? '-$pawns' : '+$pawns';
}

List<_PositionSample> _samplePositions(
  String startingFen,
  List<String> movesUci, {
  required int maxSamples,
}) {
  final all = <_PositionSample>[];
  var position = Position.setupPosition(
    Rule.chess,
    Setup.parseFen(startingFen),
  );
  all.add(_PositionSample(ply: 0, position: position));
  for (var i = 0; i < movesUci.length; i++) {
    final move = NormalMove.fromUci(movesUci[i]);
    if (!position.isLegal(move)) break;
    position = position.play(move);
    all.add(_PositionSample(ply: i + 1, position: position));
  }
  if (all.length <= maxSamples) return all;
  final selected = <int>{0, all.length - 1};
  final step = (all.length - 1) / (maxSamples - 1);
  for (var i = 1; i < maxSamples - 1; i++) {
    selected.add((i * step).round().clamp(0, all.length - 1));
  }
  return [for (final index in selected.toList()..sort()) all[index]];
}

List<ChessMove> _buildMainline(String startingFen, List<String> movesUci) {
  final moves = <ChessMove>[];
  var position = Position.setupPosition(
    Rule.chess,
    Setup.parseFen(startingFen),
  );
  for (final uci in movesUci) {
    final move = NormalMove.fromUci(uci);
    if (!position.isLegal(move)) break;
    final san = position.makeSan(move).$2;
    final next = position.play(move);
    moves.add(
      ChessMove(
        num: position.fullmoves,
        fen: next.fen,
        san: san,
        uci: move.uci,
        turn: position.turn == Side.white ? ChessColor.white : ChessColor.black,
      ),
    );
    position = next;
  }
  return moves;
}

bool _canReplay(String startingFen, List<String> movesUci) {
  try {
    var position = Position.setupPosition(
      Rule.chess,
      Setup.parseFen(startingFen),
    );
    for (final uci in movesUci) {
      final move = NormalMove.fromUci(uci);
      if (!position.isLegal(move)) return false;
      position = position.play(move);
    }
    return true;
  } catch (_) {
    return false;
  }
}

PlayOpeningSummary classifyOpening(String startingFen, List<String> movesUci) {
  if (startingFen != Chess.initial.fen) {
    return const PlayOpeningSummary(name: 'Custom starting position');
  }
  bool starts(List<String> prefix) {
    if (movesUci.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (movesUci[i] != prefix[i]) return false;
    }
    return true;
  }

  if (starts(const ['e2e4', 'c7c6'])) {
    return const PlayOpeningSummary(eco: 'B10', name: 'Caro-Kann Defense');
  }
  if (starts(const ['e2e4', 'c7c5'])) {
    return const PlayOpeningSummary(eco: 'B20', name: 'Sicilian Defense');
  }
  if (starts(const ['e2e4', 'e7e6'])) {
    return const PlayOpeningSummary(eco: 'C00', name: 'French Defense');
  }
  if (starts(const ['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5'])) {
    return const PlayOpeningSummary(eco: 'C60', name: 'Ruy Lopez');
  }
  if (starts(const ['d2d4', 'd7d5', 'c2c4'])) {
    return const PlayOpeningSummary(eco: 'D06', name: 'Queen\'s Gambit');
  }
  if (starts(const ['d2d4', 'g8f6', 'c2c4', 'g7g6'])) {
    return const PlayOpeningSummary(eco: 'E60', name: 'King\'s Indian Defense');
  }
  if (starts(const ['d2d4', 'd7d5', 'c1f4']) ||
      starts(const ['g1f3', 'd7d5', 'd2d4', 'g8f6', 'c1f4']) ||
      starts(const ['d2d4', 'g8f6', 'g1f3', 'd7d5', 'c1f4'])) {
    return const PlayOpeningSummary(eco: 'D02', name: 'London System');
  }
  if (starts(const ['c2c4'])) {
    return const PlayOpeningSummary(eco: 'A10', name: 'English Opening');
  }
  if (starts(const ['e2e4', 'e7e5'])) {
    return const PlayOpeningSummary(eco: 'C20', name: 'Open Game');
  }
  if (starts(const ['d2d4'])) {
    return const PlayOpeningSummary(eco: 'A40', name: 'Queen\'s Pawn Opening');
  }
  if (starts(const ['g1f3'])) {
    return const PlayOpeningSummary(eco: 'A04', name: 'Reti Opening');
  }
  return const PlayOpeningSummary(eco: 'A00', name: 'Unclassified Opening');
}

PlayOpeningSummary? _openingFromTournamentGame(TournamentGame game) {
  final line = game.ecoLine?.trim();
  if (line == null || line.isEmpty) return null;
  final match = RegExp(r'^([A-E][0-9]{2})\s+[—-]\s+(.+)$').firstMatch(line);
  if (match != null) {
    return PlayOpeningSummary(eco: match.group(1), name: match.group(2));
  }
  return PlayOpeningSummary(name: line);
}

Map<String, String> _sessionHeaders({
  required PlaySessionState session,
  required BotIdentity bot,
  required DateTime playedAt,
  required String result,
  required PlayOpeningSummary opening,
  required String userDisplayName,
  required PlayGameSource source,
  String? eventTitle,
  int? eventRound,
  String? tournamentGameId,
  required String shareUrl,
}) {
  final whiteIsHuman = session.humanSide == Side.white;
  final headers = <String, String>{
    'Event':
        eventTitle?.trim().isNotEmpty == true
            ? eventTitle!.trim()
            : 'ChessEver Play',
    'Site': shareUrl,
    'Source': shareUrl,
    'Date': _pgnDate(playedAt),
    'UTCDate': _pgnDate(playedAt.toUtc()),
    'UTCTime': _pgnTime(playedAt.toUtc()),
    'Round': eventRound?.toString() ?? '-',
    'White': whiteIsHuman ? userDisplayName : bot.fullName,
    'Black': whiteIsHuman ? bot.fullName : userDisplayName,
    'Result': result,
    'TimeControl':
        '${session.config.baseSeconds}+${session.config.incrementSeconds}',
    'Termination': session.endReason.banner,
    'ChessEverSource': source.value,
    'ChessEverSourceUrl': shareUrl,
    'ChessEverEngine': session.config.engine.displayName,
    'ChessEverEngineKind': session.config.engine.name,
    'ChessEverEngineElo': session.config.elo.toString(),
    'ChessEverHumanColor': session.humanSide == Side.white ? 'white' : 'black',
  };
  _put(headers, 'ChessEverTournamentGameId', tournamentGameId);
  if (!whiteIsHuman) {
    _put(headers, 'WhiteTitle', bot.title);
    _put(headers, 'WhiteElo', bot.elo.toString());
    _put(headers, 'WhiteFed', bot.countryCode);
  } else {
    _put(headers, 'BlackTitle', bot.title);
    _put(headers, 'BlackElo', bot.elo.toString());
    _put(headers, 'BlackFed', bot.countryCode);
  }
  _put(headers, 'ECO', opening.eco);
  _put(headers, 'Opening', opening.name);
  if (session.startingFen != Chess.initial.fen) {
    headers['SetUp'] = '1';
    headers['FEN'] = session.startingFen;
  }
  return headers;
}

Map<String, String> _tournamentHeaders({
  required TournamentSnapshot snapshot,
  required TournamentGame game,
  required TournamentParticipant? white,
  required TournamentParticipant? black,
  required DateTime playedAt,
  required String result,
  required PlayOpeningSummary opening,
  required String shareUrl,
}) {
  final headers = <String, String>{
    'Event': snapshot.config.title,
    'Site': shareUrl,
    'Source': shareUrl,
    'Date': _pgnDate(playedAt),
    'UTCDate': _pgnDate(playedAt.toUtc()),
    'UTCTime': _pgnTime(playedAt.toUtc()),
    'Round': game.round.toString(),
    'White': white?.identity.fullName ?? 'White',
    'Black': black?.identity.fullName ?? 'Black',
    'Result': result,
    'TimeControl':
        '${snapshot.config.baseSeconds}+${snapshot.config.incrementSeconds}',
    'Termination': game.endReason ?? '',
    'ChessEverSource': 'tournament',
    'ChessEverSourceUrl': shareUrl,
    'ChessEverTournamentFormat': snapshot.config.format.name,
    'ChessEverTournamentGameId': game.id,
    'ChessEverWhiteEngine': white?.engine.displayName ?? '',
    'ChessEverBlackEngine': black?.engine.displayName ?? '',
  };
  _put(headers, 'WhiteTitle', white?.identity.title);
  _put(headers, 'BlackTitle', black?.identity.title);
  _put(headers, 'WhiteElo', white?.identity.elo.toString());
  _put(headers, 'BlackElo', black?.identity.elo.toString());
  _put(headers, 'WhiteFed', white?.identity.countryCode);
  _put(headers, 'BlackFed', black?.identity.countryCode);
  _put(headers, 'ECO', opening.eco);
  _put(headers, 'Opening', opening.name);
  final startFen = game.startingFen ?? Chess.initial.fen;
  if (startFen != Chess.initial.fen) {
    headers['SetUp'] = '1';
    headers['FEN'] = startFen;
  }
  return headers;
}

String _resultForOutcome(Outcome? outcome) {
  return switch (outcome) {
    Outcome.whiteWins => '1-0',
    Outcome.blackWins => '0-1',
    Outcome.draw => '1/2-1/2',
    _ => '*',
  };
}

String _pgnDate(DateTime dt) {
  final d = dt.toUtc();
  return '${d.year.toString().padLeft(4, '0')}.'
      '${d.month.toString().padLeft(2, '0')}.'
      '${d.day.toString().padLeft(2, '0')}';
}

String _pgnTime(DateTime dt) {
  final d = dt.toUtc();
  return '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}

String _gameKey(String prefix, String startingFen, List<String> movesUci) {
  final digest =
      sha256
          .convert(utf8.encode('$prefix|$startingFen|${movesUci.join(' ')}'))
          .toString();
  return '${prefix}_${digest.substring(0, 24)}';
}

String _gameShareUrl(String gameKey) => 'https://chessever.com/games/$gameKey';

Map<String, dynamic> _botJson(BotIdentity bot) => {
  'firstName': bot.firstName,
  'lastName': bot.lastName,
  'fullName': bot.fullName,
  'title': bot.title,
  'nickname': bot.nickname,
  'countryCode': bot.countryCode,
  'elo': bot.elo,
  'profileLine': bot.profileLine,
};

Map<String, dynamic> _participantJson(TournamentParticipant participant) => {
  'id': participant.id,
  'engine': participant.engine.name,
  'identity': _botJson(participant.identity),
};

void _put(Map<String, String> headers, String key, String? value) {
  final text = value?.trim() ?? '';
  if (text.isNotEmpty) headers[key] = text;
}

TimeControlCategory _categoryForSeconds(int seconds) {
  if (seconds <= 120) return TimeControlCategory.bullet;
  if (seconds <= 300) return TimeControlCategory.blitz;
  if (seconds <= 1800) return TimeControlCategory.rapid;
  return TimeControlCategory.classical;
}

@immutable
class _PositionSample {
  const _PositionSample({required this.ply, required this.position});
  final int ply;
  final Position position;
}

@immutable
class _UciScore {
  const _UciScore({this.cp, this.mate});
  final int? cp;
  final int? mate;
}
