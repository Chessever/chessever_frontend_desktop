import 'package:flutter/material.dart';
import 'package:chessever/desktop/widgets/desktop_tappable.dart';
import 'package:chessever/theme/app_theme.dart';

/// Dialog-local disclosure; hiding rows never owns or clears their selection.
class LibrarySaveSection extends StatefulWidget {
  const LibrarySaveSection({
    super.key,
    required this.label,
    required this.icon,
    required this.children,
    this.selectedCount = 0,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final List<Widget> children;
  final int selectedCount;
  final bool enabled;

  @override
  State<LibrarySaveSection> createState() => _LibrarySaveSectionState();
}

class _LibrarySaveSectionState extends State<LibrarySaveSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: kBlack3Color.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kDividerColor.withValues(alpha: 0.6)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LibrarySaveSectionHeader(
          label: widget.label,
          icon: widget.icon,
          expanded: _expanded,
          trailing:
              widget.selectedCount == 0
                  ? null
                  : '${widget.selectedCount} selected',
          onToggle:
              widget.enabled
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
      ],
    ),
  );
}

/// The Game Details header recipe, shared by every save disclosure. The
/// forui-backed target supplies focus traversal and Enter/Space activation.
class LibrarySaveSectionHeader extends StatelessWidget {
  const LibrarySaveSectionHeader({
    super.key,
    required this.label,
    required this.icon,
    required this.expanded,
    required this.onToggle,
    this.trailing,
  });

  final String label;
  final IconData icon;
  final bool expanded;
  final VoidCallback? onToggle;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Semantics(
    expanded: expanded,
    child: DesktopTappable(
      onPress: onToggle,
      borderRadius: BorderRadius.circular(10),
      hoverColor: kWhiteColor.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            Icon(icon, size: 16, color: kLightGreyColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: kLightGreyColor,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            if (trailing != null) ...[
              Text(
                trailing!,
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              color: kPrimaryColor,
              size: 18,
            ),
          ],
        ),
      ),
    ),
  );
}
