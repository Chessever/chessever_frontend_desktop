import 'dart:math' as math;

/// One scored entry from a real game or an official result. Null points are
/// unfinished/unavailable; non-played entries must set rated to false.
class ScorecardMetricGame {
  const ScorecardMetricGame({
    required this.points,
    required this.opponentRating,
    this.rated = true,
  });
  final double? points;
  final double? opponentRating;
  final bool rated;
}

class ScorecardMetricResult {
  ScorecardMetricResult({
    required this.performanceRating,
    required this.ratingChange,
    required List<int?> gameRatingChanges,
  }) : gameRatingChanges = List.unmodifiable(gameRatingChanges);
  final int? performanceRating;
  final int? ratingChange;
  final List<int?> gameRatingChanges;
}

// JavaScript Math.round uses ties towards +infinity (unlike Dart.round).
int _roundLikeWeb(double value) => (value + .5).floor();

/// Estimates only: the source's linear performance approximation, not a
/// federation's published performance/rating or its exact rating tables.
ScorecardMetricResult calculateScorecardMetrics({
  required double? playerRating,
  required double? kFactor,
  required Iterable<ScorecardMetricGame> games,
}) {
  var totalOpponentRating = 0.0;
  var totalScore = 0.0;
  var validGames = 0;
  var rawRatingChange = 0.0;
  final canCalculateRating =
      playerRating != null &&
      playerRating.isFinite &&
      playerRating > 0 &&
      kFactor != null &&
      kFactor.isFinite &&
      kFactor > 0;
  final changes = <int?>[];
  for (final game in games) {
    final score = game.points;
    final rating = game.opponentRating;
    if (!game.rated ||
        score == null ||
        !const [0.0, .5, 1.0].contains(score) ||
        rating == null ||
        !rating.isFinite ||
        rating <= 0) {
      changes.add(null);
      continue;
    }
    totalOpponentRating += rating;
    totalScore += score;
    validGames++;
    if (!canCalculateRating) {
      changes.add(null);
      continue;
    }
    final difference = (rating - playerRating).clamp(-400, 400);
    final expected = 1 / (1 + math.pow(10, difference / 400));
    final change = kFactor * (score - expected);
    rawRatingChange += change;
    changes.add(_roundLikeWeb(change));
  }
  int? performance;
  if (validGames > 0) {
    final percentage = totalScore / validGames;
    final delta =
        percentage >= 1
            ? 800
            : percentage <= 0
            ? -800
            : 400 * (2 * percentage - 1);
    performance = _roundLikeWeb(totalOpponentRating / validGames + delta);
  }
  return ScorecardMetricResult(
    performanceRating: performance,
    ratingChange:
        canCalculateRating && validGames > 0
            ? _roundLikeWeb(rawRatingChange)
            : null,
    gameRatingChanges: changes,
  );
}

/// Adapt one player's official results; callers must not pass the whole roster.
ScorecardMetricResult calculateOfficialScorecardMetrics({
  required double? playerRating,
  required double? kFactor,
  required Iterable<OfficialRoundResult> results,
}) => calculateScorecardMetrics(
  playerRating: playerRating,
  kFactor: kFactor,
  games: results.map(
    (r) => ScorecardMetricGame(
      points: r.points,
      opponentRating: r.opponentRating,
      rated: !r.nonPlayed,
    ),
  ),
);

/// Result-only domain data: never a game, never an invented game identifier.
class OfficialRoundResult {
  const OfficialRoundResult({
    required this.playerName,
    this.playerFideId,
    required this.roundId,
    required this.roundName,
    required this.roundNumber,
    this.tourId,
    this.color,
    required this.points,
    required this.opponentName,
    this.opponentFideId,
    this.opponentRating,
    this.opponentTitle,
    this.opponentFed,
    this.opponentRank,
    this.nonPlayed = false,
  });

  final String playerName;
  final String? playerFideId;
  final String roundId;
  final String roundName;
  final int roundNumber;
  final String? tourId;

  /// 'white', 'black', or null for a bye.
  final String? color;
  final double points;
  final String opponentName;
  final String? opponentFideId;
  final double? opponentRating;
  final String? opponentTitle;
  final String? opponentFed;
  final int? opponentRank;
  final bool nonPlayed;
}

