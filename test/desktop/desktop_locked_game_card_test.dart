import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_locked_content.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

const _reason = 'Locked in this test.';

const _finished = GameCardData(
  id: 'mini-1',
  title: 'Nepomniachtchi vs Vachier-Lagrave',
  whiteName: 'Nepomniachtchi, Ian',
  blackName: 'Vachier-Lagrave, Maxime',
  whiteFederation: 'FID',
  blackFederation: 'FRA',
  whiteTitle: 'GM',
  blackTitle: 'GM',
  whiteRating: 2650,
  blackRating: 2580,
  fen: null,
  status: GameStatus.whiteWins,
  hasStarted: true,
);

const _live = GameCardData(
  id: 'live-1',
  title: 'Carlsen vs So',
  whiteName: 'Carlsen, Magnus',
  blackName: 'So, Wesley',
  whiteFederation: 'NOR',
  blackFederation: 'USA',
  whiteTitle: 'GM',
  blackTitle: 'GM',
  whiteRating: 2830,
  blackRating: 2760,
  fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1',
  lastMove: 'e2e4',
  status: GameStatus.ongoing,
  hasStarted: true,
);

Future<void> _pump(
  WidgetTester tester, {
  required GameCardData data,
  required DesktopCardLayout layout,
  String? lockedReason = _reason,
  bool selected = false,
}) async {
  final grid = layout == DesktopCardLayout.grid;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardSettingsProviderNew.overrideWith(_TestBoardSettingsNotifier.new),
        engineSettingsProviderNew.overrideWith(_TestEngineSettingsNotifier.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: grid ? 250 : 320,
              height: grid ? 263 : 82,
              child: DesktopGameCard(
                data: data,
                layout: layout,
                onTap: () {},
                selected: selected,
                lockedReason: lockedReason,
                allowStockfishFallback: false,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Every text box in the card other than the lock's own icon glyph.
List<Rect> _textRects(WidgetTester tester) {
  final lockIcon = find.descendant(
    of: find.byType(DesktopLockGlyph),
    matching: find.byType(RichText),
  );
  final lockElements = lockIcon.evaluate().toSet();
  return [
    for (final element
        in find
            .descendant(
              of: find.byType(DesktopGameCard),
              matching: find.byType(RichText),
            )
            .evaluate())
      if (!lockElements.contains(element))
        tester.getRect(find.byWidget(element.widget)),
  ];
}

void _expectClearOf(Rect lock, Iterable<Rect> others) {
  for (final rect in others) {
    expect(
      lock.overlaps(rect),
      isFalse,
      reason: 'lock $lock touches content at $rect',
    );
  }
}

void main() {
  testWidgets('an unlocked card draws no lock and no greyscale', (
    tester,
  ) async {
    await _pump(
      tester,
      data: _finished,
      layout: DesktopCardLayout.compact,
      lockedReason: null,
    );

    expect(find.byType(DesktopLockGlyph), findsNothing);
    expect(find.byType(ColorFiltered), findsNothing);
  });

  testWidgets('a locked compact card keeps its lock clear of every text', (
    tester,
  ) async {
    await _pump(tester, data: _finished, layout: DesktopCardLayout.compact);

    final lock = tester.getRect(find.byType(DesktopLockGlyph));
    expect(tester.getRect(find.byType(DesktopGameCard)).contains(lock.center),
        isTrue);
    _expectClearOf(lock, _textRects(tester));
  });

  testWidgets('a locked live compact card keeps its lock clear of the strips', (
    tester,
  ) async {
    await _pump(tester, data: _live, layout: DesktopCardLayout.compact);

    final lock = tester.getRect(find.byType(DesktopLockGlyph));
    _expectClearOf(lock, _textRects(tester));
  });

  testWidgets('a locked grid card puts its lock beside the board', (
    tester,
  ) async {
    await _pump(tester, data: _finished, layout: DesktopCardLayout.grid);

    final lock = tester.getRect(find.byType(DesktopLockGlyph));
    final board = tester.getRect(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_BoardPreview'),
    );
    final card = tester.getRect(find.byType(DesktopGameCard));

    _expectClearOf(lock, [board, ..._textRects(tester)]);
    expect(lock.left, greaterThan(board.right));
    expect(lock.right, lessThan(card.right));
    // Centred on the board's height and in the gutter beside it.
    expect(lock.center.dy, moreOrLessEquals(board.center.dy, epsilon: 0.5));
    expect(
      lock.center.dx,
      moreOrLessEquals((board.right + card.right - 1) / 2, epsilon: 1),
    );
  });

  for (final layout in [DesktopCardLayout.compact, DesktopCardLayout.grid]) {
    testWidgets('a selected locked ${layout.name} card keeps the brand border', (
      tester,
    ) async {
      await _pump(tester, data: _finished, layout: layout, selected: true);

      final selectedBorder = find.byWidgetPredicate((widget) {
        if (widget is! Container) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.border is Border &&
            (decoration.border! as Border).top.color ==
                kPrimaryColor.withValues(alpha: 0.96);
      });
      expect(selectedBorder, findsOneWidget);
      expect(
        find.ancestor(of: selectedBorder, matching: find.byType(ColorFiltered)),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byType(DesktopLockGlyph),
          matching: find.byType(ColorFiltered),
        ),
        findsNothing,
      );
      expect(find.byType(DesktopDesaturated), findsWidgets);
    });
  }
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew();
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _TestEngineSettingsNotifier extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings();
    state = const AsyncValue.data(settings);
    return settings;
  }
}
