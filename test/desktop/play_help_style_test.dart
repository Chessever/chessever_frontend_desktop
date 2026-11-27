import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_help_rating.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/play_help_modules.dart';
import 'package:chessever/desktop/state/play_help_style.dart';
import 'package:chessever/desktop/widgets/play_help_trigger.dart';

void main() {
  group('help gain factor', () {
    test('no help keeps the whole gain', () {
      expect(playHelpGainFactor(const PlayHelpUsage(humanMoves: 30)), 1);
    });

    test('help on screen for every move keeps a quarter', () {
      expect(
        playHelpGainFactor(
          const PlayHelpUsage(humanMoves: 30, helpedMoves: 30),
        ),
        kPlayHelpMinGainFactor,
      );
    });

    test('help for part of the game costs in proportion', () {
      expect(
        playHelpGainFactor(
          const PlayHelpUsage(humanMoves: 40, helpedMoves: 20),
        ),
        closeTo(0.63, 0.001),
      );
    });

    test('peeks and hints cost a fixed share each', () {
      expect(
        playHelpGainFactor(const PlayHelpUsage(humanMoves: 30, peeks: 3)),
        closeTo(0.76, 0.001),
      );
      expect(
        playHelpGainFactor(const PlayHelpUsage(humanMoves: 30, hints: 3)),
        closeTo(0.70, 0.001),
      );
    });

    test('the threat shown for moves costs a third of full help', () {
      expect(
        playHelpGainFactor(
          const PlayHelpUsage(humanMoves: 20, threatMoves: 20),
        ),
        closeTo(0.74, 0.001),
      );
    });

    test('never below the floor', () {
      expect(
        playHelpGainFactor(
          const PlayHelpUsage(humanMoves: 10, helpedMoves: 10, hints: 5),
        ),
        kPlayHelpMinGainFactor,
      );
    });

    test('a saved record carries its factor', () {
      expect(playHelpGainFactorFromMetadata(const {}), 1);
      expect(
        playHelpGainFactorFromMetadata(const {
          'help': {'gainFactor': 0.7},
        }),
        0.7,
      );
      expect(
        playHelpGainFactorFromMetadata(const {
          'help': {'gainFactor': 0.01},
        }),
        kPlayHelpMinGainFactor,
      );
    });
  });

  group('rating with help', () {
    const stats = PlayRatingStats(
      rating: 1500,
      peak: 1500,
      gamesPlayed: 40,
      wins: 20,
      losses: 20,
      draws: 0,
      rd: 80,
    );
    final at = DateTime.utc(2026, 11, 27);

    test('a win keeps only its share of the gain', () {
      final full = ratePlayGame(
        stats: stats,
        opponentRating: 1500,
        score: 1,
        at: at,
      );
      final helped = ratePlayGame(
        stats: stats,
        opponentRating: 1500,
        score: 1,
        at: at,
        gainFactor: 0.5,
      );
      expect(full.delta, greaterThan(0));
      expect(helped.delta, (full.delta * 0.5).round());
    });

    test('a loss is never softened', () {
      final full = ratePlayGame(
        stats: stats,
        opponentRating: 1500,
        score: 0,
        at: at,
      );
      final helped = ratePlayGame(
        stats: stats,
        opponentRating: 1500,
        score: 0,
        at: at,
        gainFactor: 0.25,
      );
      expect(helped.delta, full.delta);
      expect(helped.delta, lessThan(0));
    });
  });

  group('help usage', () {
    test('each style decides when the help shows', () {
      const always = PlayHelpUsage();
      expect(always.revealedAt(7), isTrue);
      const peek = PlayHelpUsage(level: PlayHelpLevel.peek);
      expect(peek.revealedAt(7), isFalse);
      expect(peek.copyWith(held: {null}).revealedAt(7), isTrue);
      const hint = PlayHelpUsage(level: PlayHelpLevel.hints);
      final spent = hint.copyWith(
        hints: 1,
        revealedPly: () => 7,
        hinted: {null},
      );
      expect(spent.revealedAt(7), isTrue);
      expect(spent.revealedAt(8), isFalse);
      expect(spent.hintsLeft, 2);
    });

    test('a peek or a hint can reveal one module', () {
      const peek = PlayHelpUsage(level: PlayHelpLevel.peek);
      final lines = peek.copyWith(held: {PlayHelpModule.engineLines});
      expect(lines.revealedModulesAt(3), {PlayHelpModule.engineLines});
      expect(
        peek.copyWith(held: {null}).revealedModulesAt(3),
        PlayHelpModule.values.toSet(),
      );
      const hint = PlayHelpUsage(level: PlayHelpLevel.hints);
      final bar = hint.copyWith(
        hints: 1,
        revealedPly: () => 4,
        hinted: {PlayHelpModule.evalBar},
      );
      expect(bar.revealedModulesAt(4), {PlayHelpModule.evalBar});
      expect(bar.revealedModulesAt(5), isEmpty);
    });

    test('the help on screen keeps only the revealed modules', () {
      const chosen = PlayHelpModules(
        engineLines: true,
        evalBar: true,
        arrows: PlayHelpArrows.toby,
      );
      expect(
        chosen.onlyRevealed({PlayHelpModule.evalBar}),
        const PlayHelpModules(evalBar: true),
      );
      // Arrows keep their chosen source.
      expect(
        chosen.onlyRevealed({PlayHelpModule.arrows}),
        const PlayHelpModules(arrows: PlayHelpArrows.toby),
      );
      expect(chosen.onlyRevealed(PlayHelpModule.values.toSet()), chosen);
      expect(chosen.chosenModules, [
        PlayHelpModule.engineLines,
        PlayHelpModule.evalBar,
        PlayHelpModule.arrows,
      ]);
    });

    test('the style survives a save', () {
      const style = PlayHelpStyle(level: PlayHelpLevel.hints, hints: 5);
      expect(PlayHelpStyle.fromJson(style.toJson()), style);
      expect(
        PlayHelpStyle.fromJson(const {'level': 'nope', 'hints': 4}),
        const PlayHelpStyle(),
      );
    });
  });

  group('help keys', () {
    final map = BoardShortcutMap(defaultBoardShortcuts());

    test('every help action has a key of its own by default', () {
      for (final action in kPlayHelpActions.keys) {
        final chords = map.chordsFor(action);
        expect(chords, isNotEmpty, reason: action.label);
        for (final chord in chords) {
          expect(map.actionForChord(chord), action, reason: action.label);
          expect(
            map.actionForChord(chord, except: action),
            isNull,
            reason: '${action.label} shares ${chord.label}',
          );
        }
      }
      expect(kPlayHelpActions.length, PlayHelpModule.values.length + 1);
      for (final module in PlayHelpModule.values) {
        expect(kPlayHelpActions[playHelpActionFor(module)], module);
      }
      expect(playHelpActionFor(null), BoardActionKey.playHelpAll);
    });

    test('a key down resolves through the bindings, modifiers exact', () {
      expect(
        playHelpActionForKeyDown(map, LogicalKeyboardKey.keyH),
        BoardActionKey.playHelpAll,
      );
      expect(
        playHelpActionForKeyDown(map, LogicalKeyboardKey.keyL, shift: true),
        BoardActionKey.playHelpEngineLines,
      );
      expect(playHelpActionForKeyDown(map, LogicalKeyboardKey.keyL), isNull);
      expect(
        playHelpActionForKeyDown(map, LogicalKeyboardKey.keyH, shift: true),
        isNull,
      );
      // A key up matches the key alone: Shift may come up first.
      expect(playHelpActionsForKey(map, LogicalKeyboardKey.keyL), [
        BoardActionKey.playHelpEngineLines,
      ]);
    });

    test('a rebound key is read from the player\'s map', () {
      final rebound = BoardShortcutMap({
        ...map.bindings,
        BoardActionKey.playHelpAll: [
          KeyChord(keyId: LogicalKeyboardKey.keyP.keyId),
        ],
      });
      expect(
        playHelpActionForKeyDown(rebound, LogicalKeyboardKey.keyH),
        isNull,
      );
      expect(
        playHelpActionForKeyDown(rebound, LogicalKeyboardKey.keyP),
        BoardActionKey.playHelpAll,
      );
      expect(playHelpKeyLabel(rebound, null), 'P');
    });

    test('global search and Play\'s move keys never fire help', () {
      final f = LogicalKeyboardKey.keyF.keyId;
      final left = LogicalKeyboardKey.arrowLeft.keyId;
      final stolen = BoardShortcutMap({
        ...map.bindings,
        BoardActionKey.playHelpAll: [
          KeyChord(keyId: f, meta: true, shift: true),
          KeyChord(keyId: f, ctrl: true, shift: true),
          KeyChord(keyId: left),
        ],
      });
      // Cmd/Ctrl+Shift+F is search: a stored binding is dropped.
      expect(stolen.chordsFor(BoardActionKey.playHelpAll), [
        KeyChord(keyId: left),
      ]);
      expect(isReservedSearchChord(KeyChord(keyId: f, meta: true)), isTrue);
      expect(
        isReservedSearchChord(KeyChord(keyId: f, ctrl: true, shift: true)),
        isTrue,
      );
      expect(isReservedSearchChord(KeyChord(keyId: f, shift: true)), isFalse);
      for (final shift in [false, true]) {
        expect(
          playHelpActionForKeyDown(
            stolen,
            LogicalKeyboardKey.keyF,
            meta: true,
            shift: shift,
          ),
          isNull,
        );
        expect(
          playHelpActionForKeyDown(
            stolen,
            LogicalKeyboardKey.keyF,
            ctrl: true,
            shift: shift,
          ),
          isNull,
        );
      }
      // Left steps back through the moves in Play, whatever is stored.
      expect(isPlayNavigationChord(KeyChord(keyId: left)), isTrue);
      expect(
        isPlayNavigationChord(KeyChord(keyId: left, shift: true)),
        isFalse,
      );
      expect(
        playHelpActionForKeyDown(stolen, LogicalKeyboardKey.arrowLeft),
        isNull,
      );
    });

    test('the Board and the shell leave the help keys to Play', () {
      for (final action in BoardActionKey.values) {
        expect(
          action.isPlayHelp,
          kPlayHelpActions.containsKey(action),
          reason: action.label,
        );
      }
    });
  });
}
