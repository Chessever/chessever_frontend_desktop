import 'dart:io';

import 'package:chessever/desktop/widgets/library/twic_filter_dialog.dart';
import 'package:chessever/screens/library/widgets/library_gamebase_filter_dialog.dart';
import 'package:chessever/widgets/game_filter/game_filter_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('showTwicFilterDialog source includes ECO and Online filters', () {
    final source =
        File(
          'lib/desktop/widgets/library/twic_filter_dialog.dart',
        ).readAsStringSync();

    expect(source, contains('showTwicFilterDialog'));
    expect(source, contains('EcoFilterDropdown'));
    expect(source, contains('GameEcoFilter'));
    expect(source, contains('GameOnlineFilter'));
    expect(source, contains('widget.initial.eco'));
    expect(source, contains('widget.initial.isOnline'));
    expect(source, contains('eco: _eco'));
    expect(source, contains('isOnline: _isOnline'));
    expect(source, contains('_eco = GameEcoFilter.all'));
    expect(source, contains('_isOnline = GameOnlineFilter.all'));
  });

  test('buildTwicFilterDraft keeps applied eco and isOnline', () {
    final applied = buildTwicFilterDraft(
      GamebaseFilter(),
      eco: GameEcoFilter.forCode('C45'),
      isOnline: GameOnlineFilter.otb,
    );

    expect(applied.eco, GameEcoFilter.forCode('C45'));
    expect(applied.eco.code, 'C45');
    expect(applied.isOnline, GameOnlineFilter.otb);
    expect(applied.hasActiveFilters, isTrue);
  });

  test('buildTwicFilterDraft no longer drops eco from the initial filter', () {
    final initial = GamebaseFilter(
      eco: GameEcoFilter.forCode('B90'),
      isOnline: GameOnlineFilter.online,
    );
    final applied = buildTwicFilterDraft(
      initial,
      result: GameResultFilter.whiteWins,
    );

    expect(applied.eco.code, 'B90');
    expect(applied.isOnline, GameOnlineFilter.online);
    expect(applied.result, GameResultFilter.whiteWins);
  });

  test('Reset stays enabled for an already-applied ECO filter', () {
    final defaults = GamebaseFilter();
    final applied = GamebaseFilter(eco: GameEcoFilter.forCode('A49'));
    final reopened = buildTwicFilterDraft(applied);

    expect(reopened, applied);
    expect(twicFilterCanReset(defaults), isFalse);
    expect(twicFilterCanReset(applied), isTrue);
    expect(twicFilterCanReset(reopened), isTrue);
  });
}
