import 'dart:async';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/editorial/discovery_dot.dart';
import 'package:chessever/desktop/services/editorial/discovery_dots_provider.dart';
import 'package:chessever/desktop/services/editorial/editorial_links.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/theme/app_theme.dart';

class DesktopNudgeAnchor extends ConsumerStatefulWidget {
  const DesktopNudgeAnchor({super.key, required this.ids, required this.child});
  final List<String> ids;
  final Widget child;
  @override
  ConsumerState<DesktopNudgeAnchor> createState() => _DesktopNudgeAnchorState();
}

class _DesktopNudgeAnchorState extends ConsumerState<DesktopNudgeAnchor>
    with SingleTickerProviderStateMixin {
  late final FPopoverController controller = FPopoverController(vsync: this);
  List<DiscoveryNudgeMessage> messages = const [];
  int index = 0;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> open() async {
    final notifier = ref.read(discoveryDotsProvider.notifier);
    final state = ref.read(discoveryDotsProvider);
    final stack = <DiscoveryNudgeMessage>[];
    for (final id in widget.ids.where(state.lit.contains)) {
      stack.addAll(notifier.acknowledge(id));
    }
    if (stack.isEmpty) return;
    setState(() {
      messages = stack;
      index = 0;
    });
    await controller.show();
  }

  String signature(DiscoveryDotsState state) => state.dots
      .where(
        (dot) =>
            widget.ids.any((id) => dot.target == id || dot.trail.contains(id)),
      )
      .map((dot) => '${dot.id}:${dot.rev}')
      .join('|');
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoveryDotsProvider);
    ref.listen(discoveryDotsProvider, (previous, next) {
      // Dismiss stale tooltip content when an admin edits, takes back, or
      // removes its campaign. Seen-state updates from a tap keep it open.
      if (previous != null &&
          signature(previous) != signature(next) &&
          messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(controller.hide());
        });
      }
    });
    final lit = widget.ids.any(state.lit.contains);
    final label =
        state.dots
            .where(
              (d) =>
                  widget.ids.any(
                    (id) => d.target == id || d.trail.contains(id),
                  ) &&
                  (state.seen[d.id] ?? -1) < d.rev,
            )
            .map((d) => d.label)
            .whereType<String>()
            .firstOrNull;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: controller,
        childAnchor: Alignment.topRight,
        popoverAnchor: Alignment.topLeft,
        spacing: const FPortalSpacing(12),
        hideRegion: FPopoverHideRegion.anywhere,
        popoverBuilder:
            (context, _) => Container(
              width: 320,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: kBlack2Color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDividerColor),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (messages.isNotEmpty)
                    Text(
                      messages[index].body,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      FButton.raw(
                        style: FButtonStyle.ghost(),
                        onPress:
                            index > 0 ? () => setState(() => index--) : null,
                        child: const Icon(
                          Icons.chevron_left,
                          size: 18,
                          color: kWhiteColor70,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          '${index + 1}/${messages.length}',
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      FButton.raw(
                        style: FButtonStyle.ghost(),
                        onPress:
                            index + 1 < messages.length
                                ? () => setState(() => index++)
                                : null,
                        child: const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: kWhiteColor70,
                        ),
                      ),
                      const Spacer(),
                      if (messages.isNotEmpty &&
                          editorialLink(
                                messages[index].actionUrl?.toString(),
                              ) !=
                              null)
                        DesktopToolbarPillButton(
                          label: 'See',
                          icon: Icons.north_east,
                          onPress: () {
                            final uri =
                                editorialLink(
                                  messages[index].actionUrl?.toString(),
                                )!;
                            unawaited(controller.hide());
                            unawaited(openDesktopEditorialLink(context, uri));
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            widget.child,
            if (lit)
              Positioned(
                top: 0,
                right: 6,
                child: FButton.raw(
                  style: FButtonStyle.ghost(),
                  onPress: () => unawaited(open()),
                  child: Semantics(
                    label: label ?? 'New feature',
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child:
                          label == null
                              ? Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: kPrimaryColor,
                                  shape: BoxShape.circle,
                                ),
                              )
                              : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: kPrimaryColor,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  label,
                                  style: const TextStyle(
                                    color: kBlackColor,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
