import 'package:chessever/desktop/services/local_pgn_source_recovery.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

/// Regression guard for the actionable failure toast: a local database row that
/// cannot be opened must offer the refresh action instead of only printing an
/// error string.
void main() {
  Future<void> pumpToastHost(
    WidgetTester tester, {
    required void Function(BuildContext context) onShow,
  }) async {
    await tester.pumpWidget(
      FTheme(
        data: FThemes.zinc.dark,
        child: FToaster(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => onShow(context),
                  child: const Text('show'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('an action toast renders its label and runs the action',
      (tester) async {
    var refreshed = 0;
    await pumpToastHost(
      tester,
      onShow: (context) => showDesktopToast(
        context,
        'That game is no longer in Lesson Plans.pgn.',
        error: true,
        actionLabel: 'Refresh',
        onAction: () => refreshed++,
      ),
    );

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('That game is no longer in Lesson Plans.pgn.'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(refreshed, 0);

    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(refreshed, 1);

    // Flush forui's hover and auto-dismiss timers so teardown sees no pending
    // Timer. In production the FToaster outlives every toast.
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a plain toast adds no action affordance', (tester) async {
    await pumpToastHost(
      tester,
      onShow: (context) => showDesktopToast(context, 'Database refreshed.'),
    );

    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Database refreshed.'), findsOneWidget);
    expect(find.text('Refresh'), findsNothing);
  });

  test('recovery failures always carry human wording', () {
    const failure = LocalPgnGameUnavailableException(
      sourcePath: r'C:\Users\User\Desktop\Lesson Plans\Francis Prep.pgn',
      failure: LocalPgnRecoveryFailure.gameMissing,
    );
    expect(failure.toString(), contains('Francis Prep.pgn'));
    expect(failure.toString(), isNot(contains('Bad state')));
    expect(
      localPgnOpenErrorMessage(failure),
      contains('Francis Prep.pgn'),
    );
  });
}
