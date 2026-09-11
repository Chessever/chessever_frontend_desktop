import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/state/broadcast_video_streams_provider.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:country_flags/country_flags.dart';

/// Live-stream panel for the top of the Board pane's right rail.
///
/// Lists the organiser-managed Twitch / YouTube / Kick streams for the
/// game's round (or tour), polled every 30 seconds and grouped by language
/// exactly as the site's `VideoStreams` toolbar does, and opens the selected
/// stream on the provider or on chessever.com's watch page with live boards.
///
/// Nothing plays inside the app. ChessEver Desktop is a paid product and the
/// providers' embed terms are written for web pages (Twitch verifies the
/// embedding domain through `parent`; YouTube forbids a player behind a
/// paywall), so the desktop lists and links instead of framing a player.
/// See docs/broadcast_video_embed_compliance.md before changing that.
///
/// Renders nothing while the scope has no configured streams, so the rail
/// collapses to the notation panel for ordinary analysis tabs.
class BroadcastVideoPanel extends ConsumerStatefulWidget {
  const BroadcastVideoPanel({
    super.key,
    required this.tourId,
    required this.tournamentStorageId,
    this.roundId,
    this.active = true,
  });

  /// Tournament that owns the game on the board.
  final String tourId;

  /// Whether the owning Board tab is the foreground surface. Inactive tabs
  /// render nothing, so only the visible tab polls the stream list.
  final bool active;

  /// Round of the game on the board, when known. The API resolves stream
  /// inheritance round → tour → group, so the panel asks for the narrowest
  /// scope it has.
  final String? roundId;

  /// Identity for the session preference slot (`ce-video.v1:<id>`), matching
  /// the web's per-tournament sessionStorage key.
  final String tournamentStorageId;

  @override
  ConsumerState<BroadcastVideoPanel> createState() =>
      _BroadcastVideoPanelState();
}

class _BroadcastVideoPanelState extends ConsumerState<BroadcastVideoPanel> {
  BroadcastVideoScope get _scope =>
      BroadcastVideoScope(tourId: widget.tourId, roundId: widget.roundId);

  String get _storageKey => 'ce-video.v1:${widget.tournamentStorageId}';

  void _selectStream(BroadcastVideoStream stream) {
    ref
        .read(broadcastVideoSessionPreferencesProvider.notifier)
        .write(
          _storageKey,
          BroadcastVideoPreference(
            selectedId: stream.id,
            countryCode: stream.countryCode,
            visible: true,
          ),
        );
    final languageGroupKey = broadcastVideoLanguageGroupKey(stream);
    unawaited(
      ref
          .read(broadcastVideoLanguageProvider.notifier)
          .remember(languageGroupKey),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    final scope = _scope;
    final streamsState = ref.watch(broadcastVideoStreamsProvider(scope));
    final data = streamsState.valueOrNull;
    // No list yet, or the read failed: render nothing, as the site's in-game
    // view does. A transient failure keeps polling every 30 seconds and the
    // panel appears once a read succeeds.
    if (data == null || data.streams.isEmpty) return const SizedBox.shrink();
    final languageState = ref.watch(broadcastVideoLanguageProvider);
    // The remembered language only applies once loaded, so the first paint
    // never flashes the default stream before settling on the spectator's
    // last pick. Mirrors the web's `language.loaded` gate.
    if (languageState.isLoading) return const SizedBox.shrink();
    final preferences =
        ref.watch(broadcastVideoSessionPreferencesProvider)[_storageKey] ??
        const BroadcastVideoPreference();
    final selected = resolveBroadcastVideoSelection(
      data.streams,
      selectedId: preferences.selectedId,
      language: languageState.valueOrNull,
      countryCode: preferences.countryCode,
    );
    if (selected == null) return const SizedBox.shrink();
    final groups = groupBroadcastVideoStreams(data.streams);
    final source = data.source;
    final watchUri =
        source != null
            ? broadcastVideoWatchUri(
              scope: source.scope,
              scopeId: source.id,
              streamId: selected.id,
            )
            : Uri.parse(selected.url);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _BroadcastVideoToolbar(
            groups: groups,
            selectedId: selected.id,
            onSelect: _selectStream,
            onOpenWatch: () => unawaited(launchDesktopWebUrl(watchUri)),
          ),
          _SelectedStreamRow(
            stream: selected,
            onOpenSource:
                () => unawaited(launchDesktopWebUrl(Uri.parse(selected.url))),
          ),
        ],
      ),
    );
  }
}

