import 'dart:async';

import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/desktop/state/botvinnik_chat.dart';
import 'package:flutter_test/flutter_test.dart';

// Quota fixtures shaped like the Worker payload; not product constants.
const Map<String, dynamic> _openFixture = {
  'limit': 13,
  'used': 2,
  'remaining': 11,
  'isPremium': false,
};
const Map<String, dynamic> _afterAnswerFixture = {
  'limit': 13,
  'used': 3,
  'remaining': 10,
  'isPremium': false,
};
const Map<String, dynamic> _exhaustedFixture = {
  'limit': 13,
  'used': 13,
  'remaining': 0,
  'isPremium': false,
};
const Map<String, dynamic> _upgradeFixture = {
  'limit': 0,
  'used': 0,
  'remaining': 0,
  'isPremium': false,
};

typedef _StreamFactory =
    Stream<ChatStreamEvent> Function(String conversationId, String content);

class _FakeBackend implements BotvinnikChatBackend {
  _FakeBackend({this.hasPermanentSession = true});

  @override
  bool hasPermanentSession;

  final List<ChatConversation> serverConversations = [];
  final Map<String, List<ChatMessage>> serverMessages = {};
  int sendCalls = 0;
  int messagesCalls = 0;
  int createCalls = 0;
  bool failMessages = false;
  _StreamFactory? streamFor;
  Future<ChatConversation> Function()? createFor;
  Future<List<ChatMessage>> Function(String)? messagesFor;

  void store(String conversationId, String question, String answer) {
    final list = serverMessages.putIfAbsent(conversationId, () => []);
    list.add(
      ChatMessage(id: 'srv-${list.length}', role: 'user', content: question),
    );
    list.add(
      ChatMessage(id: 'srv-${list.length}', role: 'assistant', content: answer),
    );
  }

  @override
  Future<List<ChatConversation>> conversations() async =>
      List.of(serverConversations);

  @override
  Future<List<ChatMessage>> messages(String conversationId) async {
    messagesCalls++;
    if (messagesFor != null) return messagesFor!(conversationId);
    if (failMessages) throw Exception('offline');
    return List.of(serverMessages[conversationId] ?? const <ChatMessage>[]);
  }

  @override
  Future<ChatConversation> createConversation({
    required String locale,
    String? title,
  }) async {
    createCalls++;
    if (createFor != null) return createFor!();
    final conversation = ChatConversation(
      id: 'conv-$createCalls',
      title: title ?? 'New chat',
      locale: locale,
      updatedAt: DateTime.utc(2026, 9, 12),
    );
    serverConversations.insert(0, conversation);
    return conversation;
  }

  @override
  Future<void> deleteConversation(String id) async {
    serverConversations.removeWhere((conversation) => conversation.id == id);
  }

  @override
  Future<ChatMessage> setMessageFeedback({
    required String conversationId,
    required String messageId,
    required String? feedback,
  }) async {
    final message = serverMessages[conversationId]!.firstWhere(
      (item) => item.id == messageId,
    );
    return message.withFeedback(feedback);
  }

  @override
  Stream<ChatStreamEvent> send({
    required String conversationId,
    required String content,
    required String locale,
    required String timezone,
    required ChatClientContext clientContext,
    ChatScreenContext? screenContext,
  }) {
    sendCalls++;
    return (streamFor ?? _answer)(conversationId, content);
  }

  Stream<ChatStreamEvent> _answer(
    String conversationId,
    String content,
  ) async* {
    store(conversationId, content, 'Answer');
    yield const ChatStreamEvent('delta', {'text': 'Answer'});
    yield const ChatStreamEvent('done', {});
  }

  @override
  void close() {}
}

class _FakeQuota implements BotvinnikQuotaSink {
  _FakeQuota([this.current]);

  @override
  ChatQuotaStatus? current;
  int refreshes = 0;

  @override
  void set(ChatQuotaStatus quota) => current = quota;

  @override
  Future<void> refresh() async => refreshes++;
}

BotvinnikChatController _controller(
  _FakeBackend backend,
  _FakeQuota quota, {
  Future<bool> Function()? aiConsentGranted,
}) {
  return BotvinnikChatController(
    backend: backend,
    quota: quota,
    aiConsentGranted: aiConsentGranted ?? () async => true,
    locale: () => 'en',
    clientContext:
        () => const ChatClientContext(
          platform: 'macos',
          surface: 'desktop',
          formFactor: 'desktop',
        ),
  );
}

