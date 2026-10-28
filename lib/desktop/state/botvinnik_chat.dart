import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/chat/chat_references.dart';
import 'package:chessever/providers/auth_state_provider.dart';

/// Network seam for the Botvinnik conversation. Production wraps [ChatApi];
/// tests substitute a fake so the controller's send and reconcile rules can
/// be exercised without Supabase or the Worker.
abstract class BotvinnikChatBackend {
  /// True only for a signed-in, non-anonymous Supabase session. Guests and
  /// signed-out users are sent to the sign-in path before any request.
  bool get hasPermanentSession;

  Future<List<ChatConversation>> conversations();

  Future<List<ChatMessage>> messages(String conversationId);

  Future<ChatConversation> createConversation({
    required String locale,
    String? title,
  });

  Future<void> deleteConversation(String id);

  Future<ChatMessage> setMessageFeedback({
    required String conversationId,
    required String messageId,
    required String? feedback,
  });

  Stream<ChatStreamEvent> send({
    required String conversationId,
    required String content,
    required String locale,
    required String timezone,
    required ChatClientContext clientContext,
    ChatScreenContext? screenContext,
  });

  void close();
}

class ChatApiBotvinnikBackend implements BotvinnikChatBackend {
  ChatApiBotvinnikBackend() : _api = ChatApi();

  final ChatApi _api;

  @override
  bool get hasPermanentSession {
    try {
      final auth = Supabase.instance.client.auth;
      final user = auth.currentUser;
      return user != null && !user.isAnonymous && auth.currentSession != null;
    } catch (_) {
      // Supabase not initialised yet: treat as signed out, never as a crash.
      return false;
    }
  }

  @override
  Future<List<ChatConversation>> conversations() => _api.conversations();

  @override
  Future<List<ChatMessage>> messages(String conversationId) =>
      _api.messages(conversationId);

  @override
  Future<ChatConversation> createConversation({
    required String locale,
    String? title,
  }) => _api.createConversation(locale: locale, title: title);

  @override
  Future<void> deleteConversation(String id) => _api.deleteConversation(id);

  @override
  Future<ChatMessage> setMessageFeedback({
    required String conversationId,
    required String messageId,
    required String? feedback,
  }) => _api.setMessageFeedback(
    conversationId: conversationId,
    messageId: messageId,
    feedback: feedback,
  );

  @override
  Stream<ChatStreamEvent> send({
    required String conversationId,
    required String content,
    required String locale,
    required String timezone,
    required ChatClientContext clientContext,
    ChatScreenContext? screenContext,
  }) => _api.send(
    conversationId: conversationId,
    content: content,
    locale: locale,
    timezone: timezone,
    clientContext: clientContext,
    screenContext: screenContext,
  );

  @override
  void close() => _api.close();
}

/// Where the controller reads and writes the account allowance. Production
/// forwards to [botvinnikQuotaProvider]; every figure comes from the API.
abstract class BotvinnikQuotaSink {
  ChatQuotaStatus? get current;

  void set(ChatQuotaStatus quota);

  Future<void> refresh();
}

class _ProviderQuotaSink implements BotvinnikQuotaSink {
  const _ProviderQuotaSink(this._ref);

  final Ref _ref;

  @override
  ChatQuotaStatus? get current => _ref.read(botvinnikQuotaProvider).valueOrNull;

  @override
  void set(ChatQuotaStatus quota) =>
      _ref.read(botvinnikQuotaProvider.notifier).setQuota(quota);

  @override
  Future<void> refresh() =>
      _ref.read(botvinnikQuotaProvider.notifier).refresh();
}

/// A question whose delivery is unknown because the stream broke after the
/// request left the client. It blocks any resend until persisted history has
/// been compared against it.
@immutable
class BotvinnikInterruptedSend {
  const BotvinnikInterruptedSend({
    required this.conversationId,
    required this.content,
    required this.knownMessageIds,
  });

  final String conversationId;
  final String content;
  final Set<String> knownMessageIds;
}

/// What happened when the user pressed send. The pane maps the gate results
/// onto the sign-in modal or the Settings subscription card; nothing here
/// touches a widget.
enum BotvinnikSendResult {
  sent,
  ignored,
  signInRequired,
  exhausted,
  upgradeRequired,

