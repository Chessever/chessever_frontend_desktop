import 'package:chessever/desktop/utils/event_game_card_keyboard_navigation.dart';
import 'package:chessever/desktop/widgets/desktop_for_you_strip_layout.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  test('a column is added only when its cards and gaps fit', () {
    for (final layout in DesktopCardLayout.values) {
      final metrics = DesktopGameCardsFlow.metricsFor(layout);
      final threshold = metrics.targetWidth * 3 + metrics.spacing * 2;
      expect(
        DesktopGameCardsFlow.columnCountForWidth(layout, threshold - 1),
        2,
      );
      expect(DesktopGameCardsFlow.columnCountForWidth(layout, threshold), 3);
      expect(DesktopGameCardsFlow.columnCountForWidth(layout, 320), 1);
    }
    expect(
      DesktopGameCardsFlow.columnCountForWidth(DesktopCardLayout.list, 3840),
      10,
    );
    expect(
      DesktopGameCardsFlow.columnCountForWidth(DesktopCardLayout.compact, 3840),
      12,
    );
  });

  for (final layout in DesktopCardLayout.values) {
    testWidgets('$layout keeps embedded and scrollable grid strides equal', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(2000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final embedded in [false, true]) {
        for (final width in [320.0, 900.0, 1200.0, 1920.0]) {
          int? resolvedColumns;
          final flow = DesktopGameCardsFlow(
            layout: layout,
            itemCount: 12,
            embedded: embedded,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            onColumnsResolved: (value) => resolvedColumns = value,
            itemBuilder:
                (context, index) => ColoredBox(
                  key: ValueKey('cell-$index'),
                  color: Colors.black,
                ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 1000,
                  child: embedded ? SingleChildScrollView(child: flow) : flow,
                ),
              ),
            ),
          );
          final expected = DesktopGameCardsFlow.columnCountForWidth(
            layout,
            width - 40,
          );
          expect(resolvedColumns, expected);
          final first = tester.getRect(find.byKey(const ValueKey('cell-0')));
          final nextRow = tester.getRect(
            find.byKey(ValueKey('cell-$expected')),
          );
          expect(nextRow.left, closeTo(first.left, 0.001));
          expect(nextRow.top, greaterThan(first.bottom));
          final lastInRow = tester.getRect(
            find.byKey(ValueKey('cell-${expected - 1}')),
          );
          expect(lastInRow.right, closeTo(width - 20, 0.001));
          expect(tester.takeException(), isNull);
        }
      }
    });
  }

  testWidgets(
    'For You fits real Compact and List cards within the event height',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(2000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final layout in [
        DesktopCardLayout.compact,
        DesktopCardLayout.list,
      ]) {
        for (final width in [320.0, 900.0, 1218.0, 1920.0]) {
          DesktopForYouStripLayout? resolved;
          var opened = -1;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                boardSettingsProviderNew.overrideWith(_BoardSettings.new),
                engineSettingsProviderNew.overrideWith(_EngineSettings.new),
              ],
              child: MaterialApp(
                home: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: DesktopForYouStripLayout.heightFor(layout),
                    child: DesktopForYouGamesPreview(
                      layout: layout,
                      itemCount: 12,
                      onLayoutResolved: (value) => resolved = value,
                      itemBuilder:
                          (context, index) => DesktopGameCard(
                            key: ValueKey('game-$index'),
                            data: _data,
                            layout: layout,
                            onTap: () => opened = index,
                            allowStockfishFallback: false,
                          ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final preview = tester.getRect(
            find.byType(DesktopForYouGamesPreview),
          );
          expect(
            find.byType(DesktopGameCard),
            findsNWidgets(resolved!.visibleCount),
          );
          for (var i = 0; i < resolved!.visibleCount; i++) {
            final card = tester.getRect(find.byKey(ValueKey('game-$i')));
            expect(card.left, greaterThanOrEqualTo(preview.left));
            expect(card.right, lessThanOrEqualTo(preview.right + 0.001));
            expect(card.bottom, lessThanOrEqualTo(preview.bottom + 0.001));
          }
          if (resolved!.visibleCount == resolved!.columns * resolved!.rows) {
            final last = tester.getRect(
              find.byKey(ValueKey('game-${resolved!.visibleCount - 1}')),
            );
            expect(last.bottom, closeTo(preview.bottom, 0.001));
          }
          await tester.tap(
            find.byKey(ValueKey('game-${resolved!.visibleCount - 1}')),
          );
          await tester.pump(const Duration(milliseconds: 300));
          expect(opened, resolved!.visibleCount - 1);
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  test('Compact arrows reach each row with the rendered column count', () {
    final layout = DesktopForYouStripLayout.compute(
      available: 1218,
      gameCount: 12,
      layout: DesktopCardLayout.compact,
    );
    expect(layout.visibleCount, 12);
    expect(layout.columns, 4);
    expect(layout.rows, 3);
    EventGameCardFocus? focus = const EventGameCardFocus(
      eventIndex: 0,
      column: EventGameCardFocusColumn.game,
    );
    for (final expectedIndex in [4, 8]) {
      focus = moveEventGameCardFocus(
        current: focus,
        key: LogicalKeyboardKey.arrowDown,
        eventCount: 1,
        gameCountForEvent: (_) => layout.visibleCount,
        gameColumnCountForEvent: (_) => layout.columns,
        hierarchicalGroups: true,
      );
      expect(focus!.gameIndex, expectedIndex);
    }
  });
}

const _data = GameCardData(
  id: 'finished-game',
  title: 'Nepomniachtchi vs Vachier-Lagrave',
  whiteName: 'Nepomniachtchi, Ian',
  blackName: 'Vachier-Lagrave, Maxime',
  whiteFederation: '',
  blackFederation: '',
  whiteTitle: 'GM',
  blackTitle: 'GM',
  whiteRating: 2750,
  blackRating: 2720,
  fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
  status: GameStatus.whiteWins,
  hasStarted: true,
);

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async => const BoardSettingsNew();
}

class _EngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async => const EngineSettings();
}
