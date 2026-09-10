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
