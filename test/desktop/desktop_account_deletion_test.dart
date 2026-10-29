import 'dart:async';
import 'dart:convert';

import 'package:chessever/desktop/services/auth/desktop_account_deletion.dart';
import 'package:chessever/desktop/widgets/desktop_delete_account_dialog.dart';
import 'package:chessever/repository/local_storage/local_storage_repository.dart';
import 'package:flutter/services.dart';
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
        return const DesktopAccountDeletionResult();
      },
      clearAccountData: () async {
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

Widget _host(Widget child, {DesktopAccountDeletion? deletion}) {
  return ProviderScope(
    overrides: [
      if (deletion != null)
        desktopAccountDeletionProvider.overrideWithValue(deletion),
    ],
    child: MaterialApp(
      home: Scaffold(body: FTheme(data: FThemes.zinc.dark, child: child)),
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
  for (final guest in [false, true]) {
    testWidgets(
      'quiet ${guest ? "guest" : "permanent"} deletion action supports pointer and keyboard',
      (tester) async {
        var clicks = 0;
        await tester.pumpWidget(
          _host(
            DesktopDeleteAccountAction(isGuest: guest, onPress: () => clicks++),
          ),
        );
        final label = guest ? 'Delete guest account' : 'Delete account';
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(clicks, 1);
        Focus.of(tester.element(find.text(label))).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(clicks, 2);
      },
    );
  }
  group('DesktopAccountDeletion', () {
    test(
      'cleanup preserves another account and unrelated install preferences',
      () async {
        SharedPreferences.setMockInitialValues({
          'supabase_user': jsonEncode({'id': 'account-a'}),
          'supabase_session': jsonEncode({
            'user': {'id': 'account-b'},
          }),
          'botvinnik_ai_sharing_v1_account-a': true,
          'botvinnik_ai_sharing_v1_account-b': true,
          'guest_session_started_at_ms': 100,
          'board_theme': 'classic',
        });
        final prefs = await SharedPreferences.getInstance();
        await clearDesktopDeletedAccountPreferences(
          prefs: prefs,
          accountId: 'account-a',
          isCurrentAccount: () => false,
          isGuest: true,
        );
        expect(prefs.getString('supabase_user'), isNull);
        expect(prefs.getString('supabase_session'), contains('account-b'));
        expect(prefs.getBool('botvinnik_ai_sharing_v1_account-b'), isTrue);
        expect(prefs.containsKey('botvinnik_ai_sharing_v1_account-a'), isFalse);
        expect(prefs.getInt('guest_session_started_at_ms'), 100);
        expect(prefs.getString('board_theme'), 'classic');
      },
    );

    test(
      'a later sign-in cannot be wiped by queued old-account cleanup',
      () async {
        SharedPreferences.setMockInitialValues({
          'supabase_user': jsonEncode({'id': 'account-a'}),
        });
        final prefs = await SharedPreferences.getInstance();
        final pending = clearDesktopDeletedAccountPreferences(
          prefs: prefs,
          accountId: 'account-a',
          isCurrentAccount: () => true,
        );
        await prefs.setString('supabase_user', jsonEncode({'id': 'account-b'}));
        await pending;
        expect(prefs.getString('supabase_user'), contains('account-b'));
      },
    );
    test(
      'deletion clears its own data without signing out a different account',
      () async {
        var current = true;
        var cleared = false;
        var signedOut = false;
        final deletion = DesktopAccountDeletion(
          isCurrentAccount: () => current,
          deleteRemoteAccount: () async {
            current = false;
            return const DesktopAccountDeletionResult();
          },
          clearAccountData: () async => cleared = true,
          signOutLocal: () async => signedOut = true,
        );
        await deletion.run();
        expect(cleared, isTrue);
        expect(signedOut, isFalse);
      },
    );

    test(
      'a guest keeps its session and data when remote deletion fails',
      () async {
        var cleared = false;
        var signedOut = false;
        final deletion = DesktopAccountDeletion(
          deleteRemoteAccount: () async => throw StateError('offline'),
          clearAccountData: () async => cleared = true,
          signOutLocal: () async => signedOut = true,
        );
        await expectLater(
          deletion.run(),
          throwsA(isA<DesktopAccountDeletionException>()),
        );
        expect(cleared, isFalse);
        expect(signedOut, isFalse);
      },
    );
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

    test('a failed request retains local data and session, and surfaces '
        'safe copy', () async {
      final recorder = _Recorder();
      final deletion = recorder.build(
        rpc:
            () async =>
                throw Exception(
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
      expect(recorder.steps, ['providers', 'rpc', 'track:failure']);
      expect(recorder.tracked.single.success, isFalse);
      expect(recorder.reported, hasLength(1));
    });

    test('a new sign-in during cleanup is never signed out', () async {
      final clearing = Completer<void>();
      var current = true;
      var signedOut = false;
      final deletion = DesktopAccountDeletion(
        isCurrentAccount: () => current,
        deleteRemoteAccount: () async => const DesktopAccountDeletionResult(),
        clearAccountData: () => clearing.future,
        signOutLocal: () async => signedOut = true,
      );
      final pending = deletion.run();
      await pumpEventQueue();
      current = false;
      clearing.complete();
      await pending;
      expect(signedOut, isFalse);
    });

    test('only explicit deletion confirmation is accepted', () {
      for (final response in [
        null,
        <String, Object>{},
        {'deleted': false},
        {'deleted': true},
      ]) {
        expect(
          () => DesktopAccountDeletionResult.fromResponse(response),
          throwsA(isA<DesktopAccountDeletionException>()),
        );
      }
      final result = DesktopAccountDeletionResult.fromResponse({
        'deleted': true,
        'apple_manual_revoke_required': false,
        'apple_revocation_pending': true,
        'data_removal_pending': true,
      });
      expect(result.appleRevocationPending, isTrue);
      expect(result.dataRemovalPending, isTrue);
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
        desktopAccountDeletionMessage(
          Exception('SocketException: failed host lookup'),
        ),
        contains('No internet'),
      );
      expect(
        desktopAccountDeletionMessage(Exception('Not authenticated')),
        contains('session'),
      );
    });
  });

  group('DesktopDeleteAccountDialogBody', () {
    for (final pending in [false, true]) {
      testWidgets(
        'server-confirmed Apple ${pending ? "pending" : "revoked"} status is shown accurately',
        (tester) async {
          final service = DesktopAccountDeletion(
            deleteRemoteAccount:
                () async => DesktopAccountDeletionResult(
                  appleRevocationPending: pending,
                  dataRemovalPending: pending,
                ),
            clearAccountData: () async {},
            signOutLocal: () async {},
          );
          await tester.pumpWidget(
            _host(
              const DesktopDeleteAccountDialogBody(usesApple: true),
              deletion: service,
            ),
          );
          await tester.tap(find.byType(FCheckbox));
          await tester.pump();
          await tester.tap(
            find.byKey(const ValueKey('desktop-delete-account-confirm')),
          );
          await tester.pumpAndSettle();
          expect(
            find.textContaining('queued for automatic removal'),
            pending ? findsOneWidget : findsNothing,
          );
          expect(
            find.textContaining('Some associated service data'),
            pending ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('Open Apple Account'),
            pending ? findsOneWidget : findsNothing,
          );
          expect(
            find.textContaining('remaining Sign in with Apple connection'),
            pending ? findsOneWidget : findsNothing,
          );
        },
      );
    }
    testWidgets('warns about continuing Apple billing before deletion', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(DesktopDeleteAccountDialogBody(onDelete: () async {})),
      );
      expect(find.textContaining('billing continues'), findsOneWidget);
      expect(find.text('Manage Apple subscriptions'), findsOneWidget);
      expect(_confirmButton(tester).onPress, isNull);
    });

    testWidgets(
      'Apple deletion succeeds before manual disconnection is offered',
      (tester) async {
        var deleted = false;
        await tester.pumpWidget(
          _host(
            DesktopDeleteAccountDialogBody(
              usesApple: true,
              onDelete: () async => deleted = true,
            ),
          ),
        );
        expect(find.text('Open Apple Account'), findsNothing);
        await tester.tap(find.text('I understand the consequences'));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('desktop-delete-account-confirm')),
        );
        await tester.pumpAndSettle();
        expect(deleted, isTrue);
        expect(
          find.text('Your ChessEver account has been deleted.'),
          findsOneWidget,
        );
        expect(find.text('Open Apple Account'), findsOneWidget);
        expect(find.text('Done'), findsOneWidget);
      },
    );

    testWidgets(
      'guest confirmation names the guest and has no billing action',
      (tester) async {
        await tester.pumpWidget(
          _host(
            DesktopDeleteAccountDialogBody(
              isGuest: true,
              onDelete: () async {},
            ),
          ),
        );
        expect(find.textContaining('your guest account'), findsOneWidget);
        expect(find.text('Manage Apple subscriptions'), findsNothing);
      },
    );
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

      await tester.tap(
        find.byKey(const ValueKey('desktop-delete-account-confirm')),
      );
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
      await tester.tap(
        find.byKey(const ValueKey('desktop-delete-account-confirm')),
      );
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
