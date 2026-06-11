import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/theme/app_theme.dart';

abstract class DesktopContextMenuEntry<T> {
  const DesktopContextMenuEntry();
}

class DesktopContextMenuItem<T> extends DesktopContextMenuEntry<T> {
  const DesktopContextMenuItem({
    required this.value,
    required this.icon,
    required this.label,
    this.shortcut,
    this.enabled = true,
    this.destructive = false,
  });

  final T value;
  final IconData icon;
  final String label;
  final String? shortcut;
  final bool enabled;
  final bool destructive;
}

class DesktopContextMenuDivider<T> extends DesktopContextMenuEntry<T> {
  const DesktopContextMenuDivider();
}

class DesktopContextSubmenu<T> extends DesktopContextMenuEntry<T> {
  const DesktopContextSubmenu({
    required this.icon,
    required this.label,
    required this.entries,
    this.enabled = true,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final List<DesktopContextMenuEntry<T>> entries;
  final bool enabled;
  final bool destructive;
}

/// Cursor-anchored desktop context menu with the project's forui chrome.
///
/// This avoids Flutter's Material popup route for new desktop chrome and gives
/// all right-click menus the same short spring entrance and compact row design.
Future<T?> showDesktopContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<DesktopContextMenuEntry<T>> entries,
  double width = 240,
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<T?>();
  late final OverlayEntry entry;

  entry = OverlayEntry(
    builder:
        (_) => _DesktopContextMenuOverlay<T>(
          position: position,
          entries: entries,
          width: width,
          onDismissed: (value) {
            entry.remove();
            if (!completer.isCompleted) completer.complete(value);
          },
        ),
  );

  overlay.insert(entry);
  return completer.future;
}

class _DesktopContextMenuOverlay<T> extends StatefulWidget {
  const _DesktopContextMenuOverlay({
    required this.position,
    required this.entries,
    required this.width,
    required this.onDismissed,
  });

  final Offset position;
  final List<DesktopContextMenuEntry<T>> entries;
  final double width;
  final ValueChanged<T?> onDismissed;

  @override
  State<_DesktopContextMenuOverlay<T>> createState() =>
      _DesktopContextMenuOverlayState<T>();
}

class _DesktopContextMenuOverlayState<T>
    extends State<_DesktopContextMenuOverlay<T>>
    with SingleTickerProviderStateMixin {
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 520,
    damping: 34,
  );

  late final AnimationController _controller = AnimationController(
    vsync: this,
    lowerBound: 0,
    upperBound: 1,
  );

  bool _closing = false;
  T? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.animateWith(SpringSimulation(_spring, 0, 1, 0)));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss([T? result]) async {
    if (_closing) return;
    _closing = true;
    _result = result;
    try {
      await _controller.animateTo(
        0,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeInCubic,
      );
    } finally {
      if (mounted) widget.onDismissed(_result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final overlaySize = MediaQuery.sizeOf(context);
    final estimatedHeight = _estimatedMenuHeight(widget.entries);
    final hasSubmenu = widget.entries.any(
      (entry) => entry is DesktopContextSubmenu<T>,
    );
    final estimatedWidth = hasSubmenu ? (widget.width * 2) + 4 : widget.width;
    final maxLeft =
        (overlaySize.width - estimatedWidth - 8)
            .clamp(8.0, double.infinity)
            .toDouble();
    final maxTop =
        (overlaySize.height - estimatedHeight - 8)
            .clamp(8.0, double.infinity)
            .toDouble();
    final left = widget.position.dx.clamp(8.0, maxLeft).toDouble();
    final top = widget.position.dy.clamp(8.0, maxTop).toDouble();

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _dismiss(),
              onSecondaryTap: () => _dismiss(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final t = _controller.value.clamp(0.0, 1.0);
                final scale = 0.965 + (0.035 * t);
                return Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, -4 * (1 - t)),
                    child: Transform.scale(
                      scale: scale,
                      alignment: Alignment.topLeft,
                      child: child,
                    ),
                  ),
                );
              },
              child: _DesktopContextMenuSurface<T>(
                entries: widget.entries,
                width: widget.width,
                onSelect: _dismiss,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopContextMenuSurface<T> extends StatefulWidget {
  const _DesktopContextMenuSurface({
    required this.entries,
    required this.width,
    required this.onSelect,
  });

  final List<DesktopContextMenuEntry<T>> entries;
  final double width;
  final ValueChanged<T> onSelect;

  @override
  State<_DesktopContextMenuSurface<T>> createState() =>
      _DesktopContextMenuSurfaceState<T>();
}

class _DesktopContextMenuSurfaceState<T>
    extends State<_DesktopContextMenuSurface<T>> {
  int? _activeSubmenuIndex;

  @override
  Widget build(BuildContext context) {
    final activeIndex = _activeSubmenuIndex;
    final activeEntry =
        activeIndex == null || activeIndex >= widget.entries.length
            ? null
            : widget.entries[activeIndex];
    final submenu =
        activeEntry is DesktopContextSubmenu<T> && activeEntry.enabled
            ? activeEntry
            : null;
    final submenuTop =
        activeIndex == null ? 0.0 : _submenuTopFor(widget.entries, activeIndex);

    return FTheme(
      data: FThemes.zinc.dark,
      child: Material(
        color: Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _DesktopContextMenuBox<T>(
              entries: widget.entries,
              width: widget.width,
              onSelect: widget.onSelect,
              onSubmenuHover: (index) {
                if (_activeSubmenuIndex == index) return;
                setState(() => _activeSubmenuIndex = index);
              },
              onPlainItemHover: () {
                if (_activeSubmenuIndex == null) return;
                setState(() => _activeSubmenuIndex = null);
              },
            ),
            if (submenu != null) ...[
              const SizedBox(width: 4),
              Padding(
                padding: EdgeInsets.only(top: submenuTop),
                child: _DesktopContextMenuBox<T>(
                  entries: submenu.entries,
                  width: widget.width,
                  onSelect: widget.onSelect,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DesktopContextMenuBox<T> extends StatelessWidget {
  const _DesktopContextMenuBox({
    required this.entries,
    required this.width,
    required this.onSelect,
    this.onSubmenuHover,
    this.onPlainItemHover,
  });

  final List<DesktopContextMenuEntry<T>> entries;
  final double width;
  final ValueChanged<T> onSelect;
  final ValueChanged<int>? onSubmenuHover;
  final VoidCallback? onPlainItemHover;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF101418),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.42),
            blurRadius: 26,
            spreadRadius: -8,
            offset: const Offset(0, 18),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.30),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < entries.length; i++)
            if (entries[i] is DesktopContextMenuDivider<T>)
              const _DesktopContextDivider()
            else if (entries[i] is DesktopContextMenuItem<T>)
              _DesktopContextMenuRow<T>(
                item: entries[i] as DesktopContextMenuItem<T>,
                onSelect: onSelect,
                onHover: onPlainItemHover,
              )
            else if (entries[i] is DesktopContextSubmenu<T>)
              _DesktopContextSubmenuRow<T>(
                item: entries[i] as DesktopContextSubmenu<T>,
                onHover: () => onSubmenuHover?.call(i),
              ),
        ],
      ),
    );
  }
}

