import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:motor/motor.dart';

import 'package:chessever/chat/botvinnik_provider.dart';
import 'package:chessever/chat/chat_api.dart';
import 'package:chessever/chat/chat_references.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_mark.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_sign_in.dart';
import 'package:chessever/desktop/state/botvinnik_chat.dart';
import 'package:chessever/desktop/state/botvinnik_dock.dart';
import 'package:chessever/desktop/state/botvinnik_reference_router.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/deferred_pointer_state.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/auth_state_provider.dart';
import 'package:chessever/theme/app_theme.dart';

const _tabular = [FontFeature.tabularFigures()];

/// Mounts the Botvinnik dock beside the tab stack. Renders nothing while the
/// dock is closed, Botvinnik is switched off in Settings, or the build has the
/// chatbot disabled.
class BotvinnikDockHost extends ConsumerWidget {
  const BotvinnikDockHost({super.key, this.visible = true});

  /// False while the board focus mode hides the rest of the shell chrome.
  final bool visible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.watch(botvinnikDockProvider);
    final enabled =
        ChatApi.buildEnabled &&
        (ref.watch(botvinnikEnabledProvider).valueOrNull ?? true);
    if (!visible || !dock.open || !enabled) return const SizedBox.shrink();
    // The width is the user's drag-resized split, clamped by the notifier.
    return SizedBox(width: dock.width, child: const BotvinnikDock());
  }
}

class BotvinnikDock extends ConsumerStatefulWidget {
  const BotvinnikDock({super.key});

  @override
  ConsumerState<BotvinnikDock> createState() => _BotvinnikDockState();
}

class _BotvinnikDockState extends ConsumerState<BotvinnikDock> {
  late final FocusNode _composerFocus = FocusNode(
    debugLabel: 'botvinnik-composer',
    onKeyEvent: _handleComposerKey,
  );

  @override
  void initState() {
    super.initState();
    unawaited(
      Future<void>.microtask(() {
        if (!mounted) return;
        unawaited(
          ref.read(botvinnikChatControllerProvider.notifier).ensureLoaded(),
        );
        _composerFocus.requestFocus();
      }),
    );
  }

  @override
  void dispose() {
    _composerFocus.dispose();
    super.dispose();
  }

