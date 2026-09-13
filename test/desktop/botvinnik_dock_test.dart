import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/shell/desktop_main_routes.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/chat/chat_references.dart';
import 'package:chessever/desktop/state/botvinnik_chat.dart';
import 'package:chessever/desktop/state/botvinnik_dock.dart';
import 'package:chessever/desktop/state/botvinnik_reference_router.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_dock.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Allowance fixtures; the copy must echo whatever the API sends.
const Map<String, dynamic> _freeFixture = {
  'limit': 37,
  'used': 12,
  'remaining': 25,
  'isPremium': false,
};
const Map<String, dynamic> _premiumFixture = {
  'limit': 91,
  'used': 8,
  'remaining': 83,
  'isPremium': true,
};
const Map<String, dynamic> _freeExhaustedFixture = {
  'limit': 37,
  'used': 37,
  'remaining': 0,
  'isPremium': false,
};
const Map<String, dynamic> _premiumExhaustedFixture = {
  'limit': 91,
  'used': 91,
  'remaining': 0,
  'isPremium': true,
};
const Map<String, dynamic> _upgradeFixture = {
  'limit': 0,
  'used': 0,
  'remaining': 0,
  'isPremium': false,
};

ChatQuotaStatus _quota(Map<String, dynamic> json) =>
    ChatQuotaStatus.fromJson(json);

/// Copy under test uses no-break spaces to control wrapping; compare words.
String _words(String? text) => (text ?? '').replaceAll('\u00A0', ' ');

class _DockBackend implements BotvinnikChatBackend {
  @override
  bool hasPermanentSession = true;
  final List<ChatConversation> chats = [];
  int deletes = 0;
  int sends = 0;

  @override
  Future<List<ChatConversation>> conversations() async => List.of(chats);

  @override
  Future<List<ChatMessage>> messages(String conversationId) async => const [];

  @override
  Future<ChatConversation> createConversation({
    required String locale,
    String? title,
  }) async => ChatConversation(
    id: 'created',
    title: title ?? 'New chat',
    locale: locale,
    updatedAt: DateTime.utc(2026, 9, 12),
  );

  @override
  Future<void> deleteConversation(String id) async {
    deletes++;
    chats.removeWhere((chat) => chat.id == id);
  }

  @override
  Future<ChatMessage> setMessageFeedback({
    required String conversationId,
    required String messageId,
    required String? feedback,
  }) => throw UnimplementedError();

  @override
  Stream<ChatStreamEvent> send({
    required String conversationId,
    required String content,
    required String locale,
    required String timezone,
    required ChatClientContext clientContext,
    ChatScreenContext? screenContext,
  }) {
    sends++;
    return const Stream.empty();
  }

  @override
  void close() {}
}

class _FixedQuota extends BotvinnikQuotaNotifier {
  _FixedQuota(this.value);

  final ChatQuotaStatus value;

  @override
  Future<ChatQuotaStatus?> build() async => value;
}

class _ContainerQuotaSink implements BotvinnikQuotaSink {
  const _ContainerQuotaSink(this.ref);

  final Ref ref;

  @override
  ChatQuotaStatus? get current => ref.read(botvinnikQuotaProvider).valueOrNull;

  @override
  void set(ChatQuotaStatus quota) {}

  @override
  Future<void> refresh() async {}
}

