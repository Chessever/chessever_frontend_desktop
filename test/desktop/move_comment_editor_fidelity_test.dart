import 'dart:io';

import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/screens/chessboard/utils/pgn_external_compat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Editor {
  late Future<String?> result;

  Future<void> open(WidgetTester tester, {String initial = ''}) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    final context = tester.element(find.byType(Scaffold));
    result = showMoveCommentEditor(context, initialComment: initial);
    await tester.pumpAndSettle();
  }
}

Future<void> _paste(WidgetTester tester, String text) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => switch (call.method) {
      'Clipboard.getData' => <String, dynamic>{'text': text},
      'Clipboard.hasStrings' => <String, dynamic>{'value': true},
      _ => null,
    },
  );
  await tester.tap(find.byType(TextField));
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'pasting a long move comment returns its complete final paragraph',
    (tester) async {
      final note = List.generate(
        30,
        (i) => 'Paragraph $i: a long analysis note with Unicode ♞, é, and ½–½.',
      ).join('\n\n');
      final editor = _Editor();
      await editor.open(tester);
      await _paste(tester, note);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        note,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await editor.result, note);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an already-long comment can be extended without truncation', (
    tester,
  ) async {
    final initial = List.filled(80, 'Original note ♞.').join(' ');
    final extended = '$initial\n\nA new final paragraph 👨‍👩‍👧‍👦.';
    final editor = _Editor();
    await editor.open(tester, initial: initial);
    await tester.enterText(find.byType(TextField), extended);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      extended,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await editor.result, extended);
  });

  testWidgets('large Unicode paragraphs remain scrollable inside the dialog', (
    tester,
  ) async {
    final note = List.generate(
      180,
      (i) => 'Analysis $i: ♞ 👨‍👩‍👧‍👦 e\u0301 ½–½.',
    ).join('\n\n');
    final editor = _Editor();
    await editor.open(tester);
    await _paste(tester, note);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, note);
    expect(field.maxLines, 8);
    expect(tester.getRect(find.byType(TextField)).height, lessThan(400));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await editor.result, note);
  });

  testWidgets('cancel discards a long edit and clear still returns empty', (
    tester,
  ) async {
    final note = List.filled(90, 'Keep my existing commentary.').join(' ');
    final cancel = _Editor();
    await cancel.open(tester, initial: note);
    await _paste(tester, '$note changed');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await cancel.result, isNull);
    final clear = _Editor();
    await clear.open(tester, initial: note);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(await clear.result, '');
  });

  final reported = Platform.environment['CHESSEVER_LONG_COMMENT_FILE'];
  testWidgets(
    'reported long comment survives real paste save reopen and external PGN',
    (tester) async {
      final note = File(reported!).readAsStringSync();
      expect(note.length, greaterThan(600));
      final editor = _Editor();
      await editor.open(tester);
      await _paste(tester, note);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        note,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final saved = await editor.result;
      expect(saved, note);
      _expectPgnRoundTrip(saved!);
    },
    // The reported text is private and deliberately lives outside the repo.
    skip: reported == null,
  );

  test(
    'long commentary preserves tree clocks and evaluation in PGN round trips',
    () {
      _expectPgnRoundTrip(
        List.filled(100, 'Long analytical commentary ♞.').join('\n\n'),
      );
    },
  );
}

void _expectPgnRoundTrip(String note) {
  final base = ChessGame.fromPgn(
    'comment-round-trip',
    r'[Result "*"]'
        '\n\n'
        r'1. e4 $18 {[%clk 0:05:00]} e5 (1... c5 {Untouched variation}) *',
  );
  final before = base.toJson();
  final edited = base.copyWith(
    mainline: [
      base.mainline.first.copyWith(
        comments: [...?base.mainline.first.comments, note],
      ),
      ...base.mainline.skip(1),
    ],
  );
  final native = exportGameToPgn(edited);
  final outputs = [native, toExternalCompatiblePgn(native)];
  String normalize(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  for (final pgn in outputs) {
    final reopened = ChessGame.fromPgn('reopened-comment', pgn);
    final comments = reopened.mainline.first.comments ?? const <String>[];
    expect(comments.map(normalize).join(' '), contains(normalize(note)));
    expect(comments.join(' '), contains('[%clk 0:05:00]'));
    expect(reopened.mainline.first.nags, contains(18));
    final variations =
        reopened.mainline
            .expand((move) => move.variations ?? const <ChessLine>[])
            .toList();
    expect(variations, hasLength(1));
    expect(variations.single.single.comments, ['Untouched variation']);
    expect(
      reopened.mainline.map((m) => m.uci),
      edited.mainline.map((m) => m.uci),
    );
  }
  expect(base.toJson(), before);
}
