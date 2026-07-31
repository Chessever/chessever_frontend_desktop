import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';
import 'package:dartchess/dartchess.dart';

enum GameDisplayMode { all, hideFinishedGames, showfinishedGame }

enum GameSource {
  supabase,
  gamebase,
  twic,
  openingExplorer,
  boardEditor,
  savedAnalysis,
  localAnalysis,
}

class GamesScreenModel {
  GamesScreenModel({
    required this.gamesTourModels,
    required this.pinnedGamedIs,
    this.gameDisplayMode = GameDisplayMode.all,
    this.isSearchMode = false,
    this.searchQuery,
  });

  final List<GamesTourModel> gamesTourModels;
  final List<String> pinnedGamedIs;
  final bool isSearchMode;
  final String? searchQuery;
  final GameDisplayMode gameDisplayMode;

  GamesScreenModel copyWith({
    List<GamesTourModel>? gamesTourModels,
    List<String>? pinnedGamedIs,
    bool? isSearchMode,
    String? searchQuery,
    final GameDisplayMode? gameDisplayMode,
  }) {
    return GamesScreenModel(
      gamesTourModels: gamesTourModels ?? this.gamesTourModels,
      pinnedGamedIs: pinnedGamedIs ?? this.pinnedGamedIs,
      isSearchMode: isSearchMode ?? this.isSearchMode,
      searchQuery: searchQuery ?? this.searchQuery,
      gameDisplayMode: gameDisplayMode ?? this.gameDisplayMode,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GamesScreenModel &&
        other.gamesTourModels == gamesTourModels &&
        other.pinnedGamedIs == pinnedGamedIs;
  }

  @override
  int get hashCode => gamesTourModels.hashCode ^ pinnedGamedIs.hashCode;
}

class GamesTourModel {
  final String gameId;
  final GameSource source;
  final PlayerCard whitePlayer;
  final PlayerCard blackPlayer;
  final String whiteTimeDisplay;
  final String blackTimeDisplay;
  final int whiteClockCentiseconds;
  final int blackClockCentiseconds;
  final int? whiteClockSeconds; // New: time in seconds from last_clock_white
  final int? blackClockSeconds; // New: time in seconds from last_clock_black
  final GameStatus gameStatus;
  final String? fen;
  final String? pgn;
  final String? lastMove;
  final int? boardNr;
  final String roundId;
  final String? roundSlug;
  final String tourId;
  final String? tourSlug;
  final String? tourName;
  final String? eventName;
  final DateTime? lastMoveTime;
  final DateTime? dateStart;
  final DateTime? gameDay;

  /// Canonical scheduled start for the round that owns this game, propagated
  /// from the `rounds.starts_at` row via the `round_schedule` embed.
  ///
  /// Unlike [dateStart] (a date-only broadcast pairing-upload day that parses
  /// to local midnight), this carries the real round wall-clock time, so round
  /// headers can show the hour/minute instead of `00:00`.
  final DateTime? roundStartsAt;
  final String? eco;
  final String? openingName;
  final String?
  timeControl; // From group_broadcasts: 'standard', 'rapid', 'blitz'
  /// Raw tournament time control text (`tours.info->>'tc'`), e.g.
  /// `90 min / 40 moves + 30 min + 30 sec / move`. Source for the PGN
  /// `TimeControl` tag, which must be a machine field and not a category.
  final String? timeControlText;
  final int? avgElo; // New: average ELO of the tournament
  final bool isOnline;

  GamesTourModel({
    required this.gameId,
    this.source = GameSource.supabase,
    required this.whitePlayer,
    required this.blackPlayer,
    required this.whiteTimeDisplay,
    required this.blackTimeDisplay,
    required this.whiteClockCentiseconds,
    required this.blackClockCentiseconds,
    this.whiteClockSeconds,
    this.blackClockSeconds,
    required this.gameStatus,
    required this.roundId, // Make required
    this.roundSlug,
    required this.tourId, // Make required
    this.tourSlug,
    this.tourName,
    this.eventName,
    this.lastMove,
    this.fen,
    this.pgn,
    this.boardNr,
    this.lastMoveTime,
    this.dateStart,
    this.gameDay,
    this.roundStartsAt,
    this.eco,
    this.openingName,
    this.timeControl,
    this.timeControlText,
    this.avgElo,
    this.isOnline = false,
  });

