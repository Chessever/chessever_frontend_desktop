import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/widgets/pgn_attribution_editor.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';

void main() {
  test(
    'untouched optional tags, unknown values, types and unrelated metadata are preserved exactly',
    () {
      final metadata = <String, dynamic>{
        'Annotator': '  Original author  ',
        'WhiteTeam': '?',
        'BlackTeam': null,
        'Source': 42,
        'Author': 'Legacy author',
        'TimeControl': '60+2',
        'Custom': 'keep',
      };
      final before = Map.of(metadata);
      final draft = PgnAttributionController(metadata);
      addTearDown(draft.dispose);
      draft.field('Annotator').selection = const TextSelection.collapsed(
        offset: 1,
      );
      expect(draft.applyTo(metadata), before);
      expect(metadata, before);
    },
  );
  for (final tag in PgnAttributionController.labels.keys) {
    test(
      '$tag accepts a deliberate edit and explicit clear without changing other tags',
      () {
        final original = <String, dynamic>{
          for (final key in PgnAttributionController.labels.keys)
            key: 'Imported $key',
          'Custom': 'keep',
        };
        final draft = PgnAttributionController(original);
        addTearDown(draft.dispose);
        draft.field(tag).text = '  New $tag  ';
        expect(draft.applyTo(original)[tag], 'New $tag');
        draft.field(tag).text = '';
        final cleared = draft.applyTo(original);
        expect(cleared.containsKey(tag), isFalse);
        expect(cleared, {...original}..remove(tag));
        expect(original[tag], 'Imported $tag');
      },
    );
  }
  test('no author or team is invented for a game without attribution', () {
    final draft = PgnAttributionController({});
    addTearDown(draft.dispose);
    expect(draft.applyTo({}), isEmpty);
  });
  test(
    'native PGN and JSON round trips preserve edited attribution and game annotations',
    () {
      final game = ChessGame.fromPgn(
        'fixture',
        '[TimeControl "60+2"]\n\n1. e4 {Keep prose [%clk 0:00:59]} e5 (1... c5 \$14 {Variation}) *',
      );
      final draft = PgnAttributionController(game.metadata);
      addTearDown(draft.dispose);
      draft.field('Annotator').text = r'José "J" \\ Analysis';
      draft.field('WhiteTeam').text = 'Nový Bor';
      draft.field('BlackTeam').text = 'Alkaloid';
      draft.field('Source').text = 'Original broadcast';
      final edited = game.copyWith(metadata: draft.applyTo(game.metadata));
      final reopened = ChessGame.fromPgn('reopened', exportGameToPgn(edited));
      final jsonCopy = ChessGame.fromJson(edited.toJson());
      for (final key in PgnAttributionController.labels.keys) {
        expect(reopened.metadata[key], edited.metadata[key]);
        expect(jsonCopy.metadata[key], edited.metadata[key]);
      }
      expect(reopened.metadata['TimeControl'], '60+2');
      expect(reopened.mainline.first.clockTime, '0:00:59');
      expect(exportGameToPgn(reopened), contains('Keep prose'));
      expect(exportGameToPgn(reopened), contains('Variation'));
      expect(exportGameToPgn(reopened), contains('\$14'));
    },
  );
  testWidgets(
    'collapse and outer unmount preserve controller draft; disabled fields cannot edit',
    (tester) async {
      final draft = PgnAttributionController({'Annotator': 'Original'});
      addTearDown(draft.dispose);
      Future<void> show({bool enabled = true}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: PgnAttributionEditor(controller: draft, enabled: enabled),
            ),
          ),
        ),
      );
      await show();
      await tester.tap(find.text('Annotator and teams'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byKey(const ValueKey('pgn-Annotator')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field, 'Draft author');
      await tester.tap(find.text('Annotator and teams'));
      await tester.pumpAndSettle();
      expect(
        draft.applyTo({'Annotator': 'Original'})['Annotator'],
        'Draft author',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      await show(enabled: false);
      expect(find.text('Annotator (author)'), findsNothing);
      await tester.tap(find.text('Annotator and teams'));
      await tester.pumpAndSettle();
      expect(find.text('Annotator (author)'), findsNothing);
      expect(draft.field('Annotator').text, 'Draft author');
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );
}
