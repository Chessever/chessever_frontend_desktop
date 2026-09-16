import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/country_utils.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:country_flags/country_flags.dart';

/// In-board stream language rail. Visual and grouping contract is the web
/// `VideoStreamToolbar`: circular 34px flags in 38px slots, overlapping
/// count badges, FIDE commentary / numbered cameras as their own controls,
/// and a trailing pin + camera toggle.
class BroadcastVideoToolbar extends StatelessWidget {
  const BroadcastVideoToolbar({
    super.key,
    required this.streams,
    required this.selectedId,
    required this.visible,
    required this.pins,
    required this.onSelect,
    required this.onToggle,
    required this.onPin,
  });

  final List<BroadcastVideoStream> streams;
  final String selectedId;
  final bool visible;
  final List<String> pins;
  final ValueChanged<BroadcastVideoStream> onSelect;
  final VoidCallback onToggle;
  final ValueChanged<String> onPin;

  static const double slot = 38;
  static const double gap = 8;
  static const double button = 34;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: slot + 12,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final capacity =
                      constraints.maxWidth <= 0
                          ? 0
                          : ((constraints.maxWidth + gap) / (slot + gap))
                              .floor();
                  final groups = toolbarBroadcastVideoGroups(
                    streams,
                    pins,
                    capacity,
                    selectedId: selectedId,
                  );
                  return SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.only(right: 6),
                    child: Row(
                      children: [
                        for (var index = 0; index < groups.length; index++) ...[
                          if (index > 0) const SizedBox(width: gap),
                          _LanguageGroupButton(
                            group: groups[index],
                            selectedId: selectedId,
                            pinned: pins.contains(
                              groups[index].streams.first.id,
                            ),
                            onSelect: onSelect,
                            onPin: onPin,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.only(left: 8),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: kDividerColor)),
              ),
              child: Row(
                children: [
                  _PinMenuButton(
                    groupsBuilder:
                        (capacity) => toolbarBroadcastVideoGroups(
                          streams,
                          pins,
                          capacity,
                          selectedId: selectedId,
                        ),
                    pins: pins,
                    onPin: onPin,
                  ),
                  const SizedBox(width: 6),
                  _IconAction(
                    key: const ValueKey<String>(
                      'desktop-broadcast-video-toggle',
                    ),
                    icon:
                        visible
                            ? Icons.videocam_off_rounded
                            : Icons.videocam_rounded,
                    tooltip: visible ? 'Hide video' : 'Show video',
                    selected: visible,
                    onPress: onToggle,
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

class _LanguageGroupButton extends StatefulWidget {
  const _LanguageGroupButton({
    required this.group,
    required this.selectedId,
    required this.pinned,
    required this.onSelect,
    required this.onPin,
  });

  final BroadcastToolbarVideoGroup group;
  final String selectedId;
  final bool pinned;
  final ValueChanged<BroadcastVideoStream> onSelect;
  final ValueChanged<String> onPin;

  @override
  State<_LanguageGroupButton> createState() => _LanguageGroupButtonState();
}

class _LanguageGroupButtonState extends State<_LanguageGroupButton>
    with SingleTickerProviderStateMixin {
  static const Duration _closeGrace = Duration(milliseconds: 140);

  late final FPopoverController _menuController = FPopoverController(
    vsync: this,
  );
  Timer? _closeTimer;

  bool get _isCameraGroup =>
      widget.group.kind == BroadcastToolbarVideoKind.cameras;

  bool get _multiple => _isCameraGroup || widget.group.streams.length > 1;

  @override
  void dispose() {
    _closeTimer?.cancel();
    _menuController.dispose();
    super.dispose();
  }

  void _cancelClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _openMenu() {
    if (!_multiple) return;
    _cancelClose();
    final status = _menuController.status;
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.forward) {
      return;
    }
    unawaited(_menuController.show());
  }

  void _closeMenu() {
    _cancelClose();
    unawaited(_menuController.hide());
  }

  void _closeMenuSoon() {
    if (!_multiple) return;
    _cancelClose();
    _closeTimer = Timer(_closeGrace, () {
      _closeTimer = null;
      if (mounted) unawaited(_menuController.hide());
    });
  }

  void _onTrigger() {
    if (_isCameraGroup) {
      _openMenu();
      return;
    }
    _closeMenu();
    widget.onSelect(widget.group.streams.first);
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final selected = group.streams.any(
      (stream) => stream.id == widget.selectedId,
    );
    final cameraLabel =
        group.cameraNumber == null ? null : 'Camera ${group.cameraNumber}';
    final tooltip =
        _isCameraGroup
            ? 'Choose among ${group.streams.length} cameras'
            : cameraLabel ??
                (_multiple
                    ? '${group.label} · ${group.streams.length} streams'
                    : '${group.label} · ${broadcastToolbarStreamName(group.streams.first)}');
    final mark = SizedBox(
      width: BroadcastVideoToolbar.slot,
      height: BroadcastVideoToolbar.slot,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Align(
            child: _StreamMarkButton(
              key: ValueKey<String>(
                'desktop-broadcast-video-language-${group.key}',
              ),
              group: group,
              selected: selected,
              pinned: widget.pinned,
              semanticsLabel: tooltip,
              onPress: _onTrigger,
            ),
          ),
          if (_multiple)
            Positioned(
              top: -2,
              right: -3,
              child: _StreamCountBadge(
                count: group.streams.length,
                semanticsLabel:
                    _isCameraGroup
                        ? 'Choose among ${group.streams.length} cameras'
                        : 'Choose among ${group.streams.length} ${group.label} streams',
                onPress: () {
                  _cancelClose();
                  unawaited(_menuController.toggle());
                },
              ),
            ),
        ],
      ),
    );
    final trigger = MouseRegion(
      onEnter: (_) => _openMenu(),
      onExit: (_) => _closeMenuSoon(),
      child: GestureDetector(
        onSecondaryTap: () => widget.onPin(group.streams.first.id),
        child:
            _multiple
                ? mark
                : DesktopTooltip(
                  message: tooltip,
                  tipAnchor: Alignment.topCenter,
                  childAnchor: Alignment.bottomCenter,
                  child: mark,
                ),
      ),
    );
    if (!_multiple) return trigger;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _menuController,
        popoverBuilder:
            (context, _) => MouseRegion(
              onEnter: (_) => _cancelClose(),
              onExit: (_) => _closeMenuSoon(),
              child: _GroupStreamMenu(
                group: group,
                selectedId: widget.selectedId,
                onSelect: (stream) {
                  _closeMenu();
                  widget.onSelect(stream);
                },
              ),
            ),
        child: trigger,
      ),
    );
  }
}