  /// Calendar day the game belongs to, for UI bucketing.
  ///
  /// Priority: `gameDay` (PGN [Date], stable per round) → `lastMoveTime` (UTC
  /// day of latest move) → `dateStart` (broadcast pairing-upload day).
  /// `dateStart` is the day the broadcast pairings were uploaded to Lichess,
  /// which can drift several days from the actual round day on tournaments
  /// whose rounds are pre-created (e.g. GCT multi-round formats), so it is
  /// only used as a last-resort fallback.
  DateTime? get bucketDate => gameDay ?? lastMoveTime ?? dateStart;

  GamesTourModel copyWith({
    String? gameId,
    GameSource? source,
    PlayerCard? whitePlayer,
    PlayerCard? blackPlayer,
    String? whiteTimeDisplay,
    String? blackTimeDisplay,
    int? whiteClockCentiseconds,
    int? blackClockCentiseconds,
    int? whiteClockSeconds,
    int? blackClockSeconds,
    bool clearWhiteClockSeconds = false,
    bool clearBlackClockSeconds = false,
    GameStatus? gameStatus,
    String? lastMove,
    bool clearLastMove = false,
    String? fen,
    bool clearFen = false,
    String? pgn,
    bool clearPgn = false,
    int? boardNr,
    String? roundId,
    String? roundSlug,
    String? tourId,
    String? tourSlug,
    String? tourName,
    String? eventName,
    DateTime? lastMoveTime,
    bool clearLastMoveTime = false,
    DateTime? dateStart,
    DateTime? gameDay,
    DateTime? roundStartsAt,
    String? eco,
    String? openingName,
    String? timeControl,
    String? timeControlText,
    int? avgElo,
    bool? isOnline,
  }) {
    return GamesTourModel(
      gameId: gameId ?? this.gameId,
      source: source ?? this.source,
      whitePlayer: whitePlayer ?? this.whitePlayer,
      blackPlayer: blackPlayer ?? this.blackPlayer,
      whiteTimeDisplay: whiteTimeDisplay ?? this.whiteTimeDisplay,
      blackTimeDisplay: blackTimeDisplay ?? this.blackTimeDisplay,
      whiteClockCentiseconds:
          whiteClockCentiseconds ?? this.whiteClockCentiseconds,
      blackClockCentiseconds:
          blackClockCentiseconds ?? this.blackClockCentiseconds,
      whiteClockSeconds:
          clearWhiteClockSeconds
              ? null
              : whiteClockSeconds ?? this.whiteClockSeconds,
      blackClockSeconds:
          clearBlackClockSeconds
              ? null
              : blackClockSeconds ?? this.blackClockSeconds,
      gameStatus: gameStatus ?? this.gameStatus,
      lastMove: clearLastMove ? null : lastMove ?? this.lastMove,
      fen: clearFen ? null : fen ?? this.fen,
      pgn: clearPgn ? null : pgn ?? this.pgn,
      boardNr: boardNr ?? this.boardNr,
      roundId: roundId ?? this.roundId,
      roundSlug: roundSlug ?? this.roundSlug,
      tourId: tourId ?? this.tourId,
      tourSlug: tourSlug ?? this.tourSlug,
      tourName: tourName ?? this.tourName,
      eventName: eventName ?? this.eventName,
      lastMoveTime:
          clearLastMoveTime ? null : lastMoveTime ?? this.lastMoveTime,
      dateStart: dateStart ?? this.dateStart,
      gameDay: gameDay ?? this.gameDay,
      roundStartsAt: roundStartsAt ?? this.roundStartsAt,
      eco: eco ?? this.eco,
      openingName: openingName ?? this.openingName,
      timeControl: timeControl ?? this.timeControl,
      timeControlText: timeControlText ?? this.timeControlText,
      avgElo: avgElo ?? this.avgElo,
      isOnline: isOnline ?? this.isOnline,
    );
  }

