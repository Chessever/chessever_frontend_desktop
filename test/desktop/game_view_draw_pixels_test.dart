import 'dart:io' as io;

import 'dart:ui' as ui;

import 'package:chessground/chessground.dart' as cg;
import 'package:chessground/src/widgets/board_painter.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';

const _fen = '6k1/3R1ppp/1p2p3/4P3/8/1NP2q2/P4P1P/5R1K w - - 0 1';
const _size = 400.0;
const _mint = cg.SquareHighlight(
  details: cg.HighlightDetails(solidColor: Color(0xCCADE1CD)),
);
const _draw = IMapConst<Square, cg.SquareHighlight>({
  Square.g8: _mint,
  Square.h1: _mint,
});

void main() {
  for (final orientation in Side.values) {
    testWidgets(
      'interactive draw preserves opaque king pixels: ${orientation.name}',
      (tester) async {
        await tester.runAsync(() async {
          for (final family in ['Geist', 'Roboto']) {
            await (FontLoader(family)..addFont(
              rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'),
            )).load();
          }
          await cg.ChessgroundImages.instance.loadAll(
            const BoardSettingsNew().pieceAssets,
          );
        });
        final plain = await _render(
          tester,
          orientation,
          draw: false,
          under: false,
        );
        final before = await _render(
          tester,
          orientation,
          draw: true,
          under: false,
        );
        expect(_highlights(tester).squareHighlights, isEmpty);
        final after = await _render(
          tester,
          orientation,
          draw: true,
          under: true,
        );
        expect(
          _highlights(tester).squareHighlights.keys,
          unorderedEquals([Square.g8, Square.h1]),
        );
        for (final details in _highlights(tester).squareHighlights.values) {
          expect(
            details.solidColor,
            const Color(0xCCADE1CD).withValues(alpha: 0.6),
          );
        }
        for (final square in [Square.g8, Square.h1]) {
          final file =
              orientation == Side.white ? square.file : 7 - square.file;
          final rank =
              orientation == Side.white ? 7 - square.rank : square.rank;
          var cores = 0;
          var washed = 0;
          for (var y = rank * 50 + 8; y < rank * 50 + 42; y++) {
            for (var x = file * 50 + 8; x < file * 50 + 42; x++) {
              final i = (y * 400 + x) * 4;
              final rgb = plain.rgba.sublist(i, i + 3);
              if (rgb.every((v) => v == 0) || rgb.every((v) => v == 255)) {
                cores++;
                expect(
                  after.rgba.sublist(i, i + 4),
                  plain.rgba.sublist(i, i + 4),
                  reason: 'Opaque king artwork must retain its actual colors.',
                );
                if (!_samePixel(before.rgba, plain.rgba, i)) washed++;
              }
            }
          }
          expect(cores, greaterThan(30));
          expect(
            washed,
            greaterThan(30),
            reason: 'Old overlay reproduces the wash.',
          );
        }
        // Only result squares may change; last-move highlights and other pieces
        // retain the exact original overlay pixels.
        for (var y = 0; y < 400; y++) {
          for (var x = 0; x < 400; x++) {
            final file = orientation == Side.white ? x ~/ 50 : 7 - x ~/ 50;
            final rank = orientation == Side.white ? 7 - y ~/ 50 : y ~/ 50;
            if ((file == Square.g8.file && rank == Square.g8.rank) ||
                (file == Square.h1.file && rank == Square.h1.rank)) {
              continue;
            }
            final i = (y * 400 + x) * 4;
            expect(_samePixel(after.rgba, before.rgba, i), isTrue);
          }
        }
        final output = io.Platform.environment['CHESSEVER_TEST_EVIDENCE_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final dir = io.Directory(output)..createSync(recursive: true);
            io.File(
              '${dir.path}/before-${orientation.name}.png',
            ).writeAsBytesSync(before.png);
            io.File(
              '${dir.path}/after-${orientation.name}.png',
            ).writeAsBytesSync(after.png);
          });
        }
      },
    );
  }

  testWidgets('legacy highlight callers keep their overlay and alpha', (
    tester,
  ) async {
    await _render(tester, Side.white, draw: true, under: false);
    expect(_highlights(tester).squareHighlights, isEmpty);
    expect(
      _highlights(tester).squareHighlights,
      same(const <Square, cg.HighlightDetails>{}),
      reason: 'Unchanged boards must retain the shared empty painter map.',
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color ==
                const Color(0xCCADE1CD).withValues(alpha: 0.6),
      ),
      findsNWidgets(2),
    );
  });
  testWidgets('draw tint updates in place and clears on replay', (
    tester,
  ) async {
    final key = GlobalKey();
    await _render(
      tester,
      Side.white,
      draw: false,
      under: false,
      boundaryKey: key,
    );
    final controller =
        tester.widget<cg.Chessboard>(find.byType(cg.Chessboard)).controller;
    await _render(
      tester,
      Side.white,
      draw: true,
      under: true,
      boundaryKey: key,
    );
    expect(
      tester.widget<cg.Chessboard>(find.byType(cg.Chessboard)).controller,
      same(controller),
    );
    expect(_highlights(tester).squareHighlights, hasLength(2));
    await _render(
      tester,
      Side.white,
      draw: false,
      under: false,
      boundaryKey: key,
    );
    expect(
      tester.widget<cg.Chessboard>(find.byType(cg.Chessboard)).controller,
      same(controller),
    );
    expect(_highlights(tester).squareHighlights, isEmpty);
  });
}

bool _samePixel(Uint8List a, Uint8List b, int i) =>
    a[i] == b[i] &&
    a[i + 1] == b[i + 1] &&
    a[i + 2] == b[i + 2] &&
    a[i + 3] == b[i + 3];

HighlightsPainter _highlights(WidgetTester tester) =>
    tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<HighlightsPainter>()
        .single;

Future<({Uint8List rgba, Uint8List png})> _render(
  WidgetTester tester,
  Side orientation, {
  required bool draw,
  required bool under,
  GlobalKey? boundaryKey,
}) async {
  final key = boundaryKey ?? GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [boardSettingsProviderNew.overrideWith(_Settings.new)],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Geist'),
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: SizedBox.square(
              dimension: _size,
              child: DesktopChessBoard(
                size: _size,
                fen: _fen,
                orientation: orientation,
                playerSide: cg.PlayerSide.none,
                sideToMove: Side.white,
                validMoves: const {},
                onMove: (_, {viaDragAndDrop}) {},
                lastMove: const NormalMove(from: Square.g4, to: Square.f3),
                squareHighlights: draw ? _draw : const IMapConst({}),
                squareHighlightsUnderPieces: under,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final rgba =
        (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
    final png =
        (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
    image.dispose();
    return (rgba: rgba, png: png);
  });
  return result!;
}

class _Settings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const value = BoardSettingsNew();
    state = const AsyncValue.data(value);
    return value;
  }
}
