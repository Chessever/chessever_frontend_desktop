import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Pure SavedAnalysis -> GamesTourModel converters.
///
/// Split out of `load_saved_analysis.dart`, which also carries board
/// navigation. Nothing here touches a `BuildContext`, a route or a provider,
/// so view-models (My Likes) can build card models without importing the
/// board screen.

/// Converts a SavedAnalysis to a board-ready GamesTourModel.
///
/// Uses `saved_analysis_<id>` as gameId to avoid conflicts with live games;
/// the original game stays reachable through [GamesTourModel.sourceGameId].
/// PGN is populated via exportGameToPgn so swiped-to games can load moves.
GamesTourModel convertSavedAnalysisToGame(SavedAnalysis analysis) {
  final chessGame = analysis.chessGame;

  final md = chessGame.metadata;
  final whiteName = md['White'] as String? ?? 'White';
  final blackName = md['Black'] as String? ?? 'Black';
  final result = md['Result'] as String? ?? '*';
  final whiteTitle = (md['WhiteTitle'] ?? '').toString().trim();
  final blackTitle = (md['BlackTitle'] ?? '').toString().trim();
  final whiteRating = _parseRating(md['WhiteElo']);
  final blackRating = _parseRating(md['BlackElo']);
  final whiteCountryCode = _countryCodeFromMetadata(md, isWhite: true);
  final blackCountryCode = _countryCodeFromMetadata(md, isWhite: false);

  final whitePlayer = PlayerCard(
    name: whiteName,
    federation: whiteCountryCode,
    title: whiteTitle,
    rating: whiteRating,
    countryCode: whiteCountryCode,
    team: null,
    fideId: null,
  );

  final blackPlayer = PlayerCard(
    name: blackName,
    federation: blackCountryCode,
    title: blackTitle,
    rating: blackRating,
    countryCode: blackCountryCode,
    team: null,
    fideId: null,
  );

  final eco = md['ECO']?.toString();
  final openingName = md['Opening']?.toString();
  final event = md['Event']?.toString() ?? 'library';
  final round = md['Round']?.toString() ?? 'saved_analysis';
  // `TimeControl` is the PGN machine field (`40/5400+30:1800+30`); the speed
  // word lives on `TcCategory`.
  final tcCategory = md['TcCategory']?.toString();
  final timeControl =
      (tcCategory != null && tcCategory.isNotEmpty)
          ? tcCategory
          : md['TimeControl']?.toString();

  final parsedDate = _parsePgnDate(md['Date']?.toString());

  final whiteTimeDisplay = md['WhiteTimeDisplay']?.toString() ?? '--:--';
  final blackTimeDisplay = md['BlackTimeDisplay']?.toString() ?? '--:--';
  final whiteClockSeconds =
      md['WhiteClockSeconds'] != null
          ? int.tryParse(md['WhiteClockSeconds'].toString())
          : null;
  final blackClockSeconds =
      md['BlackClockSeconds'] != null
          ? int.tryParse(md['BlackClockSeconds'].toString())
          : null;
  final boardNr =
      md['BoardNr'] != null ? int.tryParse(md['BoardNr'].toString()) : null;
  final tourSlug = md['TourSlug']?.toString();
  final roundSlug = md['RoundSlug']?.toString();

  // Prefer the saved UUID from sourceTournamentId, which allows fetching full
  // event info (images, website, etc.).
  final tourId =
      (analysis.sourceTournamentId?.isNotEmpty == true)
          ? analysis.sourceTournamentId!
          : event;

  return GamesTourModel(
    gameId: 'saved_analysis_${analysis.id}',
    sourceGameId: analysis.sourceGameId,
    source: GameSource.savedAnalysis,
    whitePlayer: whitePlayer,
    blackPlayer: blackPlayer,
    whiteTimeDisplay: whiteTimeDisplay,
    blackTimeDisplay: blackTimeDisplay,
    whiteClockCentiseconds: (whiteClockSeconds ?? 0) * 100,
    blackClockCentiseconds: (blackClockSeconds ?? 0) * 100,
    whiteClockSeconds: whiteClockSeconds,
    blackClockSeconds: blackClockSeconds,
    boardNr: boardNr,
    tourSlug: tourSlug,
    roundSlug: roundSlug,
    gameStatus: GameStatus.fromString(result),
    roundId: round,
    tourId: tourId,
    timeControl: timeControl,
    // PGN populated for swiped-to games (the tapped game restores from its
    // saved analysis instead).
    pgn: exportGameToPgn(chessGame),
    eco: eco,
    openingName: openingName,
    lastMoveTime: parsedDate,
  );
}

