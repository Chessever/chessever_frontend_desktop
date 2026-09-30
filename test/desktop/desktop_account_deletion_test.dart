import 'dart:async';

import 'package:chessever/desktop/services/auth/desktop_account_deletion.dart';
import 'package:chessever/desktop/widgets/desktop_delete_account_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _Recorder {
  final steps = <String>[];
  final tracked = <({bool success, String? reason})>[];
  final reported = <Object>[];

  DesktopAccountDeletion build({
    Future<void> Function()? rpc,
    Future<void> Function()? clear,
    Future<void> Function()? signOut,
  }) {
    return DesktopAccountDeletion(
      signOutIdentityProviders: () async => steps.add('providers'),
      deleteRemoteAccount: () async {
        steps.add('rpc');
        await rpc?.call();
      },
      clearAllUserData: () async {
        steps.add('clear');
        await clear?.call();
      },
      signOutLocal: () async {
        steps.add('signOut');
        await signOut?.call();
      },
      trackResult: ({required bool success, String? reason}) {
        steps.add(success ? 'track:success' : 'track:failure');
        tracked.add((success: success, reason: reason));
      },
      reportError: (error, _) => reported.add(error),
    );
  }
}

Widget _host(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: FTheme(data: FThemes.zinc.dark, child: child),
      ),
    ),
  );
}

FButton _confirmButton(WidgetTester tester) {
  return tester.widget<FButton>(
    find.descendant(
      of: find.byKey(const ValueKey('desktop-delete-account-confirm')),
      matching: find.byType(FButton),
    ),
  );
}

FButton _cancelButton(WidgetTester tester) {
  return tester.widget<FButton>(
    find.ancestor(of: find.text('Cancel'), matching: find.byType(FButton)),
  );
}

void main() {
  group('DesktopAccountDeletion', () {
    test('follows the phone order on success', () async {
      final recorder = _Recorder();
      await recorder.build().run();
      expect(recorder.steps, [
        'providers',
        'rpc',
        'track:success',
        'clear',
        'signOut',
      ]);
      expect(recorder.reported, isEmpty);
    });

    test('a failed RPC still clears local data, signs out, and surfaces '
        'safe copy', () async {
      final recorder = _Recorder();
      final deletion = recorder.build(
        rpc: () async => throw Exception(
          'PostgrestException(message: permission denied for table users)',
        ),
      );

      await expectLater(
        deletion.run(),
        throwsA(
          isA<DesktopAccountDeletionException>().having(
            (e) => e.message,
            'message',
            allOf(
              isNotEmpty,
              isNot(contains('Postgrest')),
              isNot(contains('permission denied')),
            ),
          ),
        ),
      );
      expect(recorder.steps, [
        'providers',
        'rpc',
        'track:failure',
        'clear',
        'signOut',
      ]);
      expect(recorder.tracked.single.success, isFalse);
      expect(recorder.reported, hasLength(1));
    });

    test('local cleanup failures never block the remaining steps', () async {
      final recorder = _Recorder();
      await recorder
          .build(clear: () async => throw StateError('prefs unavailable'))
          .run();
      expect(recorder.steps.last, 'signOut');
      expect(recorder.reported.single, isA<StateError>());
    });

    test('messages classify failures without leaking raw text', () {
      expect(
        desktopAccountDeletionMessage(TimeoutException('rpc')),
        contains('timed out'),
      );
      expect(
        desktopAccountDeletionMessage(Exception('SocketException: failed host lookup')),
        contains('No internet'),
      );
      expect(
        desktopAccountDeletionMessage(Exception('Not authenticated')),
        contains('session'),
      );
    });
  });

  group('DesktopDeleteAccountDialogBody', () {
    testWidgets('Delete stays disabled until the consequences are '
        'acknowledged', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _host(
          DesktopDeleteAccountDialogBody(
            email: 'player@example.com',
            onDelete: () async => calls++,
          ),
        ),
      );

      expect(find.text('player@example.com'), findsNothing);
      expect(find.textContaining('player@example.com'), findsOneWidget);
      expect(_confirmButton(tester).onPress, isNull);

      await tester.tap(find.text('I understand the consequences'));
      await tester.pump();
      expect(_confirmButton(tester).onPress, isNotNull);

      await tester.tap(find.byKey(const ValueKey('desktop-delete-account-confirm')));
      await tester.pump();
      expect(calls, 1);
      // Let forui press and hover timers finish before the tree is torn down.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Cancel is disabled while deleting and a failure renders '
        'inline', (tester) async {
      final pending = Completer<void>();
      await tester.pumpWidget(
        _host(DesktopDeleteAccountDialogBody(onDelete: () => pending.future)),
      );

      await tester.tap(find.text('I understand the consequences'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('desktop-delete-account-confirm')));
      await tester.pump();

      expect(find.text('Deleting'), findsOneWidget);
      expect(_cancelButton(tester).onPress, isNull);
      expect(_confirmButton(tester).onPress, isNull);

      pending.completeError(
        const DesktopAccountDeletionException('Could not delete your account.'),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not delete your account.'), findsOneWidget);
      expect(_cancelButton(tester).onPress, isNotNull);
      expect(_confirmButton(tester).onPress, isNotNull);
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
