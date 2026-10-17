import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/editorial/inbox_provider.dart';
import 'package:chessever/theme/app_theme.dart';

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