class _StreamMarkButton extends StatelessWidget {
  const _StreamMarkButton({
    super.key,
    required this.group,
    required this.selected,
    required this.pinned,
    required this.onPress,
    required this.semanticsLabel,
  });

  final BroadcastToolbarVideoGroup group;
  final bool selected;
  final bool pinned;
  final VoidCallback onPress;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        onPress: onPress,
        semanticsLabel: semanticsLabel,
        builder: (context, states, child) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          final rim =
              selected || focused || hovered ? kPrimaryColor : kDividerColor;
          final circle = SizedBox(
            width: BroadcastVideoToolbar.button,
            height: BroadcastVideoToolbar.button,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    selected
                        ? kPrimaryColor.withValues(alpha: 0.14)
                        : Colors.transparent,
                border: pinned ? null : Border.all(color: rim),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (selected)
                    const Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.all(1),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.fromBorderSide(
                              BorderSide(color: kPrimaryColor),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (child != null) child,
                ],
              ),
            ),
          );
          if (!pinned) return circle;
          return CustomPaint(
            painter: _DashedCirclePainter(color: rim, strokeWidth: 1),
            child: circle,
          );
        },
        child: _StreamMark(group: group),
      ),
    );
  }
}

class _StreamMark extends StatelessWidget {
  const _StreamMark({required this.group});