  int get cardElo {
    final whiteElo = whitePlayer.rating;
    final blackElo = blackPlayer.rating;
    return whiteElo >= blackElo ? whiteElo : blackElo;
  }

  factory GamesTourModel.fromGame(Games game) {
    // Enhanced null safety and validation
    if (game.players == null || game.players!.length < 2) {
      throw ArgumentError(
        'Game must have at least 2 players, found: ${game.players?.length ?? 0}',
      );
    }

    final players = game.players!;

    // Ensure we have exactly 2 players, take first two if more
    final Player white = players.first;
    final Player black = players.length > 1 ? players[1] : players.first;

    // Validate player data
    if (white.name.isEmpty || black.name.isEmpty) {
      throw ArgumentError('Player names cannot be empty');
    }

    try {
      // Check if game has started (has moves)
      final gameHasStarted = game.lastMove != null && game.lastMove!.isNotEmpty;

      // Determine clock display
      String whiteTimeDisplay;
      String blackTimeDisplay;
      int? whiteClockSecondsToUse;
      int? blackClockSecondsToUse;

      if (gameHasStarted) {
        // Game has started - prefer last_clock values, then player clock, then PGN clocks
        final pgnClocks = _extractClockSecondsFromPgn(game.pgn);

        whiteClockSecondsToUse =
            normalizeClockSeconds(
              clockSeconds: game.lastClockWhite,
              clockCentiseconds: white.clock,
            ) ??
            pgnClocks.whiteSeconds;
        blackClockSecondsToUse =
            normalizeClockSeconds(
              clockSeconds: game.lastClockBlack,
              clockCentiseconds: black.clock,
            ) ??
            pgnClocks.blackSeconds;

        whiteTimeDisplay =
            (game.lastClockWhite != null && game.lastClockWhite! > 0)
                ? _formatTimeFromSeconds(game.lastClockWhite!)
                : (white.clock > 0
                    ? _formatTime(white.clock)
                    : (pgnClocks.whiteSeconds != null
                        ? _formatTimeFromSeconds(pgnClocks.whiteSeconds!)
                        : '--:--'));
        blackTimeDisplay =
            (game.lastClockBlack != null && game.lastClockBlack! > 0)
                ? _formatTimeFromSeconds(game.lastClockBlack!)
                : (black.clock > 0
                    ? _formatTime(black.clock)
                    : (pgnClocks.blackSeconds != null
                        ? _formatTimeFromSeconds(pgnClocks.blackSeconds!)
                        : '--:--'));
      } else {
        final hasInitialClock = white.clock > 0 || black.clock > 0;

        if (hasInitialClock) {
          whiteTimeDisplay = _formatTime(white.clock);
          blackTimeDisplay = _formatTime(black.clock);
          whiteClockSecondsToUse = _centisecondsToSeconds(white.clock);
          blackClockSecondsToUse = _centisecondsToSeconds(black.clock);
        } else if (game.thinkTime != null && game.thinkTime! > 0) {
          whiteTimeDisplay = _formatTimeFromSeconds(game.thinkTime!);
          blackTimeDisplay = _formatTimeFromSeconds(game.thinkTime!);
          whiteClockSecondsToUse = game.thinkTime;
          blackClockSecondsToUse = game.thinkTime;
        } else {
          whiteTimeDisplay = '--:--';
          blackTimeDisplay = '--:--';
          whiteClockSecondsToUse = null;
          blackClockSecondsToUse = null;
        }
      }

      final normalizedEco = _normalizeEco(game.eco);
      final normalizedOpening = _normalizeOpeningName(game.openingName);
      String? resolvedEco = normalizedEco;
      String? resolvedOpening = normalizedOpening;

      if ((resolvedEco == null || resolvedOpening == null) &&
          game.pgn != null &&
          game.pgn!.isNotEmpty) {
        final parsed = _extractOpeningFromPgn(game.pgn);
        resolvedEco ??= parsed.eco;
        resolvedOpening ??= parsed.opening;
      }

      return GamesTourModel(
        gameId: game.id,
        source: GameSource.supabase,
        whitePlayer: PlayerCard.fromPlayer(white),
        blackPlayer: PlayerCard.fromPlayer(black),
        whiteTimeDisplay: whiteTimeDisplay,
        blackTimeDisplay: blackTimeDisplay,
        whiteClockCentiseconds: white.clock,
        blackClockCentiseconds: black.clock,
        whiteClockSeconds: whiteClockSecondsToUse,
        blackClockSeconds: blackClockSecondsToUse,
        gameStatus: GameStatus.fromString(game.status),
        roundId: game.roundId, // Include roundId in model
        roundSlug: game.roundSlug, // Include roundSlug for display
        tourId: game.tourId, // Include tourId in model
        tourSlug: game.tourSlug, // Include tourSlug for display
        tourName: game.tourName,
        eventName: game.eventName,
        fen: game.fen?.isNotEmpty == true ? game.fen : null,
        pgn: game.pgn?.isNotEmpty == true ? game.pgn : null,
        lastMove: game.lastMove?.isNotEmpty == true ? game.lastMove : null,
        boardNr: game.boardNr,
        // Prefer lastMoveTime, then gameDay (round start), then dateStart.
        lastMoveTime: game.lastMoveTime ?? game.gameDay ?? game.dateStart,
        dateStart: game.dateStart,
        gameDay: game.gameDay,
        roundStartsAt: game.roundStartsAt,
        eco: resolvedEco,
        openingName: resolvedOpening,
        timeControl: game.timeControl,
        timeControlText: game.timeControlText,
        avgElo: game.avgElo,
      );
    } catch (e) {
      throw ArgumentError(
        'Failed to create GamesTourModel from game ${game.id}: $e',
      );
    }
  }

