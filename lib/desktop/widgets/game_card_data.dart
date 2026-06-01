import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';

/// Generic, view-agnostic data for a single chess game card on the desktop.
///
/// Lets a single [DesktopGameCard] render games coming from very different
/// sources — live tournament feeds (`GamesTourModel`) and saved analyses
/// (`SavedAnalysis`) — without each surface needing its own bespoke card.
@immutable
class GameCardData {
  const GameCardData({
    required this.id,
    required this.title,
    required this.whiteName,
    required this.blackName,
    required this.whiteFederation,
    required this.blackFederation,
    required this.whiteTitle,
    required this.blackTitle,
    required this.whiteRating,
    required this.blackRating,
    this.whiteFideId,
    this.blackFideId,
    required this.fen,
    required this.status,
    required this.hasStarted,
    this.lastMove,
    this.openingName,
    this.subtitle,
    this.whiteClockSeconds,
    this.blackClockSeconds,
    this.whiteClockCentiseconds = 0,
    this.blackClockCentiseconds = 0,
    this.lastMoveTime,
    this.activePlayer,
    this.canResolveRemoteFen = false,
  });

  /// Stable identifier — game id for tournament games, saved-analysis id for
  /// library entries. Used as a list key.
  final String id;

  /// One-line label for the card (used as a fallback if names are empty).
  final String title;

  final String whiteName;
  final String blackName;
  final String whiteFederation;
  final String blackFederation;
  final String whiteTitle;
  final String blackTitle;
  final int whiteRating;
  final int blackRating;
  final int? whiteFideId;
  final int? blackFideId;

  /// Last-known FEN for the eval bar. Null when the game hasn't started yet.
  final String? fen;
  final String? lastMove;

  /// Outcome / progress of the game. Mapped to the same enum the
  /// tournament games use so the card's status pill stays consistent.
  final GameStatus status;
  final bool hasStarted;

  final String? openingName;

  /// Optional secondary line (e.g. "saved 3 days ago", "Round 4").
  final String? subtitle;

  /// Live broadcast clock state. `whiteClockSeconds` / `blackClockSeconds`
  /// are the canonical Supabase `last_clock_white` / `last_clock_black`
  /// snapshots (taken when the player completed their last move).
  /// Centiseconds are the legacy fallback. [lastMoveTime] anchors the
  /// "elapsed since the last move" calculation that drives the live
  /// countdown — the AtomicCountdownText subtracts wall-clock elapsed
  /// from the saved snapshot for the side currently on move.
  final int? whiteClockSeconds;
  final int? blackClockSeconds;
  final int whiteClockCentiseconds;
  final int blackClockCentiseconds;
  final DateTime? lastMoveTime;
  final Side? activePlayer;

  /// True for Gamebase preview rows whose first-page payload may omit the
  /// final FEN. Desktop board previews can render the start position
  /// immediately and hydrate the real final position asynchronously.
  final bool canResolveRemoteFen;

  GameCardData copyWith({
    String? whiteFederation,
    String? blackFederation,
    int? whiteFideId,
    int? blackFideId,
  }) {
    return GameCardData(
      id: id,
      title: title,
      whiteName: whiteName,
      blackName: blackName,
      whiteFederation: whiteFederation ?? this.whiteFederation,
      blackFederation: blackFederation ?? this.blackFederation,
      whiteTitle: whiteTitle,
      blackTitle: blackTitle,
      whiteRating: whiteRating,
      blackRating: blackRating,
      whiteFideId: whiteFideId ?? this.whiteFideId,
      blackFideId: blackFideId ?? this.blackFideId,
      fen: fen,
      lastMove: lastMove,
      status: status,
      hasStarted: hasStarted,
      openingName: openingName,
      subtitle: subtitle,
      whiteClockSeconds: whiteClockSeconds,
      blackClockSeconds: blackClockSeconds,
      whiteClockCentiseconds: whiteClockCentiseconds,
      blackClockCentiseconds: blackClockCentiseconds,
      lastMoveTime: lastMoveTime,
      activePlayer: activePlayer,
      canResolveRemoteFen: canResolveRemoteFen,
    );
  }

  // ---------- factories ----------

  factory GameCardData.fromGamesTourModel(GamesTourModel game) {
    // Match mobile's behaviour: when the row's `fen` column is empty or
    // stale (a common shape for finished broadcast games where the live
    // server stops pushing FEN updates after the result is set), fall
    // back to replaying the PGN to recover the final position. The eval
    // bar and the static board preview both render off this single
    // source — if it's wrong, the card looks like an unstarted game.
    final resolvedFen = resolveFreshestGameFen(
      fen: game.fen,
      pgn: game.pgn,
      lastMove: game.lastMove,
    );
    return GameCardData(
      id: game.gameId,
      title: '${game.whitePlayer.name} vs ${game.blackPlayer.name}',
      whiteName: game.whitePlayer.name,
      blackName: game.blackPlayer.name,
      whiteFederation: _playerFederation(game.whitePlayer),
      blackFederation: _playerFederation(game.blackPlayer),
      whiteTitle: game.whitePlayer.title,
      blackTitle: game.blackPlayer.title,
      whiteRating: game.whitePlayer.rating,
      blackRating: game.blackPlayer.rating,
      whiteFideId: game.whitePlayer.fideId,
      blackFideId: game.blackPlayer.fideId,
      fen: resolvedFen ?? game.fen,
      lastMove: game.lastMove,
      // `effectiveGameStatus` falls back to a position-based result when the
      // DB still says ongoing but the clocks are at 0 — so a card stops
      // showing the "Live" pill (and starts showing 1-0 / 0-1 / ½-½) the
      // moment the broadcast actually ends, not whenever Supabase happens
      // to flip its `status` column.
      status: game.effectiveGameStatus,
      hasStarted: game.hasStarted,
      openingName: game.openingName ?? game.eco,
      whiteClockSeconds: game.whiteClockSeconds,
      blackClockSeconds: game.blackClockSeconds,
      whiteClockCentiseconds: game.whiteClockCentiseconds,
      blackClockCentiseconds: game.blackClockCentiseconds,
      lastMoveTime: game.lastMoveTime,
      activePlayer: game.activePlayer,
      canResolveRemoteFen: _isGamebasePreviewGame(game),
    );
  }

