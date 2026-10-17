import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/services/editorial/editorial_links.dart';
import 'package:chessever/desktop/services/editorial/inbox_message.dart';
import 'package:chessever/desktop/services/editorial/inbox_provider.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_reader.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_image.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_unread_anchor.dart';
import 'package:chessever/theme/app_theme.dart';

String inboxDate(BuildContext context, DateTime date) => DateFormat.yMMMd(
  Localizations.localeOf(context).toString(),
).format(date.toLocal());

/// Inbox belongs to the desktop workspace. Wide panes keep the list beside
/// the reader; compact panes switch between them without opening a dialog.
class InboxPane extends ConsumerStatefulWidget {
  const InboxPane({super.key, this.tabId});

  final String? tabId;

  @override
  ConsumerState<InboxPane> createState() => _InboxPaneState();
}

class _InboxPaneState extends ConsumerState<InboxPane> {
  (String?, String)? _selected;
  (String?, String, DateTime)? _rendered;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(inboxProvider.notifier).refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(inboxProvider);
    final controller = ref.read(inboxProvider.notifier);
    final selected = _selected?.$1 == state.ownerId ? _selected?.$2 : null;
    final message = selected == null ? null : state.message(selected);
    final active =
        widget.tabId == null ||
        ref.watch(desktopTabsProvider.select((tabs) => tabs.activeId)) ==
            widget.tabId;
    if (message != null && active) {
      final edition = (state.ownerId, message.id, message.publishedAt);
      if (_rendered != edition) {
        _rendered = edition;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _selected != (edition.$1, edition.$2)) return;
          if (widget.tabId != null &&
              ref.read(desktopTabsProvider).activeId != widget.tabId) {
            return;
          }
          final current = ref.read(inboxProvider);
          if (current.ownerId == edition.$1 &&
              current.message(edition.$2)?.publishedAt == edition.$3) {
            unawaited(controller.markOpened(edition.$2));
          }
        });
      }
    }

    if (!active) _rendered = null;
    return FTheme(
      data: FThemes.zinc.dark,
      child: ColoredBox(
        color: kBackgroundColor,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final reading = compact && selected != null;
            return Column(
              children: [
                Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  color: kBlack2Color,
                  child: Row(
                    children: [
                      if (reading) ...[
                        DesktopDialogButton(
                          label: 'Inbox',
                          icon: Icons.arrow_back,
                          onPress: () => setState(() => _selected = null),
                        ),
                        const SizedBox(width: 16),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (!reading)
                              const Text(
                                'Inbox',
                                style: TextStyle(
                                  color: kWhiteColor,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Text(
                              state.loading
                                  ? 'Loading messages…'
                                  : '${state.messages.length} ${state.messages.length == 1 ? 'message' : 'messages'}'
                                      '${state.hasUnread ? ' · ${state.messages.where((m) => m.isUnread).length} unread' : ''}',
                              style: const TextStyle(
                                color: kWhiteColor70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      DesktopDialogButton(
                        label: state.refreshing ? 'Refreshing…' : 'Refresh',
                        icon: Icons.refresh,
                        onPress:
                            state.refreshing
                                ? null
                                : () => unawaited(controller.refresh()),
                      ),
                    ],
                  ),
                ),
                if (state.syncError != null || state.cacheError != null)
                  Container(
                    width: double.infinity,
                    color: kBlack2Color,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      [
                        state.syncError,
                        state.cacheError,
                      ].whereType<String>().join('\n'),
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ),
                Expanded(
                  child:
                      compact
                          ? reading
                              ? _reader(state, message, selected)
                              : _list(state, selected)
                          : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: (constraints.maxWidth * .30).clamp(
                                  260.0,
                                  340.0,
                                ),
                                child: _list(state, selected),
                              ),
                              Expanded(
                                child: _reader(state, message, selected),
                              ),
                            ],
                          ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _reader(InboxState state, InboxMessage? message, String? selected) {
    if (message == null) {
      return _InboxEmpty(
        title:
            selected != null
                ? 'Message unavailable'
                : state.messages.isEmpty
                ? 'Your Inbox'
                : 'Choose a message',
        message:
            selected != null
                ? 'This message has been taken back or removed.'
                : 'Updates and chess tips from the ChessEver team arrive here.',
      );
    }
    return InboxReader(
      key: ValueKey((state.ownerId, message.id)),
      message: message,
      readError: state.markErrors[message.id],
      onRetryRead:
          () => unawaited(
            ref.read(inboxProvider.notifier).markOpened(message.id),
          ),
    );
  }

  Widget _list(InboxState state, String? selected) => ColoredBox(
    color: kBlack2Color,
    child:
        state.loading
            ? const Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: kPrimaryColor,
                ),
              ),
            )
            : state.messages.isEmpty
            ? const _InboxEmpty(
              title: 'No messages yet',
              message:
                  'Updates and chess tips from the ChessEver team arrive here.',
            )
            : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: state.messages.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final message = state.messages[index];
                return _InboxRow(
                  message: message,
                  selected: message.id == selected,
                  onOpen:
                      () => setState(() {
                        _selected = (state.ownerId, message.id);
                        _rendered = null;
                      }),
                );
              },
            ),
  );
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({
    required this.message,
    required this.selected,
    required this.onOpen,
  });

  final InboxMessage message;
  final bool selected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    label: message.isUnread ? 'Unread message' : 'Read message',
    child: FButton.raw(
      key: ValueKey('inbox-row-${message.id}'),
      style: FButtonStyle.ghost(),
      onPress: onOpen,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? kBlack3Color : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    inboxDate(context, message.publishedAt),
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                // The slot stays present after acknowledgement so text never shifts.
                SizedBox.square(
                  dimension: 8,
                  child:
                      message.isUnread
                          ? const Center(child: DesktopInboxDot())
                          : null,
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              message.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                height: 1.4,
                fontWeight:
                    message.isUnread ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    message.previewText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: kWhiteColor70,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
                if (editorialImage(message.imageUrl) case final image?) ...[
                  const SizedBox(width: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: InboxImage(
                      uri: image,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _InboxEmpty extends StatelessWidget {
  const _InboxEmpty({required this.title, required this.message});
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inbox_outlined, size: 32, color: kWhiteColor70),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
