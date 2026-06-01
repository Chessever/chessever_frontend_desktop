import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _initialFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

void main() {
  testWidgets(
    'hover popup refreshes after parent rebuild without build errors',
    (tester) async {
      final harnessKey = GlobalKey<_MoveHoverPreviewHarnessState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: _MoveHoverPreviewHarness(key: harnessKey),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer();
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey<String>('hover-token'))),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      harnessKey.currentState!.advance();
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.pump();
      expect(tester.takeException(), isNull);
      await gesture.removePointer();
    },
  );

  testWidgets(
    'rapid hover enter and exit does not mutate overlay in callbacks',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardSettingsProviderNew.overrideWith(
              _TestBoardSettingsNotifier.new,
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: _MoveHoverPreviewHarness(),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer();
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey<String>('hover-token'))),
      );
      await gesture.moveTo(const Offset(400, 400));
      expect(tester.takeException(), isNull);

      await tester.pump();
      expect(tester.takeException(), isNull);
      await gesture.removePointer();
    },
  );
}

class _MoveHoverPreviewHarness extends StatefulWidget {
  const _MoveHoverPreviewHarness({super.key});

  @override
  State<_MoveHoverPreviewHarness> createState() =>
      _MoveHoverPreviewHarnessState();
}

class _MoveHoverPreviewHarnessState extends State<_MoveHoverPreviewHarness> {
  int _index = 0;

  void advance() {
    setState(() => _index = (_index + 1) % 2);
  }

  @override
  Widget build(BuildContext context) {
    final moves = _index == 0 ? const ['e2e4'] : const ['d2d4'];
    return SizedBox(
      width: 180,
      height: 80,
      child: MoveHoverPreview(
        startingFen: _initialFen,
        movesUpToHover: moves,
        child: const SizedBox(
          key: ValueKey<String>('hover-token'),
          width: 96,
          height: 28,
          child: Text('hover'),
        ),
      ),
    );
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
