import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/scroll_edge_arrows.dart';
import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/play_pane.dart'
    show PlayPaneTab, playPaneTabByTabIdProvider, playPaneTabProvider;
import 'package:chessever/desktop/panes/player_workspace_pane.dart'
    show
        PlayerSourceMark,
        PlayerWorkspacePane,
        kOwnPrepSources,
        showAttachOwnUsernamesFlow;
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_stats_summary.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_profile_sign_in.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/play_profile/play_badge_cabinet.dart';
import 'package:chessever/desktop/widgets/play_profile/play_profile_charts.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart'
    show GameStatus;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';
import 'package:chessever/desktop/widgets/desktop_spinner.dart';

/// The profile's two halves: Stats from the games played against the bots
/// (shown first), and the user's own prep profile.
enum _ProfileSection { play, prep }

/// Views inside Stats.
enum _PlayView { overview, games, achievements }

extension on _PlayView {
  String get label {
    switch (this) {
      case _PlayView.overview:
        return 'Overview';
      case _PlayView.games:
        return 'Games';
      case _PlayView.achievements:
        return 'Achievements';
    }
  }
}

const _kTimeControls = <RatedTimeControl>[
  RatedTimeControl.classical,
  RatedTimeControl.rapid,
  RatedTimeControl.blitz,
  RatedTimeControl.bullet,
];

/// Page gutter. Matches the Players workspace's own padding so the pinned
/// Prep view lines up with the header above it.
const double _kGutter = 24;

/// A raised surface: one tonal step above the page, no outline.
BoxDecoration _surface({bool raised = false}) => BoxDecoration(
  color: raised ? kBlack3Color : kBlack2Color,
  borderRadius: BorderRadius.circular(12),
);

const TextStyle _kHeading = TextStyle(
  color: kWhiteColor,
  fontSize: 14,
  fontWeight: FontWeight.w800,
);

const TextStyle _kMuted = TextStyle(
  color: kSecondaryTextColor,
  fontSize: 11,
  fontWeight: FontWeight.w600,
  fontFeatures: [FontFeature.tabularFigures()],
);

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

class PlayProfilePane extends ConsumerStatefulWidget {
  const PlayProfilePane({super.key, this.playTabId, this.hostTabId});

  /// Set when the profile is shown inside a Play tab.
  final String? playTabId;

  /// The desktop tab showing this profile, when it has one of its own.
  final String? hostTabId;

  @override
  ConsumerState<PlayProfilePane> createState() => _PlayProfilePaneState();
}

class _PlayProfilePaneState extends ConsumerState<PlayProfilePane> {
  _ProfileSection _section = _ProfileSection.play;
  _PlayView _playView = _PlayView.overview;
  RatedTimeControl? _chartTc;
  DesktopAccountProvider? _busyProvider;
  String? _signInError;

