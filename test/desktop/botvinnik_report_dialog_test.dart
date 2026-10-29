import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_report_dialog.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _account = 'account-a';
const _conversation = 'conversation-a';
const _message = 'assistant-a';
final _userProvider = StateProvider<AppUser?>(
  (_) => AppUser(id: _account, createdAt: DateTime.utc(2026)),
);

typedef _Target = ({String accountId, String conversationId, String messageId});

// Forui delays pressed/focus states without scheduling a frame. Drain those
// bounded timers as well as frame animations after real input events.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required BotvinnikReportCallback report,
  Widget? child,
  double textScale = 1,
  List<Override> overrides = const [],
}) async {
  final container = ProviderContainer(
    overrides: [
      currentUserProvider.overrideWith((ref) => ref.watch(_userProvider)),
      botvinnikReportCallbackProvider.overrideWithValue(report),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 600));
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder:
            (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: FTheme(data: FThemes.zinc.dark, child: child!),
            ),
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body:
              child ??
              const Center(
                child: BotvinnikReportAction(
                  accountId: _account,
                  conversationId: _conversation,
                  messageId: _message,
                ),
              ),
        ),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Report'));
  await _settle(tester);
  expect(
    find.text('Share this answer with ChessEver for safety review'),
    findsOneWidget,
  );
}

Finder get _confirm => find.byKey(const ValueKey('botvinnik-report-confirm'));
FButton _confirmButton(WidgetTester tester) => tester.widget<FButton>(
  find.descendant(of: _confirm, matching: find.byType(FButton)),
);

void main() {
  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    font.addFont(
      rootBundle.load('packages/forui/assets/fonts/inter/Inter-Regular.ttf'),
    );
    await font.load();
  });

  testWidgets('pointer opens confirmation; Cancel and Escape share nothing', (
    tester,
  ) async {
    var reports = 0;
    await _pump(
      tester,
      report: ({
        required accountId,
        required conversationId,
        required messageId,
      }) async {
        reports++;
      },
    );
    await _open(tester);
    expect(reports, 0);
    await tester.tap(find.text('Cancel'));
    await _settle(tester);
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byType(BotvinnikReportDialog), findsNothing);
    expect(reports, 0);
  });

  testWidgets(
    'keyboard opens and confirms the report; pending blocks duplicate clicks and Escape',
    (tester) async {
      final submitted = <_Target>[];
      final pending = Completer<void>();
      await _pump(
        tester,
        report: ({
          required accountId,
          required conversationId,
          required messageId,
        }) {
          submitted.add((
            accountId: accountId,
            conversationId: conversationId,
            messageId: messageId,
          ));
          return pending.future;
        },
      );
      Focus.of(tester.element(find.text('Report'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      Focus.of(
        tester.element(
          find.descendant(of: _confirm, matching: find.byType(Text)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(submitted, [
        (
          accountId: _account,
          conversationId: _conversation,
          messageId: _message,
        ),
      ]);
      expect(find.text('Reporting…'), findsOneWidget);
      expect(_confirmButton(tester).onPress, isNull);
      await tester.tap(_confirm);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(BotvinnikReportDialog), findsOneWidget);
      expect(submitted, hasLength(1));
      pending.complete();
      await _settle(tester);
      expect(find.textContaining('Private report diagnostics'), findsNothing);
      expect(
        find.text('Report sent to ChessEver for safety review.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await _settle(tester);
      expect(find.byType(BotvinnikReportDialog), findsNothing);
    },
  );

  testWidgets(
    'failed report stays visible and can retry without claiming success',
    (tester) async {
      var attempts = 0;
      await _pump(
        tester,
        report: ({
          required accountId,
          required conversationId,
          required messageId,
        }) async {
          attempts++;
          if (attempts == 1) throw StateError('private provider diagnostics');
        },
      );
      await _open(tester);
      await tester.tap(_confirm);
      await _settle(tester);
      expect(
        find.text(
          'Your report could not be confirmed. Check your connection and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private provider'), findsNothing);
      expect(
        find.text('Report sent to ChessEver for safety review.'),
        findsNothing,
      );
      expect(_confirmButton(tester).onPress, isNotNull);
      await tester.tap(_confirm);
      await _settle(tester);
      expect(attempts, 2);
      expect(
        find.text('Report sent to ChessEver for safety review.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('429 explains the daily UTC retry and disables resubmission', (
    tester,
  ) async {
    await _pump(
      tester,
      report: ({
        required accountId,
        required conversationId,
        required messageId,
      }) async {
        throw const ChatApiException('report_limit', statusCode: 429);
      },
    );
    await _open(tester);
    await tester.tap(_confirm);
    await _settle(tester);
    expect(
      find.text(
        'The daily report limit has been reached. Try again after 00:00 UTC.',
      ),
      findsOneWidget,
    );
    expect(_confirmButton(tester).onPress, isNull);
    expect(
      find.text('Report sent to ChessEver for safety review.'),
      findsNothing,
    );
  });

  testWidgets('account change before confirmation prevents submission', (
    tester,
  ) async {
    var reports = 0;
    final container = await _pump(
      tester,
      report: ({
        required accountId,
        required conversationId,
        required messageId,
      }) async {
        reports++;
      },
    );
    await _open(tester);
    container.read(_userProvider.notifier).state = AppUser(
      id: 'account-b',
      createdAt: DateTime.utc(2026),
    );
    await _settle(tester);
    expect(_confirm, findsNothing);
    expect(find.textContaining('Your account changed.'), findsOneWidget);
    expect(reports, 0);
  });

  for (final fails in [false, true]) {
    testWidgets(
      'a pending ${fails ? 'failure' : 'result'} cannot leak across account changes, even if the original account returns',
      (tester) async {
        final pending = Completer<void>();
        final container = await _pump(
          tester,
          report:
              ({
                required accountId,
                required conversationId,
                required messageId,
              }) => pending.future,
        );
        await _open(tester);
        await tester.tap(_confirm);
        await tester.pump();
        container.read(_userProvider.notifier).state = AppUser(
          id: 'account-b',
          createdAt: DateTime.utc(2026),
        );
        await tester.pump();
        container.read(_userProvider.notifier).state = AppUser(
          id: _account,
          createdAt: DateTime.utc(2026),
        );
        await tester.pump();
        if (fails) {
          pending.completeError(StateError('Private report diagnostics'));
        } else {
          pending.complete();
        }
        await _settle(tester);
        expect(find.textContaining('Private report diagnostics'), findsNothing);
        expect(
          find.text('Report sent to ChessEver for safety review.'),
          findsNothing,
        );
        expect(find.textContaining('Your account changed.'), findsOneWidget);
        expect(_confirm, findsNothing);
      },
    );
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'narrow dialog remains readable and clickable at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(360, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await _pump(
          tester,
          report:
              ({
                required accountId,
                required conversationId,
                required messageId,
              }) async {},
          textScale: scale,
          child: RepaintBoundary(
            key: boundary,
            child: const BotvinnikReportDialog(
              accountId: _account,
              conversationId: _conversation,
              messageId: _message,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(_confirm);
        await _settle(tester);
        expect(_confirm.hitTestable(), findsOneWidget);
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await render.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/chessever-botvinnik-report-${scale.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(_confirm);
        await _settle(tester);
        expect(
          find.text('Report sent to ChessEver for safety review.'),
          findsOneWidget,
        );
      },
    );
  }
}
