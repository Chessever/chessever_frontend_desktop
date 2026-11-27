import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/state/botvinnik_dock.dart';

void main() {
  group('the Botvinnik chat closes for a new Play game', () {
    final game = Object();
    final other = Object();

    test('a tab gaining a game closes it', () {
      expect(botvinnikClosesForNewGame(null, {'a': game}), isTrue);
      expect(botvinnikClosesForNewGame({}, {'a': game}), isTrue);
    });

    test('a rematch (new args on the same tab) closes it', () {
      expect(botvinnikClosesForNewGame({'a': game}, {'a': other}), isTrue);
    });

    test('a game ending or a tab closing leaves it alone', () {
      expect(botvinnikClosesForNewGame({'a': game}, {}), isFalse);
      expect(
        botvinnikClosesForNewGame({'a': game, 'b': other}, {'a': game}),
        isFalse,
      );
    });

    test('an unchanged map leaves a chat opened during the game open', () {
      expect(botvinnikClosesForNewGame({'a': game}, {'a': game}), isFalse);
    });

    test('the dock starts closed', () {
      expect(BotvinnikDockNotifier().state.open, isFalse);
    });
  });
}