/// The selected stream, named, with the one action that plays it: on the
/// provider, in the system browser.
class _SelectedStreamRow extends StatelessWidget {
  const _SelectedStreamRow({required this.stream, required this.onOpenSource});

  final BroadcastVideoStream stream;
  final VoidCallback onOpenSource;

  @override
  Widget build(BuildContext context) {
    final provider = stream.provider.displayName;
    final live = stream.publication?.isLive ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  broadcastVideoStreamDisplayName(stream),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: kWhiteColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  live ? '$provider · Live now' : provider,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: kLightGreyColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DesktopToolbarPillButton(
            label: 'Open on $provider',
            icon: Icons.open_in_new_rounded,
            tone: DesktopToolbarPillTone.primary,
            height: 28,
            onPress: onOpenSource,
          ),
        ],
      ),
    );
  }
}

class _BroadcastVideoToolbar extends StatelessWidget {
  const _BroadcastVideoToolbar({
    required this.groups,
    required this.selectedId,
    required this.onSelect,
    required this.onOpenWatch,
  });

  final List<BroadcastVideoStreamGroup> groups;
  final String selectedId;
  final ValueChanged<BroadcastVideoStream> onSelect;
  final VoidCallback onOpenWatch;

  // A 30px flag, plus the 18px count badge laid out beside it when the
  // language owns several streams. Reserving the badged footprint for every
  // slot keeps the row from overflowing when the first N groups happen to be
  // multi-stream.
  static const double _slot = 48;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    // Extra bottom room for the count badge, which hangs below its flag.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The trailing action is fixed; only the remaining width can hold
          // language slots.
          const actionsWidth = 38.0;
          final flagsWidth = constraints.maxWidth - actionsWidth;
          final capacity =
              flagsWidth <= 0
                  ? 0
                  : ((flagsWidth + _gap) / (_slot + _gap)).floor();
          final visibleCount =
              capacity >= groups.length
                  ? groups.length
                  : (capacity - 1).clamp(0, groups.length);
          final visibleGroups = groups.take(visibleCount).toList();
          final hiddenGroups = groups.skip(visibleCount).toList();
          return Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (final group in visibleGroups) ...[
                      _LanguageGroupButton(
                        group: group,
                        selectedId: selectedId,
                        onSelect: onSelect,
                      ),
                      const SizedBox(width: _gap),
                    ],
                    if (hiddenGroups.isNotEmpty)
                      _OverflowLanguageButton(
                        groups: hiddenGroups,
                        selectedId: selectedId,
                        onSelect: onSelect,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _RailIconButton(
                icon: Icons.grid_view_rounded,
                tooltip: 'Watch video with live boards',
                onPress: onOpenWatch,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LanguageGroupButton extends StatefulWidget {
  const _LanguageGroupButton({
    required this.group,
    required this.selectedId,
    required this.onSelect,
  });

  final BroadcastVideoStreamGroup group;
  final String selectedId;
  final ValueChanged<BroadcastVideoStream> onSelect;

  @override
  State<_LanguageGroupButton> createState() => _LanguageGroupButtonState();
}

class _LanguageGroupButtonState extends State<_LanguageGroupButton>
    with SingleTickerProviderStateMixin {
  /// Same grace the site gives: leaving the flag closes the list unless the
  /// pointer reaches it within this window.
  static const Duration _closeGrace = Duration(milliseconds: 140);

  late final FPopoverController _menuController = FPopoverController(
    vsync: this,
  );
  Timer? _closeTimer;

  bool get _multiple => widget.group.streams.length > 1;

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

  /// Hovering a flag that owns several streams lists them, as on the site;
  /// a single-stream flag only carries its tooltip.
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

  Widget _withTooltip(String? message, Widget child) =>
      message == null
          ? child
          : DesktopTooltip(
            message: message,
            tipAnchor: Alignment.topCenter,
            childAnchor: Alignment.bottomCenter,
            child: child,
          );

  @override
  Widget build(BuildContext context) {
    final multiple = _multiple;
    final primary = widget.group.streams.first;
    final selected = widget.group.streams.any(
      (stream) => stream.id == widget.selectedId,
    );
    final tooltip =
        multiple
            ? '${widget.group.label} · ${widget.group.streams.length} streams'
            : '${widget.group.label} · ${broadcastVideoStreamTitle(primary)}';
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _menuController,
        popoverBuilder:
            (context, _) => MouseRegion(
              onEnter: (_) => _cancelClose(),
              onExit: (_) => _closeMenuSoon(),
              child: _GroupStreamMenu(
                group: widget.group,
                selectedId: widget.selectedId,
                onSelect: (stream) {
                  _closeMenu();
                  widget.onSelect(stream);
                },
              ),
            ),
        child: MouseRegion(
          onEnter: (_) => _openMenu(),
          onExit: (_) => _closeMenuSoon(),
          child: _withTooltip(
            // A multi-stream flag answers hover with the list itself; a
            // tooltip on top of it would only clutter the rail.
            multiple ? null : tooltip,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _FlagButton(
                  code: widget.group.countryCode,
                  selected: selected,
                  semanticsLabel: tooltip,
                  onPress: () {
                    _closeMenu();
                    widget.onSelect(primary);
                  },
                ),
                if (multiple)
                  _StreamCountBadge(
                    count: widget.group.streams.length,
                    semanticsLabel:
                        'Choose among ${widget.group.streams.length} ${widget.group.label} streams',
                    onPress: () {
                      _cancelClose();
                      unawaited(_menuController.toggle());
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FlagButton extends StatelessWidget {
  const _FlagButton({
    required this.code,
    required this.selected,
    required this.onPress,
    required this.semanticsLabel,
  });

  final String? code;
  final bool selected;
  final VoidCallback onPress;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final code = this.code;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        onPress: onPress,
        semanticsLabel: semanticsLabel,
        builder: (context, states, child) {
          final hovered = states.contains(WidgetState.hovered);
          final pressed = states.contains(WidgetState.pressed);
          final focused = states.contains(WidgetState.focused);
          final border =
              selected || focused
                  ? kPrimaryColor
                  : (hovered
                      ? kWhiteColor.withValues(alpha: 0.28)
                      : kDividerColor);
          return Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.12)
                      : (hovered || pressed
                          ? kBlack3Color
                          : Colors.transparent),
              border: Border.all(color: border),
            ),
            child: child,
          );
        },
        child:
            code == null
                ? const Icon(
                  Icons.language_rounded,
                  size: 16,
                  color: kWhiteColor70,
                )
                : CountryFlag.fromCountryCode(
                  code,
                  theme: const ImageTheme(
                    width: 20,
                    height: 20,
                    shape: Circle(),
                  ),
                ),
      ),
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
    return Transform.translate(
      offset: const Offset(-4, 8),
      child: FTheme(
        data: FThemes.zinc.dark,
        child: FTappable(
          onPress: onPress,
          semanticsLabel: semanticsLabel,
          builder: (context, states, _) {
            final hovered = states.contains(WidgetState.hovered);
            final focused = states.contains(WidgetState.focused);
            return Container(
              constraints: const BoxConstraints(minWidth: 18),
              height: 18,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    hovered || focused
                        ? kPrimaryColor.withValues(alpha: 0.18)
                        : kBlack2Color,
                borderRadius: BorderRadius.circular(9),
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
      ),
    );
  }
}

class _OverflowLanguageButton extends StatefulWidget {
  const _OverflowLanguageButton({
    required this.groups,
    required this.selectedId,
    required this.onSelect,
  });

  final List<BroadcastVideoStreamGroup> groups;
  final String selectedId;
  final ValueChanged<BroadcastVideoStream> onSelect;

  @override
  State<_OverflowLanguageButton> createState() =>
      _OverflowLanguageButtonState();
}

class _OverflowLanguageButtonState extends State<_OverflowLanguageButton>
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
        popoverBuilder:
            (context, _) => _OverflowMenu(
              groups: widget.groups,
              selectedId: widget.selectedId,
              onSelect: (stream) {
                _controller.hide();
                widget.onSelect(stream);
              },
            ),
        child: DesktopTooltip(
          message: 'More video languages',
          tipAnchor: Alignment.topCenter,
          childAnchor: Alignment.bottomCenter,
          child: _RailIconButton(
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: '',
            onPress: _controller.toggle,
          ),
        ),
      ),
    );
  }
}

/// Per-language stream list. Shown when a flag owns more than one stream.
class _GroupStreamMenu extends StatelessWidget {
  const _GroupStreamMenu({
    required this.group,
    required this.selectedId,
    required this.onSelect,
  });

  final BroadcastVideoStreamGroup group;
  final String selectedId;
  final ValueChanged<BroadcastVideoStream> onSelect;

  @override
  Widget build(BuildContext context) {
    return _MenuSurface(
      width: 260,
      children: [
        _MenuHeader(label: group.label),
        for (final stream in group.streams)
          _MenuRow(
            label: broadcastVideoStreamDisplayName(stream),
            trailing: stream.provider.displayName,
            selected: stream.id == selectedId,
            onTap: () => onSelect(stream),
          ),
      ],
    );
  }
}

/// Hidden language groups. A group with several streams lists them directly
/// (the site nests a submenu; a flat list reads better in the rail).
class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.groups,
    required this.selectedId,
    required this.onSelect,
  });

