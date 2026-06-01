import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:flutter_test/flutter_test.dart';

PlayerStandingModel _player({
  required String name,
  required int rating,
  String countryCode = 'USA',
  String? title,
  int? fideId,
}) {
  return PlayerStandingModel(
    countryCode: countryCode,
    title: title,
    name: name,
    score: rating,
    scoreChange: 0,
    matchScore: '0.0 / 0',
    fideId: fideId,
  );
}

void main() {
  group('standings search filtering', () {
    test('preserves the unfiltered overall rank for a one-player result', () {
      final standings = assignOverallRanks([
        for (var i = 1; i <= 36; i++)
          _player(name: 'Player $i', rating: 2800 - i, fideId: i),
        _player(
          name: 'Mamedyarov, Shakhriyar',
          rating: 2704,
          countryCode: 'AZE',
          title: 'GM',
          fideId: 13401319,
        ),
        _player(name: 'Player 38', rating: 2600, fideId: 38),
      ]);

      final result = filterStandingsByQuery(standings, 'mamedyarov');

      expect(result, hasLength(1));
      expect(result.single.name, 'Mamedyarov, Shakhriyar');
      expect(result.single.overallRank, 37);
    });

    test('matches title and federation without renumbering results', () {
      final standings = assignOverallRanks([
        _player(name: 'Carlsen, Magnus', rating: 2830, countryCode: 'NOR'),
        _player(
          name: 'Mamedyarov, Shakhriyar',
          rating: 2704,
          countryCode: 'AZE',
          title: 'GM',
        ),
      ]);

      expect(filterStandingsByQuery(standings, 'aze').single.overallRank, 2);
      expect(filterStandingsByQuery(standings, 'gm').single.overallRank, 2);
      expect(filterStandingsByQuery(standings, 'gm aze').single.overallRank, 2);
    });

    test('matches comma-separated names in natural typed order', () {
      final standings = assignOverallRanks([
        _player(name: 'Carlsen, Magnus', rating: 2830, countryCode: 'NOR'),
        _player(
          name: 'Mamedyarov, Shakhriyar',
          rating: 2704,
          countryCode: 'AZE',
          title: 'GM',
        ),
      ]);

      final result = filterStandingsByQuery(standings, 'shakhriyar mamedyarov');

      expect(result, hasLength(1));
      expect(result.single.name, 'Mamedyarov, Shakhriyar');
      expect(result.single.overallRank, 2);
    });
  });

  group('PlayerStandingModel overallRank', () {
    test('participates in json and equality', () {
      final player = _player(
        name: 'Mamedyarov, Shakhriyar',
        rating: 2704,
      ).copyWith(overallRank: 37);

      expect(PlayerStandingModel.fromJson(player.toJson()).overallRank, 37);
      expect(player, isNot(player.copyWith(overallRank: 1)));
    });
  });

  group('standing score resolution', () {
    test('keeps server score when game-derived score is empty', () {
      final resolved = resolveStandingScore(
        sourceScore: 4.5,
        sourcePlayed: 7,
        calculatedScore: 0,
        calculatedPlayed: 0,
      );

      expect(resolved.score, 4.5);
      expect(resolved.played, 7);
    });

    test('keeps server score when loaded games are only a partial subset', () {
      final resolved = resolveStandingScore(
        sourceScore: 4.5,
        sourcePlayed: 7,
        calculatedScore: 1,
        calculatedPlayed: 2,
      );

      expect(resolved.score, 4.5);
      expect(resolved.played, 7);
    });

    test(
      'uses game-derived score when games are more complete than source standings',
      () {
        final resolved = resolveStandingScore(
          sourceScore: 4.5,
          sourcePlayed: 7,
          calculatedScore: 5,
          calculatedPlayed: 8,
        );

        expect(resolved.score, 5);
        expect(resolved.played, 8);
      },
    );

    test('trusts custom-scored source even on Lichess broadcasts', () {
      // Norway Chess style: source 7.5 from 4 games is impossible under
      // standard 1/0.5/0 but valid under 3-1-0 + 1.5-armageddon scoring.
      final resolved = resolveStandingScore(
        sourceScore: 7.5,
        sourcePlayed: 4,
        calculatedScore: 2.5,
        calculatedPlayed: 4,
      );

      expect(resolved.score, 7.5);
      expect(resolved.played, 4);
    });

    test('uses game-derived score when no server score exists', () {
      final resolved = resolveStandingScore(
        sourceScore: null,
        sourcePlayed: 0,
        calculatedScore: 1.5,
        calculatedPlayed: 2,
      );

      expect(resolved.score, 1.5);
      expect(resolved.played, 2);
    });
  });

  group('source standings order resolution', () {
    test('preserves external order when external scores are current', () {
      expect(
        shouldPreserveExternalStandingOrder(
          useExternalOrder: true,
          hasUniversalRank: false,
          hasStaleExternalScores: false,
        ),
        isTrue,
      );
    });

    test('preserves rank order when every Lichess player has a rank', () {
      expect(
        shouldPreserveExternalStandingOrder(
          useExternalOrder: false,
          hasUniversalRank: true,
          hasStaleExternalScores: false,
        ),
        isTrue,
      );
    });

    test('falls back to client sort when external scores lag game rows', () {
      expect(
        shouldPreserveExternalStandingOrder(
          useExternalOrder: true,
          hasUniversalRank: false,
          hasStaleExternalScores: true,
        ),
        isFalse,
      );
    });

    test('falls back to client sort when no source order signal present', () {
      expect(
        shouldPreserveExternalStandingOrder(
          useExternalOrder: false,
          hasUniversalRank: false,
          hasStaleExternalScores: false,
        ),
        isFalse,
      );
    });
  });
}
