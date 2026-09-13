import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

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
import 'package:chessever/desktop/state/broadcast_video_visibility_provider.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:country_flags/country_flags.dart';

/// Live-stream panel for the top of the Board pane's right rail.
///
/// Parity port of the web broadcast Board screen's `VideoStreams`: the
/// editor-curated Twitch / YouTube / Kick list for the game's round (or
/// tour) is polled every 30 seconds, grouped by language, and the selected
/// stream plays inline. The player is a real WebView (WKWebView on macOS,
/// WebView2 composited as a Flutter texture on Windows) showing
/// chessever.com's own `/embed/video` document, so the provider is framed by
/// the site exactly as in the browser: no provider player is ever loaded
/// top-level, and no referrer or `parent` is asserted by the app itself.
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

  /// Stable owning event identity: session stream choice and durable video
  /// visibility share this key, not the current round or inherited source.
  final String tournamentStorageId;

  @override
  ConsumerState<BroadcastVideoPanel> createState() =>
      _BroadcastVideoPanelState();
}

class _BroadcastVideoPanelState extends ConsumerState<BroadcastVideoPanel> {
  /// Shared across panels: the first panel starts the environment and every
  /// later one awaits that same future instead of assuming it finished.
  static Future<void>? _windowsEnvironment;

  WebViewController? _controller;
  String? _loadedEmbedUrl;

  /// The embed document failed to arrive or did not carry a player (site
  /// unreachable, route missing): show the external link instead of a
  /// broken frame.
  bool _frameFailed = false;

  /// A failed frame (site unreachable, page not deployed yet) retries on its
  /// own a few times with growing pauses, and at once from the row's Retry
  /// action. Bounded on purpose: a site that stays down must not be asked
  /// for a player forever. The providers are never in this loop; they are
  /// only reached once our own page has delivered its frame.
  static const List<Duration> _retryBackoff = <Duration>[
    Duration(seconds: 45),
    Duration(seconds: 90),
    Duration(minutes: 3),
  ];
  Timer? _retryTimer;
  int _autoRetries = 0;

  /// Leaving the tab or hiding the window does not blank the player at once:
  /// a quick switch back re-attaches the same player instead of asking the
  /// provider for it again. After the grace the player is blanked, so
  /// nothing keeps playing from a screen the user is not viewing.
  static const Duration _stopGrace = Duration(seconds: 20);
  Timer? _stopTimer;

  void _markFrameFailed() {
    if (!mounted || _frameFailed) return;
    setState(() => _frameFailed = true);
    _retryTimer?.cancel();
    if (_autoRetries < _retryBackoff.length) {
      _retryTimer = Timer(_retryBackoff[_autoRetries], () {
        _autoRetries++;
        _retryEmbed();
      });
    }
  }

  void _scheduleStopPlaybackAfterGrace() {
    if (_loadedEmbedUrl == null || _stopTimer != null) return;
    _stopTimer = Timer(_stopGrace, () {
      _stopTimer = null;
      if (mounted) _stopPlaybackNow();
    });
  }

  void _cancelStopGrace() {
    _stopTimer?.cancel();
    _stopTimer = null;
  }

  void _stopPlaybackNow() {
    if (_loadedEmbedUrl == null) return;
    _loadedEmbedUrl = null;
    final controller = _controller;
    if (controller == null) return;
    unawaited(
      controller
          .loadRequest(Uri.parse('about:blank'))
          .catchError((Object _) {}),
    );
  }