  /// The question had already reached the server; its history was adopted
  /// and nothing was sent again.
  reconciled,
  failed,
}

@immutable
class BotvinnikChatState {
  const BotvinnikChatState({
    this.conversations = const <ChatConversation>[],
    this.selected,
    this.messages = const <ChatMessage>[],
    this.loaded = false,
    this.loading = false,
    this.sending = false,
    this.error,
    this.feedbackPending = const <String>{},
    this.interrupted,
    this.screenContext,
  });

  final List<ChatConversation> conversations;
  final ChatConversation? selected;
  final List<ChatMessage> messages;

  /// History has been fetched at least once for the current account.
  final bool loaded;
  final bool loading;
  final bool sending;
  final String? error;
  final Set<String> feedbackPending;
  final BotvinnikInterruptedSend? interrupted;
  final ChatScreenContext? screenContext;

  static const _unset = Object();

  BotvinnikChatState copyWith({
    List<ChatConversation>? conversations,
    Object? selected = _unset,
    List<ChatMessage>? messages,
    bool? loaded,
    bool? loading,
    bool? sending,
    Object? error = _unset,
    Set<String>? feedbackPending,
    Object? interrupted = _unset,
    Object? screenContext = _unset,
  }) {
    return BotvinnikChatState(
      conversations: conversations ?? this.conversations,
      selected:
          identical(selected, _unset)
              ? this.selected
              : selected as ChatConversation?,
      messages: messages ?? this.messages,
      loaded: loaded ?? this.loaded,
      loading: loading ?? this.loading,
      sending: sending ?? this.sending,
      error: identical(error, _unset) ? this.error : error as String?,
      feedbackPending: feedbackPending ?? this.feedbackPending,
      interrupted:
          identical(interrupted, _unset)
              ? this.interrupted
              : interrupted as BotvinnikInterruptedSend?,
      screenContext:
          identical(screenContext, _unset)
              ? this.screenContext
              : screenContext as ChatScreenContext?,
    );
  }
}

String _defaultChatLocale() =>
    PlatformDispatcher.instance.locale.toLanguageTag();

/// Conversation state for the Botvinnik dock.
///
/// Lives in an app-scoped provider rather than the widget so the composer
/// draft, the open conversation and any interrupted send survive closing the
/// dock, switching tabs, the sign-in modal and a checkout trip to Settings.
class BotvinnikChatController extends StateNotifier<BotvinnikChatState> {
  BotvinnikChatController({
    required BotvinnikChatBackend backend,
    required BotvinnikQuotaSink quota,
    String Function()? locale,
    ChatClientContext Function()? clientContext,
  }) : _backend = backend,
       _quota = quota,
       _locale = locale ?? _defaultChatLocale,
       _clientContext = clientContext,
       super(const BotvinnikChatState());

  final BotvinnikChatBackend _backend;
  final BotvinnikQuotaSink _quota;
  final String Function() _locale;
  final ChatClientContext Function()? _clientContext;

  /// The composer draft. Owned here, not by the widget, so it is never lost.
  final TextEditingController draft = TextEditingController();

  String? _appVersion;
  String? _buildNumber;
  bool _clientMetadataRequested = false;
  int _loadGeneration = 0;

  bool get hasPermanentSession => _backend.hasPermanentSession;

  ChatComposerAccess get composerAccess => chatComposerAccess(
    isSignedIn: _backend.hasPermanentSession,
    quota: _quota.current,
  );

  void setScreenContext(ChatScreenContext? screenContext) {
    state = state.copyWith(screenContext: screenContext);
  }

  void dismissError() => state = state.copyWith(error: null);

  /// Loads history once per account. Signed-out users get an empty,
  /// non-error state so the pane can show the sign-in path.
  Future<void> ensureLoaded() async {
    if (state.loaded || state.loading) return;
    await load();
  }

