import 'package:chessever/desktop/widgets/desktop_game_points.dart';
import 'package:chessever/utils/awarded_points.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

enum DesktopTeamGameOrder { sameOrder, oppositeOrder }

class DesktopTeamMatchGame {
  const DesktopTeamMatchGame({required this.game, required this.order});

  final GamesTourModel game;
  final DesktopTeamGameOrder order;
}

class DesktopTeamMatchScore {
  const DesktopTeamMatchScore({required this.left, required this.right});

  final double left;
  final double right;

  bool get isDraw => left == right;
}

class DesktopTeamMatchGroup {
  const DesktopTeamMatchGroup({
    required this.leftTeam,
    required this.rightTeam,
    required this.games,
  });

  final String leftTeam;
  final String rightTeam;
  final List<DesktopTeamMatchGame> games;

  List<GamesTourModel> get gameModels =>
      games.map((matchGame) => matchGame.game).toList(growable: false);

  List<PlayerCard> get leftPlayers => [
    for (final matchGame in games)
      desktopTeamMatchSidePlayer(matchGame, isLeft: true),
  ];

  List<PlayerCard> get rightPlayers => [
    for (final matchGame in games)
      desktopTeamMatchSidePlayer(matchGame, isLeft: false),
  ];

  DesktopTeamMatchScore get score {
    var left = 0.0;
    var right = 0.0;

    for (final matchGame in games) {
      final game = matchGame.game;
      final white = desktopGamePoints(game.gameStatus, isWhite: true,
          customPoints: game.whitePlayer.customPoints) ?? 0;
      final black = desktopGamePoints(game.gameStatus, isWhite: false,
          customPoints: game.blackPlayer.customPoints) ?? 0;
      final sameOrder = matchGame.order == DesktopTeamGameOrder.sameOrder;
      left += sameOrder ? white : black;
      right += sameOrder ? black : white;
    }

    return DesktopTeamMatchScore(left: left, right: right);
  }
}

List<DesktopTeamMatchGroup> buildDesktopTeamMatchGroups(
  List<GamesTourModel> games,
) {
  final order = <String>[];
  final builders = <String, _DesktopTeamMatchGroupBuilder>{};

  for (final game in games) {
    final whiteTeam = _teamLabel(game.whitePlayer);
    final blackTeam = _teamLabel(game.blackPlayer);
    final key = _canonicalTeamKey(whiteTeam, blackTeam);
    final normalizedWhite = _normalizeTeam(whiteTeam);
    final normalizedBlack = _normalizeTeam(blackTeam);

    final builder = builders.putIfAbsent(key, () {
      order.add(key);
      return _DesktopTeamMatchGroupBuilder(
        leftTeam: whiteTeam,
        rightTeam: blackTeam,
      );
    });

    final sameOrder =
        _normalizeTeam(builder.leftTeam) == normalizedWhite &&
        _normalizeTeam(builder.rightTeam) == normalizedBlack;
    builder.games.add(
      DesktopTeamMatchGame(
        game: game,
        order:
            sameOrder
                ? DesktopTeamGameOrder.sameOrder
                : DesktopTeamGameOrder.oppositeOrder,
      ),
    );
  }

  return [
    for (final key in order)
      DesktopTeamMatchGroup(
        leftTeam: builders[key]!.leftTeam,
        rightTeam: builders[key]!.rightTeam,
        games: List<DesktopTeamMatchGame>.unmodifiable(builders[key]!.games),
      ),
  ];
}

PlayerCard desktopTeamMatchSidePlayer(
  DesktopTeamMatchGame matchGame, {
  required bool isLeft,
}) {
  final sameOrder = matchGame.order == DesktopTeamGameOrder.sameOrder;
  if (isLeft) {
    return sameOrder ? matchGame.game.whitePlayer : matchGame.game.blackPlayer;
  }
  return sameOrder ? matchGame.game.blackPlayer : matchGame.game.whitePlayer;
}

/// Best flag token for a team row: the majority player country/federation,
/// otherwise the team name so [FederationFlag] can resolve "Jamaica" etc.
String? desktopTeamMatchFlagCode({
  required String teamName,
  required Iterable<PlayerCard> players,
}) {
  final counts = <String, int>{};
  for (final player in players) {
    final code = _playerFlagCode(player);
    if (code == null) continue;
    counts[code] = (counts[code] ?? 0) + 1;
  }
  if (counts.isNotEmpty) {
    final ranked =
        counts.entries.toList()..sort((left, right) {
          final byCount = right.value.compareTo(left.value);
          if (byCount != 0) return byCount;
          return left.key.compareTo(right.key);
        });
    return ranked.first.key;
  }

  final trimmed = teamName.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _playerFlagCode(PlayerCard player) {
  for (final value in [player.countryCode, player.federation]) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == '?') continue;
    return trimmed;
  }
  return null;
}

/// Horizontal inset that keeps a short team-match board row centered in the
/// same tile-width grid the surrounding Games tab uses.
double desktopCenteredSparseRowPadding({
  required double availableWidth,
  required int itemCount,
  required int columns,
  required double spacing,
}) {
  if (availableWidth <= 0 || itemCount <= 0 || columns <= 0) return 0;
  if (itemCount >= columns) return 0;
  final tileWidth = (availableWidth - spacing * (columns - 1)) / columns;
  if (tileWidth <= 0) return 0;
  final usedWidth = tileWidth * itemCount + spacing * (itemCount - 1);
  final padding = (availableWidth - usedWidth) / 2;
  return padding > 0 ? padding : 0;
}

int desktopCenteredSparseRowColumns({
  required int itemCount,
  required int columns,
}) {
  if (columns <= 0) return 1;
  if (itemCount <= 0) return columns;
  return itemCount < columns ? itemCount : columns;
}

String formatDesktopTeamMatchScore(double score) {
  if (score == score.truncateToDouble()) {
    return score.toInt().toString();
  }
  return formatAwardedPoints(score);
}

class _DesktopTeamMatchGroupBuilder {
  _DesktopTeamMatchGroupBuilder({
    required this.leftTeam,
    required this.rightTeam,
  });

  final String leftTeam;
  final String rightTeam;
  final List<DesktopTeamMatchGame> games = <DesktopTeamMatchGame>[];
}

String _teamLabel(PlayerCard player) {
  final team = player.team?.trim();
  if (team != null && team.isNotEmpty) {
    return team;
  }

  final country = player.countryCode.trim();
  if (country.isNotEmpty) {
    return country;
  }

  final federation = player.federation.trim();
  if (federation.isNotEmpty) {
    return federation;
  }

  return player.name.trim().isNotEmpty ? player.name.trim() : 'Unknown';
}

String _canonicalTeamKey(String firstTeam, String secondTeam) {
  final first = _normalizeTeam(firstTeam);
  final second = _normalizeTeam(secondTeam);
  return first.compareTo(second) <= 0
      ? '$first\u0000$second'
      : '$second\u0000$first';
}

String _normalizeTeam(String team) => team.trim().toLowerCase();
