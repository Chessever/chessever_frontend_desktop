import 'package:chessever/desktop/widgets/variation_fork_chooser.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveVariationForkOptions', () {
    test(
      'renders mainline and variation continuations as one-line previews',
      () {
        final mainline = _line(12);
        final variation = _line(12, whitePrefix: 'Vw', blackPrefix: 'Vb');
        final game = _gameWithFork(mainline: mainline, variations: [variation]);

        final options = resolveVariationForkOptions(
          game: game,
          next: const [0],
        );

        expect(options, isNotNull);
        expect(options, hasLength(2));
        expect(options![0].label, 'Mainline');
        expect(options[0].san, 'W1');
        expect(options[0].previewLine, _expectedLine(10));
        expect(options[1].label, 'Variation');
        expect(options[1].san, 'Vw1');
        expect(
          options[1].previewLine,
          _expectedLine(10, whitePrefix: 'Vw', blackPrefix: 'Vb'),
        );
      },
    );

    test('caps continuation previews at 10 full moves', () {
      final mainline = _line(12);
      final variation = _line(12, whitePrefix: 'Vw', blackPrefix: 'Vb');
      final game = _gameWithFork(mainline: mainline, variations: [variation]);

      final options = resolveVariationForkOptions(game: game, next: const [0]);

      expect(options![0].previewLine, contains('10.W10 B10'));
      expect(options[0].previewLine, isNot(contains('11.W11')));
      expect(options[1].previewLine, contains('10.Vw10 Vb10'));
      expect(options[1].previewLine, isNot(contains('11.Vw11')));
    });

    test(
      'does not offer a black continuation before entering a white move',
      () {
        final game = ChessGame(
          gameId: 'continuation-before-white',
          startingFen: 'start',
          metadata: const {},
          mainline: [
            _move(
              10,
              'Qd2',
              ChessColor.white,
              variations: [
                [_move(10, 'a5', ChessColor.black)],
              ],
            ),
            _move(10, 'Be6', ChessColor.black),
          ],
        );

        final options = resolveVariationForkOptions(
          game: game,
          current: const [],
          next: const [0],
        );

        expect(options, isNull);
      },
    );

    test(
      'offers black continuation choices after the white move is active',
      () {
        final game = ChessGame(
          gameId: 'continuation-after-white',
          startingFen: 'start',
          metadata: const {},
          mainline: [
            _move(
              10,
              'Qd2',
              ChessColor.white,
              variations: [
                [
                  _move(10, 'a5', ChessColor.black),
                  _move(11, 'Nc4', ChessColor.white),
                ],
              ],
            ),
            _move(10, 'Be6', ChessColor.black),
            _move(11, 'Rc1', ChessColor.white),
          ],
        );

        final options = resolveVariationForkOptions(
          game: game,
          current: const [0],
          next: const [1],
        );

        expect(options, isNotNull);
        expect(options, hasLength(2));
        expect(options![0].san, 'Be6');
        expect(options[0].pointer, const [1]);
        expect(options[0].previewLine, '10... Be6 11.Rc1');
        expect(options[1].san, 'a5');
        expect(options[1].pointer, const [0, 0, 0]);
        expect(options[1].previewLine, '10... a5 11.Nc4');
      },
    );
  });

  group('variation chooser popup layout', () {
    testWidgets('opens on the notation side without dimming the board', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final options = [
        const VariationForkOption(
          pointer: [0],
          label: 'Mainline',
          san: 'Nf3',
          previewLine: '1.Nf3 Nf6',
          isMainline: true,
          variationOrder: 0,
        ),
        const VariationForkOption(
          pointer: [0, 0, 0],
          label: 'Variation',
          san: 'Nc3',
          previewLine: '1.Nc3 Nf6',
          isMainline: false,
          variationOrder: 1,
        ),
      ];

      final notationKey = GlobalKey();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(
              () => _TestBoardSettingsNotifier(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (rootContext) {
                  ResponsiveHelper.init(rootContext);
                  return Row(
                    children: [
                      Container(width: 720, color: Colors.grey),
                      Expanded(
                        key: notationKey,
                        child: Builder(
                          builder:
                              (notationContext) => TextButton(
                                onPressed:
                                    () => showVariationForkChooser(
                                      context: rootContext,
                                      options: options,
                                      targetContext: notationContext,
                                    ),
                                child: const Text('open'),
                              ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final barriers = tester.widgetList<ModalBarrier>(
        find.byType(ModalBarrier),
      );
      expect(
        barriers.any(
          (barrier) => barrier.color == null || barrier.color!.a == 0,
        ),
        true,
      );

      final notationRect = tester.getRect(find.byKey(notationKey));
      final popupRect = tester.getRect(find.text('Continue with'));
      expect(popupRect.left, greaterThanOrEqualTo(notationRect.left));
      expect(popupRect.right, lessThanOrEqualTo(notationRect.right));
    });
  });
}

class _TestBoardSettingsNotifier extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    return const BoardSettingsNew(useFigurine: false);
  }
}

ChessGame _gameWithFork({
  required ChessLine mainline,
  required List<ChessLine> variations,
}) {
  return ChessGame(
    gameId: 'variation-fork-test',
    startingFen: 'start',
    metadata: const {},
    mainline: [
      mainline.first.copyWith(variations: variations, overrideVariations: true),
      ...mainline.skip(1),
    ],
  );
}

ChessLine _line(
  int fullMoves, {
  String whitePrefix = 'W',
  String blackPrefix = 'B',
}) {
  return [
    for (var num = 1; num <= fullMoves; num++) ...[
      _move(num, '$whitePrefix$num', ChessColor.white),
      _move(num, '$blackPrefix$num', ChessColor.black),
    ],
  ];
}

ChessMove _move(
  int num,
  String san,
  ChessColor turn, {
  List<ChessLine>? variations,
}) {
  return ChessMove(
    num: num,
    fen: 'fen-$san',
    san: san,
    uci: san,
    turn: turn,
    variations: variations,
  );
}

String _expectedLine(
  int fullMoves, {
  String whitePrefix = 'W',
  String blackPrefix = 'B',
}) {
  return [
    for (var num = 1; num <= fullMoves; num++)
      '$num.$whitePrefix$num $blackPrefix$num',
  ].join(' ');
}