  Future<void> load({String? preferredConversationId}) async {
    _requestClientMetadata();
    if (!_backend.hasPermanentSession) {
      state = state.copyWith(loading: false, error: null);
      return;
    }
    final generation = ++_loadGeneration;
    state = state.copyWith(loading: true, error: null);
    try {
      final conversations = await _backend.conversations();
      if (!mounted || generation != _loadGeneration) return;
      final preferred = preferredConversationId ?? state.selected?.id;
      final keepDraft = state.selected?.isDraft ?? false;
      late final ChatConversation selected;
      var messages = const <ChatMessage>[];
      if (keepDraft || conversations.isEmpty) {
        selected =
            keepDraft
                ? state.selected!
                : ChatConversation.draft(locale: _locale());
      } else {
        selected = chatConversationForOpen(conversations, preferred);
        // Cold open of an existing conversation: persisted history is the
        // source of truth, including answers generated while we were away.
        messages = await _backend.messages(selected.id);
      }
      if (!mounted || generation != _loadGeneration) return;
      state = state.copyWith(
        conversations: conversations,
        selected: selected,
        messages: messages,
        loaded: true,
        loading: false,
        interrupted: _settleInterrupted(selected.id, messages),
      );
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      state = state.copyWith(loading: false, error: _messageFor(error));
    }
  }

  /// Account changed (sign in, sign out, guest upgrade). History belongs to
  /// the previous account and is dropped; the draft is kept on purpose.
  Future<void> handleAccountChanged() async {
    _loadGeneration++;
    state = BotvinnikChatState(screenContext: state.screenContext);
    await _quota.refresh();
    if (_backend.hasPermanentSession) await load();
  }

  void startNewConversation() {
    if (state.sending) return;
    state = state.copyWith(
      selected: ChatConversation.draft(locale: _locale()),
      messages: const <ChatMessage>[],
      error: null,
    );
  }

  Future<void> select(ChatConversation conversation) async {
    if (state.sending) return;
    if (conversation.isDraft) {
      state = state.copyWith(
        selected: conversation,
        messages: const <ChatMessage>[],
        error: null,
      );
      return;
    }
    final generation = ++_loadGeneration;
    state = state.copyWith(selected: conversation, error: null, loading: true);
    try {
      final messages = await _backend.messages(conversation.id);
      if (!mounted || generation != _loadGeneration) return;
      state = state.copyWith(
        messages: messages,
        loading: false,
        interrupted: _settleInterrupted(conversation.id, messages),
      );
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      state = state.copyWith(loading: false, error: _messageFor(error));
    }
  }

  Future<void> delete(ChatConversation conversation) async {
    if (state.sending) return;
    try {
      if (!conversation.isDraft) {
        await _backend.deleteConversation(conversation.id);
      }
      if (!mounted) return;
      final remaining =
          state.conversations
              .where((item) => item.id != conversation.id)
              .toList();
      state = state.copyWith(
        conversations: remaining,
        interrupted:
            state.interrupted?.conversationId == conversation.id
                ? null
                : state.interrupted,
      );
      if (state.selected?.id == conversation.id) {
        if (remaining.isEmpty) {
          startNewConversation();
        } else {
          await select(remaining.first);
        }
      }
    } on Object catch (error) {
      if (mounted) state = state.copyWith(error: _messageFor(error));
    }
  }

