import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/repository/library/cloud_pgn_date.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';

void main() {
  group('isCloudSafePgnDate', () {
    test('accepts real calendar dates', () {
      expect(isCloudSafePgnDate('2021.12.17'), isTrue);
      expect(isCloudSafePgnDate('1972.07.01'), isTrue);
      expect(isCloudSafePgnDate('2023.01.31'), isTrue);
      expect(isCloudSafePgnDate('2023.04.30'), isTrue);
      expect(isCloudSafePgnDate('  2024.12.31  '), isTrue);
    });

    test('rejects the value that killed a whole database save', () {
      // June has 30 days. The cloud row's date column is derived from this tag
      // server-side, and `2005.06.31` aborted the batch insert — and with it a
      // 2 695-game save — with
      // `Database error: date/time field value out of range: "2005.06.31"`.
      expect(isCloudSafePgnDate('2005.06.31'), isFalse);
      expect(cloudSafePgnDate('2005.06.31'), kCloudUnknownPgnDate);
    });

    test('rejects every sentinel and placeholder form', () {
      for (final value in <String>[
        '????.??.??',
        '2003.??.??',
        '2004.07.??',
        '0000.00.00',
        '0000.01.01',
        '',
        '   ',
        '?',
        'unknown',
        '2005-06-31',
        '2005.6.31',
        '2005.06.31.1',
      ]) {
        expect(
          isCloudSafePgnDate(value),
          isFalse,
          reason: '"$value" must never reach a date parser',
        );
      }
      expect(isCloudSafePgnDate(null), isFalse);
    });

    test('rejects impossible days and months', () {
      expect(isCloudSafePgnDate('2005.06.00'), isFalse);
      expect(isCloudSafePgnDate('2005.06.32'), isFalse);
      expect(isCloudSafePgnDate('2005.00.10'), isFalse);
      expect(isCloudSafePgnDate('2005.13.10'), isFalse);
      expect(isCloudSafePgnDate('2005.99.99'), isFalse);
      expect(isCloudSafePgnDate('2023.11.31'), isFalse);
      expect(isCloudSafePgnDate('2023.02.30'), isFalse);
    });

    test('honours the leap-year rule', () {
      expect(isCloudSafePgnDate('2004.02.29'), isTrue);
      expect(isCloudSafePgnDate('2000.02.29'), isTrue);
      expect(isCloudSafePgnDate('2005.02.29'), isFalse);
      expect(isCloudSafePgnDate('1900.02.29'), isFalse);
      expect(isCloudSafePgnDate('2024.02.29'), isTrue);
    });

    test('keeps a usable date and normalizes everything else', () {
      expect(cloudSafePgnDate('2024.02.29'), '2024.02.29');
      expect(cloudSafePgnDate(' 2024.02.29 '), '2024.02.29');
      expect(cloudSafePgnDate('2003.??.??'), kCloudUnknownPgnDate);
      expect(cloudSafePgnDate(null), kCloudUnknownPgnDate);
    });
  });

  group('cloudSafeChessGameJson', () {
    test('replaces an impossible date and leaves the game itself alone', () {
      final game = _gameWithDate('2005.06.31');

      final json = cloudSafeChessGameJson(game);
      final metadata = (json['md'] as Map).cast<String, dynamic>();

      expect(metadata['Date'], kCloudUnknownPgnDate);
      // The user's own record keeps its imported value: only the cloud payload
      // is normalized.
      expect(game.metadata['Date'], '2005.06.31');
      expect((game.toJson()['md'] as Map)['Date'], '2005.06.31');
      // Nothing else about the entry changes.
      expect(metadata['White'], 'Carlsen, Magnus');
      expect(metadata['Black'], 'Caruana, Fabiano');
      expect(metadata['Event'], 'Cloud Save Regression');
      expect(json['m'], isNotEmpty);
    });

    test('leaves a real date and every other header exactly as they are', () {
      final game = _gameWithDate('2021.12.17');

      final json = cloudSafeChessGameJson(game);
      final metadata = (json['md'] as Map).cast<String, dynamic>();

      expect(metadata['Date'], '2021.12.17');
      expect(metadata['White'], 'Carlsen, Magnus');
    });

    test('a game without a Date tag is not given one', () {
      final game = ChessGame.fromPgn(
        'no-date',
        '[Event "Cloud Save Regression"]\n'
            '[Site "?"]\n'
            '[Round "1"]\n'
            '[White "White"]\n'
            '[Black "Black"]\n'
            '[Result "1-0"]\n'
            '\n'
            '1. e4 e5 1-0\n',
      );

      final metadata =
          (cloudSafeChessGameJson(game)['md'] as Map).cast<String, dynamic>();
      expect(metadata.containsKey('Date'), isFalse);
    });
  });

  group('saved-analysis cloud payload', () {
    test('an impossible date no longer breaks the insert payload', () {
      // The regression: building the payload used to hand the server
      // `2005.06.31` verbatim, and the whole batch insert failed.
      final analysis = _analysis(_gameWithDate('2005.06.31'));

      final payload = analysis.toSupabaseInsert();
      final chessGame = (payload['chess_game'] as Map).cast<String, dynamic>();
      final metadata = (chessGame['md'] as Map).cast<String, dynamic>();

      expect(metadata['Date'], kCloudUnknownPgnDate);
      expect(chessGame['m'], isNotEmpty);
      expect(payload['title'], 'Carlsen, Magnus vs Caruana, Fabiano');
      expect(payload['user_id'], 'user-1');
    });

    test('every row of a mixed batch carries a server-parseable date', () {
      // One page of a real database: valid dates, placeholders and the
      // impossible one — every payload must be safe, none may throw.
      const rawDates = <String>[
        '2021.12.17',
        '2005.06.31',
        '2003.??.??',
        '????.??.??',
        '0000.00.00',
        '2004.02.29',
        '2005.02.29',
        '2023.04.??',
      ];

      for (final raw in rawDates) {
        final payload = _analysis(_gameWithDate(raw)).toSupabaseInsert();
        final metadata =
            ((payload['chess_game'] as Map)['md'] as Map)
                .cast<String, dynamic>();
        final sent = metadata['Date'] as String?;
        expect(
          sent != null && (sent == kCloudUnknownPgnDate || isCloudSafePgnDate(sent)),
          isTrue,
          reason: 'payload for "$raw" carried "$sent"',
        );
      }
    });

    test('the update payload follows the same rule', () {
      final analysis = _analysis(_gameWithDate('2005.06.31'));

      final payload = analysis.toSupabase();
      final metadata =
          ((payload['chess_game'] as Map)['md'] as Map)
              .cast<String, dynamic>();

      expect(metadata['Date'], kCloudUnknownPgnDate);
      expect(payload['id'], 'analysis-1');
    });
  });
}

ChessGame _gameWithDate(String date) => ChessGame.fromPgn(
  'game-$date',
  '[Event "Cloud Save Regression"]\n'
      '[Site "?"]\n'
      '[Date "$date"]\n'
      '[Round "1"]\n'
      '[White "Carlsen, Magnus"]\n'
      '[Black "Caruana, Fabiano"]\n'
      '[Result "1-0"]\n'
      '\n'
      '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0\n',
);

SavedAnalysis _analysis(ChessGame game) => SavedAnalysis(
  id: 'analysis-1',
  userId: 'user-1',
  folderId: 'folder-1',
  title: 'Carlsen, Magnus vs Caruana, Fabiano',
  chessGame: game,
  analysisState: const <String, dynamic>{},
  variationComments: const <String, String>{},
  lastViewedPosition: -1,
  tags: const <String>[],
  isFavorite: false,
  createdAt: DateTime(2026, 9, 24),
  updatedAt: DateTime(2026, 9, 24),
);
