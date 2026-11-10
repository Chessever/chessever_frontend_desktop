import 'package:chessever/desktop/widgets/desktop_scroll_controller.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/pressable_scale.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/country_utils.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:country_flags/country_flags.dart';

/// In-board stream language rail. Visual and grouping contract is the web
/// `VideoStreamToolbar`: circular 34px flags in 38px slots, overlapping
/// count badges, FIDE commentary / numbered cameras as their own controls,
/// and a trailing pin + camera toggle.
class BroadcastVideoToolbar extends StatefulWidget {
  const BroadcastVideoToolbar({
    super.key,
    required this.streams,
    required this.selectedId,
    required this.visible,
    required this.pins,
    required this.onSelect,
    required this.onToggle,
    required this.onPin,
    this.onMenuVisibilityChanged,
  });

  final List<BroadcastVideoStream> streams;
  final String selectedId;
  final bool visible;
  final List<String> pins;
  final ValueChanged<BroadcastVideoStream> onSelect;
  final VoidCallback onToggle;
  final ValueChanged<String> onPin;

  /// Reports when the first stream menu opens and when the last one closes.
  /// The web player is a DOM iframe, which owns its rectangle even where a
  /// Flutter menu is painted above it; the panel uses this to let the menu
  /// receive clicks instead of the player underneath.
  final ValueChanged<bool>? onMenuVisibilityChanged;

  static const double slot = 38;
  static const double gap = 8;
  static const double button = 34;

  @override
  State<BroadcastVideoToolbar> createState() => _BroadcastVideoToolbarState();
}

class _BroadcastVideoToolbarState extends State<BroadcastVideoToolbar> {
  /// Every child reports each open exactly once and each close exactly once,
  /// so a simple balanced count cannot get stuck on a reordered group list.
  int _openMenus = 0;
  bool _reportedOpen = false;

  void _reportMenuVisibility(bool open) {
    _openMenus += open ? 1 : -1;
    if (_openMenus < 0) _openMenus = 0;
    final anyOpen = _openMenus > 0;
    if (anyOpen == _reportedOpen) return;
    _reportedOpen = anyOpen;
    widget.onMenuVisibilityChanged?.call(anyOpen);
  }