  static int? _centisecondsToSeconds(int? value) {
    if (value == null || value <= 0) return null;
    return (value / 100).round();
  }

  static String? _normalizeEco(String? eco) {
    final trimmed = eco?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final upper = trimmed.toUpperCase();
    if (upper == '?' || upper == 'UNKNOWN') return null;
    return trimmed;
  }

  static String? _normalizeOpeningName(String? openingName) {
    final trimmed = openingName?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final upper = trimmed.toUpperCase();
    if (upper == '?' || upper == 'UNKNOWN') return null;
    return trimmed;
  }

  static int? normalizeClockSeconds({
    required int? clockSeconds,
    required int? clockCentiseconds,
  }) {
    if (clockSeconds != null && clockSeconds > 0) {
      return clockSeconds;
    }
    return _centisecondsToSeconds(clockCentiseconds);
  }

  static ({int? whiteSeconds, int? blackSeconds}) _extractClockSecondsFromPgn(
    String? pgn,
  ) {
    if (pgn == null || pgn.isEmpty) {
      return (whiteSeconds: null, blackSeconds: null);
    }

    int? lastWhite;
    int? lastBlack;
    var index = 0;

    for (final timeString in extractPgnClockStringsFromText(pgn)) {
      final seconds = parsePgnClockToSeconds(timeString);
      if (seconds != null) {
        if (index.isEven) {
          lastWhite = seconds;
        } else {
          lastBlack = seconds;
        }
      }
      index++;
    }

    return (whiteSeconds: lastWhite, blackSeconds: lastBlack);
  }

  static ({String? eco, String? opening}) _extractOpeningFromPgn(String? pgn) {
    if (pgn == null || pgn.isEmpty) {
      return (eco: null, opening: null);
    }

    final ecoMatch = RegExp(r'\[ECO\s+"([^"]+)"\]').firstMatch(pgn);
    final openingMatch = RegExp(r'\[Opening\s+"([^"]+)"\]').firstMatch(pgn);

    final eco = _normalizeEco(ecoMatch?.group(1));
    final opening = _normalizeOpeningName(openingMatch?.group(1));

    return (eco: eco, opening: opening);
  }