  Future<BotvinnikSendResult> send() async {
    switch (composerAccess) {
      case ChatComposerAccess.signedOut:
        return BotvinnikSendResult.signInRequired;
      case ChatComposerAccess.exhausted:
        return BotvinnikSendResult.exhausted;
      case ChatComposerAccess.upgradeRequired:
        return BotvinnikSendResult.upgradeRequired;
      case ChatComposerAccess.enabled:
        break;
    }
    var selected = state.selected;
    final content = draft.text.trim();
    if (content.isEmpty || state.sending) return BotvinnikSendResult.ignored;
    selected ??= ChatConversation.draft(locale: _locale());

    final interrupted = state.interrupted;
    if (interrupted != null) {
      // Reconcile before resending: an earlier stream broke after the request
      // left the client, so the server may already hold that question.
      final settled = await _reconcileInterrupted(interrupted);
      if (!mounted) return BotvinnikSendResult.ignored;
      if (settled == null) return BotvinnikSendResult.failed;
      if (settled == ChatReconcileOutcome.alreadyDelivered &&
          interrupted.content.trim() == content) {
        draft.clear();
        return BotvinnikSendResult.reconciled;
      }
      selected = state.selected ?? selected;
    }

    final knownIds = {
      for (final message in state.messages)
        if (!message.id.startsWith('local-')) message.id,
    };
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final localUser = ChatMessage(
      id: 'local-user-$stamp',
      role: 'user',
      content: content,
    );
    final localAssistant = ChatMessage(
      id: 'local-assistant-$stamp',
      role: 'assistant',
      content: '',
    );
    draft.clear();
    state = state.copyWith(
      sending: true,
      error: null,
      selected: selected,
      messages: [...state.messages, localUser, localAssistant],
    );

    var requestLeftClient = false;
    var receivedEvent = false;
    var streamCompleted = false;
    var conversationId = selected.id;
    try {
      if (selected.isDraft) {
        final draftId = selected.id;
        final persisted = await _backend.createConversation(
          locale: _locale(),
          title: chatTitleFromQuestion(content),
        );
        conversationId = persisted.id;
        if (!mounted) return BotvinnikSendResult.ignored;
        state = state.copyWith(
          selected: persisted,
          conversations: [
            persisted,
            ...state.conversations.where(
              (item) => item.id != draftId && item.id != persisted.id,
            ),
          ],
        );
      }
      requestLeftClient = true;
      await for (final event in _backend.send(
        conversationId: conversationId,
        content: content,
        locale: _locale(),
        timezone: DateTime.now().timeZoneName,
        clientContext: _buildClientContext(),
        screenContext: state.screenContext,
      )) {
        if (!mounted) return BotvinnikSendResult.ignored;
        receivedEvent = true;
        _applyStreamEvent(conversationId, content, event);
      }
      streamCompleted = true;
      // Reconcile after the stream closes: persisted ids unlock feedback and
      // the stored text replaces whatever the stream delivered.
      final refreshed = await _backend.messages(conversationId);
      if (!mounted) return BotvinnikSendResult.ignored;
      state = state.copyWith(messages: refreshed, sending: false);
      return BotvinnikSendResult.sent;
    } on ChatApiException catch (error) {
      if (!mounted) return BotvinnikSendResult.ignored;
      if (streamCompleted) return _afterRefreshFailed(error.message);
      final rejectedBeforeStream = error.statusCode != null && !receivedEvent;
      if (error.quota != null) {
        _quota.set(error.quota!);
      } else {
        unawaited(_quota.refresh());
      }
      if (rejectedBeforeStream || !requestLeftClient) {
        // The Worker refused the request outright, so it was never stored.
        // Put the question back where the user left it.
        _restoreDraft(content, localUser.id, localAssistant.id);
        state = state.copyWith(
          sending: false,
          error:
              error.quota != null && error.quota!.remaining <= 0
                  ? null
                  : error.message,
        );
        return BotvinnikSendResult.failed;
      }
      return _afterInterruptedStream(
        conversationId: conversationId,
        content: content,
        knownIds: knownIds,
        localIds: {localUser.id, localAssistant.id},
        message: error.message,
      );
    } on Object catch (error) {
      if (!mounted) return BotvinnikSendResult.ignored;
      if (streamCompleted) return _afterRefreshFailed(_messageFor(error));
      if (!requestLeftClient) {
        _restoreDraft(content, localUser.id, localAssistant.id);
        state = state.copyWith(sending: false, error: _messageFor(error));
        return BotvinnikSendResult.failed;
      }
      return _afterInterruptedStream(
        conversationId: conversationId,
        content: content,
        knownIds: knownIds,
        localIds: {localUser.id, localAssistant.id},
        message: _messageFor(error),
      );
    }
  }

  /// Puts a suggestion in the composer and sends it. When a gate blocks the
  /// send the suggestion stays in the draft for after sign-in.
  Future<BotvinnikSendResult> sendSuggestion(String prompt) async {
    if (state.sending) return BotvinnikSendResult.ignored;
    draft.text = prompt;
    draft.selection = TextSelection.collapsed(offset: prompt.length);
    return send();
  }

  /// The answer streamed to completion but the history refresh failed. The
  /// question is known to be stored, so the streamed text stays and nothing is
  /// handed back for resending.
  BotvinnikSendResult _afterRefreshFailed(String message) {
    state = state.copyWith(sending: false, error: message);
    return BotvinnikSendResult.sent;
  }