  @override
  void dispose() {
    if (_reportedOpen) {
      _reportedOpen = false;
      widget.onMenuVisibilityChanged?.call(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: SizedBox(
        height: BroadcastVideoToolbar.slot + 12,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: ClipRect(
                  key: const ValueKey<String>(
                    'desktop-broadcast-video-languages',
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final capacity =
                          constraints.maxWidth <= 0
                              ? 0
                              : ((constraints.maxWidth +
                                          BroadcastVideoToolbar.gap) /
                                      (BroadcastVideoToolbar.slot +
                                          BroadcastVideoToolbar.gap))
                                  .floor();
                      final grouped = toolbarBroadcastVideoGroups(
                        widget.streams,
                        widget.pins,
                        capacity,
                        selectedId: widget.selectedId,
                      );
                      final groups = [...grouped]..sort((a, b) {
                        if (a.streams.first.isAnalysis ||
                            b.streams.first.isAnalysis) {
                          return widget.streams
                              .indexOf(a.streams.first)
                              .compareTo(
                                widget.streams.indexOf(b.streams.first),
                              );
                        }
                        return grouped.indexOf(a).compareTo(grouped.indexOf(b));
                      });
                      return DesktopScrollHost(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          clipBehavior: Clip.hardEdge,
                          padding: const EdgeInsets.only(right: 6),
                          child: Row(
                            children: [
                              for (
                                var index = 0;
                                index < groups.length;
                                index++
                              ) ...[
                                if (index > 0)
                                  const SizedBox(
                                    width: BroadcastVideoToolbar.gap,
                                  ),
                                _LanguageGroupButton(
                                  group: groups[index],
                                  selectedId: widget.selectedId,
                                  pinned: widget.pins.contains(
                                    groups[index].streams.first.id,
                                  ),
                                  onSelect: widget.onSelect,
                                  onToggle: widget.onToggle,
                                  onPin: widget.onPin,
                                  onMenuVisibilityChanged:
                                      _reportMenuVisibility,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Container(
                key: const ValueKey<String>('desktop-broadcast-video-actions'),
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
                            widget.streams,
                            widget.pins,
                            capacity,
                            selectedId: widget.selectedId,
                          ),
                      pins: widget.pins,
                      onPin: widget.onPin,
                      onMenuVisibilityChanged: _reportMenuVisibility,
                    ),
                    const SizedBox(width: 6),
                    _IconAction(
                      key: const ValueKey<String>(
                        'desktop-broadcast-video-toggle',
                      ),
                      icon:
                          widget.visible
                              ? Icons.videocam_off_rounded
                              : Icons.videocam_rounded,
                      tooltip: widget.visible ? 'Hide video' : 'Show video',
                      selected: widget.visible,
                      onPress: widget.onToggle,
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

class _LanguageGroupButton extends StatefulWidget {
  const _LanguageGroupButton({
    required this.group,
    required this.selectedId,
    required this.pinned,
    required this.onSelect,
    required this.onToggle,
    required this.onPin,
    this.onMenuVisibilityChanged,
  });

  final BroadcastToolbarVideoGroup group;
  final String selectedId;
  final bool pinned;
  final ValueChanged<BroadcastVideoStream> onSelect;

  /// Hide/show the player. A tap on the already-selected flag routes here,
  /// so the highlighted circle closes the video it opened.
  final VoidCallback onToggle;
  final ValueChanged<String> onPin;
  final ValueChanged<bool>? onMenuVisibilityChanged;

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
  bool _menuReportedOpen = false;

  bool get _isCameraGroup =>
      widget.group.kind == BroadcastToolbarVideoKind.cameras;

  bool get _multiple => _isCameraGroup || widget.group.streams.length > 1;

  @override
  void initState() {
    super.initState();
    _menuController.addListener(_syncMenuVisibility);
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    _menuController.removeListener(_syncMenuVisibility);
    _reportMenuOpen(false);
    _menuController.dispose();
    super.dispose();
  }

  /// The popover can also close itself (tap outside, another menu opening):
  /// the listener keeps the toolbar's report in step with the real state.
  void _syncMenuVisibility() {
    final status = _menuController.status;
    _reportMenuOpen(
      status == AnimationStatus.forward || status == AnimationStatus.completed,
    );
  }

  void _reportMenuOpen(bool open) {
    if (_menuReportedOpen == open) return;
    _menuReportedOpen = open;
    widget.onMenuVisibilityChanged?.call(open);
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
    // The overlay is on screen from the first frame of the entrance; report
    // it before the animation ends so clicks over the player already reach
    // the menu.
    _reportMenuOpen(true);
    unawaited(_menuController.show());
  }

  void _closeMenu() {
    _cancelClose();
    // Single-stream flags render no FPopover, so the controller is never
    // attached to an overlay and `hide()` would assert.
    if (!_multiple) return;
    unawaited(_menuController.hide());
  }

  void _toggleMenu() {
    _cancelClose();
    final status = _menuController.status;
    if (status == AnimationStatus.dismissed ||
        status == AnimationStatus.reverse) {
      _reportMenuOpen(true);
    }
    unawaited(_menuController.toggle());
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
    final selected = widget.group.streams.any(
      (stream) => stream.id == widget.selectedId,
    );
    if (selected) {
      widget.onToggle();
      return;
    }
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
                onPress: _toggleMenu,
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
        child: _multiple ? mark : DesktopTooltip(message: tooltip, child: mark),
      ),
    );
    if (!_multiple) return trigger;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _menuController,
        popoverAnchor: Alignment.bottomLeft,
        childAnchor: Alignment.topLeft,
        spacing: const FPortalSpacing(6),
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
        style: _withoutForuiBounce,
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
          if (!pinned) return _PressScale(child: circle);
          return _PressScale(
            child: CustomPaint(
              painter: _DashedCirclePainter(color: rim, strokeWidth: 1),
              child: circle,
            ),
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
    final stream = group.streams.first;
    if (stream.isAnalysis) {
      return PlayerInitialsAvatar(
        photoUrl: stream.authorAvatarUrl,
        initials:
            stream.authorName!
                .trim()
                .split(RegExp(r'\s+'))
                .where((s) => s.isNotEmpty)
                .take(2)
                .map((s) => s.characters.first)
                .join()
                .toUpperCase(),
        size: 22,
        isCircular: true,
      );
    }
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
        style: _withoutForuiBounce,
        onPress: onPress,
        semanticsLabel: semanticsLabel,
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          return _PressScale(
            child: Container(
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
    this.onMenuVisibilityChanged,
  });

  final List<BroadcastToolbarVideoGroup> Function(int capacity) groupsBuilder;
  final List<String> pins;
  final ValueChanged<String> onPin;
  final ValueChanged<bool>? onMenuVisibilityChanged;

  @override
  State<_PinMenuButton> createState() => _PinMenuButtonState();
}

class _PinMenuButtonState extends State<_PinMenuButton>
    with SingleTickerProviderStateMixin {
  late final FPopoverController _controller = FPopoverController(vsync: this);
  bool _menuReportedOpen = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncMenuVisibility);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncMenuVisibility);
    _reportMenuOpen(false);
    _controller.dispose();
    super.dispose();
  }

  void _syncMenuVisibility() {
    final status = _controller.status;
    _reportMenuOpen(
      status == AnimationStatus.forward || status == AnimationStatus.completed,
    );
  }

  void _reportMenuOpen(bool open) {
    if (_menuReportedOpen == open) return;
    _menuReportedOpen = open;
    widget.onMenuVisibilityChanged?.call(open);
  }

  void _toggleMenu() {
    final status = _controller.status;
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.forward) {
      unawaited(_controller.hide());
      return;
    }
    _reportMenuOpen(true);
    unawaited(_controller.show());
  }

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _controller,
        popoverAnchor: Alignment.bottomRight,
        childAnchor: Alignment.topRight,
        spacing: const FPortalSpacing(6),
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
                      '${stream.isAnalysis ? (stream.followed ? 'Unfollow author' : 'Follow author') : (widget.pins.contains(stream.id) ? 'Unpin' : 'Pin')} · ${broadcastToolbarStreamName(stream)}',
                  selected: widget.pins.contains(stream.id),
                  onTap: () {
                    unawaited(_controller.hide());
                    widget.onPin(stream.id);
                  },
                ),
            ],
          );
        },
        child: _IconAction(
          label: '⋯',
          tooltip: 'Manage stream pins (or right-click a flag)',
          onPress: _toggleMenu,
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
      child: DesktopScrollHost(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
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
        style: _withoutForuiBounce,
        onPress: onTap,
        semanticsLabel: label,
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          return _PressScale(
            child: Container(
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
    this.icon,
    this.label,
    required this.tooltip,
    required this.onPress,
    this.selected = false,
  }) : assert(
         (icon != null) != (label != null),
         'Provide exactly one of icon or label',
       );

  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback onPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final button = FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        style: _withoutForuiBounce,
        onPress: onPress,
        semanticsLabel: tooltip.isEmpty ? null : tooltip,
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          final highlighted = focused || hovered;
          // Web `.ce-video__icon-action`: square 34px, hairline border,
          // primary rim/ink on hover, selected is ink only.
          final border = highlighted ? kPrimaryColor : kDividerColor;
          final foreground =
              selected || highlighted ? kPrimaryColor : kWhiteColor70;
          return _PressScale(
            child: Container(
              width: BroadcastVideoToolbar.button,
              height: BroadcastVideoToolbar.button,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border.all(color: border)),
              child:
                  label != null
                      ? Text(
                        label!,
                        style: TextStyle(
                          fontSize: 18,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      )
                      : Icon(icon, size: 18, color: foreground),
            ),
          );
        },
      ),
    );
    if (tooltip.isEmpty) return button;
    return DesktopTooltip(message: tooltip, child: button);
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

/// forui's stock tappable bounce is an unfiltered 0.97 [ScaleTransition]:
/// Impeller re-shapes the flag, icon and label glyphs at each fractional
/// scale, so a press shudders. [_PressScale] replaces it.
FTappableStyle _withoutForuiBounce(FTappableStyle style) =>
    style.copyWith(motion: (_) => FTappableMotion.none);

/// The same 0.97 press as forui's bounce, but through [PressableScale]'s
/// spring and filtered raster scale, so it eases smoothly. No hover scale:
/// the toolbar's hover is the rim / ink colour change alone.
class _PressScale extends StatelessWidget {
  const _PressScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      PressableScale(hoveredScale: 1, child: child);
}
