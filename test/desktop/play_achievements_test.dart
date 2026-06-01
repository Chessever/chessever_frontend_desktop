import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/play_achievements.dart';

void main() {
  test('achievement definitions cover every badge id exactly once', () {
    final ids = kPlayAchievementDefinitions.map((d) => d.id).toList();

    expect(ids.length, PlayAchievementId.values.length);
    expect(ids.toSet().length, ids.length);
    expect(ids, unorderedEquals(PlayAchievementId.values));
  });

  test('stat-backed achievement progress covers chess result axes', () {
    const stats = PlayAchievementStats(
      gamesPlayed: 50,
      wins: 25,
      draws: 1,
      checkmateWins: 2,
      whiteWins: 3,
      blackWins: 4,
      bulletWins: 5,
      blitzWins: 6,
      rapidWins: 7,
      classicalWins: 8,
      stockfishWins: 9,
      leelaWins: 10,
      maiaWins: 11,
      tournamentsCreated: 12,
      tournamentsCompleted: 13,
      fullHouseTournaments: 14,
    );

    expect(stats.progressFor(PlayAchievementId.fiftyGames), 50);
    expect(stats.progressFor(PlayAchievementId.twentyFiveWins), 25);
    expect(stats.progressFor(PlayAchievementId.firstDraw), 1);
    expect(stats.progressFor(PlayAchievementId.checkmateArtist), 2);
    expect(stats.progressFor(PlayAchievementId.whiteWin), 3);
    expect(stats.progressFor(PlayAchievementId.blackWin), 4);
    expect(stats.progressFor(PlayAchievementId.bulletWinner), 5);
    expect(stats.progressFor(PlayAchievementId.blitzWinner), 6);
    expect(stats.progressFor(PlayAchievementId.rapidWinner), 7);
    expect(stats.progressFor(PlayAchievementId.classicalWinner), 8);
    expect(stats.progressFor(PlayAchievementId.stockfishSlayer), 9);
    expect(stats.progressFor(PlayAchievementId.leelaBreaker), 10);
    expect(stats.progressFor(PlayAchievementId.maiaMatch), 11);
    expect(stats.progressFor(PlayAchievementId.tournamentDirector), 12);
    expect(stats.progressFor(PlayAchievementId.eventFinisher), 13);
    expect(stats.progressFor(PlayAchievementId.fullHouseDirector), 14);
  });

  test('contribution-backed achievement progress fills tactical badges', () {
    final stats = const PlayAchievementStats().withBadgeContributions(const [
      PlayBadgeContribution(
        id: PlayAchievementId.queenHunter,
        reason: 'Captured the queen',
      ),
      PlayBadgeContribution(
        id: PlayAchievementId.queenHunter,
        reason: 'Captured the queen again',
      ),
      PlayBadgeContribution(
        id: PlayAchievementId.scandinavianWin,
        reason: 'Scandinavian Win',
      ),
    ]);

    expect(stats.progressFor(PlayAchievementId.queenHunter), 2);
    expect(stats.progressFor(PlayAchievementId.scandinavianWin), 1);
    expect(stats.progressFor(PlayAchievementId.promotionPoint), 0);
  });
}