void main() {
  test(
    'no consent means no conversation or message, including suggestions',
    () async {
      final backend = _FakeBackend();
      final controller = _controller(
        backend,
        _FakeQuota(ChatQuotaStatus.fromJson(_openFixture)),
        aiConsentGranted: () async => false,
      );
      addTearDown(controller.dispose);
      controller.draft.text = 'A private question';
      expect(await controller.send(), BotvinnikSendResult.consentRequired);
      expect(controller.draft.text, 'A private question');
      expect(
        await controller.sendSuggestion('A suggested question'),
        BotvinnikSendResult.consentRequired,
      );
      expect(backend.createCalls, 0);
      expect(backend.sendCalls, 0);
    },
  );

  test('withdrawing consent blocks later sends', () async {
    var granted = true;
    final backend = _FakeBackend();
    final controller = _controller(
      backend,
      _FakeQuota(ChatQuotaStatus.fromJson(_openFixture)),
      aiConsentGranted: () async => granted,
    );
    addTearDown(controller.dispose);
    controller.draft.text = 'First question';
    expect(await controller.send(), BotvinnikSendResult.sent);
    final calls = backend.sendCalls;
    granted = false;
    controller.draft.text = 'Second question';
    expect(await controller.send(), BotvinnikSendResult.consentRequired);
    expect(backend.sendCalls, calls);
  });

  test('an account change while checking permission cannot send', () async {
    final permission = Completer<bool>();
    final backend = _FakeBackend();
    final controller = _controller(
      backend,
      _FakeQuota(ChatQuotaStatus.fromJson(_openFixture)),
      aiConsentGranted: () => permission.future,
    );
    addTearDown(controller.dispose);
    controller.draft.text = 'Private question';
    final pending = controller.send();
    backend.hasPermanentSession = false;
    await controller.handleAccountChanged();
    permission.complete(true);
    expect(await pending, BotvinnikSendResult.ignored);
    expect(backend.createCalls, 0);
    expect(backend.sendCalls, 0);
  });

  test('signing out removes the old account draft', () async {
    final backend = _FakeBackend();
    final controller = _controller(backend, _FakeQuota());
    addTearDown(controller.dispose);
    controller.draft.text = 'Account A unsent private draft';
    backend.hasPermanentSession = false;
    await controller.handleAccountChanged(clearDraft: true);
    expect(controller.draft.text, isEmpty);
    expect(controller.state.messages, isEmpty);
  });

  test(
    'a late conversation creation cannot send under another account',
    () async {
      final created = Completer<ChatConversation>();
      final backend = _FakeBackend()..createFor = () => created.future;
      final controller = _controller(backend, _FakeQuota());
      addTearDown(controller.dispose);
      controller.draft.text = 'Account A private question';
      final pending = controller.send();
      await pumpEventQueue();
      expect(backend.createCalls, 1);
      await controller.handleAccountChanged();
      controller.draft.text = 'Account B draft';
      created.complete(
        ChatConversation(
          id: 'a',
          title: 'Private',
          locale: 'en',
          updatedAt: DateTime.utc(2026, 10, 29),
        ),
      );
      expect(await pending, BotvinnikSendResult.ignored);
      expect(backend.sendCalls, 0);
      expect(controller.state.messages, isEmpty);
      expect(controller.draft.text, 'Account B draft');
    },
  );

  test('account changes cancel an old stream and ignore its events', () async {
    var cancelled = false;
    final stream = StreamController<ChatStreamEvent>(
      onCancel: () => cancelled = true,
    );
    addTearDown(stream.close);
    final backend = _FakeBackend()..streamFor = (_, _) => stream.stream;
    final controller = _controller(backend, _FakeQuota());
    addTearDown(controller.dispose);
    controller.draft.text = 'Account A private question';
    final pending = controller.send();
    await pumpEventQueue();
    expect(backend.sendCalls, 1);
    backend.serverConversations.clear();
    await controller.handleAccountChanged();
    controller.draft.text = 'Account B draft';
    stream.add(const ChatStreamEvent('delta', {'text': 'Account A answer'}));
    expect(await pending, BotvinnikSendResult.ignored);
    expect(cancelled, isTrue);
    expect(controller.state.messages, isEmpty);
    expect(controller.state.interrupted, isNull);
    expect(controller.draft.text, 'Account B draft');
  });

  test('late history and errors cannot overwrite another account', () async {
    for (final fail in [false, true]) {
      final history = Completer<List<ChatMessage>>();
      final backend = _FakeBackend()..messagesFor = (_) => history.future;
      final controller = _controller(backend, _FakeQuota());
      controller.draft.text = 'Account A private question';
      final pending = controller.send();
      await pumpEventQueue();
      expect(backend.messagesCalls, 1);
      backend.serverConversations.clear();
      await controller.handleAccountChanged();
      controller.draft.text = 'Account B draft';
      if (fail) {
        history.completeError(StateError('Account A history failed'));
      } else {
        history.complete(const [
          ChatMessage(id: 'a', role: 'assistant', content: 'Private A'),
        ]);
      }
      expect(await pending, BotvinnikSendResult.ignored);
      expect(controller.state.messages, isEmpty);
      expect(controller.state.error, isNull);
      expect(controller.draft.text, 'Account B draft');
      controller.dispose();
    }
  });
  test('an anonymous session gets the sign-in path, not a request', () async {
    final backend = _FakeBackend(hasPermanentSession: false);
    final controller = _controller(backend, _FakeQuota());
    addTearDown(controller.dispose);

    await controller.load();
    controller.draft.text = 'Who leads Norway Chess?';

    expect(controller.state.error, isNull);
    expect(await controller.send(), BotvinnikSendResult.signInRequired);
    expect(backend.sendCalls, 0);
    expect(backend.createCalls, 0);
    expect(controller.state.messages, isEmpty);
    expect(controller.draft.text, 'Who leads Norway Chess?');
  });

  test('the production backend treats missing Supabase as signed out', () {
    final backend = ChatApiBotvinnikBackend();
    addTearDown(backend.close);

    expect(backend.hasPermanentSession, isFalse);
  });

  test('the draft survives a sign-in round trip and then sends', () async {
    final backend = _FakeBackend(hasPermanentSession: false);
    final quota = _FakeQuota();
    final controller = _controller(backend, quota);
    addTearDown(controller.dispose);

    controller.draft.text = 'Explain the Armageddon rules';
    expect(await controller.send(), BotvinnikSendResult.signInRequired);

    backend.hasPermanentSession = true;
    await controller.handleAccountChanged();

    expect(controller.draft.text, 'Explain the Armageddon rules');
    expect(controller.state.loaded, isTrue);
    expect(quota.refreshes, 1);

    expect(await controller.send(), BotvinnikSendResult.sent);
    expect(backend.sendCalls, 1);
    expect(controller.draft.text, isEmpty);
    expect(controller.state.messages.map((message) => message.content), [
      'Explain the Armageddon rules',
      'Answer',
    ]);
  });

  test('a suggestion blocked by sign-in stays in the draft', () async {
    final backend = _FakeBackend(hasPermanentSession: false);
    final controller = _controller(backend, _FakeQuota());
    addTearDown(controller.dispose);

    expect(
      await controller.sendSuggestion('Which games are live right now?'),
      BotvinnikSendResult.signInRequired,
    );
    expect(controller.draft.text, 'Which games are live right now?');
    expect(backend.sendCalls, 0);
  });

  group('quota gating uses the API allowance', () {
    test('an exhausted allowance blocks sending and keeps the draft', () async {
      final backend = _FakeBackend();
      final controller = _controller(
        backend,
        _FakeQuota(ChatQuotaStatus.fromJson(_exhaustedFixture)),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.draft.text = 'One more question';

      expect(await controller.send(), BotvinnikSendResult.exhausted);
      expect(backend.sendCalls, 0);
      expect(controller.draft.text, 'One more question');
    });

    test('a plan without an allowance reports upgrade required', () async {
      final backend = _FakeBackend();
      final controller = _controller(
        backend,
        _FakeQuota(ChatQuotaStatus.fromJson(_upgradeFixture)),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.draft.text = 'Hello';

      expect(await controller.send(), BotvinnikSendResult.upgradeRequired);
      expect(backend.sendCalls, 0);
    });

    test('stream quota events replace the stored allowance', () async {
      final backend = _FakeBackend();
      final quota = _FakeQuota(ChatQuotaStatus.fromJson(_openFixture));
      final controller = _controller(backend, quota);
      addTearDown(controller.dispose);
      await controller.load();

      final assistantSnapshots = <String>[];
      controller.addListener((state) {
        final last = state.messages.isEmpty ? null : state.messages.last;
        if (last != null && last.role == 'assistant') {
          assistantSnapshots.add(last.content);
        }
      }, fireImmediately: false);

      backend.streamFor = (conversationId, content) async* {
        yield const ChatStreamEvent('start', {'quota': _openFixture});
        yield const ChatStreamEvent('delta', {'text': 'Carlsen '});
        yield const ChatStreamEvent('heartbeat', {});
        yield const ChatStreamEvent('delta', {'text': 'leads.'});
        yield const ChatStreamEvent('references', {
          'references': [
            {'type': 'player', 'id': '1503014', 'label': 'Carlsen, Magnus'},
          ],
        });
        backend.store(conversationId, content, 'Carlsen leads.');
        yield const ChatStreamEvent('done', {'quota': _afterAnswerFixture});
      };
      controller.draft.text = 'Who leads?';

      expect(await controller.send(), BotvinnikSendResult.sent);
      expect(
        assistantSnapshots,
        containsAllInOrder(['Carlsen ', 'Carlsen leads.']),
      );
      expect(quota.current!.remaining, _afterAnswerFixture['remaining']);
      expect(quota.current!.limit, _afterAnswerFixture['limit']);
      expect(controller.state.messages.last.content, 'Carlsen leads.');
      expect(controller.state.messages.last.id, startsWith('srv-'));
    });
  });

  group('reconcile before resend', () {
    test('cold open reads persisted history before anything is sent', () async {
      final backend = _FakeBackend();
      backend.serverConversations.add(
        ChatConversation(
          id: 'existing',
          title: 'Earlier',
          locale: 'en',
          updatedAt: DateTime.utc(2026, 9, 11),
        ),
      );
      backend.store('existing', 'Earlier question', 'Answer finished offline');
      final controller = _controller(backend, _FakeQuota());
      addTearDown(controller.dispose);

      await controller.load();

      expect(backend.messagesCalls, 1);
      expect(backend.sendCalls, 0);
      expect(controller.state.selected!.id, 'existing');
      expect(controller.state.messages.last.content, 'Answer finished offline');
    });

    test('a question already on the server is never sent twice', () async {
      final backend = _FakeBackend();
      final controller = _controller(backend, _FakeQuota());
      addTearDown(controller.dispose);
      await controller.load();

      backend.streamFor = (conversationId, content) async* {
        // The Worker stored the question, then the connection dropped.
        backend.store(conversationId, content, 'Generated while offline');
        yield const ChatStreamEvent('start', {});
        throw Exception('connection reset');
      };
      backend.failMessages = true;
      controller.draft.text = 'Explain the tiebreaks';

      expect(await controller.send(), BotvinnikSendResult.failed);
      expect(backend.sendCalls, 1);
      expect(controller.state.interrupted, isNotNull);
      // The text is handed back, but the next send must reconcile first.
      expect(controller.draft.text, 'Explain the tiebreaks');

      backend.failMessages = false;
      backend.streamFor = null;

      expect(await controller.send(), BotvinnikSendResult.reconciled);
      expect(backend.sendCalls, 1);
      expect(controller.draft.text, isEmpty);
      expect(controller.state.interrupted, isNull);
      expect(
        controller.state.messages.where(
          (message) =>
              message.role == 'user' &&
              message.content == 'Explain the tiebreaks',
        ),
        hasLength(1),
      );
      expect(controller.state.messages.last.content, 'Generated while offline');
    });

    test('a broken stream the server never stored may be sent again', () async {
      final backend = _FakeBackend();
      final controller = _controller(backend, _FakeQuota());
      addTearDown(controller.dispose);
      await controller.load();

      backend.streamFor = (conversationId, content) async* {
        throw Exception('reset before the Worker stored anything');
      };
      controller.draft.text = 'Standings after round 5?';

      expect(await controller.send(), BotvinnikSendResult.failed);
      expect(controller.state.interrupted, isNull);
      expect(controller.draft.text, 'Standings after round 5?');

      backend.streamFor = null;
      expect(await controller.send(), BotvinnikSendResult.sent);
      expect(backend.sendCalls, 2);
    });

    test('a request refused before streaming restores the draft', () async {
      final backend = _FakeBackend();
      final quota = _FakeQuota(ChatQuotaStatus.fromJson(_openFixture));
      final controller = _controller(backend, quota);
      addTearDown(controller.dispose);
      await controller.load();

      backend.streamFor = (conversationId, content) async* {
        throw ChatApiException(
          chatDailyLimitMessage,
          statusCode: 429,
          quota: ChatQuotaStatus.fromJson(_exhaustedFixture),
        );
      };
      controller.draft.text = 'Last one for today';

      expect(await controller.send(), BotvinnikSendResult.failed);
      expect(controller.draft.text, 'Last one for today');
      expect(controller.state.interrupted, isNull);
      expect(controller.state.messages, isEmpty);
      expect(quota.current!.remaining, _exhaustedFixture['remaining']);
      expect(controller.state.error, isNull);
    });
  });
}
