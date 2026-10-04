import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/widgets/library/library_publish_button.dart';
import 'package:chessever/repository/library/models/library_folder.dart';

LibraryFolder _folder({bool subscribed = false, bool liked = false}) =>
    LibraryFolder(
      id: 'folder-id',
      userId: 'owner',
      name: 'Sicilian studies',
      color: '#000000',
      icon: 'folder',
      orderIndex: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      isSubscribed: subscribed,
      isLikedGames: liked,
    );

Future<List<LibraryFolder>> _pump(
  WidgetTester tester,
  LibraryFolder? folder,
) async {
  final published = <LibraryFolder>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: LibraryPublishButton(folder: folder, onPublish: published.add),
        ),
      ),
    ),
  );
  return published;
}

void main() {
  testWidgets('an own cloud folder is published by one press', (tester) async {
    final folder = _folder();
    final published = await _pump(tester, folder);
    expect(find.text('Publish'), findsOneWidget);
    await tester.tap(find.text('Publish'));
    await tester.pump(const Duration(seconds: 1));
    expect(published, [folder]);
  });

  testWidgets('with nothing to publish the button stays, and does nothing', (
    tester,
  ) async {
    for (final folder in [
      null,
      _folder(subscribed: true),
      _folder(liked: true),
    ]) {
      final published = await _pump(tester, folder);
      // Still on screen: the feature is findable before a folder is chosen.
      expect(find.text('Publish'), findsOneWidget);
      await tester.tap(find.text('Publish'), warnIfMissed: false);
      await tester.pump(const Duration(seconds: 1));
      expect(published, isEmpty);
    }
  });

  testWidgets('a narrow toolbar keeps the action as an icon', (tester) async {
    final folder = _folder();
    final published = <LibraryFolder>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LibraryPublishButton(
              folder: folder,
              onPublish: published.add,
              compact: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Publish'), findsNothing);
    await tester.tap(find.byIcon(Icons.publish_rounded));
    await tester.pump(const Duration(seconds: 1));
    expect(published, [folder]);
  });

  test('the hover text says what a press does, or why it cannot', () {
    expect(
      libraryPublishButtonTooltip(null),
      'Select one of your cloud folders or databases to publish it as a '
      'collection.',
    );
    expect(
      libraryPublishButtonTooltip(_folder()),
      'Publish "Sicilian studies" as a collection, or edit what is published.',
    );
    expect(
      libraryPublishButtonTooltip(_folder(subscribed: true)),
      contains('belongs to someone else'),
    );
    expect(
      libraryPublishButtonTooltip(_folder(liked: true)),
      contains('cannot be published'),
    );
  });
}
