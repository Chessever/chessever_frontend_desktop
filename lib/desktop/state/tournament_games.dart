import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/live_game_position_resolver.dart';

/// Stable write target for a game that came from a local PGN file.
///
/// Database rails pass lightweight [TournamentGameSummary] values around when
/// users switch rows. Keeping the source coordinates here lets a newly opened
/// row retain its own update target instead of inheriting (or losing) the
/// original Board tab's local-file origin.
class TournamentGameLocalPgnSource {
  const TournamentGameLocalPgnSource({
    required this.sourcePath,
    required this.sourceIndex,
    required this.sourceFileGameCount,
    this.pgnFingerprint = '',
    required this.title,
  });

  final String sourcePath;
  final int sourceIndex;
  final int sourceFileGameCount;
  final String pgnFingerprint;
  final String title;
}

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
    this.whiteTeam = '',
    this.blackTeam = '',
    this.localPgnSource,
  });

  factory TournamentGameSummary.fromGamesTourModel(
    GamesTourModel game, {
    DateTime? roundStartsAt,
    String? roundName,
  }) {
    final fen =
        resolveFreshestGameFen(
          fen: game.fen,
          pgn: game.pgn,
          lastMove: game.lastMove,
        )?.trim();
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
      // Keep the server's status canonical in shared navigation state. A
      // position/clock-derived UI fallback must not terminate a live stream.
      status: game.gameStatus,
      openingName: game.openingName ?? game.eco,
      lastMoveTime: game.lastMoveTime,
      startsAt: game.dateStart,
      // Explicit round schedule (Tournament Detail passes a rounds map) wins;
      // otherwise fall back to the round time the model carried from its
      // source `Games` row so board-side round headers show real times.
      roundStartsAt: roundStartsAt ?? game.roundStartsAt,
      hasStarted: game.hasStarted,
      whiteTeam: game.whitePlayer.team?.trim() ?? '',
      blackTeam: game.blackPlayer.team?.trim() ?? '',
    );
  }

  factory TournamentGameSummary.fromGame(Games game) {
    final players = game.players ?? const <Player>[];
    final white = players.isNotEmpty ? players.first : null;
    final black = players.length >= 2 ? players[1] : null;
    final fen =
        resolveFreshestGameFen(
          fen: game.fen,
          pgn: game.pgn,
          lastMove: game.lastMove,
        )?.trim();
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
      roundName: game.roundName?.trim() ?? '',
      boardNumber: game.boardNr,
      status: GameStatus.fromString(game.status),
      openingName: game.openingName ?? game.eco,
      lastMoveTime: game.lastMoveTime,
      startsAt: game.dateStart,
      roundStartsAt: game.roundStartsAt,
      hasStarted: game.lastMove?.trim().isNotEmpty == true,
      whiteTeam: white?.team.trim() ?? '',
      blackTeam: black?.team.trim() ?? '',
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

  /// Team labels for team events (Olympiad, leagues). Empty when the source
  /// row carries no team info; the board event rail uses these to group a
  /// round's boards into team matchups like the mobile Games tab.
  final String whiteTeam;
  final String blackTeam;

  /// Optional PGN payload for non-live database/library entries. Live event
  /// summaries usually omit this and let the board fetch the current PGN.
  final String? pgn;

  /// Local PGN coordinates when this summary is a row from an imported file.
  /// Null for cloud, Gamebase, and detached-preview entries.
  final TournamentGameLocalPgnSource? localPgnSource;

  TournamentGameSummary copyWith({
    String? name,
    String? whitePlayer,
    String? blackPlayer,
    String? whiteFederation,
    String? blackFederation,
    String? whiteTitle,
    String? blackTitle,
    int? whiteRating,
    int? blackRating,
    int? whiteFideId,
    int? blackFideId,
    String? whiteTeam,
    String? blackTeam,
    String? pgn,
    String? fen,
    DateTime? lastMoveTime,
    GameStatus? status,
    bool? hasStarted,
    TournamentGameLocalPgnSource? localPgnSource,
  }) {
    return TournamentGameSummary(
      id: id,
      name: name ?? this.name,
      whitePlayer: whitePlayer ?? this.whitePlayer,
      blackPlayer: blackPlayer ?? this.blackPlayer,
      hasPgn: ((pgn ?? this.pgn)?.trim().isNotEmpty ?? false) || hasPgn,
      tourId: tourId,
      tourSlug: tourSlug,
      whiteFederation: whiteFederation ?? this.whiteFederation,
      blackFederation: blackFederation ?? this.blackFederation,
      whiteTitle: whiteTitle ?? this.whiteTitle,
      blackTitle: blackTitle ?? this.blackTitle,
      whiteRating: whiteRating ?? this.whiteRating,
      blackRating: blackRating ?? this.blackRating,
      whiteFideId: whiteFideId ?? this.whiteFideId,
      blackFideId: blackFideId ?? this.blackFideId,
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
      whiteTeam: whiteTeam ?? this.whiteTeam,
      blackTeam: blackTeam ?? this.blackTeam,
      localPgnSource: localPgnSource ?? this.localPgnSource,
    );
  }
}

