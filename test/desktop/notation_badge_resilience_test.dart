import 'dart:async';

import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercise the actual notation widget with a browser-like pending/failed asset,
// rather than declaring a badge visible merely because SvgPicture exists.
class _DelayedBadgeBundle extends CachingAssetBundle {
  final pending = <String, Completer<ByteData>>{};
  @override
  Future<ByteData> load(String key) {
    if (key.startsWith('assets/svgs/')) {
      return pending.putIfAbsent(key, Completer<ByteData>.new).future;
    }
    return rootBundle.load(key);
  }

  Future<void> succeed() async {
    for (final entry in pending.entries) {
      entry.value.complete(await rootBundle.load(entry.key));
    }
  }
}

void main() {
  for (final mode in NotationLayoutMode.values) {
    testWidgets('quality marks stay visible until SVGs load in ${mode.name}', (
      tester,
    ) async {
      final bundle = _DelayedBadgeBundle();
      final layout = ValueNotifier(mode);
      addTearDown(layout.dispose);
      final game = ChessGame.fromPgn(
        'fallback',
        r'''[Result "*"]

1. d4 $1 d5 $6 (1... Nf6 $5 $146 2. c4 $15 e6) 2. c4 $2 e6 $3 3. Nc3 $4 Nf6 *''',
      );
      final before = game.toJson();
      await tester.pumpWidget(
        DefaultAssetBundle(
          bundle: bundle,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: Scaffold(
              body: NotationLadderView(
                game: game,
                activePointer: const [],
                onJump: (_) {},
                layoutModeController: layout,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(bundle.pending, hasLength(6));
      for (final glyph in ['!', '?!', '!?', '?', '!!', '??']) {
        expect(
          find.text(glyph),
          findsOneWidget,
          reason: 'A pending SVG must not erase $glyph',
        );
      }
      for (final glyph in ['!', '?!', '!?', '?', '!!', '??']) {
        expect(
          tester.widget<Text>(find.text(glyph)).style!.color!.computeLuminance(),
          greaterThan(0.7),
          reason: 'Fallback marks must remain readable without a colored disc',
        );
      }
      expect(find.text('N'), findsOneWidget);
      expect(find.text('⩱'), findsOneWidget);
      await tester.runAsync(bundle.succeed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final glyph in ['!', '?!', '!?', '?', '!!', '??']) {
        expect(
          find.text(glyph),
          findsNothing,
          reason: 'Successful SVGs replace, not duplicate, the fallback',
        );
      }
      expect(find.text('N'), findsOneWidget);
      expect(find.text('⩱'), findsOneWidget);
      expect(game.toJson(), before);
    });
  }
}