  Future<void> _signIn(DesktopAccountProvider provider) async {
    if (_busyProvider != null) return;
    setState(() {
      _busyProvider = provider;
      _signInError = null;
    });
    try {
      final signedIn = await signInDesktopPermanentAccount(
        ref,
        provider,
        surface: 'profile',
      );
      if (!mounted) return;
      if (signedIn) {
        ref.invalidate(playUserProfileProvider);
        ref.invalidate(playRecentGamesProvider);
      } else {
        setState(
          () => _signInError = 'Sign-in did not finish. Please try again.',
        );
      }
    } catch (error, stackTrace) {
      ErrorReporter.report(error, stackTrace: stackTrace, tag: 'auth.profile');
      if (mounted) {
        setState(() => _signInError = desktopSignInErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busyProvider = null);
    }
  }

  void _showPlay(_PlayView view) => setState(() {
    _section = _ProfileSection.play;
    _playView = view;
  });

  void _showRating(RatedTimeControl tc) => setState(() {
    _section = _ProfileSection.play;
    _playView = _PlayView.overview;
    _chartTc = tc;
  });

  @override
  Widget build(BuildContext context) {
    final isPermanent = ref.watch(desktopAccountIdentityProvider).isPermanent;
    final profileAsync = ref.watch(playUserProfileProvider);
    final achievements = ref.watch(playAchievementsProvider);
    final gamesAsync = ref.watch(playRecentGamesProvider);
    return FTheme(
      data: FThemes.zinc.dark,
      child: ColoredBox(
        color: kBackgroundColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!isPermanent)
              DesktopProfileSignIn(
                busyProvider: _busyProvider,
                error: _signInError,
                onSignIn: _signIn,
              ),
            Expanded(
              child: profileAsync.when(
                loading: () => const _Loading(),
                error:
                    (e, _) => _ErrorState(
                      message: 'Profile could not load: $e',
                      onRetry: () => ref.invalidate(playUserProfileProvider),
                    ),
                data: (profile) {
                  final games =
                      gamesAsync.valueOrNull ?? const <PlayGameRecord>[];
                  final chartTc = _chartTc ?? profile.headlineTimeControl;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _kGutter,
                          16,
                          _kGutter,
                          0,
                        ),
                        child: _IdentityHeader(
                          profile: profile,
                          achievements: achievements,
                          playTabId: widget.playTabId,
                          selectedTc:
                              _section == _ProfileSection.play &&
                                      _playView == _PlayView.overview
                                  ? chartTc
                                  : null,
                          onRatingTap: _showRating,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _kGutter,
                        ),
                        child: _SectionBar(
                          section: _section,
                          onChanged: (s) => setState(() => _section = s),
                          playView: _playView,
                          onPlayViewChanged: _showPlay,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: PersistentIndexedStack(
                          index: _section.index,
                          sizing: StackFit.expand,
                          children: [
                            _PlayStatsSection(
                              profile: profile,
                              achievements: achievements,
                              games: games,
                              historyLoading: gamesAsync.isLoading,
                              historyError:
                                  gamesAsync.hasError
                                      ? '${gamesAsync.error}'
                                      : null,
                              view: _playView,
                              chartTc: chartTc,
                              onChartTc: (tc) => setState(() => _chartTc = tc),
                              onViewChanged: _showPlay,
                            ),
                            _PrepSection(
                              hostTabId: widget.hostTabId ?? widget.playTabId,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Identity header: one band with who you are, your level and your four
// ratings. Content starts right under it.
// ---------------------------------------------------------------------------

class _IdentityHeader extends ConsumerStatefulWidget {
  const _IdentityHeader({
    required this.profile,
    required this.achievements,
    required this.playTabId,
    required this.selectedTc,
    required this.onRatingTap,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final String? playTabId;

  /// The ladder the Stats chart shows, when the chart is on screen.
  final RatedTimeControl? selectedTc;
  final ValueChanged<RatedTimeControl> onRatingTap;

  @override
  ConsumerState<_IdentityHeader> createState() => _IdentityHeaderState();
}

class _IdentityHeaderState extends ConsumerState<_IdentityHeader> {
  late final TextEditingController _name;
  // Focused explicitly when Edit opens: `autofocus` lost to the pane's own
  // keyboard-scroll focus, so typing went nowhere.
  final FocusNode _nameFocus = FocusNode(debugLabel: 'play-profile-name');
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.profile.displayName);
  }

  @override
  void didUpdateWidget(covariant _IdentityHeader old) {
    super.didUpdateWidget(old);
    if (!_editing &&
        old.profile.displayName != widget.profile.displayName &&
        _name.text != widget.profile.displayName) {
      _name.text = widget.profile.displayName;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _startEditing() {
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _nameFocus.requestFocus();
    });
  }

  void _cancel() {
    setState(() {
      _name.text = widget.profile.displayName;
      _editing = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final trimmed = _name.text.trim();
    final next = widget.profile.copyWith(
      displayName: trimmed.isEmpty ? 'ChessEver Player' : trimmed,
    );
    await ref.read(playProfileRepositoryProvider).saveProfile(next);
    ref.invalidate(playUserProfileProvider);
    if (mounted) {
      setState(() {
        _saving = false;
        _editing = false;
      });
    }
  }

  void _play() {
    final playTabId = widget.playTabId;
    if (playTabId == null) {
      ref.read(playPaneTabProvider.notifier).state = PlayPaneTab.single;
    } else {
      ref.read(playPaneTabByTabIdProvider(playTabId).notifier).state =
          PlayPaneTab.single;
    }
    ref.read(desktopTabsProvider.notifier).open(TabKind.play);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final isPermanent = ref.watch(desktopAccountIdentityProvider).isPermanent;
    final displayName =
        !isPermanent && p.displayName == 'ChessEver Player'
            ? 'Guest player'
            : p.displayName;
    final level = widget.achievements.level;
    final joined = p.createdAt;
    final meta = [
      'Level ${level.level} ${level.title}',
      if (!isPermanent) 'Guest profile',
      if (joined != null) 'Joined ${_formatDate(joined)}',
    ].join(' · ');

    final identity = Row(
      children: [
        DesktopUserAvatar(size: 44, displayName: displayName, borderRadius: 12),
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_editing)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: FTextField(
                    controller: _name,
                    focusNode: _nameFocus,
                    hint: 'Display name',
                    autofocus: true,
                    inputFormatters: [LengthLimitingTextInputFormatter(42)],
                    onSubmit: (_) => _saving ? null : _save(),
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    DesktopTooltip(
                      message: 'Edit name',
                      child: _Hoverable(
                        onTap: _startEditing,
                        builder:
                            (hovered) => Padding(
                              padding: const EdgeInsets.all(5),
                              child: _FadingIcon(
                                Icons.edit_outlined,
                                size: 14,
                                color:
                                    hovered ? kWhiteColor : kSecondaryTextColor,
                              ),
                            ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 3),
              Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final actions =
        _editing
            ? <Widget>[
              FButton(
                style: playSecondaryActionButtonStyle(),
                onPress: _saving ? null : _cancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FButton(
                style: playPrimaryActionButtonStyle(),
                prefix: const Icon(Icons.save_outlined, size: 16),
                onPress: _saving ? null : _save,
                child: Text(_saving ? 'Saving...' : 'Save'),
              ),
            ]
            : <Widget>[
              FButton(
                style: playPrimaryActionButtonStyle(),
                prefix: const Icon(Icons.play_arrow_rounded, size: 16),
                onPress: _play,
                child: const Text('Play'),
              ),
            ];

    return LayoutBuilder(
      builder: (context, c) {
        final showRatings = c.maxWidth >= 760;
        // A floor, not a fixed height: the name field while editing is
        // taller than the name, and must not shave the line under it.
        return ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Row(
            children: [
              Expanded(child: identity),
              if (showRatings) ...[
                const SizedBox(width: 16),
                for (final tc in _kTimeControls)
                  _HeaderRating(
                    timeControl: tc,
                    stats: p.statsFor(tc),
                    selected: widget.selectedTc == tc,
                    onTap: () => widget.onRatingTap(tc),
                  ),
              ],
              const SizedBox(width: 16),
              ...actions,
            ],
          ),
        );
      },
    );
  }
}

/// One ladder in the header: clock name over the rating. Provisional
/// ratings carry a "?". Clicking opens that ladder's chart.
class _HeaderRating extends StatelessWidget {
  const _HeaderRating({
    required this.timeControl,
    required this.stats,
    required this.selected,
    required this.onTap,
  });

  final RatedTimeControl timeControl;
  final PlayRatingStats stats;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final played = stats.gamesPlayed > 0;
    return DesktopTooltip(
      message:
          played
              ? '${timeControl.displayName}: ${stats.gamesPlayed} rated '
                  '${stats.gamesPlayed == 1 ? 'game' : 'games'}, '
                  'peak ${stats.peak}'
                  '${stats.isProvisional ? '. Provisional while the rating settles.' : ''}'
              : 'No rated ${timeControl.displayName.toLowerCase()} games yet',
      child: _Hoverable(
        onTap: onTap,
        builder:
            (hovered) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              width: 78,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color:
                    selected
                        ? kBlack2Color
                        : hovered
                        ? kBlack2Color.withValues(alpha: 0.6)
                        : kBlack2Color.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeControl.displayName,
                    style: TextStyle(
                      color: selected ? kWhiteColor70 : kSecondaryTextColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stats.displayRating,
                    style: TextStyle(
                      color:
                          !played
                              ? kSecondaryTextColor
                              : selected || hovered
                              ? kWhiteColor
                              : kWhiteColor70,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section bar: Stats | Prep, with the current section's own links.
// ---------------------------------------------------------------------------

class _SectionBar extends ConsumerWidget {
  const _SectionBar({
    required this.section,
    required this.onChanged,
    required this.playView,
    required this.onPlayViewChanged,
  });

  final _ProfileSection section;
  final ValueChanged<_ProfileSection> onChanged;
  final _PlayView playView;
  final ValueChanged<_PlayView> onPlayViewChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linkedId = ref.watch(myPrepPlayerIdIfPresentProvider);
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          DesktopSegmentedTabs<_ProfileSection>(
            selected: section,
            onChanged: onChanged,
            tabs: const [
              DesktopSegmentedTab(
                value: _ProfileSection.play,
                label: 'Stats',
                icon: Icons.insights_outlined,
              ),
              DesktopSegmentedTab(
                value: _ProfileSection.prep,
                label: 'Prep',
                icon: Icons.person_search_outlined,
              ),
            ],
          ),
          const SizedBox(width: 18),
          if (section == _ProfileSection.play)
            for (final v in _PlayView.values)
              _ViewLink(
                label: v.label,
                selected: v == playView,
                onTap: () => onPlayViewChanged(v),
              ),
          const Spacer(),
          if (section == _ProfileSection.prep && linkedId != null)
            _QuietButton(
              label: 'Use another prep profile',
              icon: Icons.swap_horiz_rounded,
              onTap:
                  () => unawaited(
                    ref.read(myPrepPlayerIdProvider.notifier).unlink(),
                  ),
            ),
        ],
      ),
    );
  }
}

/// A text action that brightens on hover. No fill, no outline, no motion.
class _QuietButton extends StatelessWidget {
  const _QuietButton({required this.label, required this.onTap, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: onTap,
      builder: (hovered) {
        final color = hovered ? kWhiteColor : kSecondaryTextColor;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Click target that reports hover to its [builder].
class _Hoverable extends StatefulWidget {
  const _Hoverable({required this.builder, this.onTap});

  final Widget Function(bool hovered) builder;
  final VoidCallback? onTap;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    final enabled = onTap != null;
    // Focusable so Tab reaches it and Enter/Space activate it; only the
    // activate intent is claimed, so shell shortcuts pass straight through.
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: widget.builder(enabled && (_hovered || _focused)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Prep section
// ---------------------------------------------------------------------------

class _PrepSection extends ConsumerWidget {
  const _PrepSection({required this.hostTabId});

  final String? hostTabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pointer = ref.watch(myPrepPlayerIdProvider);
    final workspaceLoading = ref.watch(
      playerWorkspaceProvider.select((state) => state.isLoading),
    );
    final linkedId = ref.watch(myPrepPlayerIdIfPresentProvider);
    if (pointer.isLoading ||
        (workspaceLoading && pointer.valueOrNull != null)) {
      return const _Loading();
    }
    if (linkedId != null) {
      return PlayerWorkspacePane(
        key: ValueKey('my-prep-$linkedId'),
        pinnedPlayerId: linkedId,
        hostTabId: hostTabId,
      );
    }
    return const _PrepSetup();
  }
}

/// Makes [playerId] the user's own prep profile. A previous own profile that
/// was emptied of every source (no accounts, so no files either) is removed
/// rather than left behind as a nameless orphan in Players.
Future<void> _linkOwnPrepProfile(WidgetRef ref, String playerId) async {
  // Everything is read before the first await: linking swaps this setup
  // for the pinned profile, which unmounts the widget that owns [ref].
  final previous = ref.read(myPrepPlayerIdProvider).valueOrNull;
  final pointer = ref.read(myPrepPlayerIdProvider.notifier);
  final workspace = ref.read(playerWorkspaceProvider.notifier);
  PlayerWorkspacePlayer? old;
  for (final player in ref.read(playerWorkspaceProvider).players) {
    if (player.id == previous) old = player;
  }
  await pointer.link(playerId);
  if (previous == null || previous == playerId) return;
  if (old == null || old.allAccounts.isNotEmpty) return;
  await workspace.removePlayer(previous);
}

/// Shown until the user has a prep profile of their own. Mirrors the phone
/// app's My Prep > Games: attach the usernames you play under and the
/// profile is built from them, or adopt a profile already built in Players.
class _PrepSetup extends ConsumerWidget {
  const _PrepSetup();

  Future<void> _attach(
    BuildContext context,
    WidgetRef ref, [
    PlayerWorkspaceSource? source,
  ]) {
    return showAttachOwnUsernamesFlow(
      context,
      ref,
      source: source,
      onCreated: (playerId) => unawaited(_linkOwnPrepProfile(ref, playerId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only profiles that still hold a source can be "me": an emptied shell
    // (every account detached) would just pin a stranger's name again.
    final players = ref
        .watch(playerWorkspaceProvider.select((state) => state.players))
        .where((player) => player.allAccounts.isNotEmpty)
        .toList(growable: false);
    return LayoutBuilder(
      builder:
          (context, constraints) => ScrollEdgeArrows(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(_kGutter, 32, _kGutter, 32),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 64).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Center(child: _setupColumn(context, ref, players)),
              ),
            ),
          ),
    );
  }

  Widget _setupColumn(
    BuildContext context,
    WidgetRef ref,
    List<PlayerWorkspacePlayer> players,
  ) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final source in kOwnPrepSources) ...[
                  _SourceMarkButton(
                    source: source,
                    onTap: () => unawaited(_attach(context, ref, source)),
                  ),
                  if (source != kOwnPrepSources.last) const SizedBox(width: 6),
                ],
              ],
            ),
            const SizedBox(height: 18),
            const Text(
              'Attach your own usernames',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Add your Lichess and Chess.com accounts here. Their games stay '
              'together. You can also attach your ChessEver player record.',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            IntrinsicWidth(
              child: FButton(
                style: playPrimaryActionButtonStyle(),
                prefix: const Icon(Icons.person_add_alt_1_outlined, size: 16),
                onPress: () => unawaited(_attach(context, ref)),
                child: const Text('Attach your username'),
              ),
            ),
            if (players.isNotEmpty) ...[
              const SizedBox(height: 36),
              const Text('Already in Players? Pick yourself', style: _kHeading),
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: _surface(),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    children: [
                      for (final player in players)
                        _PrepProfileChoice(
                          player: player,
                          onTap:
                              () => unawaited(
                                _linkOwnPrepProfile(ref, player.id),
                              ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A label whose colour fades on the shared 120 ms hover curve, so the
/// hover tint moves with the fill beside it instead of snapping. The weight
/// is applied as given (it only changes on selection, a click).
class _FadingLabel extends StatelessWidget {
  const _FadingLabel(
    this.label, {
    required this.color,
    required this.fontSize,
    required this.fontWeight,
  });

  final String label;
  final Color color;
  final double fontSize;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      builder:
          (context, value, _) => Text(
            label,
            style: TextStyle(
              color: value,
              fontSize: fontSize,
              fontWeight: fontWeight,
            ),
          ),
    );
  }
}

/// An [Icon] whose colour fades with the surrounding hover fill.
class _FadingIcon extends StatelessWidget {
  const _FadingIcon(this.icon, {required this.size, required this.color});

  final IconData icon;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: color),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      builder: (context, value, _) => Icon(icon, size: size, color: value),
    );
  }
}

/// One source's mark in the Prep empty state; clicking it opens the attach
/// flow straight at that source, skipping the source choice.
class _SourceMarkButton extends StatelessWidget {
  const _SourceMarkButton({required this.source, required this.onTap});

  final PlayerWorkspaceSource source;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: 'Attach ${source.label}',
      child: _Hoverable(
        onTap: onTap,
        builder:
            (hovered) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: hovered ? kBlack3Color : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: PlayerSourceMark(source: source, size: 32),
            ),
      ),
    );
  }
}

class _PrepProfileChoice extends StatelessWidget {
  const _PrepProfileChoice({required this.player, required this.onTap});

  final PlayerWorkspacePlayer player;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sources = <String>{
      for (final account in player.allAccounts)
        if (account.isConnected) account.source.label,
    };
    final detail = [
      '${player.totalGames} games',
      if (sources.isNotEmpty) sources.join(', '),
    ].join(' · ');
    return _Hoverable(
      onTap: onTap,
      builder:
          (hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                _ChoiceAvatar(player: player),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        player.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _kMuted,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'This is me',
                  style: TextStyle(
                    color: hovered ? kPrimaryColor : kSecondaryTextColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
    );
  }
}

/// The profile's photo, or its initials on a plain raised circle.
class _ChoiceAvatar extends StatelessWidget {
  const _ChoiceAvatar({required this.player});

  static const double _size = 32;

  final PlayerWorkspacePlayer player;

  @override
  Widget build(BuildContext context) {
    final initials = Center(
      child: Text(
        _initials(player.displayName),
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
    final url = player.bestAvatarUrl;
    return ClipOval(
      child: SizedBox.square(
        dimension: _size,
        child: ColoredBox(
          color: kBlack3Color,
          child:
              url == null
                  ? initials
                  : Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => initials,
                  ),
        ),
      ),
    );
  }
}

String _initials(String name) {
  final parts =
      name
          .replaceAll(',', ' ')
          .split(RegExp(r'\s+'))
          .where((part) => part.isNotEmpty)
          .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
}

// ---------------------------------------------------------------------------
// Play stats section
// ---------------------------------------------------------------------------

class _PlayStatsSection extends ConsumerWidget {
  const _PlayStatsSection({
    required this.profile,
    required this.achievements,
    required this.games,
    required this.historyLoading,
    required this.view,
    required this.chartTc,
    required this.onChartTc,
    required this.onViewChanged,
    this.historyError,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final List<PlayGameRecord> games;
  final bool historyLoading;
  final String? historyError;
  final _PlayView view;
  final RatedTimeControl chartTc;
  final ValueChanged<RatedTimeControl> onChartTc;
  final ValueChanged<_PlayView> onViewChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> claim(List<PlayAchievementId> ids) async {
      await ref.read(playAchievementsProvider.notifier).claimAchievements(ids);
      ref.invalidate(playUserProfileProvider);
    }

    Future<void> claimAll() async {
      await ref.read(playAchievementsProvider.notifier).claimAllPending();
      ref.invalidate(playUserProfileProvider);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kGutter),
      child: PersistentIndexedStack(
        index: view.index,
        sizing: StackFit.expand,
        children: [
          _PlayOverview(
            profile: profile,
            achievements: achievements,
            games: games,
            chartTc: chartTc,
            onChartTc: onChartTc,
            onShowGames: () => onViewChanged(_PlayView.games),
            onShowAchievements: () => onViewChanged(_PlayView.achievements),
          ),
          _GamesBody(
            games: games,
            loading: historyLoading,
            error: historyError,
          ),
          PlayBadgeCabinet(
            state: achievements,
            onClaim: claim,
            onClaimAll: claimAll,
          ),
        ],
      ),
    );
  }
}

/// Secondary navigation inside Stats: plain words, the current one in
/// full white.
class _ViewLink extends StatelessWidget {
  const _ViewLink({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: selected ? null : onTap,
      builder:
          (hovered) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: _FadingLabel(
              label,
              color:
                  selected
                      ? kWhiteColor
                      : hovered
                      ? kWhiteColor70
                      : kSecondaryTextColor,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
    );
  }
}

/// A panel: one tonal step above the page, a plain heading, its content.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: _surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 22,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _kHeading,
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Two panels side by side on wide panes, stacked on narrow ones. Side by
/// side they share one height so their bottoms line up.
class _PanelPair extends StatelessWidget {
  const _PanelPair({
    required this.left,
    required this.right,
    this.leftFlex = 1,
    this.rightFlex = 1,
    this.breakpoint = 900,
  });

  /// Built with `true` when the pair sits side by side.
  final Widget Function(bool sideBySide) left;
  final Widget Function(bool sideBySide) right;
  final int leftFlex;
  final int rightFlex;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [left(false), const SizedBox(height: 12), right(false)],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: leftFlex, child: left(true)),
              const SizedBox(width: 12),
              Expanded(flex: rightFlex, child: right(true)),
            ],
          ),
        );
      },
    );
  }
}

class _PlayOverview extends StatelessWidget {
  const _PlayOverview({
    required this.profile,
    required this.achievements,
    required this.games,
    required this.chartTc,
    required this.onChartTc,
    required this.onShowGames,
    required this.onShowAchievements,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final List<PlayGameRecord> games;
  final RatedTimeControl chartTc;
  final ValueChanged<RatedTimeControl> onChartTc;
  final VoidCallback onShowGames;
  final VoidCallback onShowAchievements;

  @override
  Widget build(BuildContext context) {
    final summary = PlayStatsSummary.from(games);
    // Both colour panels hold the same number of rows so they line up.
    final openingRows = [
      summary.whiteOpenings.length,
      summary.blackOpenings.length,
    ].reduce((a, b) => a > b ? a : b).clamp(1, 6);
    return ScrollEdgeArrows(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelPair(
              leftFlex: 3,
              rightFlex: 2,
              left:
                  (_) => _RatingPanel(
                    profile: profile,
                    timeControl: chartTc,
                    onTimeControl: onChartTc,
                  ),
              right:
                  (sideBySide) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Hoverable(
                        onTap: onShowAchievements,
                        builder:
                            (hovered) => AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              curve: Curves.easeOut,
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                14,
                                16,
                                14,
                              ),
                              decoration: BoxDecoration(
                                color: hovered ? kBlack3Color : kBlack2Color,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: PlayLevelPanel(
                                state: achievements,
                                compact: true,
                              ),
                            ),
                      ),
                      const SizedBox(height: 12),
                      if (sideBySide)
                        Expanded(child: _RecordPanel(summary: summary))
                      else
                        _RecordPanel(summary: summary),
                    ],
                  ),
            ),
            const SizedBox(height: 12),
            _PanelPair(
              left:
                  (_) => _OpeningsPanel(
                    title: 'Openings as White',
                    record: summary.asWhite,
                    openings: summary.whiteOpenings,
                    rows: openingRows,
                  ),
              right:
                  (_) => _OpeningsPanel(
                    title: 'Openings as Black',
                    record: summary.asBlack,
                    openings: summary.blackOpenings,
                    rows: openingRows,
                  ),
            ),
            const SizedBox(height: 12),
            _PanelPair(
              leftFlex: 3,
              rightFlex: 2,
              left:
                  (_) => _Panel(
                    title: 'Score by bot strength',
                    trailing:
                        summary.performance == null
                            ? null
                            : Text(
                              'Performance ${summary.performance}',
                              style: _kMuted,
                            ),
                    child: PlayStrengthChart(
                      bands: summary.bands,
                      yourRating: profile.ratingFor(
                        profile.headlineTimeControl,
                      ),
                    ),
                  ),
              right:
                  (_) => _HighlightsPanel(summary: summary, profile: profile),
            ),
            const SizedBox(height: 12),
            _PanelPair(
              leftFlex: 2,
              rightFlex: 3,
              breakpoint: 1000,
              left: (_) => _ClockPanel(summary: summary, profile: profile),
              right:
                  (_) => _Panel(
                    title: 'Activity',
                    trailing: Text(
                      '${summary.activity.values.fold<int>(0, (a, b) => a + b)} '
                      'games in 15 weeks',
                      style: _kMuted,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: PlayActivityGrid(activity: summary.activity),
                    ),
                  ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Text('Latest games', style: _kHeading),
                const Spacer(),
                if (games.isNotEmpty)
                  _QuietButton(label: 'See all', onTap: onShowGames),
              ],
            ),
            const SizedBox(height: 8),
            _GameList(games: games.take(6).toList(growable: false)),
          ],
        ),
      ),
    );
  }
}

class _RatingPanel extends ConsumerWidget {
  const _RatingPanel({
    required this.profile,
    required this.timeControl,
    required this.onTimeControl,
  });

  final PlayUserProfile profile;
  final RatedTimeControl timeControl;
  final ValueChanged<RatedTimeControl> onTimeControl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = profile.statsFor(timeControl);
    final history =
        ref.watch(playRatingHistoryProvider(timeControl)).valueOrNull ??
        const <PlayRatingPoint>[];
    final rd = stats.ratingDeviation.round();
    final last30 = history.where(
      (p) => DateTime.now().difference(p.playedAt).inDays < 30,
    );
    final month = last30.fold<int>(0, (sum, p) => sum + p.delta);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
      decoration: _surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (final tc in _kTimeControls)
                _FilterChip(
                  label: tc.displayName,
                  selected: tc == timeControl,
                  onTap: () => onTimeControl(tc),
                ),
              const Spacer(),
              DesktopTooltip(
                message:
                    'Rated with Glicko-2, like Lichess. The rating is about '
                    '95% likely to sit within ±${rd * 2} of the number shown.'
                    ' It is provisional (marked ?) until that range narrows.',
                child: Text('±${rd * 2}', style: _kMuted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                stats.displayRating,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  letterSpacing: 0.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 14),
              if (last30.isNotEmpty)
                Text(
                  '${month >= 0 ? '+' : ''}$month in 30 days',
                  style: TextStyle(
                    color: month > 0 ? kPrimaryColor : kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              const Spacer(),
              Text(
                stats.gamesPlayed == 0
                    ? 'No games yet'
                    : 'Peak ${stats.peak} · ${stats.gamesPlayed} '
                        '${stats.gamesPlayed == 1 ? 'game' : 'games'}',
                style: _kMuted,
              ),
            ],
          ),
          const SizedBox(height: 14),
          PlayRatingTimeline(
            points: history,
            height: 196,
            emptyLabel:
                'Finish a rated ${timeControl.displayName.toLowerCase()} '
                'game to start this chart.',
          ),
        ],
      ),
    );
  }
}

class _RecordPanel extends StatelessWidget {
  const _RecordPanel({required this.summary});

  final PlayStatsSummary summary;

  @override
  Widget build(BuildContext context) {
    final r = summary.overall;
    final current = summary.current;
    final streak =
        current == null || current.length < 2
            ? null
            : switch (current.kind) {
              PlayStreakKind.win => '${current.length} wins in a row',
              PlayStreakKind.draw => '${current.length} draws in a row',
              PlayStreakKind.loss => '${current.length} losses in a row',
            };
    return _Panel(
      title: 'Record',
      trailing: Text(
        r.games == 0 ? 'No games yet' : '${r.scorePct}% score',
        style: _kMuted,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _RecordFigure(label: 'Won', value: r.wins)),
              Expanded(child: _RecordFigure(label: 'Drawn', value: r.draws)),
              Expanded(child: _RecordFigure(label: 'Lost', value: r.losses)),
            ],
          ),
          const SizedBox(height: 14),
          PlayWdlBar(record: r),
          const SizedBox(height: 14),
          Row(
            children: [
              const Text('Form', style: _kMuted),
              const SizedBox(width: 10),
              Expanded(child: PlayFormStrip(form: summary.form, cell: 12)),
            ],
          ),
          if (streak != null) ...[
            const SizedBox(height: 8),
            Text(
              'On a run: $streak',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecordFigure extends StatelessWidget {
  const _RecordFigure({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 24,
            fontWeight: FontWeight.w900,
            fontFeatures: [FontFeature.tabularFigures()],
            height: 1.05,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: _kMuted),
      ],
    );
  }
}

class _OpeningsPanel extends StatelessWidget {
  const _OpeningsPanel({
    required this.title,
    required this.record,
    required this.openings,
    required this.rows,
  });

  final int rows;
  final String title;
  final PlayWdl record;
  final List<PlayOpeningStat> openings;

  @override
  Widget build(BuildContext context) {
    final shown = openings.take(rows).toList();
    return _Panel(
      title: title,
      trailing: Text(
        record.games == 0
            ? 'No games'
            : '${record.games} games · ${record.scorePct}%',
        style: _kMuted,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.isEmpty)
            const SizedBox(
              height: 40,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Openings show up here after your first game with this colour.',
                  style: _kMuted,
                ),
              ),
            ),
          // Fixed rows, so the two colour panels line up row for row.
          for (var i = 0; i < rows; i++)
            if (i < shown.length)
              _OpeningRow(stat: shown[i])
            else if (shown.isNotEmpty)
              const SizedBox(height: _OpeningRow.height),
        ],
      ),
    );
  }
}

class _OpeningRow extends StatelessWidget {
  const _OpeningRow({required this.stat});

  static const double height = 30;

  final PlayOpeningStat stat;

  @override
  Widget build(BuildContext context) {
    final r = stat.record;
    return DesktopTooltip(
      message:
          '${stat.name}${stat.eco == null ? '' : ' (${stat.eco})'}: '
          '${r.wins} won, ${r.draws} drawn, ${r.losses} lost',
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: Text(
                stat.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 26,
              child: Text(
                '${r.games}',
                textAlign: TextAlign.right,
                style: _kMuted,
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(width: 96, child: PlayWdlBar(record: r, height: 5)),
            const SizedBox(width: 10),
            SizedBox(
              width: 44,
              child: Text(
                '${r.scorePct}%',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HighlightsPanel extends StatelessWidget {
  const _HighlightsPanel({required this.summary, required this.profile});

  final PlayStatsSummary summary;
  final PlayUserProfile profile;

  @override
  Widget build(BuildContext context) {
    final best = summary.strongestWin;
    String opponentOf(PlayGameRecord g) =>
        g.humanColor == 'white' ? g.blackName : g.whiteName;
    return _Panel(
      title: 'Highlights',
      child: Column(
        children: [
          _Fact(
            label: 'Strongest win',
            value: best == null ? 'Not yet' : '${best.opponentElo}',
            detail: best == null ? null : opponentOf(best),
          ),
          _Fact(label: 'Best win streak', value: '${summary.bestWinStreak}'),
          _Fact(
            label: 'Longest unbeaten run',
            value: '${summary.bestUnbeaten}',
          ),
          _Fact(
            label: 'Average opponent',
            value: summary.averageOpponent?.toString() ?? 'None yet',
          ),
          _Fact(
            label: 'Average game',
            value:
                summary.averageMoves == 0
                    ? 'None yet'
                    : '${summary.averageMoves} moves',
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              detail ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: _kMuted,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ClockPanel extends StatelessWidget {
  const _ClockPanel({required this.summary, required this.profile});

  final PlayStatsSummary summary;
  final PlayUserProfile profile;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'By clock',
      child: Column(
        children: [
          for (final tc in _kTimeControls)
            Builder(
              builder: (context) {
                final r = summary.byTimeControl[tc] ?? const PlayWdl();
                return SizedBox(
                  height: 30,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 70,
                        child: Text(
                          tc.displayName,
                          style: const TextStyle(
                            color: kWhiteColor70,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 54,
                        child: Text(
                          profile.statsFor(tc).displayRating,
                          style: _kMuted,
                        ),
                      ),
                      Expanded(child: PlayWdlBar(record: r, height: 5)),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 64,
                        child: Text(
                          r.games == 0
                              ? 'No games'
                              : '${r.games} · ${r.scorePct}%',
                          textAlign: TextAlign.right,
                          style: _kMuted,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime d) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Filter toggle: the chosen one sits on a raised step in white, the rest
/// are plain grey words.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: onTap,
      builder:
          (hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color:
                  selected ? kBlack3Color : kBlack3Color.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(6),
            ),
            child: _FadingLabel(
              label,
              color:
                  selected
                      ? kWhiteColor
                      : hovered
                      ? kWhiteColor70
                      : kSecondaryTextColor,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
    );
  }
}

// ---------------------------------------------------------------------------
// Games tab -- filter + sort + list.
// ---------------------------------------------------------------------------

enum _GameResultFilter { all, wins, losses, draws }

extension on _GameResultFilter {
  String get label {
    switch (this) {
      case _GameResultFilter.all:
        return 'All';
      case _GameResultFilter.wins:
        return 'Wins';
      case _GameResultFilter.losses:
        return 'Losses';
      case _GameResultFilter.draws:
        return 'Draws';
    }
  }
}

enum _GameSort { newest, oldest, longest, shortest }

extension on _GameSort {
  String get label {
    switch (this) {
      case _GameSort.newest:
        return 'Newest';
      case _GameSort.oldest:
        return 'Oldest';
      case _GameSort.longest:
        return 'Longest';
      case _GameSort.shortest:
        return 'Shortest';
    }
  }
}

enum _SourceFilter { all, single, fromHere, tournament }

extension on _SourceFilter {
  String get label {
    switch (this) {
      case _SourceFilter.all:
        return 'Any source';
      case _SourceFilter.single:
        return 'Single';
      case _SourceFilter.fromHere:
        return 'From position';
      case _SourceFilter.tournament:
        return 'Tournament';
    }
  }

  bool matches(PlayGameRecord g) {
    switch (this) {
      case _SourceFilter.all:
        return true;
      case _SourceFilter.single:
        return g.source == PlayGameSource.singlePlay;
      case _SourceFilter.fromHere:
        return g.source == PlayGameSource.playFromHere;
      case _SourceFilter.tournament:
        return g.source == PlayGameSource.tournament;
    }
  }
}

class _GamesBody extends StatefulWidget {
  const _GamesBody({required this.games, required this.loading, this.error});

  final List<PlayGameRecord> games;
  final bool loading;
  final String? error;

  @override
  State<_GamesBody> createState() => _GamesBodyState();
}

class _GamesBodyState extends State<_GamesBody> {
  RatedTimeControl? _tc;
  _GameResultFilter _result = _GameResultFilter.all;
  _GameSort _sort = _GameSort.newest;
  _SourceFilter _source = _SourceFilter.all;
  Side? _color;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  RatedTimeControl? _tcOf(PlayGameRecord g) {
    final fromCat = ratedTimeControlFromString(g.timeCategory);
    if (fromCat != null) return fromCat;
    if (g.baseSeconds != null && g.baseSeconds! > 0) {
      return ratedTimeControlForSeconds(g.baseSeconds!);
    }
    return null;
  }

  bool _matchesQuery(PlayGameRecord g, String q) {
    if (q.isEmpty) return true;
    final hay =
        '${g.whiteName} ${g.blackName} '
                '${g.openingName ?? ''} ${g.eco ?? ''} '
                '${g.endReason} ${g.source.value}'
            .toLowerCase();
    return hay.contains(q);
  }

  List<PlayGameRecord> _filter() {
    final q = _search.text.trim().toLowerCase();
    Iterable<PlayGameRecord> it = widget.games;
    if (_tc != null) it = it.where((g) => _tcOf(g) == _tc);
    it = it.where(_source.matches);
    if (_color != null) {
      final wantWhite = _color == Side.white;
      it = it.where((g) => (g.humanColor == 'white') == wantWhite);
    }
    it = it.where((g) {
      switch (_result) {
        case _GameResultFilter.all:
          return true;
        case _GameResultFilter.wins:
          return g.userScore == 1;
        case _GameResultFilter.losses:
          return g.userScore == 0;
        case _GameResultFilter.draws:
          return g.userScore == 0.5;
      }
    });
    it = it.where((g) => _matchesQuery(g, q));
    final list = it.toList();
    switch (_sort) {
      case _GameSort.newest:
        list.sort((a, b) => b.playedAt.compareTo(a.playedAt));
        break;
      case _GameSort.oldest:
        list.sort((a, b) => a.playedAt.compareTo(b.playedAt));
        break;
      case _GameSort.longest:
        list.sort((a, b) => b.movesUci.length.compareTo(a.movesUci.length));
        break;
      case _GameSort.shortest:
        list.sort((a, b) => a.movesUci.length.compareTo(b.movesUci.length));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filter();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTextField(
          controller: _search,
          hint: 'Search by player, opening, ECO or source',
          onChange: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 2,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _FilterChip(
              label: 'All',
              selected: _tc == null,
              onTap: () => setState(() => _tc = null),
            ),
            for (final tc in _kTimeControls)
              _FilterChip(
                label: tc.displayName,
                selected: _tc == tc,
                onTap: () => setState(() => _tc = tc),
              ),
            const SizedBox(width: 14),
            for (final r in _GameResultFilter.values)
              _FilterChip(
                label: r.label,
                selected: r == _result,
                onTap: () => setState(() => _result = r),
              ),
            const SizedBox(width: 14),
            _FilterChip(
              label: 'Any color',
              selected: _color == null,
              onTap: () => setState(() => _color = null),
            ),
            _FilterChip(
              label: 'White',
              selected: _color == Side.white,
              onTap: () => setState(() => _color = Side.white),
            ),
            _FilterChip(
              label: 'Black',
              selected: _color == Side.black,
              onTap: () => setState(() => _color = Side.black),
            ),
            const SizedBox(width: 14),
            for (final s in _SourceFilter.values)
              _FilterChip(
                label: s.label,
                selected: s == _source,
                onTap: () => setState(() => _source = s),
              ),
            const SizedBox(width: 14),
            ..._GameSort.values.map(
              (s) => _FilterChip(
                label: s.label,
                selected: s == _sort,
                onTap: () => setState(() => _sort = s),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
          child: Text(
            widget.loading
                ? 'Loading games…'
                : '${filtered.length} of ${widget.games.length} games',
            style: const TextStyle(
              color: kSecondaryTextColor,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (widget.loading) {
                return const Center(
                  child: DesktopSpinner(color: kPrimaryColor),
                );
              }
              if (widget.error != null) {
                return Center(
                  child: Text(
                    widget.error!,
                    style: const TextStyle(color: kRedColor, fontSize: 12),
                  ),
                );
              }
              if (filtered.isEmpty) {
                return Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 26,
                    ),
                    decoration: _surface(),
                    child: const Text(
                      'No games match these filters yet.',
                      style: TextStyle(
                        color: kSecondaryTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }
              return _GameList(games: filtered, scrollable: true);
            },
          ),
        ),
      ],
    );
  }
}

class _GameList extends ConsumerWidget {
  const _GameList({required this.games, this.scrollable = false});
  final List<PlayGameRecord> games;
  final bool scrollable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (games.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: _surface(),
        child: const Center(
          child: Text(
            'No games yet. Finish a game in Play to fill this list.',
            style: TextStyle(
              color: kSecondaryTextColor,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return DesktopGameCardsFlow(
      layout: DesktopCardLayout.list,
      embedded: !scrollable,
      itemCount: games.length,
      itemBuilder: (context, i) {
        final game = games[i];
        return DesktopGameCard(
          data: _gameCardData(game),
          layout: DesktopCardLayout.list,
          allowStockfishFallback: false,
          onTap:
              () => openDetachedPgnTab(
                ref,
                label: _gameTitle(game),
                pgn: _pgnWithChesseverSource(game),
              ),
        );
      },
    );
  }
}

GameCardData _gameCardData(PlayGameRecord game) {
  final tc =
      ratedTimeControlFromString(game.timeCategory) ??
      (game.baseSeconds != null
          ? ratedTimeControlForSeconds(game.baseSeconds!)
          : null);
  final score = game.userScore;
  final resultLabel =
      score == 1
          ? 'Win'
          : score == 0
          ? 'Loss'
          : score == 0.5
          ? 'Draw'
          : game.result;
  final subtitle = [
    resultLabel,
    if (tc != null) tc.displayName,
    _formatDate(game.playedAt),
  ].join(' · ');
  return GameCardData(
    id: game.localGameKey,
    title: _gameTitle(game),
    whiteName: game.whiteName,
    blackName: game.blackName,
    whiteFederation: game.whiteCountry ?? '',
    blackFederation: game.blackCountry ?? '',
    whiteTitle: game.whiteTitle ?? '',
    blackTitle: game.blackTitle ?? '',
    whiteRating: game.whiteElo ?? 0,
    blackRating: game.blackElo ?? 0,
    fen: game.finalFen.trim().isEmpty ? game.startingFen : game.finalFen,
    lastMove: game.movesUci.isNotEmpty ? game.movesUci.last : null,
    status: _statusFromResult(game.result),
    hasStarted: game.movesUci.isNotEmpty,
    openingName:
        game.openingName?.trim().isNotEmpty == true
            ? game.openingName
            : game.eco,
    subtitle: subtitle,
  );
}

GameStatus _statusFromResult(String result) {
  switch (result.trim()) {
    case '1-0':
      return GameStatus.whiteWins;
    case '0-1':
      return GameStatus.blackWins;
    case '1/2-1/2':
    case '½-½':
      return GameStatus.draw;
    case '*':
      return GameStatus.ongoing;
    default:
      return GameStatus.unknown;
  }
}

String _gameTitle(PlayGameRecord game) {
  return '${game.whiteName} vs ${game.blackName}';
}

String _pgnWithChesseverSource(PlayGameRecord game) {
  final sourceUrl = _playGameShareUrl(game.localGameKey);
  try {
    final chessGame = ChessGame.fromPgn(game.localGameKey, game.pgn);
    final headers = Map<String, dynamic>.from(chessGame.metadata);
    _applyChesseverSourceHeaders(headers, sourceUrl);
    return exportGameToPgn(chessGame.copyWith(metadata: headers));
  } catch (_) {
    return game.pgn;
  }
}

String _playGameShareUrl(String key) => 'https://chessever.com/games/$key';

void _applyChesseverSourceHeaders(
  Map<String, dynamic> headers,
  String sourceUrl,
) {
  headers['Site'] = sourceUrl;
  headers['Source'] = sourceUrl;
  headers['ChessEverSourceUrl'] = sourceUrl;
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: DesktopSpinner(color: kPrimaryColor));
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: _surface(),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: kRedColor, fontSize: 12),
              ),
            ),
            FButton(
              style: playSecondaryActionButtonStyle(),
              prefix: const Icon(Icons.refresh_rounded),
              onPress: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
