import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/editorial/editorial_links.dart';
import 'package:chessever/desktop/services/editorial/inbox_message.dart';
import 'package:chessever/desktop/widgets/editorial/inbox_image.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// The same plain-text / Markdown, image and action contract as mobile,
/// typeset at reading width with the desktop toolbar's existing controls.
class InboxReader extends ConsumerWidget {
  const InboxReader({
    super.key,
    required this.message,
    this.readError,
    required this.onRetryRead,
  });
  final InboxMessage message;
  final String? readError;
  final VoidCallback onRetryRead;

  static const _bodyStyle = TextStyle(
    color: kWhiteColor,
    fontSize: 15,
    height: 1.7,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open(Uri uri) =>
        unawaited(ref.read(desktopEditorialLinkOpenerProvider)(context, uri));
    Widget image(Uri uri) => ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: InboxImage(uri: uri),
    );

    return SelectionArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 704),
          child: ListView(
            key: PageStorageKey('inbox-reader-${message.id}'),
            padding: const EdgeInsets.all(32),
            children: [
              Text(
                message.title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 26,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                DateFormat.yMMMd(
                  Localizations.localeOf(context).toString(),
                ).format(message.publishedAt.toLocal()),
                style: const TextStyle(color: kWhiteColor70, fontSize: 12),
              ),
              const SizedBox(height: 28),
              if (editorialImage(message.imageUrl) case final uri?) ...[
                image(uri),
                const SizedBox(height: 24),
              ],
              if (message.isMarkdown)
                MarkdownBody(
                  key: const ValueKey('inbox-full-text'),
                  data: message.body,
                  softLineBreak: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(
                    Theme.of(context),
                  ).copyWith(
                    p: _bodyStyle,
                    h1: _bodyStyle.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                    h2: _bodyStyle.copyWith(
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                    h3: _bodyStyle.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                    h4: _bodyStyle.copyWith(fontWeight: FontWeight.w600),
                    h5: _bodyStyle.copyWith(fontWeight: FontWeight.w600),
                    h6: _bodyStyle.copyWith(fontWeight: FontWeight.w600),
                    a: _bodyStyle.copyWith(color: kPrimaryColor),
                    listBullet: _bodyStyle,
                    blockquote: _bodyStyle.copyWith(color: kWhiteColor70),
                    blockquoteDecoration: BoxDecoration(
                      color: kBlack2Color,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    code: _bodyStyle.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      backgroundColor: kBlack2Color,
                    ),
                    codeblockDecoration: BoxDecoration(
                      color: kBlack2Color,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    tableBody: _bodyStyle.copyWith(fontSize: 13),
                    tableHead: _bodyStyle.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    tableBorder: TableBorder.all(color: kDividerColor),
                    horizontalRuleDecoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: kDividerColor)),
                    ),
                  ),
                  imageBuilder: (uri, title, alt) {
                    final allowed = editorialImage(uri.toString());
                    return allowed == null
                        ? const SizedBox.shrink()
                        : image(allowed);
                  },
                  onTapLink: (_, href, _) {
                    final uri = editorialLink(href);
                    if (uri != null) open(uri);
                  },
                )
              else
                Text(
                  message.body,
                  key: const ValueKey('inbox-full-text'),
                  style: _bodyStyle,
                ),
              if (message.actionLabel != null &&
                  editorialLink(message.actionUrl) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 28),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DesktopDialogButton(
                      key: const ValueKey('inbox-action'),
                      fillWidth: true,
                      tooltip: message.actionLabel!,
                      label: message.actionLabel!,
                      icon: Icons.north_east,
                      tone: DesktopDialogButtonTone.primary,
                      onPress: () => open(editorialLink(message.actionUrl)!),
                    ),
                  ),
                ),
              if (readError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        readError!,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DesktopDialogButton(
                        label: 'Retry read',
                        icon: Icons.refresh,
                        onPress: onRetryRead,
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
