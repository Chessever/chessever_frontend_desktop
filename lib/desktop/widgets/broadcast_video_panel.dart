import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_windows/webview_all_windows.dart'
    show WindowsWebViewController;
import 'package:webview_all_wkwebview/webview_all_wkwebview.dart'
    show PlaybackMediaTypes, WebKitWebViewControllerCreationParams;

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/services/desktop_web_link_launcher.dart';
import 'package:chessever/desktop/state/broadcast_video_streams_provider.dart';
import 'package:chessever/desktop/widgets/broadcast_video_player_retention.dart';
import 'package:chessever/desktop/widgets/broadcast_video_toolbar.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:chessever/theme/app_theme.dart';

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
  /// keep rendering the player in place (the tab stack hides them) for a
  /// short grace so a switch-back keeps the same webview; after that they
  /// blank it so a hidden tab cannot keep a stream (and its audio) playing.
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
  /// a quick switch back keeps the same player instead of asking the
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
    if (controller != null) {
      unawaited(
        controller
            .loadRequest(Uri.parse('about:blank'))
            .catchError((Object _) {}),
      );
    }
    if (mounted) setState(() {});
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
          // Deliberately not filtered on the reported url: a redirect (or a
          // normalized trailing slash) would no longer match the url we asked
          // for and the frame check would never run, leaving a dead embed with
          // no fallback. Staleness is handled inside the check instead.
          onPageFinished: (_) => unawaited(_verifyEmbedDocument()),
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
    // The stream was switched while the query was in flight: that answer
    // describes the old document, so it can neither clear nor fail this one.
    if (!mounted || _loadedEmbedUrl != expectedUrl) return;
    if (hasFrame) {
      _autoRetries = 0;
      return;
    }
    _markFrameFailed();
  }

  void _scheduleEmbedLoad(Uri url) {
    final key = url.toString();
    if (!shouldReloadBroadcastVideoEmbed(
      loadedEmbedUrl: _loadedEmbedUrl,
      nextEmbedUrl: key,
    )) {
      return;
    }
    _loadedEmbedUrl = key;
    _frameFailed = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A newer selection (or a stop) already claimed the slot in this frame.
      if (!mounted || _loadedEmbedUrl != key) return;
      unawaited(_ensureController().loadRequest(url));
    });
  }

  void _scheduleStopPlayback() {
    if (_loadedEmbedUrl == null) return;
    _loadedEmbedUrl = null;
    final controller = _controller;
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A load that landed in the same frame must survive the queued stop.
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

  void _toggleVisible() {
    final preferences =
        ref.read(broadcastVideoSessionPreferencesProvider)[_storageKey] ??
        const BroadcastVideoPreference();
    _setVisible(preferences.visible == false);
  }

  void _togglePin(String streamId) {
    unawaited(
      ref
          .read(broadcastVideoPinsProvider(widget.tournamentStorageId).notifier)
          .toggle(streamId),
    );
  }

  List<BroadcastVideoStream> _desktopStreams(
    ResolvedBroadcastVideoStreams? data,
  ) {
    if (data == null) return const <BroadcastVideoStream>[];
    return data.streams
        .where(
          (stream) => broadcastStreamSupportsPlatform(
            stream,
            BroadcastVideoClientPlatform.desktop,
          ),
        )
        .toList(growable: false);
  }

  bool get _hasPreservedPlayer =>
      _controller != null && _loadedEmbedUrl != null && !_frameFailed;

  @override
  Widget build(BuildContext context) {
    // Always watch the stream list while this panel's State is mounted,
    // including background Board tabs. The family is autoDispose: an early
    // return that skipped the watch used to drop the listener, refetch on
    // return, and blank the player because `data` looked empty.
    final windowVisible = ref.watch(liveGameStreamingLifecycleProvider);
    final streamsState = ref.watch(broadcastVideoStreamsProvider(_scope));
    final languageState = ref.watch(broadcastVideoLanguageProvider);
    final preferences =
        ref.watch(broadcastVideoSessionPreferencesProvider)[_storageKey] ??
        const BroadcastVideoPreference();
    final data = streamsState.valueOrNull;
    final streams = _desktopStreams(data);
    final selected =
        data == null
            ? null
            : resolveBroadcastVideoSelection(
              streams,
              selectedId: preferences.selectedId,
              language:
                  languageState.isLoading ? null : languageState.valueOrNull,
              countryCode: preferences.countryCode,
            );
    final userHidden = preferences.visible == false;
    final retention = resolveBroadcastVideoPlayerRetention(
      tabActive: widget.active,
      windowVisible: windowVisible,
      hasPreservedPlayer: _hasPreservedPlayer,
      streamsResolved: data != null,
      languageReady: !languageState.isLoading,
      hasPlayableStream: streams.isNotEmpty && selected != null,
      userHidden: userHidden,
    );
    switch (retention) {
      case BroadcastVideoPlayerRetention.hide:
        if (!widget.active || !windowVisible) {
          _scheduleStopPlaybackAfterGrace();
          return const SizedBox.shrink();
        }
        _cancelStopGrace();
        _scheduleStopPlayback();
        // Web keeps the language/camera rail when the spectator collapses
        // the player; only the frame goes away. Returning shrink here used
        // to lose the toggle so the stream could not be turned back on.
        if (userHidden &&
            streams.isNotEmpty &&
            selected != null &&
            !languageState.isLoading) {
          return _playerSkeleton(
            stream: selected,
            source: data!.source,
            mayLoad: false,
            showPlayer: false,
            toolbar: _toolbar(
              streams: streams,
              selected: selected,
              expanded: false,
            ),
          );
        }
        return const SizedBox.shrink();
      case BroadcastVideoPlayerRetention.preserveOffstage:
        // Background tab (or hidden window) with a loaded player: render
        // the exact same skeleton as the foreground tab. The tab stack
        // already hides inactive tabs behind its own Offstage; the player
        // element itself never moves, so a switch back cannot dispose or
        // reload it. Playback still stops via the grace when it expires.
        _scheduleStopPlaybackAfterGrace();
        break;
      case BroadcastVideoPlayerRetention.show:
        _cancelStopGrace();
        break;
    }
    // Only the foreground surface may start a load: a background tab that
    // shares its tournament's stream choice must not autoplay a newly
    // selected stream while hidden. It picks the new selection up when it
    // returns to the foreground.
    final mayLoad = retention == BroadcastVideoPlayerRetention.show;
    // A loading gap (or a list that cannot pick a stream) keeps the loaded
    // player mounted in its slot; the toolbar slot is reserved from the
    // first frame so resolving the rail never reparents the webview.
    if (data == null ||
        streams.isEmpty ||
        selected == null ||
        languageState.isLoading) {
      return _playerSkeleton(
        stream: selected,
        source: data?.source,
        mayLoad: mayLoad,
      );
    }
    return _playerSkeleton(
      stream: selected,
      source: data.source,
      mayLoad: mayLoad,
      toolbar: _toolbar(streams: streams, selected: selected, expanded: true),
    );
  }

  Widget _toolbar({
    required List<BroadcastVideoStream> streams,
    required BroadcastVideoStream selected,
    required bool expanded,
  }) {
    final pins =
        ref
            .watch(broadcastVideoPinsProvider(widget.tournamentStorageId))
            .valueOrNull ??
        const <String>[];
    return BroadcastVideoToolbar(
      streams: streams,
      selectedId: selected.id,
      visible: expanded,
      pins: pins,
      onSelect: _selectStream,
      onToggle: _toggleVisible,
      onPin: _togglePin,
    );
  }

  /// The one stable shape every non-hide frame renders: the language rail
  /// at index 0 (web's `VideoStreamToolbar`), the player slot at index 1.
  ///
  /// A tab switch flips only ancestor Offstage/TickerMode flags; this
  /// subtree is identical foreground and background, so the platform view
  /// is never detached and the broadcast continues instead of restarting.
  /// Collapsing the player (web's camera toggle) drops only the slot; the
  /// toolbar stays so the spectator can turn the stream back on.
  Widget _playerSkeleton({
    required BroadcastVideoStream? stream,
    required BroadcastVideoSourceRef? source,
    required bool mayLoad,
    Widget? toolbar,
    bool showPlayer = true,
  }) {
    // Same order as the site's `.ce-video`: flags and overflow sit above
    // the frame. Menus and tooltips open upward off the player (see the
    // toolbar), matching Twitch / YouTube overlay rules.
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kDividerColor)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KeyedSubtree(
            key: const ValueKey<String>('desktop-broadcast-video-toolbar-slot'),
            child: toolbar ?? const SizedBox.shrink(),
          ),
          if (showPlayer) _playerSlot(stream, source, mayLoad: mayLoad),
        ],
      ),
    );
  }

  /// The player lives here for the whole life of the panel State: one
  /// [WebViewWidget] at one tree position, with no [GlobalKey] because it
  /// never moves. A rail too narrow for the provider, or a load that
  /// delivered no frame, hides it in place (an [Offstage] flag flip, not a
  /// reparent) and shows the external row beneath it. Nothing here may
  /// unmount or relocate the webview to "park" it: detaching the platform
  /// view is what restarts the broadcast on every tab but the first.
  Widget _playerSlot(
    BroadcastVideoStream? stream,
    BroadcastVideoSourceRef? source, {
    required bool mayLoad,
  }) {
    // Windows boots the controller only once the shared environment is
    // ready; before that there is no player to preserve, so this branch is
    // a one-way first mount, never a detach.
    if (!_environmentReady && !_hasPreservedPlayer) {
      return const SizedBox(height: 8);
    }
    final provider = stream?.provider;
    final embedPage =
        stream == null || source == null
            ? null
            : broadcastVideoEmbedPageUri(
              scope: source.scope,
              scopeId: source.id,
              streamId: stream.id,
              play: true,
            );
    return LayoutBuilder(
      builder: (context, constraints) {
        final tooNarrow =
            provider != null && constraints.maxWidth < provider.minWidth;
        // Hide (never unmount) when the rail cannot show this provider's
        // player, when the last load delivered no frame, or when there is
        // neither a URL nor a kept page to show. A kept player whose scope
        // lost its source (a refresh anomaly) stays visible: it is still
        // the stream the spectator was watching.
        final hidePlayer =
            tooNarrow ||
            _frameFailed ||
            (embedPage == null && !_hasPreservedPlayer);
        // Only a visible slot on the foreground surface may load: a hidden
        // webview must not autoplay (provider policy), a background tab
        // must not start a newly selected stream, and a loading gap has no
        // URL yet. The loaded page of a kept player is left untouched.
        final embedUrl = hidePlayer || !mayLoad ? null : embedPage;
        if (embedUrl != null) _scheduleEmbedLoad(embedUrl);
        Widget? row;
        void openExternal() {
          final url = stream?.url;
          if (url != null) unawaited(launchDesktopWebUrl(Uri.parse(url)));
        }

        if (_frameFailed && provider != null) {
          row = _OpenExternallyRow(
            message: 'The player could not load here.',
            provider: provider,
            onOpenExternal: openExternal,
            onRetry: _retryEmbed,
          );
        } else if (tooNarrow) {
          row = _OpenExternallyRow(
            message: 'Open ${provider.displayName} to watch at this width.',
            provider: provider,
            onOpenExternal: openExternal,
          );
        } else if (stream != null &&
            source == null &&
            provider != null &&
            !_hasPreservedPlayer) {
          // The API attaches the resolving scope to every non-empty list;
          // without it there is no site document to frame the player
          // through.
          row = _OpenExternallyRow(
            message:
                'This stream can only be watched on ${provider.displayName}.',
            provider: provider,
            onOpenExternal: openExternal,
          );
        }
        // 16:9 for the rail width, never below the provider's minimum player
        // height, and capped so the notation below keeps a usable share of
        // the rail on short windows.
        final minHeight = provider?.minHeight ?? 200.0;
        final height =
            (constraints.maxWidth * 9 / 16)
                .clamp(minHeight, math.max(340.0, minHeight))
                .toDouble();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Offstage(
              offstage: hidePlayer,
              child: SizedBox(
                height: height,
                width: double.infinity,
                child: ColoredBox(
                  color: kBlackColor,
                  child: WebViewWidget(controller: _ensureController()),
                ),
              ),
            ),
            if (row != null) row,
          ],
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