  static String _formatTime(int? clockTimeCentiseconds) {
    // Enhanced null safety for clock time
    if (clockTimeCentiseconds == null || clockTimeCentiseconds < 0) {
      return '--:--';
    }

    // Convert centiseconds (1/100 second) to seconds
    final totalSeconds = (clockTimeCentiseconds / 100).floor();
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;

    // Handle display for very long games (over 99 minutes)
    if (minutes > 99) {
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      return '${hours}h${remainingMinutes.toString().padLeft(2, '0')}m';
    }

    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String _formatTimeFromSeconds(int totalSeconds) {
    // Enhanced null safety for time in seconds
    if (totalSeconds < 0) {
      return '--:--';
    }

    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;

    // Handle display for very long games (over 99 minutes)
    if (minutes > 99) {
      final hours = minutes ~/ 60;
      final remainingMinutes = minutes % 60;
      return '${hours}h${remainingMinutes.toString().padLeft(2, '0')}m';
    }

    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  // Helper method to get round display name
  String get roundDisplayName {
    // Extract round number for display (e.g., "round7" -> "Round 7")
    final match = RegExp(
      r'round(\d+)',
      caseSensitive: false,
    ).firstMatch(roundId);
    if (match != null) {
      final roundNumber = match.group(1);
      return 'Round $roundNumber';
    }
    // Fallback to original roundId with capitalization
    return roundId.replaceAllMapped(
      RegExp(r'\b\w'),
      (match) => match.group(0)!.toUpperCase(),
    );
  }

  bool get hasStarted => lastMove != null && lastMove!.isNotEmpty;

  Side? get activePlayer {
    if (fen == null || fen!.isEmpty) return Side.white; // Default to white

    try {
      final setup = Setup.parseFen(fen!);
      return setup.turn;
    } catch (e) {
      // Fallback if FEN is invalid
      return null;
    }
  }

  /// Effective game status with a board-state-only fallback.
  ///
  /// A clock reaching zero is not enough to derive a result: the flagged
  /// player may win, lose, or draw depending on whose clock expired and the
  /// opponent's mating material. Only results proven by the current position
  /// are inferred while the authoritative status is still ongoing.
  GameStatus get effectiveGameStatus {
    if (gameStatus.isFinished) return gameStatus;
    return _provablePositionResult();
  }

  GameStatus _provablePositionResult() {
    if (fen == null || fen!.isEmpty) return gameStatus;

    try {
      final setup = Setup.parseFen(fen!);
      final position = Chess.fromSetup(setup);

      if (position.isCheckmate) {
        return setup.turn == Side.white
            ? GameStatus.blackWins
            : GameStatus.whiteWins;
      }
      if (position.isStalemate || position.isInsufficientMaterial) {
        return GameStatus.draw;
      }
    } catch (_) {
      // Invalid or partial FEN: retain the authoritative status.
    }
    return gameStatus;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GamesTourModel &&
        other.gameId == gameId &&
        other.source == source &&
        other.whitePlayer == whitePlayer &&
        other.blackPlayer == blackPlayer &&
        other.whiteTimeDisplay == whiteTimeDisplay &&
        other.blackTimeDisplay == blackTimeDisplay &&
        other.whiteClockCentiseconds == whiteClockCentiseconds &&
        other.blackClockCentiseconds == blackClockCentiseconds &&
        other.whiteClockSeconds == whiteClockSeconds &&
        other.blackClockSeconds == blackClockSeconds &&
        other.lastMoveTime == lastMoveTime &&
        other.dateStart == dateStart &&
        other.gameDay == gameDay &&
        other.gameStatus == gameStatus &&
        other.lastMove == lastMove &&
        other.fen == fen &&
        other.pgn == pgn &&
        other.boardNr == boardNr &&
        other.roundId == roundId &&
        other.roundSlug == roundSlug &&
        other.tourId == tourId &&
        other.tourSlug == tourSlug &&
        other.tourName == tourName &&
        other.eventName == eventName &&
        other.eco == eco &&
        other.openingName == openingName &&
        other.timeControl == timeControl &&
        other.avgElo == avgElo &&
        other.isOnline == isOnline;
  }

  @override
  int get hashCode {
    return Object.hashAll([
      gameId,
      source,
      whitePlayer,
      blackPlayer,
      whiteTimeDisplay,
      blackTimeDisplay,
      whiteClockCentiseconds,
      blackClockCentiseconds,
      whiteClockSeconds,
      blackClockSeconds,
      lastMoveTime,
      dateStart,
      gameDay,
      gameStatus,
      lastMove,
      fen,
      pgn,
      boardNr,
      roundId,
      roundSlug,
      tourId,
      tourSlug,
      tourName,
      eventName,
      eco,
      openingName,
      timeControl,
      avgElo,
      isOnline,
    ]);
  }
}

// Rest of the classes remain the same...
class PlayerCard {
  final String name;
  final String federation;
  final String title;
  final int rating;
  final String countryCode;
  final int? fideId;
  final String? team;
  final String? gamebasePlayerId;
  final double? customPoints;

  PlayerCard({
    required this.name,
    required this.federation,
    required this.title,
    required this.rating,
    required this.countryCode,
    required this.team,
    this.fideId,
    this.gamebasePlayerId,
    this.customPoints,
  });

  factory PlayerCard.fromPlayer(Player player) {
    final name = player.name.trim();
    if (name.isEmpty) {
      throw ArgumentError('Player name cannot be empty');
    }

    return PlayerCard(
      name: name,
      federation: player.fed.trim(),
      title: player.title.trim(),
      rating: player.rating >= 0 ? player.rating : 0,
      countryCode: player.fed.trim(),
      fideId: player.fideId > 0 ? player.fideId : null,
      team: player.team,
      customPoints: player.customPoints,
    );
  }

  PlayerCard copyWith({
    String? name,
    String? federation,
    String? title,
    int? rating,
    String? countryCode,
    int? fideId,
    String? team,
    String? gamebasePlayerId,
    double? customPoints,
  }) {
    return PlayerCard(
      name: name ?? this.name,
      federation: federation ?? this.federation,
      title: title ?? this.title,
      rating: rating ?? this.rating,
      countryCode: countryCode ?? this.countryCode,
      fideId: fideId ?? this.fideId,
      team: team ?? this.team,
      gamebasePlayerId: gamebasePlayerId ?? this.gamebasePlayerId,
      customPoints: customPoints ?? this.customPoints,
    );
  }

  String get displayName => name;
  String get displayTitle => title.isNotEmpty ? title : '';
  String get displayRating => rating > 0 ? rating.toString() : 'Unrated';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PlayerCard &&
        other.name == name &&
        other.federation == federation &&
        other.title == title &&
        other.rating == rating &&
        other.countryCode == countryCode &&
        other.fideId == fideId &&
        other.team == team &&
        other.gamebasePlayerId == gamebasePlayerId &&
        other.customPoints == customPoints;
  }

  @override
  int get hashCode {
    return Object.hash(
      name,
      federation,
      title,
      rating,
      countryCode,
      fideId,
      team,
      gamebasePlayerId,
      customPoints,
    );
  }
}

enum GameStatus {
  ongoing,
  whiteWins,
  blackWins,
  draw,
  unknown;

