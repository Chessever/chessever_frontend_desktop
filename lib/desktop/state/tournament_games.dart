import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Lightweight summary of one game inside an event or database — just the
/// fields the BoardPane side table needs to render a row and switch games.
class TournamentGameSummary {
  const TournamentGameSummary({
    required this.id,
    required this.name,
    required this.whitePlayer,
    required this.blackPlayer,
    required this.hasPgn,
    this.tourId = '',
    this.tourSlug = '',
    this.whiteFederation = '',
    this.blackFederation = '',
    this.whiteTitle = '',
    this.blackTitle = '',
    this.whiteRating = 0,
    this.blackRating = 0,
    this.whiteFideId,
    this.blackFideId,
    this.fen,
    this.roundId = '',
    this.roundSlug = '',
    this.roundLabel = '',
    this.roundName = '',
    this.boardNumber,
    this.status = GameStatus.unknown,
    this.openingName,
    this.lastMoveTime,
    this.startsAt,
    this.roundStartsAt,
    this.hasStarted = false,
    this.pgn,
  });

  factory TournamentGameSummary.fromGamesTourModel(
    GamesTourModel game, {
    DateTime? roundStartsAt,
    String? roundName,
  }) {
    final fen = game.fen?.trim();
    return TournamentGameSummary(
      id: game.gameId,
      name: _gameName(
        explicitName: null,
        whitePlayer: game.whitePlayer.name,
        blackPlayer: game.blackPlayer.name,
        id: game.gameId,
      ),
      whitePlayer: game.whitePlayer.name,
      blackPlayer: game.blackPlayer.name,
      tourId: game.tourId,
      tourSlug: game.tourSlug ?? '',
      whiteFederation: _summaryFederation(game.whitePlayer),
      blackFederation: _summaryFederation(game.blackPlayer),
      whiteTitle: game.whitePlayer.title,
      blackTitle: game.blackPlayer.title,
      whiteRating: game.whitePlayer.rating,
      blackRating: game.blackPlayer.rating,
      whiteFideId: game.whitePlayer.fideId,
      blackFideId: game.blackPlayer.fideId,
      hasPgn: (game.pgn ?? '').trim().isNotEmpty,
      pgn: (game.pgn ?? '').trim().isEmpty ? null : game.pgn,
      fen: (fen == null || fen.isEmpty) ? null : fen,
      roundId: game.roundId,
      roundSlug: game.roundSlug ?? '',
      roundLabel: _roundLabel(roundSlug: game.roundSlug, roundId: game.roundId),
      roundName: roundName?.trim() ?? '',
      boardNumber: game.boardNr,
      status: game.effectiveGameStatus,
      openingName: game.openingName ?? game.eco,
      lastMoveTime: game.lastMoveTime,
      startsAt: game.dateStart,
      roundStartsAt: roundStartsAt,
      hasStarted: game.hasStarted,
    );
  }

  factory TournamentGameSummary.fromGame(Games game) {
    final players = game.players ?? const <Player>[];
    final white = players.isNotEmpty ? players.first : null;
    final black = players.length >= 2 ? players[1] : null;
    final fen = game.fen?.trim();
    return TournamentGameSummary(
      id: game.id,
      name: _gameName(
        explicitName: game.name,
        whitePlayer: white?.name ?? '',
        blackPlayer: black?.name ?? '',
        id: game.id,
      ),
      whitePlayer: white?.name ?? '',
      blackPlayer: black?.name ?? '',
      tourId: game.tourId,
      tourSlug: game.tourSlug,
      whiteFederation: white?.fed ?? '',
      blackFederation: black?.fed ?? '',
      whiteTitle: white?.title ?? '',
      blackTitle: black?.title ?? '',
      whiteRating: white?.rating ?? 0,
      blackRating: black?.rating ?? 0,
      whiteFideId: white?.fideId,
      blackFideId: black?.fideId,
      hasPgn: (game.pgn ?? '').trim().isNotEmpty,
      pgn: (game.pgn ?? '').trim().isEmpty ? null : game.pgn,
      fen: (fen == null || fen.isEmpty) ? null : fen,
      roundId: game.roundId,
      roundSlug: game.roundSlug,
      roundLabel: _roundLabel(roundSlug: game.roundSlug, roundId: game.roundId),
      boardNumber: game.boardNr,
      status: GameStatus.fromString(game.status),
      openingName: game.openingName ?? game.eco,
      lastMoveTime: game.lastMoveTime,
      startsAt: game.dateStart,
      hasStarted: game.lastMove?.trim().isNotEmpty == true,
    );
  }

  final String id;
  final String name;
  final String whitePlayer;
  final String blackPlayer;
  final bool hasPgn;
  final String tourId;
  final String tourSlug;
  final String whiteFederation; // FIDE 3-letter / ISO2 / country name
  final String blackFederation;
  final String whiteTitle; // GM, IM, FM, etc. (may be empty)
  final String blackTitle;
  final int whiteRating; // 0 if unknown
  final int blackRating;
  final int? whiteFideId;
  final int? blackFideId;

  /// Last-known FEN for this game. Populated from `Games.fen` when the
  /// tournament loads. Used as the Board tab's seed when the PGN is not
  /// available yet. Null when no live position is available yet.
  final String? fen;