Future<ProviderContainer> _pumpDock(
  WidgetTester tester, {
  required _DockBackend backend,
  required ChatQuotaStatus quota,
  bool history = false,
}) async {
  tester.view.physicalSize = const Size(1000, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      botvinnikChatBackendProvider.overrideWithValue(backend),
      currentUserProvider.overrideWithValue(
        AppUser(id: 'user-1', createdAt: DateTime.utc(2026)),
      ),
      botvinnikQuotaProvider.overrideWith(() => _FixedQuota(quota)),
      botvinnikChatControllerProvider.overrideWith(
        (ref) => BotvinnikChatController(
          backend: backend,
          quota: _ContainerQuotaSink(ref),
          locale: () => 'en',
          clientContext:
              () => const ChatClientContext(
                platform: 'macos',
                surface: 'desktop',
                formFactor: 'desktop',
              ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(botvinnikDockProvider.notifier)
    ..open()
    ..showHistory(history);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder:
            (context, child) => FTheme(data: FThemes.zinc.dark, child: child!),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: 420, child: BotvinnikDock()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('allowance copy', () {
    test('free and premium lines render the API numbers', () {
      expect(
        botvinnikAllowanceSpan(_quota(_freeFixture)).toPlainText(),
        '25 of 37 messages left today',
      );
      expect(
        botvinnikAllowanceSpan(_quota(_premiumFixture)).toPlainText(),
        'Premium: 83 of 91 messages left today',
      );
    });

    test('exhausted and upgrade-required lines are distinct', () {
      final exhausted =
          botvinnikAllowanceSpan(_quota(_freeExhaustedFixture)).toPlainText();
      final upgrade =
          botvinnikAllowanceSpan(_quota(_upgradeFixture)).toPlainText();
      expect(exhausted, 'No messages left today');
      expect(
        botvinnikAllowanceSpan(_quota(_premiumExhaustedFixture)).toPlainText(),
        'No Premium messages left today',
      );
      expect(upgrade, isNot(exhausted));
      expect(upgrade, contains('not in your plan'));
    });

    test('composer notices differ for each gate and name the limit', () {
      final now = DateTime(2026, 9, 12, 10);
      final signedOut = botvinnikComposerNotice(
        ChatComposerAccess.signedOut,
        null,
        now,
      );
      final free = botvinnikComposerNotice(
        ChatComposerAccess.exhausted,
        _quota(_freeExhaustedFixture),
        now,
      );
      final premium = botvinnikComposerNotice(
        ChatComposerAccess.exhausted,
        _quota(_premiumExhaustedFixture),
        now,
      );
      final upgrade = botvinnikComposerNotice(
        ChatComposerAccess.upgradeRequired,
        _quota(_upgradeFixture),
        now,
      );

      expect(
        botvinnikComposerNotice(ChatComposerAccess.enabled, null, now),
        isNull,
      );
      expect(signedOut, contains('draft stays'));
      expect(free, contains('all 37 messages'));
      expect(premium, contains('all 91 Premium messages'));
      expect(_words(upgrade), 'Premium adds a daily Botvinnik allowance.');
      // The header states the plan has no messages; the notice must not say
      // it again.
      expect(upgrade, isNot(contains('no Botvinnik messages')));
      expect({signedOut, free, premium, upgrade}, hasLength(4));
      for (final copy in [signedOut, free, premium, upgrade]) {
        expect(copy, isNot(contains('—')));
      }
    });

    test('the exhausted notice says when sending opens, time kept whole', () {
      final now = DateTime(2026, 9, 12, 10);
      final free = botvinnikComposerNotice(
        ChatComposerAccess.exhausted,
        ChatQuotaStatus(
          limit: 37,
          used: 37,
          remaining: 0,
          isPremium: false,
          resetsAt: DateTime(2026, 9, 12, 23, 30),
        ),
        now,
      );
      expect(
        _words(free),
        'You have used all 37 messages for today. '
        'Sending opens again at 23:30.',
      );
      expect(free, contains('at\u00A023:30.'));
      expect(
        _words(botvinnikSendingOpensAgain(DateTime(2026, 9, 13, 0, 0), now)),
        'Sending opens again tomorrow at 00:00.',
      );
      expect(
        _words(botvinnikSendingOpensAgain(DateTime(2026, 9, 20, 9), now)),
        'Sending opens again on Sep 20.',
      );
    });

    test('reset labels read in local time', () {
      final now = DateTime(2026, 9, 12, 10);
      expect(
        botvinnikResetLabel(DateTime(2026, 9, 12, 23, 30), now),
        'Resets 23:30',
      );
      expect(
        botvinnikResetLabel(DateTime(2026, 9, 13, 0, 0), now),
        'Resets tomorrow 00:00',
      );
    });
  });

  group('launch contexts', () {
    test('home launch identifies the home screen', () {
      expect(botvinnikHomeScreenContext.toJson(), {
        'schemaVersion': 1,
        'screen': 'home',
      });
    });

    test('tournament launch carries event and selected tour', () {
      final context = botvinnikTournamentScreenContext(
        eventId: 'group-1',
        eventName: 'Norway Chess 2026',
        tournamentId: 'tour-open',
        tournamentName: 'Open',
      );
      expect(context.toJson(), {
        'schemaVersion': 1,
        'screen': 'tournament',
        'eventId': 'group-1',
        'eventName': 'Norway Chess 2026',
        'tournamentId': 'tour-open',
        'tournamentName': 'Open',
      });
      expect(
        botvinnikTournamentScreenContext(
          eventId: 'group-1',
          eventName: 'Norway Chess 2026',
          tournamentId: '',
          tournamentName: ' ',
        ).toJson(),
        isNot(contains('tournamentId')),
      );
    });

    test('player launch prefers FIDE, then gamebase, then memorial id', () {
      expect(
        botvinnikPlayerScreenContext(
          playerName: 'Carlsen, Magnus',
          fideId: 1503014,
          gamebasePlayerId: 'gb-9',
        ).playerId,
        '1503014',
      );
      expect(
        botvinnikPlayerScreenContext(
          playerName: 'Tal, Mikhail',
          fideId: 0,
          gamebasePlayerId: 'gb-9',
          memorialRouteId: 'tal',
        ).playerId,
        'gb-9',
      );
      expect(
        botvinnikPlayerScreenContext(
          playerName: 'Tal, Mikhail',
          memorialRouteId: 'tal',
        ).playerId,
        'tal',
      );
    });

    test('the empty state names the launch subject', () {
      expect(botvinnikContextSubject(null), isNull);
      expect(
        botvinnikContextSubject(
          botvinnikPlayerScreenContext(playerName: 'Ju Wenjun'),
        ),
        'Ju Wenjun',
      );
    });

    test('a tournament launch names the event, then the category', () {
      String? subject(String? tournamentName) => botvinnikContextSubject(
        botvinnikTournamentScreenContext(
          eventId: 'group-1',
          eventName: 'Norway Chess 2026',
          tournamentId: tournamentName == null ? null : 'tour-1',
          tournamentName: tournamentName,
        ),
      );
      expect(subject('Norway Chess 2026 | Women'), 'Norway Chess 2026, Women');
      expect(subject('Open'), 'Norway Chess 2026, Open');
      expect(subject('Norway Chess 2026'), 'Norway Chess 2026');
      expect(subject(null), 'Norway Chess 2026');
    });
  });

  group('gates', () {
    test('suggestion rows never promise a send the account cannot make', () {
      expect(
        botvinnikSuggestionAction(ChatComposerAccess.enabled),
        BotvinnikSuggestionAction.send,
      );
      // Signed out keeps the prompt as a draft for after sign-in.
      expect(
        botvinnikSuggestionAction(ChatComposerAccess.signedOut),
        BotvinnikSuggestionAction.send,
      );
      expect(
        botvinnikSuggestionAction(ChatComposerAccess.upgradeRequired),
        BotvinnikSuggestionAction.openPlans,
      );
      expect(
        botvinnikSuggestionAction(ChatComposerAccess.exhausted),
        BotvinnikSuggestionAction.disabled,
      );
    });

    testWidgets('an exhausted allowance mutes suggestions and keeps the draft', (
      tester,
    ) async {
      final backend = _DockBackend();
      final container = await _pumpDock(
        tester,
        backend: backend,
        quota: _quota(_freeExhaustedFixture),
      );
      final chat = container.read(botvinnikChatControllerProvider.notifier);
      chat.draft.text = 'My own question';
      await tester.pump();

      await tester.tap(find.text('Live games'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(chat.draft.text, 'My own question');
      expect(backend.sends, 0);
      // A free account that ran out is offered Premium.
      expect(find.text('See Premium'), findsOneWidget);
    });
  });

  group('chat history', () {
    testWidgets('deleting a chat asks first; Cancel and Esc keep it', (
      tester,
    ) async {
      final backend =
          _DockBackend()
            ..chats.addAll([
              ChatConversation(
                id: 'chat-1',
                title: 'Who leads Norway Chess 2026?',
                locale: 'en',
                updatedAt: DateTime.utc(2026, 9, 12),
              ),
              ChatConversation(
                id: 'chat-2',
                title: 'Live games',
                locale: 'en',
                updatedAt: DateTime.utc(2026, 9, 11),
              ),
            ]);
      final container = await _pumpDock(
        tester,
        backend: backend,
        quota: _quota(_freeFixture),
        history: true,
      );
      final trash = find.byIcon(Icons.delete_outline_rounded).first;

      await tester.tap(trash);
      await tester.pumpAndSettle();
      expect(find.text('Delete this chat?'), findsOneWidget);
      expect(backend.deletes, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this chat?'), findsNothing);
      expect(backend.deletes, 0);

      await tester.tap(trash);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Delete this chat?'), findsNothing);
      expect(backend.deletes, 0);
      // Esc closed the dialog, not the dock behind it.
      expect(container.read(botvinnikDockProvider).open, isTrue);

      await tester.tap(trash);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(backend.deletes, 1);
      expect(backend.chats.map((chat) => chat.id), ['chat-2']);
    });
  });

  group('references', () {
    test('coordinator links for game, event, tournament and round', () {
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'game', id: 'g1', label: 'A vs B'),
        ).toString(),
        'https://chessever.com/games/g1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'event', id: 'e1', label: 'Event'),
        ).toString(),
        'https://chessever.com/broadcast/e1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'tournament', id: 't1', label: 'Open'),
        ).toString(),
        'https://chessever.com/broadcast/t1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(
            type: 'round',
            id: 'r1',
            label: 'Round 1',
            tourId: 't1',
          ),
        ).toString(),
        'https://chessever.com/broadcast/t1',
      );
      expect(
        botvinnikReferenceDeepLink(
          const ChatReference(type: 'round', id: 'r1', label: 'Round 1'),
        ),
        isNull,
      );
    });

    test('openings stay plain text until a destination is plugged in', () {
      const opening = ChatReference(type: 'opening', id: 'B14', label: 'B14');
      expect(const DesktopBotvinnikReferenceRouter().canOpen(opening), isFalse);

      final withSmartEvents = DesktopBotvinnikReferenceRouter(
        openingOpener: (ref, code) async {},
      );
      expect(withSmartEvents.canOpen(opening), isTrue);
      expect(
        withSmartEvents.canOpen(
          const ChatReference(type: 'opening', id: 'b14', label: 'b14'),
        ),
        isTrue,
      );
      for (final id in ['B1', 'BB14']) {
        expect(
          withSmartEvents.canOpen(
            ChatReference(type: 'opening', id: id, label: id),
          ),
          isFalse,
        );
      }
    });

    test('an unroutable reference is not linkified', () {
      const references = [
        ChatReference(type: 'opening', id: 'B14', label: 'Caro-Kann'),
      ];
      const router = DesktopBotvinnikReferenceRouter();
      final openable = references.where(router.canOpen).toList();
      final result = integrateChatReferences('The Caro-Kann held.', openable);
      expect(result.markdown, 'The Caro-Kann held.');
    });

    test('the opening seam opens Smart Events by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(botvinnikOpeningReferenceOpenerProvider),
        isNotNull,
      );
    });
  });

  group('shell registration', () {
    test('Botvinnik is a sidebar action under Feedback, not a route', () {
      final labels = debugDesktopSidebarLabelsInOrder();
      expect(labels[labels.indexOf('Feedback') + 1], 'Botvinnik');
      expect(debugDesktopSidebarPaneForLabel('Botvinnik'), isNull);
      expect(
        desktopMainRoutes.map((route) => route.label),
        isNot(contains('Botvinnik')),
      );
    });

    test('dock width stays inside its bounds and open asks for focus', () {
      final notifier = BotvinnikDockNotifier();
      addTearDown(notifier.dispose);
      notifier.setWidth(10);
      expect(notifier.state.width, kBotvinnikDockMinWidth);
      notifier.setWidth(5000);
      expect(notifier.state.width, kBotvinnikDockMaxWidth);
      final before = notifier.state.focusRequest;
      notifier.open();
      expect(notifier.state.open, isTrue);
      expect(notifier.state.focusRequest, before + 1);
    });
  });
}