  static GameStatus fromString(String? status) {
    if (status == null || status.trim().isEmpty) {
      return GameStatus.unknown;
    }

    final normalizedStatus = status.trim();
    final upper = normalizedStatus.toUpperCase();

    switch (normalizedStatus) {
      case '1-0':
        return GameStatus.whiteWins;
      case '0-1':
        return GameStatus.blackWins;
      case '1/2-1/2':
      case '½-½':
      case '0.5-0.5':
        return GameStatus.draw;
      case '*':
      case 'ongoing':
      case 'live':
        return GameStatus.ongoing;
      default:
        // Support Gamebase API result codes (W/B/D)
        switch (upper) {
          case 'ONGOING':
          case 'LIVE':
            return GameStatus.ongoing;
          case 'W':
            return GameStatus.whiteWins;
          case 'B':
            return GameStatus.blackWins;
          case 'D':
          case 'DRAW':
            return GameStatus.draw;
          default:
            return GameStatus.unknown;
        }
    }
  }

  String get displayText {
    switch (this) {
      case GameStatus.whiteWins:
        return '1-0';
      case GameStatus.blackWins:
        return '0-1';
      case GameStatus.draw:
        return '½-½';
      case GameStatus.ongoing:
        return '*';
      case GameStatus.unknown:
        return '';
    }
  }

  bool get isFinished {
    return this != GameStatus.ongoing && this != GameStatus.unknown;
  }

  bool get isOngoing {
    return this == GameStatus.ongoing;
  }
}