  void _retryEmbed() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!mounted) return;
    setState(() {
      _frameFailed = false;
      // Forget the failed load so the next build issues a fresh request.
      _loadedEmbedUrl = null;
    });
  }

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
            // Provider players load inside the embed document's iframe;
            // their own sub-frame navigations are theirs to make. The one
            // exception is YouTube's passive Google sign-in frame: without
            // a signed-in browser profile it reloads itself without end
            // (`signin_passive?reload=9&reload=9…`), and the player plays
            // exactly the same without it.
            if (!request.isMainFrame) {
              return _isGoogleSignInFrame(uri)
                  ? NavigationDecision.prevent
                  : NavigationDecision.navigate;
            }
            if (uri.scheme == 'about') return NavigationDecision.navigate;
            if (broadcastEmbedPageHosts.contains(uri.host.toLowerCase())) {
              return NavigationDecision.navigate;
            }
            // Anything taking over the top frame is cancelled; the rail
            // stays on the embed document. Only a provider destination
            // ("Watch on Twitch", a channel page, a YouTube title) earns a
            // browser tab, and never more than one per moment: an ad or a
            // fingerprinting frame that tries the top frame in a loop must
            // not turn the user's browser into a tab fountain.
            _maybeOpenExternally(uri);
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame != true || !mounted) return;
            _markFrameFailed();
          },
          onPageFinished: (url) {
            if (url == _loadedEmbedUrl) unawaited(_verifyEmbedDocument());
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

  static bool _isGoogleSignInFrame(Uri uri) {
    final host = uri.host.toLowerCase();
    return host == 'accounts.google.com' ||
        host.endsWith('.accounts.google.com') ||
        (host.endsWith('youtube.com') &&
            uri.path.toLowerCase().contains('signin_passive'));
  }

  /// Destinations worth a browser tab: the providers' own watch pages.
  static const Set<String> _externalHosts = <String>{
    'twitch.tv',
    'www.twitch.tv',
    'm.twitch.tv',
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
    'kick.com',
    'www.kick.com',
  };
  static const Duration _externalLaunchSpacing = Duration(seconds: 2);
  static const Duration _externalRepeatSpacing = Duration(seconds: 15);

  DateTime? _lastExternalLaunch;
  String? _lastExternalUrl;

  void _maybeOpenExternally(Uri uri) {
    if (uri.scheme != 'https' ||
        !_externalHosts.contains(uri.host.toLowerCase())) {
      return;
    }
    final now = DateTime.now();
    final last = _lastExternalLaunch;
    final url = uri.toString();
    if (last != null) {
      final since = now.difference(last);
      if (since < _externalLaunchSpacing) return;
      if (url == _lastExternalUrl && since < _externalRepeatSpacing) return;
    }
    _lastExternalLaunch = now;
    _lastExternalUrl = url;
    unawaited(launchDesktopWebUrl(uri));
  }

  /// The embed document is a bare player; a Next "not found" or error page
  /// (route not deployed, site down) has no frame at all. Fall back to the
  /// external link rather than showing that page in the rail.
  Future<void> _verifyEmbedDocument() async {
    final controller = _controller;
    final expectedUrl = _loadedEmbedUrl;
    if (controller == null || expectedUrl == null) return;
    Object? result;
    try {
      result = await controller.runJavaScriptReturningResult(
        'document.querySelector("iframe") !== null',
      );
    } catch (_) {
      return; // Not answerable (page torn down); the next load re-checks.
    }
    final hasFrame = result == true || result.toString() == 'true';
    if (!mounted || _loadedEmbedUrl != expectedUrl) return;
    if (hasFrame) {
      _autoRetries = 0;
      return;
    }
    _markFrameFailed();
  }

  void _scheduleEmbedLoad(Uri url) {
    final key = url.toString();
    if (_loadedEmbedUrl == key) return;
    _loadedEmbedUrl = key;
    _frameFailed = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadedEmbedUrl != key) return;
      if (!widget.active || !ref.read(liveGameStreamingLifecycleProvider)) {
        _loadedEmbedUrl = null;
        return;
      }
      unawaited(_ensureController().loadRequest(url));
    });
  }

  void _scheduleStopPlayback() {
    if (_loadedEmbedUrl == null) return;
    _loadedEmbedUrl = null;
    final controller = _controller;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadedEmbedUrl != null) return;
      unawaited(controller.loadRequest(Uri.parse('about:blank')));
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _stopTimer?.cancel();
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
    _setVisible(true);
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
    if (!visible) {
      _retryTimer?.cancel();
      _cancelStopGrace();
      _stopPlaybackNow();
    }
    unawaited(
      ref.read(broadcastVideoVisibilityProvider(widget.tournamentStorageId).notifier)
          .remember(visible)
          .catchError((Object error) {
            debugPrint('Could not persist video visibility: $error');
          }),
    );
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
    // A hidden or minimised window is not a screen the user is viewing;
    // YouTube's policies forbid a background player (III.I.9) and Twitch
    // may disable autoplay for hidden embeds, so playback stops with the
    // window and resumes when it is shown again.
    final windowVisible = ref.watch(liveGameStreamingLifecycleProvider);
    if (!widget.active || !windowVisible) {
      _scheduleStopPlaybackAfterGrace();
      return const SizedBox.shrink();
    }
    _cancelStopGrace();
    final visibility = ref.watch(
      broadcastVideoVisibilityProvider(widget.tournamentStorageId),
    );
    // Never create a player before the durable off preference is known.
    // A storage read error also fails closed instead of autoplaying.
    if (!visibility.hasValue || visibility.isLoading || visibility.hasError) {
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
    final visible = visibility.requireValue;
    if (!visible) _scheduleStopPlayback();
    final groups = groupBroadcastVideoStreams(data.streams);
    // Player first, toolbar under it: every popover and tooltip the toolbar
    // opens then falls downward over our own notation panel, never in front
    // of the provider player. Both Twitch ("should not be obscured in any
    // way by other page elements") and YouTube ("must not display overlays
    // … in front of any part of a YouTube embedded player") forbid that.
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (visible) _buildPlayer(selected, data.source),
          _BroadcastVideoToolbar(
            groups: groups,
            selectedId: selected.id,
            visible: visible,
            onSelect: _selectStream,
            onToggle: () => _setVisible(!visible),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(
    BroadcastVideoStream stream,
    BroadcastVideoSourceRef? source,
  ) {
    final provider = stream.provider;
    void openExternal() =>
        unawaited(launchDesktopWebUrl(Uri.parse(stream.url)));
    // The API attaches the resolving scope to every non-empty list; without
    // it there is no site document to frame the player through.
    if (source == null) {
      _scheduleStopPlayback();
      return _OpenExternallyRow(
        message: 'This stream can only be watched on ${provider.displayName}.',
        provider: provider,
        onOpenExternal: openExternal,
      );
    }
    final embedPage = broadcastVideoEmbedPageUri(
      scope: source.scope,
      scopeId: source.id,
      streamId: stream.id,
      play: true,
    );
    if (!_environmentReady) return const SizedBox(height: 8);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < provider.minWidth) {
          _scheduleStopPlayback();
          return _OpenExternallyRow(
            message: 'Open ${provider.displayName} to watch at this width.',
            provider: provider,
            onOpenExternal: openExternal,
          );
        }
        _scheduleEmbedLoad(embedPage);
        if (_frameFailed) {
          return _OpenExternallyRow(
            message: 'The player could not load here.',
            provider: provider,
            onOpenExternal: openExternal,
            onRetry: _retryEmbed,
          );
        }
        final controller = _ensureController();
        // 16:9 for the rail width, never below the provider's minimum player
        // height, and capped so the notation below keeps a usable share of
        // the rail on short windows.
        final height = (constraints.maxWidth * 9 / 16)
            .clamp(provider.minHeight, math.max(340.0, provider.minHeight))
            .toDouble();
        return SizedBox(
          height: height,
          width: double.infinity,
          child: ColoredBox(
            color: kBlackColor,
            child: WebViewWidget(controller: controller),
          ),
        );
      },
    );
  }
}