/// Lightweight card model for list surfaces (My Likes).
///
/// Unlike [convertSavedAnalysisToGame] this skips the PGN export and keeps
/// the saved row id as [GamesTourModel.gameId], with the original game on
/// [GamesTourModel.sourceGameId] so like identity survives the conversion.
GamesTourModel savedAnalysisToCardGame(SavedAnalysis analysis) {
  final md = analysis.chessGame.metadata;
  final whiteName = md['White'] as String? ?? 'White';
  final blackName = md['Black'] as String? ?? 'Black';
  final result = md['Result'] as String? ?? '*';
  final whiteTitle = (md['WhiteTitle'] ?? '').toString().trim();
  final blackTitle = (md['BlackTitle'] ?? '').toString().trim();
  final whiteRating = _parseRating(md['WhiteElo']);
  final blackRating = _parseRating(md['BlackElo']);
  final whiteCountryCode = _countryCodeFromMetadata(md, isWhite: true);
  final blackCountryCode = _countryCodeFromMetadata(md, isWhite: false);

  final eco = md['ECO']?.toString();
  final openingName = md['Opening']?.toString();
  final metadataEvent = md['Event']?.toString().trim();
  final event =
      metadataEvent == null || metadataEvent.isEmpty
          ? 'library'
          : metadataEvent;
  final round = md['Round']?.toString() ?? 'saved_analysis';

  final tcCategory = md['TcCategory']?.toString();
  final timeControl =
      (tcCategory != null && tcCategory.isNotEmpty)
          ? tcCategory
          : md['TimeControl']?.toString();
  final isOnline = md['IsOnline']?.toString().toLowerCase() == 'true';

  final tourId =
      (analysis.sourceTournamentId?.isNotEmpty == true)
          ? analysis.sourceTournamentId!
          : event;

  return GamesTourModel(
    gameId: analysis.id,
    sourceGameId: analysis.sourceGameId,
    source: GameSource.savedAnalysis,
    whitePlayer: PlayerCard(
      name: whiteName,
      federation: whiteCountryCode,
      title: whiteTitle,
      rating: whiteRating,
      countryCode: whiteCountryCode,
      team: null,
      fideId: _parseFideId(md['WhiteFideId']),
    ),
    blackPlayer: PlayerCard(
      name: blackName,
      federation: blackCountryCode,
      title: blackTitle,
      rating: blackRating,
      countryCode: blackCountryCode,
      team: null,
      fideId: _parseFideId(md['BlackFideId']),
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.fromString(result),
    roundId: round,
    tourId: tourId,
    tourName: event == 'library' ? null : event,
    eventName: event == 'library' ? null : event,
    timeControl: timeControl,
    isOnline: isOnline,
    eco: eco,
    openingName: openingName,
    lastMoveTime: _parsePgnDate(md['Date']?.toString()),
  );
}

/// PGN `YYYY.MM.DD` or ISO date. Partial PGN dates (`2026.??.??`) yield null.
DateTime? _parsePgnDate(String? date) {
  if (date == null || date.isEmpty) return null;
  if (date.contains('.')) {
    final parts = date.split('.');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }
  return DateTime.tryParse(date);
}

int _parseRating(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return 0;
  return int.tryParse(value) ?? 0;
}

int? _parseFideId(Object? raw) {
  final value = raw?.toString().trim() ?? '';
  if (value.isEmpty) return null;
  return int.tryParse(value);
}

String _countryCodeFromMetadata(
  Map<String, dynamic> md, {
  required bool isWhite,
}) {
  final prefix = isWhite ? 'White' : 'Black';

  final candidates = <Object?>[
    md['${prefix}Fed'],
    md['${prefix}Federation'],
    md['${prefix}Country'],
    md['${prefix}FideFederation'],
    md['${prefix}Nationality'],
  ];

  for (final value in candidates) {
    final s = value?.toString().trim() ?? '';
    if (s.isNotEmpty) return s;
  }

  return '';
}