class OfficialRoundResults {
  OfficialRoundResults({
    required this.roundId,
    required this.roundName,
    required this.roundNumber,
    this.tourId,
    required List<OfficialRoundResult> results,
  }) : results = List.unmodifiable(results);

  final String roundId;
  final String roundName;
  final int roundNumber;
  final String? tourId;
  final List<OfficialRoundResult> results;
}

/// Match by positive FIDE ID when both sides have one, otherwise exact name.
bool officialResultMatchesPlayer(
  OfficialRoundResult result, {
  required String playerName,
  Object? playerFideId,
}) {
  final left = _positiveFideId(result.playerFideId);
  final right = _positiveFideId(playerFideId);
  if (left != null && right != null) return left == right;
  final key = _nameKey(playerName);
  return key.isNotEmpty && key == _nameKey(result.playerName);
}

String? _positiveFideId(Object? value) {
  final text = value?.toString() ?? '';
  if (!RegExp(r'^[0-9]+$').hasMatch(text)) return null;
  final number = int.tryParse(text);
  return number != null && number > 0 ? number.toString() : null;
}

/// Null means absent OR ambiguous. Pass roundId for a per-round lookup.
OfficialRoundResult? findOfficialRoundResult(
  Iterable<OfficialRoundResults> rounds, {
  required String playerName,
  Object? playerFideId,
  String? roundId,
}) {
  OfficialRoundResult? found;
  for (final round in rounds) {
    if (roundId != null && round.roundId != roundId) continue;
    for (final result in round.results) {
      if (!officialResultMatchesPlayer(
        result,
        playerName: playerName,
        playerFideId: playerFideId,
      )) {
        continue;
      }
      if (found != null) return null;
      found = result;
    }
  }
  return found;
}

Map? _record(Object? value) => value is Map ? value : null;
String? _text(Object? value) => value is String ? value : null;
double? _finiteNumber(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;
int? _positiveRank(Object? value) =>
    value is num &&
            value.isFinite &&
            value > 0 &&
            value == value.truncateToDouble()
        ? value.toInt()
        : null;
// This checkout has no Unicode normalization dependency. Preserve letters,
// numbers AND combining marks; do not transliterate or fuzzy-match identities.
// Unlike web NFKC, compatibility/composed-vs-decomposed spellings may fail closed.
String _nameKey(Object? value) =>
    value is String
        ? value.toLowerCase().replaceAll(
          RegExp(r'[^\p{L}\p{N}\p{M}]', unicode: true),
          '',
        )
        : '';

/// HTTPS mirrors identify the same section; ports and userinfo are forbidden.
String? chessResultsEventKey(Object? value) {
  if (value is! String) return null;
  // Uri canonicalizes :443 away, so validate the original authority too.
  if (!RegExp(
    r'^https://(?:(?:s[123]|www)\.)?chess-results\.com/',
    caseSensitive: false,
  ).hasMatch(value)) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      !RegExp(
        r'^(?:(?:s[123]|www)\.)?chess-results\.com$',
        caseSensitive: false,
      ).hasMatch(uri.host)) {
    return null;
  }
  // Reject an empty userinfo marker too (Uri.userInfo alone cannot detect it).
  if (uri.authority.contains('@')) return null;
  return RegExp(
    r'^/tnr(\d+)\.aspx$',
    caseSensitive: false,
  ).firstMatch(uri.path)?.group(1);
}

