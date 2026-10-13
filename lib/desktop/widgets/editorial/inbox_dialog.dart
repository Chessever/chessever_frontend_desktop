import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/editorial/inbox_provider.dart';
import 'package:chessever/desktop/services/editorial/editorial_links.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopInboxDialog extends ConsumerStatefulWidget {
  const DesktopInboxDialog({super.key});
  static Future<void> show(BuildContext context) => showFDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierLabel: 'Inbox',
    builder:
        (context, style, animation) => FDialog.raw(
          style: (_) => style,
          animation: animation,
          semanticsLabel: 'Inbox',
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 940),
          builder: (context, _) => const DesktopInboxDialog(),
        ),
  );
  @override
  ConsumerState<DesktopInboxDialog> createState() => _DesktopInboxDialogState();
}

class _DesktopInboxDialogState extends ConsumerState<DesktopInboxDialog> {
  String? selected;
  (String?, String, DateTime)? _rendered;
  Future<void> _openLink(Uri uri) => openDesktopEditorialLink(
    context,
    uri,
    beforeNavigate: () {
      if (mounted) Navigator.of(context).pop();
    },
  );
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(inboxProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(inboxProvider);
    final controller = ref.read(inboxProvider.notifier);
    final message = selected == null ? null : state.message(selected!);
    if (message != null) {
      final key = (state.ownerId, message.id, message.publishedAt);
      if (_rendered != key) {
        _rendered = key;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final current = ref.read(inboxProvider);
          if (current.ownerId == state.ownerId &&
              current.message(message.id)?.publishedAt == message.publishedAt) {
            unawaited(controller.markOpened(message.id));
          }
        });
      }
    }
    final viewport = MediaQuery.sizeOf(context);
    return SizedBox(
      width: (viewport.width - 80).clamp(280, 900),
      height: (viewport.height - 160).clamp(280, 620),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Inbox',
                    style: TextStyle(
                      color: kWhiteColor,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                DesktopToolbarPillButton(
                  label: 'Refresh',
                  icon: Icons.refresh,
                  onPress:
                      state.refreshing
                          ? null
                          : () => unawaited(controller.refresh()),
                ),
                const SizedBox(width: 12),
                FButton.raw(
                  style: FButtonStyle.ghost(),
                  onPress: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.close, size: 18, color: kWhiteColor70),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (state.syncError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  state.syncError!,
                  style: const TextStyle(color: kWhiteColor70),
                ),
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 240,
                    child:
                        state.loading
                            ? const Center(child: CircularProgressIndicator())
                            : state.messages.isEmpty
                            ? const Center(
                              child: Text(
                                'No messages',
                                style: TextStyle(color: kWhiteColor70),
                              ),
                            )
                            : ListView.separated(
                              itemCount: state.messages.length,
                              separatorBuilder:
                                  (_, _) => const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final row = state.messages[index];
                                return FButton.raw(
                                  style: FButtonStyle.ghost(),
                                  onPress:
                                      () => setState(() => selected = row.id),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color:
                                          row.id == selected
                                              ? kBlack3Color
                                              : Colors.transparent,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                row.title,
                                                style: TextStyle(
                                                  color: kWhiteColor,
                                                  fontSize: 14,
                                                  fontWeight:
                                                      row.isUnread
                                                          ? FontWeight.w700
                                                          : FontWeight.w500,
                                                ),
                                              ),
                                              const SizedBox(height: 5),
                                              Text(
                                                row.previewText,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: kWhiteColor70,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (row.isUnread)
                                          const Padding(
                                            padding: EdgeInsets.only(left: 8),
                                            child: DesktopInboxDot(),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child:
                        message == null
                            ? Center(
                              child: Text(
                                selected == null
                                    ? 'Choose a message'
                                    : 'This message has been taken back or removed.',
                                style: const TextStyle(color: kWhiteColor70),
                              ),
                            )
                            : SelectionArea(
                              child: ListView(
                                children: [
                                  Text(
                                    message.title,
                                    style: const TextStyle(
                                      color: kWhiteColor,
                                      fontSize: 24,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  if (editorialImage(message.imageUrl)
                                      case final image?)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 20,
                                      ),
                                      child: Image.network(
                                        image.toString(),
                                        fit: BoxFit.contain,
                                        errorBuilder:
                                            (_, _, _) =>
                                                const SizedBox.shrink(),
                                      ),
                                    ),
                                  if (message.isMarkdown)
                                    MarkdownBody(
                                      data: message.body,
                                      softLineBreak: true,
                                      styleSheet: MarkdownStyleSheet(
                                        p: const TextStyle(
                                          color: kWhiteColor,
                                          fontSize: 14,
                                          height: 1.7,
                                        ),
                                        h1: const TextStyle(
                                          color: kWhiteColor,
                                          fontSize: 24,
                                        ),
                                        h2: const TextStyle(
                                          color: kWhiteColor,
                                          fontSize: 20,
                                        ),
                                        h3: const TextStyle(
                                          color: kWhiteColor,
                                          fontSize: 17,
                                        ),
                                        a: const TextStyle(
                                          color: kPrimaryColor,
                                        ),
                                      ),
                                      imageBuilder:
                                          (uri, title, alt) =>
                                              editorialImage(uri.toString()) ==
                                                      null
                                                  ? const SizedBox.shrink()
                                                  : Image.network(
                                                    uri.toString(),
                                                    errorBuilder:
                                                        (_, _, _) =>
                                                            const SizedBox.shrink(),
                                                  ),
                                      onTapLink: (_, href, _) {
                                        final uri = editorialLink(href);
                                        if (uri != null) {
                                          unawaited(_openLink(uri));
                                        }
                                      },
                                    )
                                  else
                                    Text(
                                      message.body,
                                      style: const TextStyle(
                                        color: kWhiteColor,
                                        fontSize: 14,
                                        height: 1.7,
                                      ),
                                    ),
                                  if (message.actionLabel != null &&
                                      editorialLink(message.actionUrl) != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 24),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: DesktopToolbarPillButton(
                                          label: message.actionLabel!,
                                          icon: Icons.north_east,
                                          onPress:
                                              () => unawaited(
                                                _openLink(
                                                  editorialLink(
                                                    message.actionUrl,
                                                  )!,
                                                ),
                                              ),
                                        ),
                                      ),
                                    ),
                                  if (state.markErrors[message.id]
                                      case final error?)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 20),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            error,
                                            style: const TextStyle(
                                              color: kWhiteColor70,
                                            ),
                                          ),
                                          DesktopToolbarPillButton(
                                            label: 'Retry read',
                                            icon: Icons.refresh,
                                            onPress:
                                                () => unawaited(
                                                  controller.markOpened(
                                                    message.id,
                                                  ),
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DesktopInboxDot extends StatelessWidget {
  const DesktopInboxDot({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Unread Inbox messages',
    child: Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: kPrimaryColor,
        shape: BoxShape.circle,
      ),
    ),
  );
}

class DesktopInboxUnreadAnchor extends ConsumerWidget {
  const DesktopInboxUnreadAnchor({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Stack(
    clipBehavior: Clip.none,
    children: [
      child,
      if (ref.watch(inboxHasUnreadProvider))
        const Positioned(
          top: 4,
          right: 8,
          child: IgnorePointer(child: DesktopInboxDot()),
        ),
    ],
  );
}
