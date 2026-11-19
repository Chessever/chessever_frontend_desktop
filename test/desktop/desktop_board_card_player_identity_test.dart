import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';

const _card = GameCardData(
  id: 'identity-fixture',
  title: 'Identity fixture',
  whiteName: 'Caruana, Fabiano',
  blackName: 'Firouzja, Alireza',
  whiteFederation: 'USA',
  blackFederation: 'FRA',
  whiteTitle: 'GM',
  blackTitle: 'GM',
  whiteRating: 2783,
  blackRating: 2757,
  fen: null,
  status: GameStatus.draw,
  hasStarted: true,
);

GameCardData _data({
  String? whiteName,
  String? blackName,
  int? whiteRating,
  int? blackRating,
  bool live = false,
  bool? anchor,
}) => GameCardData(
  id: _card.id,
  title: _card.title,
  whiteName: whiteName ?? _card.whiteName,
  blackName: blackName ?? _card.blackName,
  whiteFederation: _card.whiteFederation,
  blackFederation: _card.blackFederation,
  whiteTitle: _card.whiteTitle,
  blackTitle: _card.blackTitle,
  whiteRating: whiteRating ?? _card.whiteRating,
  blackRating: blackRating ?? _card.blackRating,
  fen: _card.fen,
  status: live ? GameStatus.ongoing : _card.status,
  hasStarted: true,
  whiteClockSeconds: live ? 300 : null,
  blackClockSeconds: live ? 270 : null,
  activePlayer: live ? Side.white : null,
  matchPlayAnchorIsWhite: anchor,
);

Future<void> _pump(
  WidgetTester tester, {
  double width = 400,
  GameCardData data = _card,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardSettingsProviderNew.overrideWith(_Board.new),
        engineSettingsProviderNew.overrideWith(_Engine.new),
      ],
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: width + 85,
              child: DesktopGameCard(
                data: data,
                layout: DesktopCardLayout.grid,
                onTap: () {},
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

void main() {
  testWidgets(
    'board card shows full names with the recorded rating beside each name',
    (tester) async {
      await _pump(tester);
      for (final (name, rating) in [
        ('Caruana, Fabiano', '(2783)'),
        ('Firouzja, Alireza', '(2757)'),
      ]) {
        expect(find.text(name), findsOneWidget);
        expect(find.text(rating), findsOneWidget);
        final nameBox = tester.getRect(find.text(name));
        final ratingBox = tester.getRect(find.text(rating));
        expect(ratingBox.left - nameBox.right, closeTo(4, 0.5));
        expect(ratingBox.center.dy, closeTo(nameBox.center.dy, 1));
        expect(tester.widget<Text>(find.text(name)).style?.color, kWhiteColor);
        expect(
          tester.widget<Text>(find.text(rating)).style?.color,
          kWhiteColor70,
        );
        final paragraph = tester.renderObject<RenderParagraph>(find.text(name));
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      expect(find.text('Caruana, F.'), findsNothing);
      expect(find.text('Firouzja, A.'), findsNothing);
      expect(
        tester
            .widgetList<Text>(find.text('GM'))
            .every((label) => label.style?.color == kPrimaryColor),
        isTrue,
      );
      final results = tester.getRect(find.text('½').first);
      expect(
        results.left,
        greaterThan(tester.getRect(find.text('(2783)')).right + 10),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
  testWidgets(
    'narrow board cards ellipsize only long names and keep ratings visible',
    (tester) async {
      const white = 'Vachier-Lagrave, Maxime Alexandre';
      const black = 'Nepomniachtchi, Ian Alexandrovich';
      await _pump(
        tester,
        width: 220,
        data: _data(whiteName: white, blackName: black),
      );
      final cardBox = tester.getRect(find.byType(DesktopGameCard));
      for (final (name, rating) in [(white, '(2783)'), (black, '(2757)')]) {
        expect(find.text(name), findsOneWidget);
        expect(
          tester.widget<Text>(find.text(name)).overflow,
          TextOverflow.ellipsis,
        );
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(name))
              .didExceedMaxLines,
          isTrue,
        );
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(rating))
              .didExceedMaxLines,
          isFalse,
        );
        final nameBox = tester.getRect(find.text(name));
        final ratingBox = tester.getRect(find.text(rating));
        expect(ratingBox.left - nameBox.right, closeTo(4, 0.5));
        expect(cardBox.contains(ratingBox.topLeft), isTrue);
        expect(cardBox.contains(ratingBox.bottomRight), isTrue);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'live board rows reserve the far-right clocks after inline ratings',
    (tester) async {
      await _pump(tester, data: _data(live: true));
      final clocks = find.textContaining(RegExp(r'^\d{1,2}:\d{2}(?::\d{2})?$'));
      expect(clocks, findsNWidgets(2));
      expect(find.text('½'), findsNothing);
      for (final rating in ['(2783)', '(2757)']) {
        final ratingBox = tester.getRect(find.text(rating));
        final clockBox = [
          for (final element in clocks.evaluate())
            tester.getRect(find.byWidget(element.widget)),
        ].singleWhere(
          (rect) => (rect.center.dy - ratingBox.center.dy).abs() < 2,
        );
        expect(clockBox.left, greaterThan(ratingBox.right + 6));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'match-play anchoring keeps full names paired with their own ratings',
    (tester) async {
      for (final anchor in [true, false]) {
        await _pump(tester, data: _data(anchor: anchor));
        final topName = anchor ? _card.whiteName : _card.blackName;
        final bottomName = anchor ? _card.blackName : _card.whiteName;
        expect(
          tester.getRect(find.text(topName)).top,
          lessThan(tester.getRect(find.text(bottomName)).top),
        );
        for (final (name, rating) in [
          (_card.whiteName, '(2783)'),
          (_card.blackName, '(2757)'),
        ]) {
          expect(
            tester.getRect(find.text(rating)).left -
                tester.getRect(find.text(name)).right,
            closeTo(4, 0.5),
          );
          expect(
            tester.getRect(find.text(rating)).center.dy,
            closeTo(tester.getRect(find.text(name)).center.dy, 1),
          );
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'board identities preserve unknown-player and missing-rating fallbacks',
    (tester) async {
      await _pump(
        tester,
        data: _data(
          whiteName: '?',
          blackName: 'Unknown',
          whiteRating: 0,
          blackRating: 0,
        ),
      );
      expect(find.text('Unknown'), findsNWidgets(2));
      expect(find.text('?'), findsNothing);
      expect(find.text('(0)'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
  );
}

class _Board extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async =>
      const BoardSettingsNew(showEvaluationBar: false);
}

class _Engine extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async =>
      const EngineSettings(showEngineGauge: false);
}