List<OfficialRoundResults> normalizeOfficialRoundResults(
  Object? rawTour,
  List<Object?> rawRoundRows,
) {
  final tour = _record(rawTour);
  final event = chessResultsEventKey(_record(tour?['info'])?['standings']);
  final players = tour?['players'];
  final roster = players is List ? players.whereType<Map>().toList() : <Map>[];
  if (event == null || roster.isEmpty) return const [];
  Map? identify(Object? value) {
    final p = _record(value);
    final name = _nameKey(p?['name']);
    if (p == null || name.isEmpty) return null;
    final matches =
        roster
            .where(
              (r) =>
                  _nameKey(r['name']) == name &&
                  (p['no'] == null ||
                      r['startNumber'] == null ||
                      (num.tryParse('${p['no']}') != null &&
                          num.tryParse('${p['no']}') ==
                              num.tryParse('${r['startNumber']}'))) &&
                  (p['fideId'] == null ||
                      r['fideId'] == null ||
                      '${p['fideId']}' == '${r['fideId']}'),
            )
            .toList();
    return matches.length == 1 ? matches.single : null;
  }

  final duplicateRoundIds = <String>{};
  final roundIds = <String>{};
  for (final row in rawRoundRows) {
    final id = _text(_record(row)?['id']);
    if (id != null && !roundIds.add(id)) duplicateRoundIds.add(id);
  }
  final output = <OfficialRoundResults>[];
  for (final rawRound in rawRoundRows) {
    final round = _record(rawRound);
    final table = _record(round?['pairings']);
    final match = RegExp(
      r'(?:^|-)round-(\d+)$',
    ).firstMatch(_text(round?['slug']) ?? '');
    final number = int.tryParse(match?.group(1) ?? '');
    if (round == null ||
        round['id'] is! String ||
        (round['id'] as String).isEmpty ||
        (tour?['id'] != null &&
            round['tour_id'] != null &&
            tour?['id'] != round['tour_id']) ||
        table == null ||
        table['format'] != 'individual' ||
        chessResultsEventKey(table['sourceUrl']) != event ||
        table['pairings'] is! List ||
        (table['pairings'] as List).length > 2000 ||
        number == null ||
        number <= 0 ||
        num.tryParse('${table['round_number']}') != number) {
      continue;
    }
    final roundId = round['id'] as String;
    final roundName = _text(round['name']) ?? 'Round $number';
    final tourId = _text(tour?['id']);
    if (duplicateRoundIds.contains(roundId)) continue;
    final results = <OfficialRoundResult>[];
    final seen = <String>{};
    var valid = true;
    for (final entry in table['pairings'] as List) {
      final pairing = _record(entry);
      final white = _record(pairing?['white']);
      final black = _record(pairing?['black']);
      final bye = const {
        'bye',
        'notpaired',
        'notpairedbye',
      }.contains(_nameKey(black?['name']));
      final w = identify(white);
      final b = bye ? null : identify(black);
      if (white == null ||
          black == null ||
          w == null ||
          (!bye && b == null) ||
          (!bye && _nameKey(w['name']) == _nameKey(b?['name']))) {
        valid = false;
        break;
      }
      if (!seen.add(_nameKey(w['name'])) ||
          (b != null && !seen.add(_nameKey(b['name'])))) {
        valid = false;
        break;
      }
      final raw = (_text(pairing?['result']) ?? '').replaceAll(
        RegExp(r'\s'),
        '',
      );
      final marks =
          bye
              ? const <String, List<double>>{
                '1': [1],
                '½': [.5],
                '0.5': [.5],
                '0': [0],
              }[raw]
              : const <String, List<double>>{
                '1-0': [1, 0],
                '0-1': [0, 1],
                '½-½': [.5, .5],
                '1/2-1/2': [.5, .5],
                '+--': [1, 0],
                '--+': [0, 1],
                '0-0': [0, 0],
                '---': [0, 0],
              }[raw];
      if (marks == null) continue;
      final nonPlayed = bye || const {'+--', '--+', '0-0', '---'}.contains(raw);
      for (var side = 0; side < (bye ? 1 : 2); side++) {
        final player = (side == 0 ? w : b)!;
        final opponent = side == 0 ? b : w;
        final rawOpponent = side == 0 ? black : white;
        results.add(
          OfficialRoundResult(
            playerName: player['name'] as String,
            playerFideId: player['fideId']?.toString(),
            roundId: roundId,
            roundName: roundName,
            roundNumber: number,
            tourId: tourId,
            color:
                bye
                    ? null
                    : side == 0
                    ? 'white'
                    : 'black',
            points: marks[side],
            opponentName: (opponent?['name'] ?? rawOpponent['name']) as String,
            opponentFideId: opponent?['fideId']?.toString(),
            opponentRating: _finiteNumber(rawOpponent['rating']),
            opponentTitle: _text(opponent?['title']),
            opponentFed: _text(opponent?['fed']),
            opponentRank: _positiveRank(opponent?['rank']),
            nonPlayed: nonPlayed,
          ),
        );
      }
    }
    if (valid && results.isNotEmpty) {
      output.add(
        OfficialRoundResults(
          roundId: roundId,
          roundName: roundName,
          roundNumber: number,
          tourId: tourId,
          results: results,
        ),
      );
    }
  }
  return output;
}