  final BroadcastToolbarVideoGroup group;

  @override
  Widget build(BuildContext context) {
    switch (group.kind) {
      case BroadcastToolbarVideoKind.fide:
        return ClipOval(
          child: ColoredBox(
            color: const Color(0xFF1C2B5E),
            child: Image.asset(
              PngAsset.fideFlag,
              width: 22,
              height: 22,
              fit: BoxFit.contain,
            ),
          ),
        );
      case BroadcastToolbarVideoKind.camera:
        return _CameraMark(number: group.cameraNumber);
      case BroadcastToolbarVideoKind.cameras:
        return const Icon(
          Icons.videocam_rounded,
          size: 16,
          color: kWhiteColor70,
        );
      case BroadcastToolbarVideoKind.language:
        final code = group.countryCode;
        if (code == null) {
          return const Icon(
            Icons.videocam_rounded,
            size: 18,
            color: kWhiteColor70,
          );
        }
        return _CircularLanguageFlag(countryCode: code);
    }
  }
}

/// Web `.ce-video__flag`: a 22px circle that cover-crops a rectangular flag.
///
/// `CountryFlag` circle assets are square SVGs with the flag letterboxed
/// inside, so `shape: Circle()` still reads as a rectangle in a ring. Crop
/// the 3:2 artwork instead, matching `background-size: cover`.
class _CircularLanguageFlag extends StatelessWidget {
  const _CircularLanguageFlag({required this.countryCode});

  final String countryCode;

  static const double size = 22;
  static const double flagWidth = 33;
  static const double flagHeight = 22;

  @override
  Widget build(BuildContext context) {
    final artwork = _rectangularFlagArtwork(countryCode);
    if (artwork == null) {
      return const Icon(Icons.videocam_rounded, size: 18, color: kWhiteColor70);
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipOval(child: FittedBox(fit: BoxFit.cover, child: artwork)),
          const DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.fromBorderSide(
                BorderSide(color: Color(0x26FFFFFF)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget? _rectangularFlagArtwork(String raw) {
  final code = raw.trim();
  if (code.isEmpty) return null;
  final upper = code.toUpperCase();
  const special = <String>{'FID', 'FIDE', 'ENG', 'SCO', 'WLS', 'WAL'};
  if (special.contains(upper)) {
    return FederationFlag(
      federation: upper == 'WAL' ? 'WLS' : upper,
      width: _CircularLanguageFlag.flagWidth,
      height: _CircularLanguageFlag.flagHeight,
      borderRadius: BorderRadius.zero,
    );
  }
  final iso2 = switch (upper.length) {
    2 => upper,
    3 => CountryUtils.toIso2Code(upper),
    _ => CountryUtils.countryNameToIso2(code),
  };
  if (iso2.length != 2) return null;
  return CountryFlag.fromCountryCode(
    iso2,
    theme: const ImageTheme(
      width: _CircularLanguageFlag.flagWidth,
      height: _CircularLanguageFlag.flagHeight,
    ),
  );
}

class _CameraMark extends StatelessWidget {
  const _CameraMark({this.number});

  final int? number;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.videocam_rounded, size: 16, color: kWhiteColor70),
        if (number != null)
          Text(
            '$number',
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              height: 1,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              color: kWhiteColor,
            ),
          ),
      ],
    );
  }
}

class _StreamCountBadge extends StatelessWidget {
  const _StreamCountBadge({
    required this.count,
    required this.onPress,
    required this.semanticsLabel,
  });