  final String roundId;
  final String roundSlug;
  final String roundLabel;

  /// Full round/stage name from the tournament round header, e.g.
  /// `Round 1 / Armageddon`. Game rows often only carry a generic
  /// `round-1` slug, so board-side event rails need this propagated from
  /// the Tournament Games screen to keep tiebreak/Armageddon labels visible.
  final String roundName;

  final int? boardNumber;
  final GameStatus status;
  final String? openingName;
  final DateTime? lastMoveTime;
  final DateTime? startsAt;

  /// Canonical scheduled start for the round/stage that owns this game.
  ///
  /// Tournament Games view gets this from the `rounds.starts_at` row used by
  /// the round header. Individual `games.date_start` values can be pairing
  /// upload times and may drift from the actual round schedule, so the board
  /// event rail should prefer this when rendering round headers.
  final DateTime? roundStartsAt;
  final bool hasStarted;

  /// Optional PGN payload for non-live database/library entries. Live event
  /// summaries usually omit this and let the board fetch the current PGN.
  final String? pgn;

  TournamentGameSummary copyWith({
    String? pgn,
    String? fen,
    DateTime? lastMoveTime,
    GameStatus? status,
    bool? hasStarted,
  }) {
    return TournamentGameSummary(
      id: id,
      name: name,
      whitePlayer: whitePlayer,
      blackPlayer: blackPlayer,
      hasPgn: ((pgn ?? this.pgn)?.trim().isNotEmpty ?? false) || hasPgn,
      tourId: tourId,
      tourSlug: tourSlug,
      whiteFederation: whiteFederation,
      blackFederation: blackFederation,
      whiteTitle: whiteTitle,
      blackTitle: blackTitle,
      whiteRating: whiteRating,
      blackRating: blackRating,
      whiteFideId: whiteFideId,
      blackFideId: blackFideId,
      fen: fen ?? this.fen,
      roundId: roundId,
      roundSlug: roundSlug,
      roundLabel: roundLabel,
      roundName: roundName,
      boardNumber: boardNumber,
      status: status ?? this.status,
      openingName: openingName,
      lastMoveTime: lastMoveTime ?? this.lastMoveTime,
      startsAt: startsAt,
      roundStartsAt: roundStartsAt,
      hasStarted: hasStarted ?? this.hasStarted,
      pgn: pgn ?? this.pgn,
    );
  }
}

String _summaryFederation(PlayerCard player) {
  final federation = player.federation.trim();
  if (federation.isNotEmpty) return federation;
  return player.countryCode.trim();
}

String _gameName({
  required String? explicitName,
  required String whitePlayer,
  required String blackPlayer,
  required String id,
}) {
  final explicit = explicitName?.trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (whitePlayer.trim().isNotEmpty || blackPlayer.trim().isNotEmpty) {
    return '${whitePlayer.trim()} vs ${blackPlayer.trim()}'.trim();
  }
  return 'Game $id';
}

String _roundLabel({required String? roundSlug, required String roundId}) {
  final slug =
      (roundSlug == null || roundSlug.trim().isEmpty)
          ? roundId
          : roundSlug.trim();
  final roundMatch =
      RegExp(r'round-?(\d+)', caseSensitive: false).firstMatch(slug) ??
      RegExp(r'round-?(\d+)', caseSensitive: false).firstMatch(roundId);
  if (roundMatch != null) return 'R${roundMatch.group(1)}';

  final stageMatch = RegExp(
    r'stage-([^/]+)',
    caseSensitive: false,
  ).firstMatch(slug);
  if (stageMatch != null) {
    return stageMatch.group(1)!.replaceAll('-', ' ').toUpperCase();
  }

  return slug
      .replaceAll(RegExp(r'[-_]+'), ' ')
      .replaceAllMapped(RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
}

/// State of "the tournament whose game is currently loaded in the Board
/// pane". Cleared when the user opens an unrelated PGN (drag-drop,
/// playground reset, etc.) — the BoardPane treats `null` as "show me only
/// the move list, no tournament switcher".
class TournamentGamesState {
  const TournamentGamesState({
    required this.tournamentTitle,
    required this.games,
    required this.activeGameId,
  });

  final String tournamentTitle;
  final List<TournamentGameSummary> games;
  final String? activeGameId;

  TournamentGamesState copyWith({String? activeGameId}) {
    return TournamentGamesState(
      tournamentTitle: tournamentTitle,
      games: games,
      activeGameId: activeGameId ?? this.activeGameId,
    );
  }
}

class TournamentGamesNotifier extends StateNotifier<TournamentGamesState?> {
  TournamentGamesNotifier() : super(null);

  void setLoaded({
    required String tournamentTitle,
    required List<TournamentGameSummary> games,
  }) {
    state = TournamentGamesState(
      tournamentTitle: tournamentTitle,
      games: games,
      activeGameId: null,
    );
  }

  void markActive(String gameId) {
    final current = state;
    if (current == null) return;
    state = current.copyWith(activeGameId: gameId);
  }

  void clear() {
    state = null;
  }
}

final tournamentGamesProvider =
    StateNotifierProvider<TournamentGamesNotifier, TournamentGamesState?>(
      (ref) => TournamentGamesNotifier(),
    );
