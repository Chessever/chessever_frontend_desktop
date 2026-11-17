import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/services/official_round_results.dart';

/// Presentation data, not a game. A null game must never reach a Board opener.
class PlayerScoreCardResult {
  const PlayerScoreCardResult({
    this.game,
    this.official,
    required this.playerIsWhite,
  });
  final GamesTourModel? game;
  final OfficialRoundResult? official;
  final bool playerIsWhite;

  String get roundId => game?.roundId ?? official!.roundId;
  int? get roundNumber =>
      official?.roundNumber ??
      int.tryParse(
        RegExp(
              r'(?:round|r)[\s_-]*(\d+)',
              caseSensitive: false,
            ).firstMatch(game?.roundSlug ?? '')?.group(1) ??
            '',
      );
  String? get roundLabel =>
      roundNumber == null ? game?.roundSlug : 'R$roundNumber';
  bool get nonPlayed =>
      (game?.isDoubleForfeit ?? false) || (official?.nonPlayed ?? false);
  double? get points {
    final current = game;
    if (current == null) return official!.points;
    if (current.isDoubleForfeit) return 0;
    return switch (current.gameStatus) {
      GameStatus.whiteWins => playerIsWhite ? 1 : 0,
      GameStatus.blackWins => playerIsWhite ? 0 : 1,
      GameStatus.draw => .5,
      _ => null,
    };
  }

  PlayerCard get opponent {
    final current = game;
    final card =
        current == null
            ? null
            : (playerIsWhite ? current.blackPlayer : current.whitePlayer);
    final source = official;
    return PlayerCard(
      name: card?.name ?? source!.opponentName,
      rating:
          (card?.rating ?? 0) > 0
              ? card!.rating
              : source?.opponentRating?.toInt() ?? 0,
      federation:
          (card?.federation ?? '').isNotEmpty
              ? card!.federation
              : source?.opponentFed ?? '',
      countryCode:
          (card?.countryCode ?? '').isNotEmpty
              ? card!.countryCode
              : source?.opponentFed ?? '',
      title:
          (card?.title ?? '').isNotEmpty
              ? card!.title
              : source?.opponentTitle ?? '',
      fideId: card?.fideId ?? int.tryParse(source?.opponentFideId ?? ''),
      team: card?.team,
    );
  }

  ScorecardMetricGame get metricGame => ScorecardMetricGame(
    points: points,
    opponentRating: opponent.rating.toDouble(),
    rated: !nonPlayed,
  );
}

bool _samePlayer(
  String firstName,
  int? firstFide,
  String secondName,
  Object? secondFide,
) {
  final secondId = int.tryParse(secondFide?.toString() ?? '');
  if ((firstFide ?? 0) > 0 && (secondId ?? 0) > 0) return firstFide == secondId;
  String key(String name) => name.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}\p{M}]', unicode: true),
    '',
  );
  return key(firstName).isNotEmpty && key(firstName) == key(secondName);
}

List<PlayerScoreCardResult> buildPlayerScoreCardResults({
  required String playerName,
  Object? playerFideId,
  required List<GamesTourModel> games,
  List<OfficialRoundResults> officialResults = const [],
  bool sortByRound = true,
}) {
  final entries = <PlayerScoreCardResult>[];
  final seen = <String>{};
  for (final game in games) {
    if (!seen.add(game.gameId)) continue;
    final white = _samePlayer(
      game.whitePlayer.name,
      game.whitePlayer.fideId,
      playerName,
      playerFideId,
    );
    final black = _samePlayer(
      game.blackPlayer.name,
      game.blackPlayer.fideId,
      playerName,
      playerFideId,
    );
    if (!white && !black) continue;
    entries.add(PlayerScoreCardResult(game: game, playerIsWhite: white));
  }
  final byRound = <String, List<OfficialRoundResult>>{};
  for (final round in officialResults) {
    for (final result in round.results) {
      if (!officialResultMatchesPlayer(
        result,
        playerName: playerName,
        playerFideId: playerFideId,
      )) {
        continue;
      }
      byRound
          .putIfAbsent('${result.tourId ?? ''}:${result.roundId}', () => [])
          .add(result);
    }
  }
  for (final matches in byRound.values) {
    if (matches.length != 1) continue;
    final result = matches.single;
    final recorded =
        entries.indexed
            .where(
              (entry) =>
                  entry.$2.game != null &&
                  entry.$2.roundId == result.roundId &&
                  (result.tourId == null ||
                      entry.$2.game!.tourId == result.tourId),
            )
            .toList();
    if (recorded.isNotEmpty) {
      if (recorded.length == 1) {
        final (index, entry) = recorded.single;
        final opponent = entry.opponent;
        if (_samePlayer(
          opponent.name,
          opponent.fideId,
          result.opponentName,
          result.opponentFideId,
        )) {
          entries[index] = PlayerScoreCardResult(
            game: entry.game,
            official: result,
            playerIsWhite: entry.playerIsWhite,
          );
        }
      }
      continue;
    }
    entries.add(
      PlayerScoreCardResult(
        official: result,
        playerIsWhite: result.color == 'white',
      ),
    );
  }
  // Keep the caller's existing game ordering stable within the same round.
  final order = {for (final (i, entry) in entries.indexed) entry: i};
  if (sortByRound) {
    entries.sort((a, b) {
      final round = (a.roundNumber ?? 9999).compareTo(b.roundNumber ?? 9999);
      return round != 0 ? round : order[a]!.compareTo(order[b]!);
    });
  }
  return List.unmodifiable(entries);
}
