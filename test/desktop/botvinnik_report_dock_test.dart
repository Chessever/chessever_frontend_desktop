import 'dart:async';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/state/botvinnik_chat.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_dock.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_report_dialog.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:flutter/material.dart';
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
        builder: (_, child) => FTheme(data: FThemes.zinc.dark, child: child!),
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
}

Finder get _confirm => find.byKey(const ValueKey('botvinnik-report-confirm'));

class _Backend implements BotvinnikChatBackend {
  final feedback = <String?>[];
  Completer<List<ChatMessage>>? nextMessages;
  final conversation = ChatConversation(
    id: _conversation,
    title: 'Saved chat',
    locale: 'en',
    updatedAt: DateTime.utc(2026),
  );
  final answers = const [
    ChatMessage(id: 'user-a', role: 'user', content: 'A chess question'),
    ChatMessage(
      id: 'local-assistant',
      role: 'assistant',
      content: 'Temporary answer',
    ),
    ChatMessage(
      id: _message,
      role: 'assistant',
      content: 'A saved chess answer',
    ),
  ];
  @override
  bool get hasPermanentSession => true;
  @override
  Future<List<ChatConversation>> conversations() async => [conversation];
  @override
  Future<List<ChatMessage>> messages(String conversationId) =>
      nextMessages?.future ?? Future.value(answers);
  @override
  Future<ChatMessage> setMessageFeedback({
    required String conversationId,
    required String messageId,
    required String? feedback,
  }) async {
    this.feedback.add(feedback);
    return answers.last.withFeedback(feedback);
  }

  @override
  Future<ChatConversation> createConversation({
    required String locale,
    String? title,
  }) => throw UnimplementedError();
  @override
  Future<void> deleteConversation(String id) => throw UnimplementedError();
  @override
  Stream<ChatStreamEvent> send({
    required String conversationId,
    required String content,
    required String locale,
    required String timezone,
    required ChatClientContext clientContext,
    ChatScreenContext? screenContext,
  }) => throw UnimplementedError();
  @override
  void close() {}
}

class _Quota extends BotvinnikQuotaNotifier {
  @override
  Future<ChatQuotaStatus?> build() async => const ChatQuotaStatus(
    limit: 0,
    used: 0,
    remaining: 0,
    isPremium: false,
    resetsAt: null,
  );
}

class _QuotaSink implements BotvinnikQuotaSink {
  @override
  ChatQuotaStatus? get current => null;
  @override
  void set(ChatQuotaStatus quota) {}
  @override
  Future<void> refresh() async {}
}

void main() {
  testWidgets(
    'dock reports only saved assistant answers and preserves distinct dislike feedback',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = _Backend();
      final submitted = <_Target>[];
      final container = await _pump(
        tester,
        report: ({
          required accountId,
          required conversationId,
          required messageId,
        }) async {
          submitted.add((
            accountId: accountId,
            conversationId: conversationId,
            messageId: messageId,
          ));
        },
        child: const Align(
          alignment: Alignment.centerRight,
          child: SizedBox(width: 420, child: BotvinnikDock()),
        ),
        overrides: [
          botvinnikChatBackendProvider.overrideWithValue(backend),
          botvinnikQuotaProvider.overrideWith(_Quota.new),
          botvinnikChatControllerProvider.overrideWith(
            (ref) => BotvinnikChatController(
              backend: backend,
              quota: _QuotaSink(),
              locale: () => 'en',
              aiConsentGranted: () async => true,
            ),
          ),
        ],
      );
      expect(find.byType(BotvinnikReportAction), findsOneWidget);
      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
      await _settle(tester);
      expect(backend.feedback, ['dislike']);
      expect(submitted, isEmpty);
      await _open(tester);
      final history = Completer<List<ChatMessage>>();
      backend.nextMessages = history;
      final selection = container
          .read(botvinnikChatControllerProvider.notifier)
          .select(
            ChatConversation(
              id: 'conversation-b',
              title: 'Another chat',
              locale: 'en',
              updatedAt: DateTime.utc(2026),
            ),
          );
      await _settle(tester);
      expect(find.byType(BotvinnikReportAction), findsNothing);
      await tester.tap(_confirm);
      await _settle(tester);
      expect(submitted, [
        (
          accountId: _account,
          conversationId: _conversation,
          messageId: _message,
        ),
      ]);
      expect(backend.feedback, ['dislike']);
      history.complete(const [
        ChatMessage(
          id: 'assistant-b',
          role: 'assistant',
          content: 'Another answer',
        ),
      ]);
      await selection;
      await _settle(tester);
    },
  );
}