class _OpenExternallyRow extends StatelessWidget {
  const _OpenExternallyRow({
    required this.message,
    required this.provider,
    required this.onOpenExternal,
    this.onRetry,
  });

  final String message;
  final BroadcastVideoProvider provider;
  final VoidCallback onOpenExternal;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 11.5, color: kWhiteColor70),
            ),
          ),
          if (onRetry != null) ...[
            DesktopToolbarPillButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              height: 28,
              onPress: onRetry,
            ),
            const SizedBox(width: 6),
          ],
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
  });

  final List<BroadcastVideoStreamGroup> groups;
  final String selectedId;
  final bool visible;
  final ValueChanged<BroadcastVideoStream> onSelect;
  final VoidCallback onToggle;

  // A 30px flag, plus the 18px count badge laid out beside it when the
  // language owns several streams. Reserving the badged footprint for every
  // slot keeps the row from overflowing when the first N groups happen to be
  // multi-stream.
  static const double _slot = 48;
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    // Extra bottom room for the count badge, which hangs below its flag so
    // nothing of ours reaches up into the player above.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The trailing actions are fixed; only the remaining width can hold
          // language slots.
          const actionsWidth = 38.0;
          final flagsWidth = constraints.maxWidth - actionsWidth;
          final capacity = flagsWidth <= 0
              ? 0
              : ((flagsWidth + _gap) / (_slot + _gap)).floor();
          final visibleCount = capacity >= groups.length
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
                icon: visible
                    ? Icons.videocam_off_rounded
                    : Icons.videocam_rounded,
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

  Widget _withTooltip(String? message, Widget child) => message == null
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
    final tooltip = multiple
        ? '${widget.group.label} · ${widget.group.streams.length} streams'
        : '${widget.group.label} · ${broadcastVideoStreamTitle(primary)}';
    return FTheme(
      data: FThemes.zinc.dark,
      child: FPopover(
        controller: _menuController,
        popoverBuilder: (context, _) => MouseRegion(
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
          final border = selected || focused
              ? kPrimaryColor
              : (hovered ? kWhiteColor.withValues(alpha: 0.28) : kDividerColor);
          return Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? kPrimaryColor.withValues(alpha: 0.12)
                  : (hovered || pressed ? kBlack3Color : Colors.transparent),
              border: Border.all(color: border),
            ),
            child: child,
          );
        },
        child: code == null
            ? const Icon(Icons.language_rounded, size: 16, color: kWhiteColor70)
            : CountryFlag.fromCountryCode(
                code,
                theme: const ImageTheme(width: 20, height: 20, shape: Circle()),
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
                color: hovered || focused
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
        popoverBuilder: (context, _) => _OverflowMenu(
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
            color: selected
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
          final background = selected
              ? kPrimaryColor.withValues(alpha: hovered ? 0.16 : 0.10)
              : (hovered || pressed ? kBlack3Color : Colors.transparent);
          final foreground = selected
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
                color: selected || focused
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