  final int count;
  final VoidCallback onPress;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        onPress: onPress,
        semanticsLabel: semanticsLabel,
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          return Container(
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  hovered || focused
                      ? kPrimaryColor.withValues(alpha: 0.18)
                      : kBlack2Color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kPrimaryColor),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: kPrimaryColor,
                height: 1,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PinMenuButton extends StatefulWidget {
  const _PinMenuButton({
    required this.groupsBuilder,
    required this.pins,
    required this.onPin,
  });

  final List<BroadcastToolbarVideoGroup> Function(int capacity) groupsBuilder;
  final List<String> pins;
  final ValueChanged<String> onPin;

  @override
  State<_PinMenuButton> createState() => _PinMenuButtonState();
}

class _PinMenuButtonState extends State<_PinMenuButton>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverBuilder: (context, _) {
          final groups = widget.groupsBuilder(20);
          final entries = groups
              .expand((group) => group.streams)
              .toList(growable: false);
          return _MenuSurface(
            width: 260,
            children: [
              for (final stream in entries)
                _MenuRow(
                  label:
                      '${widget.pins.contains(stream.id) ? 'Unpin' : 'Pin'} · ${broadcastToolbarStreamName(stream)}',
                  selected: widget.pins.contains(stream.id),
                  onTap: () {
                    _controller.hide();
                    widget.onPin(stream.id);
                  },
                ),
            ],
          );
        },
        child: _IconAction(
          icon: Icons.more_horiz_rounded,
          tooltip: 'Manage stream pins (or right-click a flag)',
          onPress: _controller.toggle,
        ),
      ),
    );
  }
}

class _GroupStreamMenu extends StatelessWidget {
  const _GroupStreamMenu({
    required this.group,
    required this.selectedId,
    required this.onSelect,
  });

  final BroadcastToolbarVideoGroup group;
  final String selectedId;
  final ValueChanged<BroadcastVideoStream> onSelect;

  @override
  Widget build(BuildContext context) {
    final heading =
        group.kind == BroadcastToolbarVideoKind.cameras
            ? 'Cameras'
            : group.label;
    return _MenuSurface(
      width: 260,
      children: [
        _MenuHeader(label: '$heading · ${group.streams.length}'),
        for (final stream in group.streams)
          _MenuRow(
            label: broadcastToolbarStreamName(stream),
            selected: stream.id == selectedId,
            onTap: () => onSelect(stream),
          ),
      ],
    );
  }
}

class _MenuSurface extends StatelessWidget {
  const _MenuSurface({required this.width, required this.children});

  final double width;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      constraints: const BoxConstraints(maxHeight: 320),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x73000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: kLightGreyColor,
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        onPress: onTap,
        semanticsLabel: label,
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color:
                selected || hovered || focused
                    ? kPrimaryColor.withValues(alpha: 0.12)
                    : Colors.transparent,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: selected ? kPrimaryColor : kWhiteColor,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final button = FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        onPress: onPress,
        semanticsLabel: tooltip.isEmpty ? null : tooltip,
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final pressed = states.contains(WidgetState.pressed);
          final focused = states.contains(WidgetState.focused);
          final border =
              selected || focused || hovered ? kPrimaryColor : kDividerColor;
          final foreground =
              selected || hovered ? kPrimaryColor : kWhiteColor70;
          return Container(
            width: BroadcastVideoToolbar.button,
            height: BroadcastVideoToolbar.button,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.12)
                      : (hovered || pressed
                          ? kBlack3Color
                          : Colors.transparent),
              border: Border.all(color: border),
            ),
            child: Icon(icon, size: 18, color: foreground),
          );
        },
      ),
    );
    if (tooltip.isEmpty) return button;
    return DesktopTooltip(
      message: tooltip,
      tipAnchor: Alignment.topCenter,
      childAnchor: Alignment.bottomCenter,
      child: button,
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth;
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius,
    );
    const dash = 0.28;
    const gap = 0.18;
    var angle = 0.0;
    while (angle < math.pi * 2) {
      canvas.drawArc(rect, angle, dash, false, paint);
      angle += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}
