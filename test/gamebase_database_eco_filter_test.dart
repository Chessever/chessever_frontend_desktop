import 'dart:convert';

import 'package:chessever/screens/library/providers/gamebase_database_games_provider.dart';
import 'package:chessever/screens/library/widgets/library_gamebase_filter_dialog.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildLibraryExactWhere eco', () {
    test('eco-only C45 uses startsWith without a trailing %', () {
      final filter = GamebaseFilter(eco: GameEcoFilter.forCode('C45'));

      expect(shouldUseExactLibraryGameQuery('', filter), isTrue);

      final where = buildLibraryExactWhere(filter);
      expect(where, isNotNull);
      expect(where, {'field': 'eco', 'op': 'startsWith', 'value': 'C45'});
      final encoded = jsonEncode(where);
      expect(encoded, isNot(contains('ilike')));
      expect(encoded, isNot(contains('C45%')));
    });

    test('eco B90 + year uses startsWith and never ilike B90%', () {
      final filter = GamebaseFilter(
        eco: GameEcoFilter.forCode('B90'),
        minYear: 2020,
        maxYear: 2024,
      );

      expect(shouldUseExactLibraryGameQuery('', filter), isTrue);

      final where = buildLibraryExactWhere(filter);
      expect(where, isNotNull);
      final encoded = jsonEncode(where);
      expect(encoded, isNot(contains('ilike')));
      expect(encoded, isNot(contains('B90%')));

      final clauses =
          (where!['and'] as List)
              .map((clause) => Map<String, dynamic>.from(clause as Map))
              .toList();
      final ecoClause = clauses.firstWhere(
        (clause) => clause['field'] == 'eco',
      );
      expect(ecoClause['op'], 'startsWith');
      expect(ecoClause['value'], 'B90');
      expect(
        clauses.any(
          (clause) => clause['field'] == 'date' && clause['op'] == 'between',
        ),
        isTrue,
      );
    });

    test('eco ? uses exact eq', () {
      final filter = GamebaseFilter(eco: GameEcoFilter.forCode('?'));

      expect(shouldUseExactLibraryGameQuery('', filter), isTrue);
      expect(buildLibraryExactWhere(filter), {
        'field': 'eco',
        'op': 'eq',
        'value': '?',
      });
    });
  });

  group('composeGamebaseSearchQuery', () {
    test('eco + free-text GET q prepends eco:code', () {
      final filter = GamebaseFilter(eco: GameEcoFilter.forCode('B90'));

      expect(shouldUseExactLibraryGameQuery('Carlsen', filter), isFalse);
      expect(
        composeGamebaseSearchQuery(query: 'Carlsen', filter: filter),
        'eco:B90 Carlsen',
      );
      expect(
        composeGamebaseSearchQuery(query: 'Carlsen', filter: filter),
        isNot(contains('B90%')),
      );
    });

    test('empty query becomes * and still prepends eco', () {
      expect(
        composeGamebaseSearchQuery(
          query: '',
          filter: GamebaseFilter(eco: GameEcoFilter.forCode('C45')),
        ),
        'eco:C45 *',
      );
    });
  });
}