  /// Enter sends; Shift+Enter falls through so the field inserts a newline.
  /// An active IME composition keeps Enter for itself.
  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    final chat = ref.read(botvinnikChatControllerProvider.notifier);
    if (chat.draft.value.composing.isValid) return KeyEventResult.ignored;
    unawaited(_send());
    return KeyEventResult.handled;
  }

  Future<void> _send() =>
      _handleResult(ref.read(botvinnikChatControllerProvider.notifier).send());

  Future<void> _sendSuggestion(String prompt) => _handleResult(
    ref.read(botvinnikChatControllerProvider.notifier).sendSuggestion(prompt),
  );

  Future<void> _handleResult(Future<BotvinnikSendResult> pending) async {
    final result = await pending;
    if (!mounted) return;
    if (result == BotvinnikSendResult.signInRequired) {
      await _signIn();
    } else if (result == BotvinnikSendResult.reconciled) {
      showDesktopToast(context, 'That question already reached Botvinnik.');
    }
  }

  Future<void> _signIn() async {
    final signedIn = await showBotvinnikSignIn(context);
    if (!mounted) return;
    if (signedIn) {
      final chat = ref.read(botvinnikChatControllerProvider.notifier);
      final state = ref.read(botvinnikChatControllerProvider);
      if (!state.loaded && !state.loading) unawaited(chat.load());
      unawaited(ref.read(botvinnikQuotaProvider.notifier).refresh());
    }
    _composerFocus.requestFocus();
  }

  void _openPlans() {
    ref.read(desktopTabsProvider.notifier).open(TabKind.settings);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      botvinnikDockProvider.select((dock) => dock.focusRequest),
      (_, _) => _composerFocus.requestFocus(),
    );
    final chat = ref.watch(botvinnikChatControllerProvider);
    final controller = ref.read(botvinnikChatControllerProvider.notifier);
    final dock = ref.watch(botvinnikDockProvider);
    final user = ref.watch(currentUserProvider);
    final quota = ref.watch(botvinnikQuotaProvider);
    final signedIn =
        user != null && !user.isAnonymous && controller.hasPermanentSession;
    final access = chatComposerAccess(
      isSignedIn: signedIn,
      quota: quota.valueOrNull,
    );
    final showingHistory = dock.showingHistory && signedIn;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            () => ref.read(botvinnikDockProvider.notifier).close(),
      },
      child: FocusTraversalGroup(
        child: DecoratedBox(
          decoration: const BoxDecoration(color: kBlack2Color),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _DockResizeEdge(),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DockHeader(
                      conversationTitle:
                          chat.selected == null || chat.selected!.isDraft
                              ? null
                              : chat.selected!.title,
                      signedIn: signedIn,
                      showingHistory: showingHistory,
                      sending: chat.sending,
                    ),
                    if (signedIn) _AllowanceLine(quota: quota),
                    const Divider(height: 1, color: kDividerColor),
                    Expanded(
                      child:
                          showingHistory
                              ? _HistoryList(
                                conversations: chat.conversations,
                                selectedId: chat.selected?.id,
                                loading: chat.loading,
                              )
                              : _ConversationBody(
                                state: chat,
                                signedIn: signedIn,
                                onSuggestion: _sendSuggestion,
                              ),
                    ),
                    if (chat.error != null)
                      _ErrorLine(
                        message: chat.error!,
                        onDismiss: controller.dismissError,
                      ),
                    _Composer(
                      controller: controller.draft,
                      focusNode: _composerFocus,
                      access: access,
                      quota: quota.valueOrNull,
                      sending: chat.sending,
                      screenContext: chat.screenContext,
                      onSend: _send,
                      onSignIn: _signIn,
                      onOpenPlans: _openPlans,
                      onClearContext: () => controller.setScreenContext(null),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dock's left edge: a 1px seam that doubles as the resize handle.
class _DockResizeEdge extends ConsumerStatefulWidget {
  const _DockResizeEdge();

  @override
  ConsumerState<_DockResizeEdge> createState() => _DockResizeEdgeState();
}

class _DockResizeEdgeState extends ConsumerState<_DockResizeEdge> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap:
            () => ref
                .read(botvinnikDockProvider.notifier)
                .setWidth(kBotvinnikDockDefaultWidth),
        onHorizontalDragUpdate: (details) {
          final notifier = ref.read(botvinnikDockProvider.notifier);
          notifier.setWidth(
            ref.read(botvinnikDockProvider).width - details.delta.dx,
          );
        },
        child: SizedBox(
          width: 6,
          child: Align(
            alignment: Alignment.centerLeft,
            child: ColoredBox(
              color:
                  _active ? kWhiteColor.withValues(alpha: 0.22) : kDividerColor,
              child: const SizedBox(width: 1, height: double.infinity),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockHeader extends ConsumerWidget {
  const _DockHeader({
    required this.conversationTitle,
    required this.signedIn,
    required this.showingHistory,
    required this.sending,
  });

  final String? conversationTitle;
  final bool signedIn;
  final bool showingHistory;
  final bool sending;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dock = ref.read(botvinnikDockProvider.notifier);
    final chat = ref.read(botvinnikChatControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 6),
      child: Row(
        children: [
          const BotvinnikMark(size: 30),
          // The asset carries ~6px of transparent margin at this size, so a
          // small gap gives an optical ~10px between the mark and the title.
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Botvinnik',
                  style: TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  showingHistory
                      ? 'Your chats'
                      : conversationTitle ?? 'New chat',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                ),
              ],
            ),
          ),
          _DockIconButton(
            icon: Icons.history_rounded,
            tooltip: signedIn ? 'Your chats' : 'Sign in to see your chats',
            selected: showingHistory,
            onPress:
                signedIn && !sending
                    ? () => dock.showHistory(!showingHistory)
                    : null,
          ),
          _DockIconButton(
            icon: Icons.add_comment_outlined,
            tooltip: 'New chat',
            onPress:
                sending
                    ? null
                    : () {
                      chat.startNewConversation();
                      dock.showHistory(false);
                      dock.requestComposerFocus();
                    },
          ),
          _DockIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close Botvinnik (Esc)',
            onPress: dock.close,
          ),
        ],
      ),
    );
  }
}