  /// Builds a card from a freshly-parsed [ChessGame] (e.g. an entry in a
  /// dropped PGN file that hasn't been saved to a folder yet). Mirrors the
  /// fields surfaced by [GameCardData.fromSavedAnalysis] using the PGN
  /// header bag so the preview list looks identical to the saved view.
  factory GameCardData.fromChessGame(ChessGame game, {String? subtitle}) {
    final meta = game.metadata;
    String stringMeta(String key) {
      final v = meta[key];
      return v is String ? v : '';
    }

    int intMeta(String key) {
      final v = meta[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    int? fideIdMeta(String key) {
      final value = intMeta(key);
      return value > 0 ? value : null;
    }

    final mainline = game.mainline;
    final lastFen = mainline.isNotEmpty ? mainline.last.fen : game.startingFen;
    final hasStarted = mainline.isNotEmpty;
    final whiteName =
        stringMeta('White').isEmpty ? 'White' : stringMeta('White');
    final blackName =
        stringMeta('Black').isEmpty ? 'Black' : stringMeta('Black');

    return GameCardData(
      id: game.gameId,
      title: '$whiteName vs $blackName',
      whiteName: whiteName,
      blackName: blackName,
      whiteFederation:
          stringMeta('WhiteFederation').isNotEmpty
              ? stringMeta('WhiteFederation')
              : stringMeta('WhiteFed'),
      blackFederation:
          stringMeta('BlackFederation').isNotEmpty
              ? stringMeta('BlackFederation')
              : stringMeta('BlackFed'),
      whiteTitle: stringMeta('WhiteTitle'),
      blackTitle: stringMeta('BlackTitle'),
      whiteRating: intMeta('WhiteElo'),
      blackRating: intMeta('BlackElo'),
      whiteFideId: fideIdMeta('WhiteFideId'),
      blackFideId: fideIdMeta('BlackFideId'),
      fen: lastFen,
      lastMove: mainline.isNotEmpty ? mainline.last.uci : null,
      status: _statusFromResult(stringMeta('Result')),
      hasStarted: hasStarted,
      openingName:
          stringMeta('Opening').isNotEmpty
              ? stringMeta('Opening')
              : stringMeta('ECO'),
      subtitle: subtitle,
    );
  }

  factory GameCardData.fromSavedAnalysis(SavedAnalysis analysis) {
    final meta = analysis.chessGame.metadata;
    String stringMeta(String key) {
      final v = meta[key];
      return v is String ? v : '';
    }

    int intMeta(String key) {
      final v = meta[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }

    int? fideIdMeta(String key) {
      final value = intMeta(key);
      return value > 0 ? value : null;
    }

    final mainline = analysis.chessGame.mainline;
    final lastFen =
        mainline.isNotEmpty
            ? mainline.last.fen
            : analysis.chessGame.startingFen;
    final hasStarted = mainline.isNotEmpty;

    return GameCardData(
      id: analysis.id,
      title: analysis.title,
      whiteName:
          stringMeta('White').isNotEmpty
              ? stringMeta('White')
              : (analysis.whiteName ?? ''),
      blackName:
          stringMeta('Black').isNotEmpty
              ? stringMeta('Black')
              : (analysis.blackName ?? ''),
      whiteFederation:
          stringMeta('WhiteFederation').isNotEmpty
              ? stringMeta('WhiteFederation')
              : stringMeta('WhiteFed'),
      blackFederation:
          stringMeta('BlackFederation').isNotEmpty
              ? stringMeta('BlackFederation')
              : stringMeta('BlackFed'),
      whiteTitle: stringMeta('WhiteTitle'),
      blackTitle: stringMeta('BlackTitle'),
      whiteRating: intMeta('WhiteElo'),
      blackRating: intMeta('BlackElo'),
      whiteFideId: fideIdMeta('WhiteFideId'),
      blackFideId: fideIdMeta('BlackFideId'),
      fen: lastFen,
      lastMove: mainline.isNotEmpty ? mainline.last.uci : null,
      status: _statusFromResult(stringMeta('Result')),
      hasStarted: hasStarted,
      openingName: analysis.openingName,
      subtitle: analysis.notes,
    );
  }
}

bool _isGamebasePreviewGame(GamesTourModel game) {
  final marker = game.roundId.trim().toLowerCase();
  return marker == 'gamebase_search' ||
      marker == 'twic_profile' ||
      marker == 'twic_event';
}

String _playerFederation(PlayerCard player) {
  final federation = player.federation.trim();
  if (federation.isNotEmpty) return federation;
  return player.countryCode.trim();
}

GameStatus _statusFromResult(String result) {
  switch (result.trim()) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
    case '½-½':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}
