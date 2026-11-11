import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String get _fixturePath =>
    Platform.environment['CHESSEVER_PRIVATE_NOTATION_FIXTURE'] ??
    'test/fixtures/notation_chessbase_order.pgn';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader('Geist')
      ..addFont(rootBundle.load('assets/fonts/Geist-VariableFont_wght.ttf'));
    await loader.load();
  });
  test('ChessBase ladder rows put the preferred white move before its RAV', () {
    final game = ChessGame.fromPgn(
      'rows',
      File(_fixturePath).readAsStringSync(),
    );
    final order =
        notationNavigationRows(
          game,
        ).expand((row) => row.entries).map((entry) => entry.pointer).toList();
    int index(List<int> p) =>
        order.indexWhere((other) => other.toString() == p.toString());
    expect(index(const [6]), lessThan(index(const [5, 0, 0])));
  });
  test('ChessBase navigation follows the preferred move before its branch', () {
    final game = ChessGame.fromPgn(
      'chessbase-navigation-fixture',
      File(_fixturePath).readAsStringSync(),
    );
    final order = visibleNotationMoveOrder(
      game: game,
      activePointer: const [6],
    );
    int index(List<int> pointer) => order.indexWhere(
      (p) =>
          p.length == pointer.length &&
          List.generate(
            pointer.length,
            (i) => p[i] == pointer[i],
          ).every((v) => v),
    );
    expect(index(const [6]), greaterThanOrEqualTo(0));
    expect(index(const [5, 0, 0]), greaterThan(index(const [6])));
  });

  for (final mode in NotationLayoutMode.values) {
    for (final width in <double>[1100, 400]) {
      testWidgets(
        'ChessBase recursive order and pointer safety ${mode.name} $width',
        (tester) async {
          final game = ChessGame.fromPgn(
            'chessbase-order-fixture',
            File(_fixturePath).readAsStringSync(),
          );
          final before = jsonEncode(game.toJson());
          final saved = exportGameToPgn(game);
          final layout = ValueNotifier(mode);
          final collapse = NotationVariationCollapseController();
          final captureKey = GlobalKey();
          final jumps = <ChessMovePointer>[];
          var active = <int>[];
          late StateSetter update;
          addTearDown(layout.dispose);
          await tester.binding.setSurfaceSize(Size(width, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark().copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'Geist',
                ),
              ),
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return RepaintBoundary(
                      key: captureKey,
                      child: NotationLadderView(
                        game: game,
                        activePointer: active,
                        onJump: (pointer) {
                          jumps.add(pointer);
                          update(() => active = List<int>.of(pointer));
                        },
                        layoutModeController: layout,
                        variationCollapseController: collapse,
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // These are original model pointers: presentation must not re-parent
          // branches just to place the preferred move before its alternatives.
          final principal = _chip(const [6]);
          final alternative = _chip(const [5, 0, 0]);
          expect(
            find.descendant(
              of: principal,
              matching: find.text('Nf3', findRichText: true),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: alternative,
              matching: find.text('Bg5', findRichText: true),
            ),
            findsOneWidget,
          );
          _expectBefore(tester, principal, alternative, '4.Nf3 before 4.Bg5');
          var branches = 0;
          void verify(ChessLine line, List<int> prefix) {
            for (var i = 0; i < line.length; i++) {
              final move = line[i];
              expect(_chip([...prefix, i]), findsOneWidget);
              final vars = move.variations ?? const <ChessLine>[];
              for (var v = 0; v < vars.length; v++) {
                final branch = vars[v];
                if (branch.isEmpty) continue;
                final main = branch.first.turn == move.turn ? i : i + 1;
                if (main < line.length) {
                  _expectBefore(
                    tester,
                    _chip([...prefix, main]),
                    _chip([...prefix, i, v, 0]),
                    '${line[main].san} before ${branch.first.san} at $prefix',
                  );
                }
                if (v > 0) {
                  _expectBefore(
                    tester,
                    _chip([...prefix, i, v - 1, 0]),
                    _chip([...prefix, i, v, 0]),
                    'Preserve authored sibling order at $prefix/$i',
                  );
                }
                branches++;
                verify(branch, [...prefix, i, v]);
              }
            }
          }

          verify(game.mainline, const []);
          expect(branches, greaterThanOrEqualTo(4));
          final directory = Platform.environment['CHESSEVER_NOTATION_CAPTURE'];
          if (directory != null) {
            await tester.runAsync(() async {
              final boundary =
                  captureKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File('$directory/${mode.name}-${width.toInt()}.png')
                ..parent.createSync(recursive: true)
                ..writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          for (final pointer in <List<int>>[
            [6],
            [5, 0, 2],
            [5, 0, 1, 0, 2, 0, 0],
          ]) {
            await tester.ensureVisible(_chip(pointer));
            await tester.pumpAndSettle();
            await tester.tap(_chip(pointer));
            await tester.pumpAndSettle();
            expect(jumps.last, pointer);
            expect(active, pointer);
          }
          update(() => active = []);
          await tester.pumpAndSettle();
          collapse.collapseAll();
          await tester.pumpAndSettle();
          expect(_chip(const [5, 0, 2]), findsNothing);
          expect(_chip(const [5, 0, 0]), findsOneWidget);
          collapse.expandAll();
          await tester.pumpAndSettle();
          expect(_chip(const [5, 0, 2]), findsOneWidget);
          verify(game.mainline, const []);
          expect(tester.takeException(), isNull);
          expect(jsonEncode(game.toJson()), before);
          expect(exportGameToPgn(game), saved);
          expect(exportGameToPgn(ChessGame.fromPgn('reopened', saved)), saved);
        },
      );
    }
  }
}

Finder _chip(ChessMovePointer pointer) => find.byWidgetPredicate((widget) {
  // The real clickable chip exposes its original public pointer; checking
  // only SAN is ambiguous in this deeply nested, repeated-move fixture.
  if (widget.runtimeType.toString() != '_LadderChip') return false;
  final actual = (widget as dynamic).pointer as ChessMovePointer;
  return actual.length == pointer.length &&
      List.generate(
        pointer.length,
        (i) => actual[i] == pointer[i],
      ).every((v) => v);
});

void _expectBefore(
  WidgetTester tester,
  Finder principal,
  Finder alternative,
  String reason,
) {
  expect(principal, findsOneWidget);
  expect(alternative, findsOneWidget);
  final a = tester.getCenter(principal);
  final b = tester.getCenter(alternative);
  expect(
    a.dy < b.dy - 5 || ((a.dy - b.dy).abs() <= 5 && a.dx < b.dx),
    isTrue,
    reason: '$reason; preferred=$a, alternative=$b',
  );
}
