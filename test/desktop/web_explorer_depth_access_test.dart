import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/auth/desktop_explorer_access.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';

void main() {
  const initial = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  test('starting and ordinary opening positions retain free access', () {
    expect(desktopExplorerMinimumPliesToReach(initial), 0);
    const opening =
        'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 1';
    expect(
      desktopExplorerPlayedPlies(
        const GamebaseExplorerState(currentFen: opening),
        isWebApp: true,
      ),
      4,
    );
  });
  test('pasted late-game board cannot bypass depth using move 1', () {
    const state = GamebaseExplorerState(
      currentFen: '8/8/8/3k4/8/3K4/8/8 w - - 0 1',
    );
    expect(desktopExplorerPlayedPlies(state, isWebApp: true), greaterThan(20));
    expect(desktopExplorerPlayedPlies(state, isWebApp: false), 0);
  });
  test('move-10 position is free, advancing one ply requests Premium', () {
    final fen = initial.replaceFirst('0 1', '0 11');
    final state = GamebaseExplorerState(currentFen: fen);
    expect(desktopExplorerPlayedPlies(state, isWebApp: true), 20);
    expect(desktopExplorerPlayedPlies(state, isWebApp: true, advance: 1), 21);
  });
  test('unreadable board does not invent material depth', () {
    expect(desktopExplorerMinimumPliesToReach(''), 0);
    expect(desktopExplorerMinimumPliesToReach('invalid'), 0);
  });
}