  Future<void> setFeedback(ChatMessage message, String feedback) async {
    final selected = state.selected;
    if (selected == null ||
        message.id.startsWith('local-') ||
        state.feedbackPending.contains(message.id)) {
      return;
    }
    final nextFeedback = message.feedback == feedback ? null : feedback;
    final previousFeedback = message.feedback;
    state = state.copyWith(
      feedbackPending: {...state.feedbackPending, message.id},
      messages: _replaceFeedback(message.id, nextFeedback),
    );
    try {
      final updated = await _backend.setMessageFeedback(
        conversationId: selected.id,
        messageId: message.id,
        feedback: nextFeedback,
      );
      if (!mounted || state.selected?.id != selected.id) return;
      state = state.copyWith(
        messages: [
          for (final item in state.messages)
            item.id == updated.id ? updated : item,
        ],
      );
    } on Object catch (error) {
      if (!mounted || state.selected?.id != selected.id) return;
      state = state.copyWith(
        error: _messageFor(error),
        messages: _replaceFeedback(message.id, previousFeedback),
      );
    } finally {
      if (mounted) {
        state = state.copyWith(
          feedbackPending: {...state.feedbackPending}..remove(message.id),
        );
      }
    }
  }

  List<ChatMessage> _replaceFeedback(String messageId, String? feedback) => [
    for (final item in state.messages)
      item.id == messageId ? item.withFeedback(feedback) : item,
  ];

  Future<BotvinnikSendResult> _afterInterruptedStream({
    required String conversationId,
    required String content,
    required Set<String> knownIds,
    required Set<String> localIds,
    required String message,
  }) async {
    final interrupted = BotvinnikInterruptedSend(
      conversationId: conversationId,
      content: content,
      knownMessageIds: knownIds,
    );
    state = state.copyWith(interrupted: interrupted, sending: false);
    final outcome = await _reconcileInterrupted(interrupted);
    if (!mounted) return BotvinnikSendResult.ignored;
    if (outcome == ChatReconcileOutcome.alreadyDelivered) {
      state = state.copyWith(error: message);
      return BotvinnikSendResult.reconciled;
    }
    if (outcome == ChatReconcileOutcome.notDelivered) {
      _restoreDraftIfEmpty(content);
    } else {
      // History could not be fetched. Keep the local bubbles, keep the
      // interrupted marker and hand the text back; the next send reconciles
      // before it is allowed to go out.
      state = state.copyWith(
        messages: [
          for (final item in state.messages)
            if (!(localIds.contains(item.id) && item.content.isEmpty)) item,
        ],
      );
      _restoreDraftIfEmpty(content);
    }
    state = state.copyWith(error: message);
    return BotvinnikSendResult.failed;
  }

  /// Fetches persisted history for [interrupted] and settles it. Returns null
  /// when the history request itself failed.
  Future<ChatReconcileOutcome?> _reconcileInterrupted(
    BotvinnikInterruptedSend interrupted,
  ) async {
    try {
      final serverMessages = await _backend.messages(
        interrupted.conversationId,
      );
      if (!mounted) return null;
      final outcome = chatReconcilePendingSend(
        serverMessages: serverMessages,
        pendingContent: interrupted.content,
        knownMessageIds: interrupted.knownMessageIds,
      );
      final showingConversation =
          state.selected?.id == interrupted.conversationId;
      state = state.copyWith(
        interrupted: null,
        messages: showingConversation ? serverMessages : state.messages,
      );
      return outcome;
    } on Object catch (error) {
      if (mounted) state = state.copyWith(error: _messageFor(error));
      return null;
    }
  }

  BotvinnikInterruptedSend? _settleInterrupted(
    String conversationId,
    List<ChatMessage> serverMessages,
  ) {
    final interrupted = state.interrupted;
    if (interrupted == null || interrupted.conversationId != conversationId) {
      return interrupted;
    }
    final outcome = chatReconcilePendingSend(
      serverMessages: serverMessages,
      pendingContent: interrupted.content,
      knownMessageIds: interrupted.knownMessageIds,
    );
    if (outcome == ChatReconcileOutcome.notDelivered) {
      _restoreDraftIfEmpty(interrupted.content);
    }
    return null;
  }