/// The account's daily allowance as the API reports it. Every figure here is
/// read from [ChatQuotaStatus]; nothing is assumed.
class _AllowanceLine extends ConsumerWidget {
  const _AllowanceLine({required this.quota});

  final AsyncValue<ChatQuotaStatus?> quota;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const base = TextStyle(
      color: kWhiteColor70,
      fontSize: 12,
      height: 1.3,
      fontFeatures: _tabular,
    );
    final value = quota.valueOrNull;
    Widget line;
    if (quota.hasError && value == null) {
      line = Row(
        children: [
          const Expanded(
            child: Text(
              "Couldn't load today's allowance.",
              style: base,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _DockTextButton(
            label: 'Retry',
            onPress: () => ref.read(botvinnikQuotaProvider.notifier).refresh(),
          ),
        ],
      );
    } else if (value == null) {
      // Reserve the line while the allowance loads so nothing below shifts.
      line = const Text(' ', style: base);
    } else {
      line = Row(
        children: [
          Expanded(
            child: Text.rich(
              botvinnikAllowanceSpan(value),
              style: base,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (value.resetsAt != null && value.limit > 0)
            Text(
              botvinnikResetLabel(value.resetsAt!, DateTime.now()),
              style: base.copyWith(color: kLightGreyColor),
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 16),
        child: line,
      ),
    );
  }
}

/// Allowance copy for the three account states. Numbers come from [quota].
@visibleForTesting
TextSpan botvinnikAllowanceSpan(ChatQuotaStatus quota) {
  const strong = TextStyle(color: kWhiteColor, fontWeight: FontWeight.w600);
  final access = chatComposerAccess(isSignedIn: true, quota: quota);
  final number = NumberFormat.decimalPattern();
  switch (access) {
    case ChatComposerAccess.upgradeRequired:
      return const TextSpan(text: 'Botvinnik messages are not in your plan');
    case ChatComposerAccess.exhausted:
      return TextSpan(
        children: [
          TextSpan(text: quota.isPremium ? 'Premium: ' : ''),
          const TextSpan(text: 'no messages left today', style: strong),
        ],
      );
    case ChatComposerAccess.enabled:
    case ChatComposerAccess.signedOut:
      return TextSpan(
        children: [
          TextSpan(text: quota.isPremium ? 'Premium: ' : ''),
          TextSpan(text: number.format(quota.remaining), style: strong),
          TextSpan(
            text: ' of ${number.format(quota.limit)} messages left today',
          ),
        ],
      );
  }
}

@visibleForTesting
String botvinnikResetLabel(DateTime resetsAt, DateTime now) {
  final local = resetsAt.toLocal();
  final time = DateFormat.Hm().format(local);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return 'Resets $time';
  if (day.difference(today).inDays == 1) return 'Resets tomorrow $time';
  return 'Resets ${DateFormat.MMMd().format(local)}';
}

class _ConversationBody extends StatelessWidget {
  const _ConversationBody({
    required this.state,
    required this.signedIn,
    required this.onSuggestion,
  });

  final BotvinnikChatState state;
  final bool signedIn;
  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    if (signedIn && state.loading && state.messages.isEmpty) {
      return const Center(
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      );
    }
    if (state.messages.isEmpty) {
      return _EmptyConversation(
        screenContext: state.screenContext,
        onSuggestion: state.sending ? null : onSuggestion,
      );
    }
    return _MessageList(state: state);
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({
    required this.screenContext,
    required this.onSuggestion,
  });

  final ChatScreenContext? screenContext;
  final ValueChanged<String>? onSuggestion;

  @override
  Widget build(BuildContext context) {
    final subject = botvinnikContextSubject(screenContext);
    final suggestions = chatSuggestionsForScreen(screenContext?.screen);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            subject == null ? 'Ask about live chess' : 'Ask about $subject',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 20,
              fontWeight: FontWeight.w600,
              height: 1.25,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Events, rounds, games and standings. Ask in any language.',
            style: TextStyle(color: kWhiteColor70, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 22),
          for (final suggestion in suggestions) ...[
            _SuggestionRow(
              suggestion: suggestion,
              onPress:
                  onSuggestion == null
                      ? null
                      : () => onSuggestion!(suggestion.prompt),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 14),
          const Text(
            'Botvinnik can make mistakes. Check important results.',
            style: TextStyle(color: kLightGreyColor, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Human name of what a launch was about, if the context carries one.
@visibleForTesting
String? botvinnikContextSubject(ChatScreenContext? context) {
  if (context == null) return null;
  String? clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  return clean(context.gameLabel) ??
      clean(context.playerName) ??
      clean(context.tournamentName) ??
      clean(context.eventName);
}

class _SuggestionRow extends StatefulWidget {
  const _SuggestionRow({required this.suggestion, required this.onPress});

  final ChatSuggestion suggestion;
  final VoidCallback? onPress;

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow>
    with DeferredPointerStateMixin<_SuggestionRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final hovered = enabled && _hovered;
    return CursorAware(
      mode: enabled ? CursorMode.hover : CursorMode.pointer,
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit:
            (_) => setStateAfterPointerEvent(() {
              _hovered = false;
              _pressed = false;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPress,
          onTapDown: (_) => setStateAfterPointerEvent(() => _pressed = true),
          onTapUp: (_) => setStateAfterPointerEvent(() => _pressed = false),
          onTapCancel: () => setStateAfterPointerEvent(() => _pressed = false),
          child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.suggestion.label,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
              decoration: BoxDecoration(
                color: hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: kDividerColor),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.suggestion.label,
                          style: TextStyle(
                            color: enabled ? kWhiteColor : kLightGreyColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.suggestion.prompt,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SingleMotionBuilder(
                    value: _pressed ? 0.0 : (hovered ? 2.5 : 0.0),
                    motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
                    builder:
                        (context, shift, child) => Transform.translate(
                          offset: Offset(shift, -shift),
                          child: child,
                        ),
                    child: Icon(
                      Icons.north_east_rounded,
                      size: 15,
                      color: hovered ? kWhiteColor : kLightGreyColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageList extends ConsumerStatefulWidget {
  const _MessageList({required this.state});

  final BotvinnikChatState state;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  final ScrollController _scroll = ScrollController();

  /// True while the reader sits at the bottom. Streaming only follows the
  /// answer in that case; a reader who scrolled up stays where they are.
  bool _following = true;
  bool _showJump = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _jumpToEnd();
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.state;
    final next = widget.state;
    final conversationChanged = previous.selected?.id != next.selected?.id;
    final grew = next.messages.length > previous.messages.length;
    if (conversationChanged || (grew && next.sending)) _following = true;
    final contentChanged =
        grew ||
        conversationChanged ||
        (next.messages.isNotEmpty &&
            previous.messages.isNotEmpty &&
            next.messages.last.content != previous.messages.last.content);
    if (_following && contentChanged) _jumpToEnd();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atEnd = position.maxScrollExtent - position.pixels <= 32;
    if (atEnd != _following || atEnd == _showJump) {
      setState(() {
        _following = atEnd;
        _showJump = !atEnd;
      });
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final router = ref.watch(botvinnikReferenceRouterProvider);
    final messages = state.messages;
    return Stack(
      children: [
        Positioned.fill(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            itemCount: messages.length,
            itemBuilder: (context, index) {
              final message = messages[index];
              final streaming = state.sending && index == messages.length - 1;
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child:
                    message.role == 'user'
                        ? _UserMessage(message: message)
                        : _AssistantMessage(
                          message: message,
                          streaming: streaming,
                          feedbackPending: state.feedbackPending.contains(
                            message.id,
                          ),
                          router: router,
                        ),
              );
            },
          ),
        ),
        if (_showJump)
          Positioned(
            right: 16,
            bottom: 12,
            child: DesktopToolbarPillButton(
              label: 'Latest',
              icon: Icons.arrow_downward_rounded,
              onPress: () {
                setState(() {
                  _following = true;
                  _showJump = false;
                });
                _jumpToEnd();
              },
            ),
          ),
      ],
    );
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kBlack3Color,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: SelectionArea(
              child: Text(
                message.content,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AssistantMessage extends ConsumerWidget {
  const _AssistantMessage({
    required this.message,
    required this.streaming,
    required this.feedbackPending,
    required this.router,
  });

  final ChatMessage message;
  final bool streaming;
  final bool feedbackPending;
  final BotvinnikReferenceRouter router;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (context.mounted) showDesktopToast(context, 'Message copied');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.read(botvinnikChatControllerProvider.notifier);
    final openable = [
      for (final reference in message.references)
        if (router.canOpen(reference)) reference,
    ];
    final markdown =
        integrateChatReferences(
          normalizeChatMarkdown(message.content),
          openable,
        ).markdown;
    final persisted = !message.id.startsWith('local-');
    final waiting = message.content.isEmpty && streaming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Botvinnik',
          style: TextStyle(
            color: kWhiteColor70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        if (waiting)
          const Row(
            children: [
              Text(
                'Thinking',
                style: TextStyle(color: kWhiteColor70, fontSize: 13.5),
              ),
              SizedBox(width: 6),
              _StreamingCaret(),
            ],
          )
        else
          SelectionArea(
            child: MarkdownBody(
              data: markdown,
              softLineBreak: true,
              styleSheet: _markdownStyle(context),
              onTapLink: (text, href, title) {
                final reference = chatReferenceForHref(href, openable);
                if (reference != null) {
                  unawaited(router.open(ref, reference));
                  return;
                }
                final uri = safeChatSourceUri(href);
                if (uri != null) unawaited(launchDesktopWebUrl(uri));
              },
            ),
          ),
        if (streaming && !waiting) ...[
          const SizedBox(height: 6),
          const Align(
            alignment: Alignment.centerLeft,
            child: _StreamingCaret(),
          ),
        ],
        if (!streaming && message.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Transform.translate(
                  // Pull the first 40px hit area back so its glyph sits on
                  // the text's left edge.
                  offset: const Offset(-12, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _DockIconButton(
                        icon: Icons.content_copy_rounded,
                        iconSize: 15,
                        tooltip: 'Copy message',
                        onPress: () => _copy(context),
                      ),
                      if (persisted) ...[
                        _DockIconButton(
                          icon:
                              message.feedback == 'like'
                                  ? Icons.thumb_up_alt_rounded
                                  : Icons.thumb_up_alt_outlined,
                          iconSize: 15,
                          tooltip: 'Helpful',
                          selected: message.feedback == 'like',
                          onPress:
                              feedbackPending
                                  ? null
                                  : () => chat.setFeedback(message, 'like'),
                        ),
                        _DockIconButton(
                          icon:
                              message.feedback == 'dislike'
                                  ? Icons.thumb_down_alt_rounded
                                  : Icons.thumb_down_alt_outlined,
                          iconSize: 15,
                          tooltip: 'Not helpful',
                          selected: message.feedback == 'dislike',
                          onPress:
                              feedbackPending
                                  ? null
                                  : () => chat.setFeedback(message, 'dislike'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

MarkdownStyleSheet _markdownStyle(BuildContext context) {
  const body = TextStyle(color: kWhiteColor, fontSize: 13.5, height: 1.5);
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    p: body,
    a: const TextStyle(color: kPrimaryColor, fontWeight: FontWeight.w500),
    strong: const TextStyle(color: kWhiteColor, fontWeight: FontWeight.w600),
    em: const TextStyle(color: kWhiteColor, fontStyle: FontStyle.italic),
    h1: body.copyWith(fontSize: 17, fontWeight: FontWeight.w600, height: 1.3),
    h2: body.copyWith(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.3),
    h3: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.3),
    listBullet: body.copyWith(color: kWhiteColor70),
    tableHead: body.copyWith(fontWeight: FontWeight.w600, fontSize: 12.5),
    tableBody: body.copyWith(fontSize: 12.5, fontFeatures: _tabular),
    tableBorder: TableBorder.all(color: kDividerColor),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    code: const TextStyle(
      color: kWhiteColor,
      fontSize: 12.5,
      backgroundColor: kBlack3Color,
    ),
    codeblockDecoration: BoxDecoration(
      color: kBackgroundColor,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: kDividerColor),
    ),
    blockquoteDecoration: BoxDecoration(
      color: kBlack3Color,
      borderRadius: BorderRadius.circular(8),
    ),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: kDividerColor)),
    ),
    blockSpacing: 10,
  );
}

/// The one moving thing in a streaming answer. It sits after text that is
/// already on screen; the answer itself never waits on an animation.
class _StreamingCaret extends StatefulWidget {
  const _StreamingCaret();

  @override
  State<_StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<_StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _pulse
        ..stop()
        ..value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(_pulse),
      child: const SizedBox(
        width: 7,
        height: 15,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: kPrimaryColor,
            borderRadius: BorderRadius.all(Radius.circular(1.5)),
          ),
        ),
      ),
    );
  }
}

class _HistoryList extends ConsumerWidget {
  const _HistoryList({
    required this.conversations,
    required this.selectedId,
    required this.loading,
  });

  final List<ChatConversation> conversations;
  final String? selectedId;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (conversations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        child: Text(
          loading ? 'Loading your chats' : 'No chats yet.',
          style: const TextStyle(color: kWhiteColor70, fontSize: 13),
        ),
      );
    }
    final chat = ref.read(botvinnikChatControllerProvider.notifier);
    final dock = ref.read(botvinnikDockProvider.notifier);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        return _ConversationRow(
          conversation: conversation,
          selected: conversation.id == selectedId,
          onOpen: () {
            dock.showHistory(false);
            unawaited(chat.select(conversation));
          },
          onDelete: () => unawaited(chat.delete(conversation)),
        );
      },
    );
  }
}

class _ConversationRow extends StatefulWidget {
  const _ConversationRow({
    required this.conversation,
    required this.selected,
    required this.onOpen,
    required this.onDelete,
  });

  final ChatConversation conversation;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  State<_ConversationRow> createState() => _ConversationRowState();
}

class _ConversationRowState extends State<_ConversationRow>
    with DeferredPointerStateMixin<_ConversationRow> {
  bool _hovered = false;

  Future<void> _showMenu(Offset position) async {
    final action = await showDesktopContextMenu<String>(
      context: context,
      position: position,
      entries: const [
        DesktopContextMenuItem(
          value: 'open',
          icon: Icons.chat_outlined,
          label: 'Open chat',
        ),
        DesktopContextMenuItem(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: 'Delete chat',
          destructive: true,
        ),
      ],
    );
    if (!mounted) return;
    if (action == 'open') widget.onOpen();
    if (action == 'delete') widget.onDelete();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fg =
        selected ? kPrimaryColor : (_hovered ? kWhiteColor : kWhiteColor70);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: CursorAware(
        mode: CursorMode.hover,
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpen,
            onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
            child: Container(
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                color:
                    selected
                        ? kPrimaryColor.withValues(
                          alpha: _hovered ? 0.16 : 0.10,
                        )
                        : (_hovered ? kBlack3Color : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      selected
                          ? kPrimaryColor.withValues(alpha: 0.35)
                          : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  // The slot is always reserved so rows never shift on hover.
                  Opacity(
                    opacity: _hovered || selected ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !(_hovered || selected),
                      child: _DockIconButton(
                        icon: Icons.delete_outline_rounded,
                        iconSize: 16,
                        tooltip: 'Delete chat',
                        onPress: widget.onDelete,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, size: 15, color: kRedColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
            ),
            _DockIconButton(
              icon: Icons.close_rounded,
              iconSize: 15,
              tooltip: 'Dismiss',
              onPress: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.access,
    required this.quota,
    required this.sending,
    required this.screenContext,
    required this.onSend,
    required this.onSignIn,
    required this.onOpenPlans,
    required this.onClearContext,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ChatComposerAccess access;
  final ChatQuotaStatus? quota;
  final bool sending;
  final ChatScreenContext? screenContext;
  final VoidCallback onSend;
  final VoidCallback onSignIn;
  final VoidCallback onOpenPlans;
  final VoidCallback onClearContext;

  @override
  Widget build(BuildContext context) {
    final subject = botvinnikContextSubject(screenContext);
    final notice = botvinnikComposerNotice(access, quota, DateTime.now());
    final blocked =
        access == ChatComposerAccess.exhausted ||
        access == ChatComposerAccess.upgradeRequired;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      notice,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 12.5,
                        height: 1.4,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ),
                  if (access == ChatComposerAccess.signedOut) ...[
                    const SizedBox(width: 10),
                    DesktopToolbarPillButton(
                      label: 'Sign in',
                      icon: Icons.login_rounded,
                      height: 40,
                      tone: DesktopToolbarPillTone.primary,
                      onPress: onSignIn,
                    ),
                  ],
                  if (access == ChatComposerAccess.upgradeRequired) ...[
                    const SizedBox(width: 10),
                    DesktopToolbarPillButton(
                      label: 'See Premium',
                      icon: Icons.workspace_premium_outlined,
                      height: 40,
                      tone: DesktopToolbarPillTone.primary,
                      tooltip: 'Open plans in Settings',
                      onPress: onOpenPlans,
                    ),
                  ],
                ],
              ),
            ),
          if (subject != null)
            Row(
              children: [
                const Text(
                  'About ',
                  style: TextStyle(color: kLightGreyColor, fontSize: 12),
                ),
                Expanded(
                  child: Text(
                    subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: kWhiteColor70, fontSize: 12),
                  ),
                ),
                _DockIconButton(
                  icon: Icons.close_rounded,
                  iconSize: 14,
                  tooltip: 'Stop sending this context',
                  onPress: sending ? null : onClearContext,
                ),
              ],
            ),
          _ComposerField(
            controller: controller,
            focusNode: focusNode,
            canSend: !blocked && !sending,
            sending: sending,
            onSend: onSend,
          ),
          const SizedBox(height: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final count = value.text.characters.length;
              return Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Enter to send, Shift+Enter for a new line',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: kLightGreyColor, fontSize: 11),
                    ),
                  ),
                  if (count >= kChatComposerMaxLength * 0.8)
                    Text(
                      '${NumberFormat.decimalPattern().format(count)} / '
                      '${NumberFormat.decimalPattern().format(kChatComposerMaxLength)}',
                      style: TextStyle(
                        color:
                            count >= kChatComposerMaxLength
                                ? kRedColor
                                : kLightGreyColor,
                        fontSize: 11,
                        fontFeatures: _tabular,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Copy shown above the composer for each gate, or null when sending is open.
@visibleForTesting
String? botvinnikComposerNotice(
  ChatComposerAccess access,
  ChatQuotaStatus? quota,
  DateTime now,
) {
  switch (access) {
    case ChatComposerAccess.enabled:
      return null;
    case ChatComposerAccess.signedOut:
      return 'Botvinnik needs a ChessEver account. Your draft stays here.';
    case ChatComposerAccess.upgradeRequired:
      return 'Your plan has no Botvinnik messages. Premium adds a daily allowance.';
    case ChatComposerAccess.exhausted:
      final limit = quota?.limit ?? 0;
      final plan = quota?.isPremium ?? false ? 'Premium ' : '';
      final used =
          'You have used all ${NumberFormat.decimalPattern().format(limit)} '
          '${plan}messages for today.';
      final resetsAt = quota?.resetsAt;
      if (resetsAt == null) return used;
      final reset = botvinnikResetLabel(resetsAt, now);
      return '$used ${reset.replaceFirst('Resets', 'Sending opens again')}.';
  }
}

class _ComposerField extends StatefulWidget {
  const _ComposerField({
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final bool sending;
  final VoidCallback onSend;

  @override
  State<_ComposerField> createState() => _ComposerFieldState();
}

class _ComposerFieldState extends State<_ComposerField> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant _ComposerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusNode.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: kBackgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color:
              focused ? kPrimaryColor.withValues(alpha: 0.45) : kDividerColor,
        ),
      ),
      // Outer radius 12 = send button radius 8 + 4px inset, so the corners
      // stay concentric.
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                minLines: 1,
                maxLines: 8,
                maxLength: kChatComposerMaxLength,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                buildCounter:
                    (
                      context, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => null,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: kPrimaryColor,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13.5,
                  height: 1.45,
                ),
                decoration: const InputDecoration.collapsed(
                  hintText: 'Ask Botvinnik',
                  hintStyle: TextStyle(color: kLightGreyColor, fontSize: 13.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (context, value, _) {
              final ready = widget.canSend && value.text.trim().isNotEmpty;
              return _SendButton(
                sending: widget.sending,
                onPress: ready ? widget.onSend : null,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({required this.sending, required this.onPress});

  final bool sending;
  final VoidCallback? onPress;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton>
    with DeferredPointerStateMixin<_SendButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final hovered = enabled && _hovered;
    return DesktopTooltip(
      message: widget.sending ? 'Botvinnik is answering' : 'Send (Enter)',
      child: CursorAware(
        mode: enabled ? CursorMode.hover : CursorMode.pointer,
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPress,
            child: Semantics(
              button: true,
              enabled: enabled,
              label: 'Send',
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:
                      enabled
                          ? kPrimaryColor.withValues(
                            alpha: hovered ? 0.16 : 0.10,
                          )
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        enabled
                            ? kPrimaryColor.withValues(alpha: 0.35)
                            : kDividerColor,
                  ),
                ),
                child:
                    widget.sending
                        ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                          ),
                        )
                        : Icon(
                          Icons.arrow_upward_rounded,
                          size: 18,
                          color: enabled ? kPrimaryColor : kLightGreyColor,
                        ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 40x40 icon control in the sidebar vocabulary: transparent at rest, black-3
/// on hover, brand tint when selected, muted when disabled.
class _DockIconButton extends StatefulWidget {
  const _DockIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPress,
    this.selected = false,
    this.iconSize = 18,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPress;
  final bool selected;
  final double iconSize;

  @override
  State<_DockIconButton> createState() => _DockIconButtonState();
}

class _DockIconButtonState extends State<_DockIconButton>
    with DeferredPointerStateMixin<_DockIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPress != null;
    final hovered = enabled && _hovered;
    final fg =
        !enabled
            ? kLightGreyColor
            : widget.selected
            ? kPrimaryColor
            : (hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        widget.selected
            ? kPrimaryColor.withValues(alpha: hovered ? 0.16 : 0.10)
            : (hovered ? kBlack3Color : Colors.transparent);
    return DesktopTooltip(
      message: widget.tooltip,
      child: CursorAware(
        mode: enabled ? CursorMode.hover : CursorMode.pointer,
        child: MouseRegion(
          onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
          onExit:
              (_) => setStateAfterPointerEvent(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPress,
            onTapDown: (_) => setStateAfterPointerEvent(() => _pressed = true),
            onTapUp: (_) => setStateAfterPointerEvent(() => _pressed = false),
            onTapCancel:
                () => setStateAfterPointerEvent(() => _pressed = false),
            child: Semantics(
              button: true,
              enabled: enabled,
              selected: widget.selected,
              label: widget.tooltip,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        widget.selected
                            ? kPrimaryColor.withValues(alpha: 0.35)
                            : Colors.transparent,
                  ),
                ),
                child: SingleMotionBuilder(
                  value: _pressed ? 0.94 : 1.0,
                  motion: DesktopMotion.tap,
                  builder:
                      (context, scale, child) =>
                          Transform.scale(scale: scale, child: child),
                  child: Icon(widget.icon, size: widget.iconSize, color: fg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockTextButton extends StatefulWidget {
  const _DockTextButton({required this.label, required this.onPress});

  final String label;
  final VoidCallback onPress;

  @override
  State<_DockTextButton> createState() => _DockTextButtonState();
}

class _DockTextButtonState extends State<_DockTextButton>
    with DeferredPointerStateMixin<_DockTextButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return CursorAware(
      mode: CursorMode.hover,
      child: MouseRegion(
        onEnter: (_) => setStateAfterPointerEvent(() => _hovered = true),
        onExit: (_) => setStateAfterPointerEvent(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: _hovered ? kWhiteColor : kPrimaryColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
