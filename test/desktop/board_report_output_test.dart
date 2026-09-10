import 'dart:async';

import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:flutter_test/flutter_test.dart';

GameAnalysisReport reportFor(ChessGame game, {int cp = 35}) =>
    GameAnalysisReport(
      fingerprint: gameReportFingerprint(game),
      positions: const [],
      moves: [
        GameReportMove(
          ply: 1,
          san: 'e4',
          uci: 'e2e4',
          isWhite: true,
          classification: GameMoveClassification.blunder,
          evaluation: GameReportLine(
            moves: const [],
            depth: 18,
            centipawns: cp,
          ),
        ),
      ],
      whiteAccuracy: 90,
      blackAccuracy: 90,
      generatedAt: DateTime.utc(2026),
    );

ChessGame output(ChessGame game, GameAnalysisReport report, bool visible) {
  final eligible = eligibleBoardOutputReport(
    game: game,
    report: report,
    explicitlyVisibleForActivation: visible,
  );
  return eligible == null
      ? game
      : mergeGameReportAnnotationsForGif(game, eligible.moves);
}

void main() {
  final source = ChessGame.fromPgn(
    'record-a',
    '[White "Source"]\n[Result "*"]\n\n'
        '1. e4 \$1 \$16 {imported prose [%eval 0.12]} e5 *',
  );
  final report = reportFor(source);

  test('hidden completed report adds nothing and preserves imported data', () {
    expect(output(source, report, false), same(source));
    expect(source.mainline.first.eval, '0.12');
    expect(source.mainline.first.nags, containsAll([1, 16]));
    expect(
      exportGameToPgn(output(source, report, false)),
      exportGameToPgn(source),
    );
  });

  test('show then hide without saving returns the untouched source', () {
    final shown = output(source, report, true);
    expect(shown.mainline.first.eval, '0.35');
    expect(shown.mainline.first.nags, contains(4));
    expect(shown.mainline.first.nags, contains(16));
    expect(output(source, report, false), same(source));
  });

  test('visible but mismatched mainline is ineligible', () {
    final different = ChessGame.fromPgn('b', '1. d4 d5 *');
    expect(output(different, report, true), same(different));
  });

  test('save ON promotes saved annotations; OFF and reopen retain them', () {
    final exactPgn = exportGameToPgn(output(source, report, true));
    final saved = ChessGame.fromPgn('record-a', exactPgn);
    final promoted = rebaseBoardAfterSavedSnapshot(
      before: source,
      saved: saved,
      current: source,
    );
    expect(exportGameToPgn(output(promoted, report, false)), exactPgn);
    final reopened = ChessGame.fromPgn('reopened', exactPgn);
    expect(exportGameToPgn(output(reopened, report, false)), exactPgn);
    expect(reopened.mainline.first.nags, containsAll([4, 16]));
  });

  for (final showReportOnFirstSave in [true, false]) {
    test('successive Library routing retains committed headers/edits '
        '(first report ON=$showReportOnFirstSave)', () async {
      var current = source;
      var committed = false;
      var dirty = false;
      var sourceResolutions = 0;
      Future<ChessGame> route(bool visible) => resolveBoardLibrarySaveGame(
        useOpeningSource: shouldUsePristineEventSourceForLibrarySave(
          canSaveSource: true,
          dirtySinceLoad: dirty,
          hasUserNags: false,
          hasCompletedReport: eligibleBoardOutputReport(
            game: current,
            report: report,
            explicitlyVisibleForActivation: visible,
          ) != null,
          hasCommittedSave: committed,
        ),
        workingGame: output(current, report, visible),
        resolveOpeningSource: () async {
          sourceResolutions++;
          return source;
        },
      );

      final first = await route(showReportOnFirstSave);
      // Actual dialog metadata edits and board moves are part of the saved
      // snapshot; promotion must not make the original card authoritative.
      final saved = first.copyWith(
        metadata: {...first.metadata, 'White': 'Committed dialog header'},
      );
      final savedPgn = exportGameToPgn(saved);
      current = rebaseBoardAfterSavedSnapshot(
        before: source, saved: saved, current: current,
      );
      committed = true;
      dirty = exportGameToPgn(current) != savedPgn;
      expect(dirty, isFalse);
      final resolutionsAfterFirst = sourceResolutions;
      for (var repeat = 0; repeat < 2; repeat++) {
        final second = await route(false);
        expect(exportGameToPgn(second), savedPgn);
        expect(second.metadata['White'], 'Committed dialog header');
        expect(sourceResolutions, resolutionsAfterFirst);
        if (showReportOnFirstSave) {
          expect(second.mainline.first.nags, contains(4));
          expect(second.mainline.first.eval, '0.35');
        } else {
          expect(second.mainline.first.nags, contains(1));
          expect(second.mainline.first.eval, '0.12');
        }
      }
    });
  }

  test('clean edited mainline never takes opening-source Library route',
      () async {
    final edited = ChessGame.fromPgn('record-a', '1. e4 e5 2. Nf3 *');
    final saved = await resolveBoardLibrarySaveGame(
      useOpeningSource: shouldUsePristineEventSourceForLibrarySave(
        canSaveSource: true,
        dirtySinceLoad: false,
        hasUserNags: false,
        hasCompletedReport: false,
        hasCommittedSave: true,
      ),
      workingGame: edited,
      resolveOpeningSource: () async => throw StateError('stale source route'),
    );
    expect(saved.mainline.length, 3);
    expect(saved, same(edited));
  });

  test('manual quality beats report and survives committed OFF output', () {
    final before = mergeUserMainlineNagsForGif(source, {
      0: [2],
    });
    final annotated = mergeUserMainlineNagsForGif(
      output(source, report, true),
      {
        0: [2],
      },
    );
    final saved = ChessGame.fromPgn('a', exportGameToPgn(annotated));
    final promoted = rebaseBoardAfterSavedSnapshot(
      before: before,
      saved: saved,
      current: before,
    );
    expect(output(promoted, report, false).mainline.first.nags, contains(2));
    expect(promoted.mainline.first.nags, isNot(contains(4)));
    expect(promoted.mainline.first.nags, contains(16));
    expect(
      promoted.mainline.first.comments!.join(),
      contains('imported prose'),
    );
  });

  test(
    'dialog outcome carries captured metadata, not post-await controllers',
    () {
      final committed = output(
        source,
        report,
        true,
      ).copyWith(metadata: {...source.metadata, 'White': 'Saved in dialog'});
      final outcome = LibrarySaveOutcome(
        savedRows: 0,
        folderCount: 0,
        didUpdateOriginal: true,
        committedGame: committed,
      );
      expect(outcome.didSave, isTrue);
      expect(outcome.committedGame, same(committed));
      final promoted = rebaseBoardAfterSavedSnapshot(
        before: source,
        saved: outcome.committedGame!,
        current: source,
      );
      expect(promoted.metadata['White'], 'Saved in dialog');
    },
  );

  test('delayed save rebases late comments, NAGs, moves and headers', () async {
    final exactPgn = exportGameToPgn(output(source, report, true));
    final write = Completer<String>();
    var current = source;
    final completion = write.future.then((pgn) {
      current = rebaseBoardAfterSavedSnapshot(
        before: source,
        saved: ChessGame.fromPgn('a', pgn),
        current: current,
      );
    });
    current = ChessGame.fromPgn(
      'a',
      '[White "Late edit"]\n[Result "*"]\n\n'
          '1. e4 \$2 \$16 {late prose [%eval 0.12]} e5 (1... c5) 2. Nf3 *',
    );
    write.complete(exactPgn);
    await completion;
    expect(current.mainline.first.eval, '0.35');
    expect(current.mainline.first.nags, contains(2));
    expect(current.mainline.first.nags, isNot(contains(4)));
    expect(current.mainline.first.comments!.join(), contains('late prose'));
    expect(current.mainline.length, 3);
    expect(current.mainline.first.variations, isNotEmpty);
    expect(current.metadata['White'], 'Late edit');
    expect(exportGameToPgn(current), isNot(exactPgn)); // Still dirty.
    expect(ChessGame.fromPgn('disk', exactPgn).mainline.length, 2);
  });

  test(
    'failed write never invokes promotion or mutates another dirty tab',
    () async {
      var current = source;
      final sibling = ChessGame.fromPgn(
        'sibling',
        '1. e4 {unsaved sibling} e5 *',
      );
      final siblingBefore = exportGameToPgn(sibling);
      final write = Completer<String>();
      final completion = write.future.then((pgn) {
        current = rebaseBoardAfterSavedSnapshot(
          before: source,
          saved: ChessGame.fromPgn('a', pgn),
          current: current,
        );
      });
      final assertion = expectLater(completion, throwsStateError);
      write.completeError(StateError('write rejected'));
      await assertion;
      expect(current, same(source));
      expect(exportGameToPgn(sibling), siblingBefore);
    },
  );

  test('completion promotes captured report, never a newer cached report', () {
    final captured = output(source, report, true);
    final newer = reportFor(source, cp: 900);
    final promoted = rebaseBoardAfterSavedSnapshot(
      before: source,
      saved: captured,
      current: source,
    );
    expect(output(promoted, newer, false).mainline.first.eval, '0.35');
  });

  test('same-mainline record activations and A-B-A cannot inherit reveal', () {
    final a = (Object(), gameReportFingerprint(source));
    final b = (Object(), gameReportFingerprint(source));
    final aAgain = (Object(), gameReportFingerprint(source));
    var reveal = const GameReportRevealState().activate(a).toggle();
    expect(reveal.isVisibleFor(a), isTrue);
    expect(reveal.isVisibleFor(b), isFalse);
    reveal = reveal.activate(b).activate(aAgain);
    expect(reveal.isVisibleFor(aAgain), isFalse);
    expect(
      eligibleBoardOutputReport(
        game: source,
        report: report,
        explicitlyVisibleForActivation: reveal.isVisibleFor(aAgain),
      ),
      isNull,
    );
  });

  test('late positional NAG edit retains saved report quality', () {
    final saved = output(source, report, true);
    final current = source.copyWith(
      mainline: [
        source.mainline.first.copyWith(nags: [1, 16, 18]),
        source.mainline[1],
      ],
    );
    final promoted = rebaseBoardAfterSavedSnapshot(
      before: source,
      saved: saved,
      current: current,
    );
    expect(promoted.mainline.first.nags, containsAll([4, 16, 18]));
    expect(promoted.mainline.first.nags, isNot(contains(1)));
  });

  test('late deletion or alternate mainline is never resurrected', () {
    final saved = output(source, report, true);
    final alternate = ChessGame.fromPgn('a', '1. d4 d5 *');
    final promoted = rebaseBoardAfterSavedSnapshot(
      before: source,
      saved: saved,
      current: alternate,
    );
    expect(promoted.mainline.first.eval, isNull);
    expect(promoted.mainline.first.uci, 'd2d4');
    final shortened = source.copyWith(mainline: [source.mainline.first]);
    expect(
      rebaseBoardAfterSavedSnapshot(
        before: source,
        saved: saved,
        current: shortened,
      ).mainline.length,
      1,
    );
  });
}
