import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Library Home is permanently above the Cloud Library header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: buildLibraryFolderRailForTest())),
    );
    expect(find.text('Library Home'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.text('Library Home')).dy,
      lessThan(tester.getTopLeft(find.text('Cloud Library')).dy),
    );
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(find.text('ChessEver'), findsOneWidget);
    expect(find.text('My Likes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Home remains clickable while cloud folders are loading', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildLibraryFolderRailForTest(
            isLoading: true,
            homeSelected: false,
            onHome: () => activations++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Library Home'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(activations, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Home supports Tab then Enter and Space activation', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildLibraryFolderRailForTest(onHome: () => activations++),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activations, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(activations, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