  final List<BroadcastVideoStreamGroup> groups;
  final String selectedId;
  final ValueChanged<BroadcastVideoStream> onSelect;

  @override
  Widget build(BuildContext context) {
    return _MenuSurface(
      width: 260,
      children: [
        for (final group in groups) ...[
          _MenuHeader(label: group.label, code: group.countryCode),
          for (final stream in group.streams)
            _MenuRow(
              label: broadcastVideoStreamDisplayName(stream),
              trailing: stream.provider.displayName,
              selected: stream.id == selectedId,
              onTap: () => onSelect(stream),
            ),
        ],
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
      constraints: const BoxConstraints(maxHeight: 340),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
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
  const _MenuHeader({required this.label, this.code});

  final String label;
  final String? code;

  @override
  Widget build(BuildContext context) {
    final country = code;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          if (country != null) ...[
            CountryFlag.fromCountryCode(
              country,
              theme: const ImageTheme(width: 14, height: 14, shape: Circle()),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: kLightGreyColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.label,
    required this.trailing,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String trailing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final selected = this.selected;
    return FTheme(
      data: FThemes.zinc.dark,
      child: FTappable(
        onPress: onTap,
        semanticsLabel: '$label, $trailing',
        builder: (context, states, _) {
          final hovered = states.contains(WidgetState.hovered);
          final focused = states.contains(WidgetState.focused);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.12)
                    : (hovered || focused ? kBlack3Color : Colors.transparent),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected ? kPrimaryColor : kWhiteColor,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  trailing,
                  style: const TextStyle(fontSize: 11, color: kLightGreyColor),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _RailIconButton extends StatelessWidget {
  const _RailIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPress;

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
          final background =
              hovered || pressed ? kBlack3Color : Colors.transparent;
          final foreground = hovered ? kWhiteColor : kWhiteColor70;
          return Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: background,
              border: Border.all(
                color:
                    focused
                        ? kPrimaryColor.withValues(alpha: 0.35)
                        : Colors.transparent,
              ),
            ),
            child: Icon(icon, size: 17, color: foreground),
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
