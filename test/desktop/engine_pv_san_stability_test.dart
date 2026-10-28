import 'dart:async';

import 'package:chessever/desktop/services/engine/pv_san_formatter.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:flutter/gestures.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Worker {
  final requests = <Map<String, String>>[];
  final results = <Completer<List<String>>>[];
  Future<List<String>> call(Map<String, String> input) {
    requests.add(input);
    final result = Completer<List<String>>();
    results.add(result);
    return result.future;
  }

  void complete(int index) =>
      results[index].complete(formatEnginePvSanLine(requests[index]));
}

BoardPv _pv(String moves, [double score = .21]) =>
    BoardPv(evaluation: score, mate: null, moves: moves);

Future<void> _show(
  WidgetTester tester,
  _Worker worker,
  BoardPv pv, {
  String? fen,
  void Function(String)? play,
  Object? playOwner,
  bool interactive = true,
}) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      home: FTheme(
        data: FThemes.zinc.dark,
        child: Center(
          child: SizedBox(
            width: 650,
            child: enginePvLineForTesting(
              fen: fen ?? Chess.initial.fen,
              pv: pv,
              formatSan: worker.call,
              onPlayUci: play,
              playOwner: playOwner,
              interactive: interactive,
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _start(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 121));
Finder _san(String s) => find.text(s, findRichText: true);

void main() {
  testWidgets(
    'formatted PV stays visible during next worker instead of raw UCI',
    (tester) async {
      final worker = _Worker();
      await _show(tester, worker, _pv('e2e4 e7e5'));
      await _start(tester);
      worker.complete(0);
      await tester.pump();
      await tester.pump();
      expect(_san('1.e4'), findsOneWidget);
      await _show(tester, worker, _pv('d2d4 d7d5', .42));
      expect(_san('1.e4'), findsOneWidget);
      expect(find.text('d2d4 d7d5'), findsNothing);
      expect(find.text('+0.21'), findsOneWidget);
      expect(find.text('+0.42'), findsNothing);
      await _start(tester);
      worker.complete(1);
      await tester.pump();
      await tester.pump();
      expect(_san('1.d4'), findsOneWidget);
      expect(_san('1.e4'), findsNothing);
      expect(find.text('+0.42'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('initial line never exposes UCI or plays before formatting', (
    tester,
  ) async {
    final worker = _Worker();
    final played = <String>[];
    await _show(tester, worker, _pv('e2e4 e7e5'), play: played.add);
    expect(find.text('e2e4 e7e5'), findsNothing);
    expect(find.text('Formatting…'), findsOneWidget);
    await tester.tap(find.text('Formatting…'));
    expect(played, isEmpty);
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await tester.tap(_san('1.e4'));
    expect(played, ['e2e4']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending line click belongs to visible SAN not incoming UCI', (
    tester,
  ) async {
    final worker = _Worker();
    final played = <String>[];
    await _show(tester, worker, _pv('e2e4 e7e5'), play: played.add);
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await _show(tester, worker, _pv('d2d4 d7d5'), play: played.add);
    await tester.tap(_san('1.e4'));
    expect(played, ['e2e4']);
    await _start(tester);
    worker.complete(1);
    await tester.pump();
    await tester.pump();
    await tester.tap(_san('1.d4'));
    expect(played, ['e2e4', 'd2d4']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('superseded worker cannot publish an intermediate line', (
    tester,
  ) async {
    final worker = _Worker();
    await _show(tester, worker, _pv('e2e4 e7e5'));
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await _show(tester, worker, _pv('d2d4 d7d5', .42));
    await _start(tester);
    await _show(tester, worker, _pv('g1f3 g8f6', .63));
    worker.complete(1);
    await tester.pump();
    await tester.pump();
    expect(_san('1.e4'), findsOneWidget);
    expect(_san('1.d4'), findsNothing);
    expect(find.text('+0.42'), findsNothing);
    await _start(tester);
    worker.complete(2);
    await tester.pump();
    await tester.pump();
    expect(_san('1.Nf3'), findsOneWidget);
    expect(find.text('+0.63'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'position change clears old SAN and drops late old-position worker',
    (tester) async {
      final worker = _Worker();
      final played = <String>[];
      await _show(tester, worker, _pv('e2e4 e7e5'), play: played.add);
      await _start(tester);
      worker.complete(0);
      await tester.pump();
      await tester.pump();
      await _show(tester, worker, _pv('d2d4 d7d5'), play: played.add);
      await _start(tester);
      final blackFen = Chess.initial.play(Move.parse('e2e4')!).fen;
      await _show(
        tester,
        worker,
        _pv('e7e5', -.10),
        fen: blackFen,
        play: played.add,
      );
      expect(_san('1.e4'), findsNothing);
      await tester.tap(find.text('Formatting…'));
      expect(played, isEmpty);
      worker.complete(1);
      await tester.pump();
      await tester.pump();
      expect(_san('1.d4'), findsNothing);
      await _start(tester);
      worker.complete(2);
      await tester.pump();
      await tester.pump();
      expect(_san('1…e5'), findsOneWidget);
      await tester.tap(_san('1…e5'));
      expect(played, ['e7e5']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('worker failure retains formatted reading without raw fallback', (
    tester,
  ) async {
    final worker = _Worker();
    await _show(tester, worker, _pv('e2e4 e7e5'));
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await _show(tester, worker, _pv('d2d4 d7d5', .42));
    await _start(tester);
    worker.results[1].completeError(StateError('worker failure'));
    await tester.pump();
    await tester.pump();
    expect(_san('1.e4'), findsOneWidget);
    expect(find.text('d2d4 d7d5'), findsNothing);
    expect(find.text('+0.21'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'raw labels from invalid conversion never become display tokens',
    (tester) async {
      final worker = _Worker();
      await _show(tester, worker, _pv('e2e4 e7e5'));
      await _start(tester);
      worker.results[0].complete(['e2e4', 'e7e5']);
      await tester.pump();
      await tester.pump();
      expect(find.text('e2e4', findRichText: true), findsNothing);
      expect(find.text('Formatting…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'score-only update stays paired when next move update is pending',
    (tester) async {
      final worker = _Worker();
      await _show(tester, worker, _pv('e2e4 e7e5'));
      await _start(tester);
      worker.complete(0);
      await tester.pump();
      await tester.pump();
      await _show(tester, worker, _pv('e2e4 e7e5', .30));
      expect(find.text('+0.30'), findsOneWidget);
      expect(worker.requests, hasLength(1));
      await _show(tester, worker, _pv('d2d4 d7d5', .42));
      expect(find.text('+0.30'), findsOneWidget);
      expect(find.text('+0.21'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stationary hover retains displayed token during pending format',
    (tester) async {
      final worker = _Worker();
      await _show(tester, worker, _pv('e2e4 e7e5'));
      await _start(tester);
      worker.complete(0);
      await tester.pump();
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(tester.getCenter(_san('e5')));
      await tester.pump();
      MoveHoverPreview preview() =>
          tester.widget(find.byType(MoveHoverPreview));
      expect(preview().enabled, isTrue);
      expect(preview().movesUpToHover, ['e2e4', 'e7e5']);
      await _show(tester, worker, _pv('d2d4 d7d5'));
      expect(preview().enabled, isTrue);
      expect(preview().movesUpToHover, ['e2e4', 'e7e5']);
      await _start(tester);
      worker.complete(1);
      await tester.pump();
      await tester.pump();
      expect(preview().enabled, isFalse);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('menu play survives callback recreation in same Board owner', (
    tester,
  ) async {
    final worker = _Worker();
    final played = <String>[];
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: (uci) => played.add(uci),
    );
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await tester.tap(_san('1.e4'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Play this move'), findsOneWidget);
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5', .30),
      play: (uci) => played.add(uci),
    );
    await tester.tap(find.text('Play this move'));
    await tester.pumpAndSettle();
    expect(played, ['e2e4']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('menu refuses an intervening Board owner even after returning', (
    tester,
  ) async {
    final worker = _Worker();
    final played = <String>[];
    final owner = Object();
    final other = Object();
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: owner,
    );
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await tester.tap(_san('1.e4'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: other,
    );
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: owner,
    );
    await tester.tap(find.text('Play this move'));
    await tester.pumpAndSettle();
    expect(played, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('menu refuses play after retained rows become current again', (
    tester,
  ) async {
    final worker = _Worker();
    final played = <String>[];
    final owner = Object();
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: owner,
    );
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await tester.tap(_san('1.e4'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: owner,
      interactive: false,
    );
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: owner,
      interactive: true,
    );
    await tester.tap(find.text('Play this move'));
    await tester.pumpAndSettle();
    expect(played, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('menu retains opening move while next SAN is published', (
    tester,
  ) async {
    final worker = _Worker();
    final played = <String>[];
    final owner = Object();
    await _show(
      tester,
      worker,
      _pv('e2e4 e7e5'),
      play: played.add,
      playOwner: owner,
    );
    await _start(tester);
    worker.complete(0);
    await tester.pump();
    await tester.pump();
    await tester.tap(_san('1.e4'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await _show(
      tester,
      worker,
      _pv('d2d4 d7d5'),
      play: played.add,
      playOwner: owner,
    );
    await _start(tester);
    worker.complete(1);
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Play this move'));
    await tester.pumpAndSettle();
    expect(played, ['e2e4']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'dispose cancels pending formatting and ignores late completion',
    (tester) async {
      final worker = _Worker();
      await _show(tester, worker, _pv('e2e4 e7e5'));
      await _start(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      worker.complete(0);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      expect(worker.requests, hasLength(1));
    },
  );
}