class _DesktopContextMenuRow<T> extends StatefulWidget {
  const _DesktopContextMenuRow({
    required this.item,
    required this.onSelect,
    this.onHover,
  });

  final DesktopContextMenuItem<T> item;
  final ValueChanged<T> onSelect;
  final VoidCallback? onHover;

  @override
  State<_DesktopContextMenuRow<T>> createState() =>
      _DesktopContextMenuRowState<T>();
}

class _DesktopContextMenuRowState<T> extends State<_DesktopContextMenuRow<T>> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final disabled = !item.enabled;
    final destructiveColor = const Color(0xFFEB5757);
    final foreground =
        disabled
            ? kLightGreyColor.withValues(alpha: 0.52)
            : item.destructive
            ? destructiveColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final iconColor =
        disabled
            ? kLightGreyColor.withValues(alpha: 0.42)
            : item.destructive
            ? destructiveColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final background =
        disabled || !_hovered
            ? Colors.transparent
            : item.destructive
            ? destructiveColor.withValues(alpha: 0.13)
            : kWhiteColor.withValues(alpha: 0.075);

    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      constraints: const BoxConstraints(minHeight: 40),
      margin: const EdgeInsets.symmetric(horizontal: 5),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Icon(item.icon, size: 15, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (item.shortcut != null) ...[
            const SizedBox(width: 12),
            Text(
              item.shortcut!,
              style: TextStyle(
                color:
                    disabled
                        ? kLightGreyColor.withValues(alpha: 0.42)
                        : kLightGreyColor,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );

    if (disabled) return row;

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) {
          widget.onHover?.call();
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onSelect(item.value),
          child: row,
        ),
      ),
    );
  }
}

class _DesktopContextSubmenuRow<T> extends StatefulWidget {
  const _DesktopContextSubmenuRow({required this.item, required this.onHover});

  final DesktopContextSubmenu<T> item;
  final VoidCallback onHover;

  @override
  State<_DesktopContextSubmenuRow<T>> createState() =>
      _DesktopContextSubmenuRowState<T>();
}

class _DesktopContextSubmenuRowState<T>
    extends State<_DesktopContextSubmenuRow<T>> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final disabled = !item.enabled || item.entries.isEmpty;
    final destructiveColor = const Color(0xFFEB5757);
    final foreground =
        disabled
            ? kLightGreyColor.withValues(alpha: 0.52)
            : item.destructive
            ? destructiveColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final iconColor =
        disabled
            ? kLightGreyColor.withValues(alpha: 0.42)
            : item.destructive
            ? destructiveColor
            : (_hovered ? kWhiteColor : kWhiteColor70);
    final background =
        disabled || !_hovered
            ? Colors.transparent
            : item.destructive
            ? destructiveColor.withValues(alpha: 0.13)
            : kWhiteColor.withValues(alpha: 0.075);

    final row = AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      constraints: const BoxConstraints(minHeight: 40),
      margin: const EdgeInsets.symmetric(horizontal: 5),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Icon(item.icon, size: 15, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.chevron_right_rounded, size: 16, color: iconColor),
        ],
      ),
    );

    if (disabled) return row;

    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) {
          widget.onHover();
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onHover,
          child: row,
        ),
      ),
    );
  }
}

class _DesktopContextDivider extends StatelessWidget {
  const _DesktopContextDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 9),
      color: kDividerColor.withValues(alpha: 0.8),
    );
  }
}

double _estimatedMenuHeight<T>(List<DesktopContextMenuEntry<T>> entries) {
  var height = 12.0;
  for (final entry in entries) {
    height += entry is DesktopContextMenuDivider<T> ? 11 : 40;
  }
  return height;
}

double _submenuTopFor<T>(List<DesktopContextMenuEntry<T>> entries, int index) {
  var top = 0.0;
  for (var i = 0; i < index; i++) {
    top += entries[i] is DesktopContextMenuDivider<T> ? 11 : 40;
  }
  return top;
}