  void _restoreDraft(String content, String userId, String assistantId) {
    state = state.copyWith(
      messages: [
        for (final item in state.messages)
          if (item.id != userId && item.id != assistantId) item,
      ],
    );
    _restoreDraftIfEmpty(content);
  }

  void _restoreDraftIfEmpty(String content) {
    if (draft.text.trim().isNotEmpty) return;
    draft.text = content;
    draft.selection = TextSelection.collapsed(offset: content.length);
  }

  void _applyStreamEvent(
    String conversationId,
    String question,
    ChatStreamEvent event,
  ) {
    final messages = [...state.messages];
    if (messages.isEmpty) return;
    final assistant = messages.last;
    switch (event.type) {
      case 'start':
        _useQuestionAsTitle(conversationId, question);
        _readQuota(event.data);
        return;
      case 'done':
        _readQuota(event.data);
        return;
      case 'delta':
        messages[messages.length - 1] = assistant.copyWith(
          content: '${assistant.content}${event.data['text'] as String? ?? ''}',
        );
      case 'references':
        final raw = event.data['references'] as List<dynamic>? ?? const [];
        messages[messages.length - 1] = assistant.copyWith(
          references:
              raw
                  .whereType<Map<String, dynamic>>()
                  .map(ChatReference.fromJson)
                  .toList(),
        );
      case 'error':
        throw ChatApiException(
          event.data['message'] as String? ?? 'Botvinnik could not answer.',
        );
      default:
        return;
    }
    state = state.copyWith(messages: messages);
  }

  void _readQuota(Map<String, dynamic> data) {
    final quota = data['quota'];
    if (quota is! Map<String, dynamic>) return;
    _quota.set(ChatQuotaStatus.fromJson(quota));
  }

  void _useQuestionAsTitle(String conversationId, String question) {
    final index = state.conversations.indexWhere(
      (conversation) => conversation.id == conversationId,
    );
    if (index == -1 || state.conversations[index].title != 'New chat') return;
    final renamed = state.conversations[index].copyWith(
      title: chatTitleFromQuestion(question),
    );
    final conversations = [...state.conversations];
    conversations[index] = renamed;
    state = state.copyWith(
      conversations: conversations,
      selected: state.selected?.id == conversationId ? renamed : state.selected,
    );
  }

  ChatClientContext _buildClientContext() {
    final override = _clientContext;
    if (override != null) return override();
    final views = PlatformDispatcher.instance.views;
    final view = views.isEmpty ? null : views.first;
    final size =
        view == null ? Size.zero : view.physicalSize / view.devicePixelRatio;
    return ChatClientContext.current(
      viewportWidth: size.width,
      shortestSide: size.shortestSide,
      appVersion: _appVersion,
      buildNumber: _buildNumber,
    );
  }

  void _requestClientMetadata() {
    if (_clientMetadataRequested || _clientContext != null) return;
    _clientMetadataRequested = true;
    unawaited(() async {
      try {
        final info = await PackageInfo.fromPlatform();
        _appVersion = info.version;
        _buildNumber = info.buildNumber;
      } catch (_) {
        // Platform and form factor are still sent without a version.
      }
    }());
  }

  String _messageFor(Object error) {
    if (error is ChatApiException) return error.message;
    return 'Botvinnik is unreachable right now. Check your connection.';
  }

  @override
  void dispose() {
    draft.dispose();
    super.dispose();
  }
}

final botvinnikChatBackendProvider = Provider<BotvinnikChatBackend>((ref) {
  final backend = ChatApiBotvinnikBackend();
  ref.onDispose(backend.close);
  return backend;
});

final botvinnikChatControllerProvider =
    StateNotifierProvider<BotvinnikChatController, BotvinnikChatState>((ref) {
      final controller = BotvinnikChatController(
        backend: ref.read(botvinnikChatBackendProvider),
        quota: _ProviderQuotaSink(ref),
      );
      ref.listen(currentUserProvider, (previous, next) {
        final changed =
            previous?.id != next?.id ||
            previous?.isAnonymous != next?.isAnonymous;
        if (changed) unawaited(controller.handleAccountChanged());
      });
      return controller;
    });
