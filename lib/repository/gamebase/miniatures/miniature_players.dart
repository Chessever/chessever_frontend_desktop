/// FIDE titles the Miniatures Players view offers as quick filters.
enum MiniaturePlayerTitle {
  gm('GM'),
  im('IM'),
  fm('FM');

  const MiniaturePlayerTitle(this.apiValue);

  final String apiValue;

  String get label => apiValue;
}

/// One row of the gamebase miniatures leaderboard: a player plus how they
/// fared across every miniature they appear in, on either colour. Desktop reads
/// it only for the W-L record and the gamebase player id behind a scorecard;
/// the ranking itself always comes from `chess_players` by rating.
class MiniaturePlayer {
  const MiniaturePlayer({
    required this.playerId,
    required this.name,
    required this.games,
    required this.wins,
    required this.losses,
    this.title,
    this.fed,
    this.fideId,
    this.rating,
    this.fastestWin,
    this.peakAvgRating,
  });

  final String playerId;
  final String name;
  final int games;
  final int wins;
  final int losses;
  final String? title;
  final String? fed;
  final int? fideId;
  final int? rating;

  /// Fewest moves in a miniature this player WON, null if they never won one.
  final int? fastestWin;
  final int? peakAvgRating;

  String get winLossLabel => '${wins}W-${losses}L';

  factory MiniaturePlayer.fromJson(Map<String, dynamic> json) {
    return MiniaturePlayer(
      playerId: _readString(json['playerId']),
      name: _readString(json['name']),
      games: _readInt(json['games']),
      wins: _readInt(json['wins']),
      losses: _readInt(json['losses']),
      title: _readNullableString(json['title']),
      fed: _readNullableString(json['fed']),
      fideId: _readNullableInt(json['fideId']),
      rating: _readNullableInt(json['rating']),
      fastestWin: _readNullableInt(json['fastestWin']),
      peakAvgRating: _readNullableInt(json['peakAvgRating']),
    );
  }
}

class MiniaturePlayersPage {
  const MiniaturePlayersPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  final List<MiniaturePlayer> items;
  final int total;
  final int limit;
  final int offset;

  factory MiniaturePlayersPage.fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(json['data'] as Map? ?? const {});
    return MiniaturePlayersPage(
      items:
          (data['items'] as List?)
              ?.whereType<Map>()
              .map(
                (item) =>
                    MiniaturePlayer.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList(growable: false) ??
          const <MiniaturePlayer>[],
      total: _readInt(data['total']),
      limit: _readInt(data['limit']),
      offset: _readInt(data['offset']),
    );
  }
}

/// Picks the leaderboard row that is provably the same person. FIDE id is the
/// only trustworthy key; a row without one is accepted only on an exact name
/// match.
MiniaturePlayer? matchMiniaturePlayerRecord({
  required List<MiniaturePlayer> candidates,
  required int fideId,
  required String name,
}) {
  MiniaturePlayer? byName;
  final wanted = name.trim().toLowerCase();
  for (final candidate in candidates) {
    if (candidate.fideId == fideId) return candidate;
    if (candidate.fideId == null &&
        byName == null &&
        candidate.name.trim().toLowerCase() == wanted) {
      byName = candidate;
    }
  }
  return byName;
}

String _readString(Object? value) => value?.toString().trim() ?? '';

String? _readNullableString(Object? value) {
  final trimmed = _readString(value);
  return trimmed.isEmpty ? null : trimmed;
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _readNullableInt(Object? value) {
  if (value == null) return null;
  return _readInt(value);
}
