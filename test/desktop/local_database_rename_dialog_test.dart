import 'package:chessever/desktop/widgets/desktop_dialog.dart';
import 'package:chessever/desktop/widgets/library/local_database_rename_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collision stays in the dialog and Cancel makes no change', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      TextButton(onPressed: () => showDesktopDialog<String>(context,
        child: LocalDatabaseRenameDialog(path: 'database.pgn',
          onRename: (_) async { attempts++; throw const FormatException('A database with this filename already exists.'); })),
        child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'existing');
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    expect(find.text('A database with this filename already exists.'), findsOneWidget);
    expect(find.byType(LocalDatabaseRenameDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.byType(LocalDatabaseRenameDialog), findsNothing);
  });

  testWidgets('cancel does not rename; submit passes the chosen name', (
    tester,
  ) async {
    final names = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder:
              (context) => TextButton(
                onPressed:
                    () => showDesktopDialog<String>(
                      context,
                      child: LocalDatabaseRenameDialog(
                        path: 'database.pgn',
                        onRename: (name) async {
                          names.add(name);
                          return '$name.pgn';
                        },
                      ),
                    ),
                child: const Text('Open'),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'savio');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(names, isEmpty);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'Savio Games');
    await tester.tap(find.text('Rename').last);
    await tester.pumpAndSettle();
    expect(names, ['Savio Games']);
  });
}
