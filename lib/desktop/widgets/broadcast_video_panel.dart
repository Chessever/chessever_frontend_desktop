import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_windows/webview_all_windows.dart'
    show WindowsWebViewController;
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart'
    show PlaybackMediaTypes, WebKitWebViewControllerCreationParams;

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/state/broadcast_video_streams_provider.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:country_flags/country_flags.dart';

/// Live-stream panel for the top of the Board pane's right rail.
///
/// Parity port of the web broadcast Board screen's `VideoStreams`: the
/// organiser-managed Twitch / YouTube / Kick list for the game's round (or
/// tour) is polled every 30 seconds, grouped by language, and the selected
/// stream plays inline. The player is a real WebView so provider embeds work
/// identically to the site — WKWebView on macOS, WebView2 (composited as a
/// Flutter texture) on Windows.
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
  /// render nothing and tear playback down, so a hidden tab can never keep a
  /// stream (and its audio) alive behind the one on screen.
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
  static const Set<String> _playerHosts = <String>{
    'player.twitch.tv',
    'www.youtube.com',
    'youtube.com',
    'www.youtube-nocookie.com',
    'youtube-nocookie.com',
    'consent.youtube.com',
    'player.kick.com',
  };

  /// Shared across panels: the first panel starts the environment and every
  /// later one awaits that same future instead of assuming it finished.
  static Future<void>? _windowsEnvironment;

  WebViewController? _controller;
  String? _loadedEmbedUrl;

  /// Windows only: WebView2's environment must exist before the first
  /// controller is constructed, or the controller wins the race and creates a
  /// default environment that can no longer receive the autoplay policy.
  bool _environmentReady = !Platform.isWindows;

  BroadcastVideoScope get _scope =>
      BroadcastVideoScope(tourId: widget.tourId, roundId: widget.roundId);

  String get _storageKey => 'ce-video.v1:${widget.tournamentStorageId}';

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      // WebView2 blocks autoplay with sound by default. The web embeds start
      // muted=false with autoplay on; request the same policy so the desktop
      // panel behaves identically. Idempotent across panels.
      unawaited(
        _ensureWindowsEnvironment().whenComplete(() {
          if (mounted) setState(() => _environmentReady = true);
        }),
      );
    }
  }

  static Future<void> _ensureWindowsEnvironment() {
    return _windowsEnvironment ??= _createWindowsEnvironment();
  }

  static Future<void> _createWindowsEnvironment() async {
    try {
      await WindowsWebViewController.ensureEnvironment(
        additionalArguments: '--autoplay-policy=no-user-gesture-required',
      );
    } catch (_) {
      // The panel still works; the provider's own play control remains.
    }
  }

  WebViewController _ensureController() {
    final existing = _controller;
    if (existing != null) return existing;
    final controller = _createController();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(kBlackColor)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (uri.scheme == 'about') return NavigationDecision.navigate;
            if (_playerHosts.contains(uri.host.toLowerCase())) {
              return NavigationDecision.navigate;
            }
            // Provider chrome links ("Watch on Twitch", channel pages…)
            // belong in the real browser, not in the rail-sized frame.
            unawaited(launchDesktopWebUrl(uri));
            return NavigationDecision.prevent;
          },
        ),
      );
    _controller = controller;
    return controller;
  }

  WebViewController _createController() {
    if (Platform.isMacOS) {
      // Inline HTML5 playback and autoplay, matching the web's autoplay
      // behaviour. Defaults (inline false, media requires a gesture) would
      // push the embed fullscreen and demand a click.
      return WebViewController.fromPlatformCreationParams(
        WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        ),
      );
    }
    return WebViewController();
  }

  void _scheduleEmbedLoad(BroadcastVideoEmbed embed) {
    final url = embed.url.toString();
    if (_loadedEmbedUrl == url) return;
    _loadedEmbedUrl = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _ensureController().loadRequest(embed.url, headers: embed.headers),
      );
    });
  }

  void _scheduleStopPlayback() {
    if (_loadedEmbedUrl == null) return;
    _loadedEmbedUrl = null;
    final controller = _controller;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(controller.loadRequest(Uri.parse('about:blank')));
    });
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      final platform = controller.platform;
      if (platform is WindowsWebViewController) {
        // Windows keeps a native controller alive until it is disposed; do
        // it deterministically instead of leaving a WebView2 renderer for
        // the GC.
        unawaited(platform.dispose());
      } else {
        // WKWebView outlives its widget until the controller is collected,
        // so a torn-down pane would otherwise keep the stream (and its
        // audio) playing invisibly. Blank it now.
        unawaited(
          controller
              .loadRequest(Uri.parse('about:blank'))
              .catchError((Object _) {}),
        );
      }
    }
    super.dispose();
  }

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

  void _setVisible(bool visible) {
    final preferences =
        ref.read(broadcastVideoSessionPreferencesProvider)[_storageKey] ??
        const BroadcastVideoPreference();
    ref
        .read(broadcastVideoSessionPreferencesProvider.notifier)
        .write(
          _storageKey,
          BroadcastVideoPreference(
            selectedId: preferences.selectedId,
            countryCode: preferences.countryCode,
            visible: visible,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      _scheduleStopPlayback();
      return const SizedBox.shrink();
    }
    final scope = _scope;
    final streamsState = ref.watch(broadcastVideoStreamsProvider(scope));
    final data = streamsState.valueOrNull;
    // No list yet, or the read failed: the web's in-game view renders
    // nothing in both cases (its "temporarily unavailable" notice only
    // exists on the tournament hall). A permanent failure means the scope
    // has no embeddable coverage; a transient one keeps polling every 30s
    // and the panel appears once a read succeeds.
    if (data == null) {
      _scheduleStopPlayback();
      return const SizedBox.shrink();
    }
    if (data.streams.isEmpty) {
      _scheduleStopPlayback();
      return const SizedBox.shrink();
    }
    final languageState = ref.watch(broadcastVideoLanguageProvider);
    // The remembered language only applies once loaded, so the first paint
    // never flashes (and loads) the default stream before settling on the
    // spectator's last pick. Mirrors the web's `language.loaded` gate.
    if (languageState.isLoading) return const SizedBox.shrink();
    final preferences =
        ref.watch(broadcastVideoSessionPreferencesProvider)[_storageKey] ??
        const BroadcastVideoPreference();
    final language = languageState.valueOrNull;
    final selected = resolveBroadcastVideoSelection(
      data.streams,
      selectedId: preferences.selectedId,
      language: language,
      countryCode: preferences.countryCode,
    );
    if (selected == null) {
      _scheduleStopPlayback();
      return const SizedBox.shrink();
    }
    final visible = preferences.visible ?? true;
    if (!visible) _scheduleStopPlayback();
    final groups = groupBroadcastVideoStreams(data.streams);
    final watchUri =
        data.source != null
            ? broadcastVideoWatchUri(
              scope: data.source!.scope,
              scopeId: data.source!.id,
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
            visible: visible,
            onSelect: _selectStream,
            onToggle: () => _setVisible(!visible),
            onOpenWatch: () => unawaited(launchDesktopWebUrl(watchUri)),
          ),
          if (visible) _buildPlayer(selected),
        ],
      ),
    );
  }

  Widget _buildPlayer(BroadcastVideoStream stream) {
    final provider = stream.provider;
    final embed = broadcastVideoEmbed(
      provider: provider,
      sourceId: stream.sourceId,
      play: true,
    );
    if (!_environmentReady) return const SizedBox(height: 8);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < provider.minWidth) {
          _scheduleStopPlayback();
          return _TooNarrowRow(
            provider: provider,
            onOpenExternal:
                () => unawaited(launchDesktopWebUrl(Uri.parse(stream.url))),
          );
        }
        _scheduleEmbedLoad(embed);
        final controller = _ensureController();
        // Cap the player so the notation below keeps a usable share of the
        // rail on short windows; the AspectRatio folds the excess into width.
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 340),
          child: Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ColoredBox(
                color: kBlackColor,
                child: WebViewWidget(controller: controller),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TooNarrowRow extends StatelessWidget {
  const _TooNarrowRow({required this.provider, required this.onOpenExternal});

  final BroadcastVideoProvider provider;
  final VoidCallback onOpenExternal;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Open ${provider.displayName} to watch at this width.',
              style: const TextStyle(fontSize: 11.5, color: kWhiteColor70),
            ),
          ),
          DesktopToolbarPillButton(
            label: 'Open ${provider.displayName}',
            icon: Icons.open_in_new_rounded,
            height: 28,
            onPress: onOpenExternal,
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
    required this.visible,
    required this.onSelect,
    required this.onToggle,
    required this.onOpenWatch,
  });

  final List<BroadcastVideoStreamGroup> groups;
  final String selectedId;
  final bool visible;
  final ValueChanged<BroadcastVideoStream> onSelect;
  final VoidCallback onToggle;
  final VoidCallback onOpenWatch;

  // A 30px flag, plus the 18px count badge laid out beside it when the
  // language owns several streams. Reserving the badged footprint for every
  // slot keeps the row from overflowing when the first N groups happen to be
  // multi-stream.
  static const double _slot = 48;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The trailing actions are fixed; only the remaining width can hold
          // language slots.
          const actionsWidth = 74.0;
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
              const SizedBox(width: 2),
              _RailIconButton(
                icon:
                    visible
                        ? Icons.videocam_rounded
                        : Icons.videocam_off_rounded,
                tooltip: visible ? 'Hide video' : 'Show video',
                selected: visible,
                onPress: onToggle,
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
  late final FPopoverController _menuController = FPopoverController(
    vsync: this,
  );

  @override
  void dispose() {
    _menuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multiple = widget.group.streams.length > 1;
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
            (context, _) => _GroupStreamMenu(
              group: widget.group,
              selectedId: widget.selectedId,
              onSelect: (stream) {
                _menuController.hide();
                widget.onSelect(stream);
              },
            ),
        child: DesktopTooltip(
          message: tooltip,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FlagButton(
                code: widget.group.countryCode,
                selected: selected,
                semanticsLabel: tooltip,
                onPress: () => widget.onSelect(primary),
              ),
              if (multiple)
                _StreamCountBadge(
                  count: widget.group.streams.length,
                  semanticsLabel:
                      multiple
                          ? 'Choose among ${widget.group.streams.length} ${widget.group.label} streams'
                          : tooltip,
                  onPress: _menuController.toggle,
                ),
            ],
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
      offset: const Offset(-4, -10),
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
          final background =
              selected
                  ? kPrimaryColor.withValues(alpha: hovered ? 0.16 : 0.10)
                  : (hovered || pressed ? kBlack3Color : Colors.transparent);
          final foreground =
              selected
                  ? kPrimaryColor
                  : (hovered ? kWhiteColor : kWhiteColor70);
          return Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: background,
              border: Border.all(
                color:
                    selected || focused
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
    return DesktopTooltip(message: tooltip, child: button);
  }
}