/// Builds the canonical live-card model for a lightweight event-rail row.
/// Keeping this conversion shared prevents Board, rail, and card surfaces from
/// applying different realtime arbitration rules to the same game.
GamesTourModel gamesTourModelFromTournamentSummary(
  TournamentGameSummary summary, {
  GameSource source = GameSource.supabase,
}) {
  final whiteFederation = summary.whiteFederation.trim();
  final blackFederation = summary.blackFederation.trim();
  return GamesTourModel(
    gameId: summary.id,
    source: source,
    whitePlayer: PlayerCard(
      name: summary.whitePlayer,
      federation: whiteFederation,
      title: summary.whiteTitle,
      rating: summary.whiteRating,
      countryCode: whiteFederation,
      fideId: summary.whiteFideId,
      team: summary.whiteTeam.trim().isEmpty ? null : summary.whiteTeam.trim(),
    ),
    blackPlayer: PlayerCard(
      name: summary.blackPlayer,
      federation: blackFederation,
      title: summary.blackTitle,
      rating: summary.blackRating,
      countryCode: blackFederation,
      fideId: summary.blackFideId,
      team: summary.blackTeam.trim().isEmpty ? null : summary.blackTeam.trim(),
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: summary.status,
    fen: summary.fen,
    pgn: summary.pgn,
    boardNr: summary.boardNumber,
    roundId: summary.roundId,
    roundSlug: summary.roundSlug.trim().isEmpty ? null : summary.roundSlug,
    tourId: summary.tourId,
    tourSlug: summary.tourSlug.trim().isEmpty ? null : summary.tourSlug,
    lastMoveTime: summary.lastMoveTime,
    dateStart: summary.startsAt,
    roundStartsAt: summary.roundStartsAt,
    openingName: summary.openingName,
  );
}

/// Projects one already-arbitrated live model back into an event-rail row.
/// Live fields are authoritative, including intentional clears/reopens; round
/// and local-source coordinates remain anchored to the rail row.
TournamentGameSummary tournamentSummaryWithArbitratedLiveGame({
  required TournamentGameSummary structuralSummary,
  required GamesTourModel liveGame,
}) {
  final whiteFederation = _summaryFederation(liveGame.whitePlayer);
  final blackFederation = _summaryFederation(liveGame.blackPlayer);
  final pgn = liveGame.pgn?.trim();
  final fen =
      resolveFreshestGameFen(
        fen: liveGame.fen,
        pgn: liveGame.pgn,
        lastMove: liveGame.lastMove,
      )?.trim();
  final hasStarted =
      liveGame.hasStarted ||
      (resolveFinalPositionFromPgn(liveGame.pgn)?.moveCount ?? 0) > 0 ||
      (plyFromFen(fen) ?? 0) > 0;
  return TournamentGameSummary(
    id: structuralSummary.id,
    name: structuralSummary.name,
    whitePlayer: liveGame.whitePlayer.name,
    blackPlayer: liveGame.blackPlayer.name,
    hasPgn: pgn != null && pgn.isNotEmpty,
    tourId:
        liveGame.tourId.isNotEmpty ? liveGame.tourId : structuralSummary.tourId,
    tourSlug: liveGame.tourSlug ?? structuralSummary.tourSlug,
    whiteFederation: whiteFederation,
    blackFederation: blackFederation,
    whiteTitle: liveGame.whitePlayer.title,
    blackTitle: liveGame.blackPlayer.title,
    whiteRating: liveGame.whitePlayer.rating,
    blackRating: liveGame.blackPlayer.rating,
    whiteFideId: liveGame.whitePlayer.fideId,
    blackFideId: liveGame.blackPlayer.fideId,
    fen: fen == null || fen.isEmpty ? null : fen,
    roundId: structuralSummary.roundId,
    roundSlug: structuralSummary.roundSlug,
    roundLabel: structuralSummary.roundLabel,
    roundName: structuralSummary.roundName,
    boardNumber: structuralSummary.boardNumber,
    status: liveGame.gameStatus,
    openingName: liveGame.openingName ?? structuralSummary.openingName,
    lastMoveTime: liveGame.lastMoveTime,
    startsAt: liveGame.dateStart ?? structuralSummary.startsAt,
    roundStartsAt: liveGame.roundStartsAt ?? structuralSummary.roundStartsAt,
    hasStarted: hasStarted,
    pgn: pgn == null || pgn.isEmpty ? null : liveGame.pgn,
    whiteTeam: liveGame.whitePlayer.team?.trim() ?? '',
    blackTeam: liveGame.blackPlayer.team?.trim() ?? '',
    localPgnSource: structuralSummary.localPgnSource,
  );
}

/// Merges status from a refreshed snapshot without letting incomplete or
/// out-of-order metadata regress a known result.
GameStatus mergeEventGameStatus({
  required GameStatus current,
  required GameStatus incoming,
  bool currentSnapshotIsNewer = false,
}) {
  if (incoming == GameStatus.unknown) return current;
  // Timestamp freshness wins when both snapshots are terminal. A delayed draw
  // row must not replace a newer white/black result already rendered. A first
  // terminal result still beats an ongoing/unknown snapshot even if its move
  // timestamp is older, because result state is monotonic and may arrive via a
  // separate metadata path.
  if (currentSnapshotIsNewer && current.isFinished) return current;
  if (current.isFinished && !incoming.isFinished) return current;
  if (incoming.isFinished) return incoming;
  return currentSnapshotIsNewer ? current : incoming;
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
