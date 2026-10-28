import 'package:forui/forui.dart';
import 'dart:async';
import 'dart:io';
import 'package:chessever/desktop/services/local_library_writer.dart';
import 'package:chessever/repository/library/models/saved_analysis.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/desktop/state/my_databases_focus.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/desktop/widgets/pgn_attribution_editor.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart';
import 'package:chessever/desktop/services/board_report_output.dart';
import 'package:chessever/desktop/services/board_unsaved_analysis_guard.dart';

const importedPgn =
    '[White "White"]\n[Black "Black"]\n[Annotator "Original author"]\n'
    '[WhiteTeam "White club"]\n[BlackTeam "Black club"]\n[Source "Original source"]\n'
    '[TimeControl "60+2"]\n\n1. e4 {Original comment [%clk 0:00:59]} e5 *';

class FixtureDatabase implements AppDatabase {
  @override
  Future<T?> getJson<T>(String key) async => null;
  @override
  Future<void> setJson(String key, Object value) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> openSave(
  WidgetTester tester, {
  void Function(ChessGame)? onUpdate,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final db = FixtureDatabase();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        libraryFoldersStreamProvider.overrideWith((ref) => Stream.value([])),
        myDatabasesFocusProvider.overrideWith(
          (ref) => MyDatabasesFocusNotifier(db),
        ),
        localLibraryRegistryProvider.overrideWith(
          (ref) => LocalLibraryRegistryNotifier(db),
        ),
        libraryRepositoryProvider.overrideWith(
          (ref) => throw StateError('No backend in widget tests'),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder:
                (context, ref, _) => TextButton(
                  onPressed:
                      () => unawaited(
                        showLibrarySaveToFolderDialog(
                          context: context,
                          ref: ref,
                          games: [ChessGame.fromPgn('fixture', importedPgn)],
                          updateTarget: LibraryUpdateTarget(
                            title: 'Original',
                            subtitle: 'Fixture',
                            onUpdate: (games) async {
                              onUpdate?.call(games);
                            },
                          ),
                        ),
                      ),
                  child: const Text('Open save'),
                ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open save'));
  await tester.pumpAndSettle();
}

// forui 0.16's FTextField inside a dialog route trips Flutter's semantics
// assert (`node.isMergedIntoParent`) under test, so the tests that open those
// fields run with semantics off, as in library_book_dialog_test. That assert
// also aborts the frame before inactive elements are unmounted, which is what
// made a later tap report "Looking up a deactivated widget's ancestor"; with
// the frame completing, collapsing a section with a focused field is clean.
void main() {
  Future<void> setField(WidgetTester tester, String tag, String value) async {
    final input = find.descendant(
      of: find.byKey(ValueKey('pgn-$tag')),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(input);
    await tester.enterText(input, value);
  }

  test(
    'cloud insert and update payloads retain author edits and explicit team clearing',
    () {
      final original = ChessGame.fromPgn('fixture', importedPgn);
      final draft = PgnAttributionController(original.metadata);
      addTearDown(draft.dispose);
      draft.field('Annotator').text = 'Cloud author';
      draft.field('BlackTeam').text = '';
      final edited = original.copyWith(
        metadata: draft.applyTo(original.metadata),
      );
      final saved = SavedAnalysis(
        id: 'row',
        userId: 'test-user',
        title: 'fixture',
        chessGame: edited,
        analysisState: const {},
        variationComments: const {},
        lastViewedPosition: -1,
        tags: const [],
        isFavorite: false,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      for (final payload in [saved.toSupabaseInsert(), saved.toSupabase()]) {
        final reopened = ChessGame.fromJson(
          payload['chess_game'] as Map<String, dynamic>,
        );
        expect(reopened.metadata['Annotator'], 'Cloud author');
        expect(reopened.metadata.containsKey('BlackTeam'), isFalse);
        expect(reopened.metadata['WhiteTeam'], 'White club');
        expect(reopened.metadata['Source'], 'Original source');
        expect(reopened.mainline.first.clockTime, '0:00:59');
      }
      expect(original.metadata['BlackTeam'], 'Black club');
    },
  );

  test(
    'real local PGN writer persists edited optional tags and clearing at a fresh private path',
    () async {
      final root =
          Platform.environment['CHESSEVER_TEST_TMP'] ??
          Platform.environment['TMPDIR'] ??
          Directory.systemTemp.path;
      final directory = await Directory(root).createTemp('annotator-local-');
      addTearDown(() => directory.delete(recursive: true));
      final original = ChessGame.fromPgn('fixture', importedPgn);
      final draft = PgnAttributionController(original.metadata);
      addTearDown(draft.dispose);
      draft.field('Annotator').text = 'Local author';
      draft.field('Source').text = '';
      final edited = original.copyWith(
        metadata: draft.applyTo(original.metadata),
      );
      final file = File('${directory.path}/attribution.pgn');
      final outcome = await LocalLibraryWriter(
        folderPath: file.path,
      ).writeGames([edited]);
      expect(outcome.writtenPaths, [file.path]);
      expect(outcome.errorMessage, isNull);
      final reopened = ChessGame.fromPgn('reopened', await file.readAsString());
      expect(reopened.metadata['Annotator'], 'Local author');
      expect(reopened.metadata.containsKey('Source'), isFalse);
      expect(reopened.metadata['WhiteTeam'], 'White club');
      expect(reopened.metadata['BlackTeam'], 'Black club');
      expect(reopened.mainline.first.clockTime, '0:00:59');
      expect(exportGameToPgn(reopened), contains('Original comment'));
    },
  );

  for (final tag in PgnAttributionController.labels.keys) {
    test(
      'committed clear of $tag rebases cleanly but preserves a later edit',
      () {
        final before = ChessGame.fromPgn('fixture', importedPgn);
        final draft = PgnAttributionController(before.metadata);
        addTearDown(draft.dispose);
        draft.field(tag).text = '';
        final saved = ChessGame.fromPgn(
          'saved',
          exportGameToPgn(
            before.copyWith(metadata: draft.applyTo(before.metadata)),
          ),
        );
        expect(saved.metadata.containsKey(tag), isFalse);
        final rebased = rebaseBoardAfterSavedSnapshot(
          before: before,
          saved: saved,
          current: before,
        );
        expect(rebased.metadata.containsKey(tag), isFalse);
        expect(
          shouldConfirmBoardAnalysisDiscard(
            dirtySinceLoad: true,
            currentPgn: exportGameToPgn(rebased),
            lastAppliedPgn: importedPgn,
            lastSavedAnalysisPgn: exportGameToPgn(saved),
          ),
          isFalse,
        );
        final later = before.copyWith(
          metadata: {...before.metadata, tag: 'Later edit', 'isLiveGame': true},
        );
        final preserved = rebaseBoardAfterSavedSnapshot(
          before: before,
          saved: saved,
          current: later,
        );
        expect(preserved.metadata[tag], 'Later edit');
        expect(preserved.metadata['isLiveGame'], isTrue);
        expect(
          shouldConfirmBoardAnalysisDiscard(
            dirtySinceLoad: true,
            currentPgn: exportGameToPgn(preserved),
            lastAppliedPgn: importedPgn,
            lastSavedAnalysisPgn: exportGameToPgn(saved),
          ),
          isTrue,
        );
      },
    );
  }

  testWidgets(
    'update action receives edited and explicitly cleared headers even after both sections collapse',
    semanticsEnabled: false,
    (tester) async {
      ChessGame? saved;
      await openSave(tester, onUpdate: (value) => saved = value);
      await tester.tap(find.text('GAME DETAILS'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Annotator and teams'));
      await tester.tap(find.text('Annotator and teams'));
      await tester.pumpAndSettle();
      await setField(tester, 'Annotator', 'New author');
      await setField(tester, 'WhiteTeam', 'New white club');
      await setField(tester, 'BlackTeam', '');
      await setField(tester, 'Source', 'New source');
      // The section collapses while one of its fields still has focus.
      final sourceField = tester.state<EditableTextState>(
        find.descendant(
          of: find.byKey(const ValueKey('pgn-Source')),
          matching: find.byType(EditableText),
        ),
      );
      expect(sourceField.widget.focusNode.hasFocus, isTrue);
      await tester.ensureVisible(find.text('Annotator and teams'));
      await tester.tap(find.text('Annotator and teams'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pgn-Source')), findsNothing);
      await tester.ensureVisible(find.text('GAME DETAILS'));
      await tester.tap(find.text('GAME DETAILS'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Update existing game'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.metadata['Annotator'], 'New author');
      expect(saved!.metadata['WhiteTeam'], 'New white club');
      expect(saved!.metadata.containsKey('BlackTeam'), isFalse);
      expect(saved!.metadata['Source'], 'New source');
      expect(saved!.mainline.first.clockTime, '0:00:59');
      expect(exportGameToPgn(saved!), contains('Original comment'));
    },
  );

  testWidgets(
    'untouched collapsed update preserves imported author and teams',
    (tester) async {
      ChessGame? saved;
      await openSave(tester, onUpdate: (value) => saved = value);
      await tester.tap(find.text('Update existing game'));
      await tester.pumpAndSettle();
      expect(saved!.metadata['Annotator'], 'Original author');
      expect(saved!.metadata['WhiteTeam'], 'White club');
      expect(saved!.metadata['BlackTeam'], 'Black club');
      expect(saved!.metadata['Source'], 'Original source');
    },
  );

  for (final confirm in [false, true]) {
    testWidgets(
      'PGN file metadata dialog ${confirm ? "confirms" : "cancels"} without mutating the input',
      semanticsEnabled: false,
      (tester) async {
        final original = ChessGame.fromPgn('fixture', importedPgn);
        final before = exportGameToPgn(original);
        ChessGame? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder:
                  (context) => TextButton(
                    onPressed:
                        () async =>
                            result = await showPgnAttributionDialog(
                              context,
                              original,
                            ),
                    child: const Text('Export'),
                  ),
            ),
          ),
        );
        await tester.tap(find.text('Export'));
        await tester.pumpAndSettle();
        expect(find.byType(FDialog), findsOneWidget);
        await tester.tap(find.text('Annotator and teams'));
        await tester.pumpAndSettle();
        await setField(tester, 'Annotator', 'File author');
        await setField(tester, 'BlackTeam', '');
        await tester.tap(find.text(confirm ? 'Choose file…' : 'Cancel'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(exportGameToPgn(original), before);
        if (confirm) {
          expect(result!.metadata['Annotator'], 'File author');
          expect(result!.metadata.containsKey('BlackTeam'), isFalse);
          final pgn = exportGameToPgn(result!);
          final current = rebaseBoardAfterSavedSnapshot(
            before: original,
            saved: result!,
            current: original,
          );
          expect(
            shouldConfirmBoardAnalysisDiscard(
              dirtySinceLoad: true,
              currentPgn: exportGameToPgn(current),
              lastAppliedPgn: before,
              lastSavedAnalysisPgn: pgn,
            ),
            isFalse,
          );
        } else {
          expect(result, isNull);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'single-game save exposes a collapsed attribution section with imported values',
    semanticsEnabled: false,
    (tester) async {
      await openSave(tester);
      await tester.tap(find.text('GAME DETAILS'));
      await tester.pumpAndSettle();
      expect(find.text('Annotator and teams'), findsOneWidget);
      expect(find.text('Annotator (author)'), findsNothing);
      await tester.ensureVisible(find.text('Annotator and teams'));
      await tester.tap(find.text('Annotator and teams'));
      await tester.pumpAndSettle();
      expect(find.text('Original author'), findsOneWidget);
      expect(find.text('White club'), findsOneWidget);
      expect(find.text('Black club'), findsOneWidget);
      expect(find.text('Original source'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
}
