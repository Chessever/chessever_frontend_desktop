import 'package:chessever/desktop/services/library_pgn_import_picker.dart';
import 'package:chessever/desktop/services/web_file_intake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('companions must match the selected name and directory', () {
    final incomplete = missingWebCbhCompanions([
      'A/GGGG.cbh',
      'A/gggg.CBP',
      'A/GGGG.cbt',
      'A/GGGG.cbc',
      'A/GGGG.cbs',
      'A/GGGG.cbg',
      'B/GGGG.cba',
      'A/GOTW.cba',
    ]);
    expect(incomplete.single.indexName, 'GGGG.cbh');
    expect(incomplete.single.missingNames, ['GGGG.cba']);
  });

  test('complete CBH, standalone CBV and PGN need no warning', () {
    expect(
      missingWebCbhCompanions([
        for (final ext in ['cbh', 'cbp', 'cbt', 'cbc', 'cbs', 'cbg', 'cba'])
          'GOTW.$ext',
        'Archive.cbv',
        'Games.pgn',
      ]),
      isEmpty,
    );
  });

  for (final retry in [true, false]) {
    testWidgets('shows missing filenames before conversion; retry=$retry', (
      tester,
    ) async {
      var picks = 0;
      List<String>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Center(
                child: GestureDetector(
                  onTap: () async {
                    result = await pickLibraryPgnDatabasePathsWithRecovery(
                      context,
                      pick: () async {
                        if (++picks == 1) {
                          throw WebCbhSelectionIncomplete(
                            missingWebCbhCompanions(['GGGG.cbh', 'GGGG.cbp']),
                          );
                        }
                        return ['GGGG.cbh'];
                      },
                    );
                  },
                  child: const Text('Import'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(find.text('Select all files for GGGG'), findsOneWidget);
      expect(find.textContaining('GGGG.cba'), findsOneWidget);
      expect(find.textContaining('GGGG.cbp'), findsNothing);
      expect(find.text('Convert & Open'), findsNothing);
      await tester.tap(find.text(retry ? 'Select files again' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(picks, retry ? 2 : 1);
      expect(result, retry ? ['GGGG.cbh'] : null);
    });
  }
}
