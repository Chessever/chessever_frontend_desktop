import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/models/player_workspace_models.dart';
import 'package:chessever/desktop/panes/play_pane.dart'
    show PlayPaneTab, playPaneTabByTabIdProvider, playPaneTabProvider;
import 'package:chessever/desktop/panes/player_workspace_pane.dart'
    show PlayerWorkspacePane, showCreatePrepProfileDialog;
import 'package:chessever/desktop/services/auth/desktop_guest_upgrade.dart';
import 'package:chessever/desktop/services/error_reporter.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/play_elo.dart';
import 'package:chessever/desktop/services/play/play_game_analysis.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/my_prep_profile.dart';
import 'package:chessever/desktop/state/player_workspace.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/desktop_profile_sign_in.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/desktop/widgets/game_card_data.dart';
import 'package:chessever/desktop/widgets/play_achievement_badge.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/play_rating_chart.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart'
    show GameStatus;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/png_asset.dart';
import 'package:chessever/widgets/persistent_tab_state.dart';

/// The profile's two halves: the user's own prep profile (primary) and the
/// stats of the games they played against the bots.
enum _ProfileSection { prep, play }

/// Views inside Play stats.
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

String _assetFor(RatedTimeControl tc) {
  switch (tc) {
    case RatedTimeControl.classical:
      return PngAsset.classicalIcon;
    case RatedTimeControl.rapid:
      return PngAsset.rapidIcon;
    case RatedTimeControl.blitz:
      return PngAsset.blitzIcon;
    case RatedTimeControl.bullet:
      return PngAsset.bulletIcon;
  }
}

/// The time-control marks are full-colour art; the profile shows them in
/// greyscale so teal stays the page's only accent.
const ColorFilter _kGreyscale = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

class _TcMark extends StatelessWidget {
  const _TcMark(this.tc, {this.dim = false});

  static const double size = 14;

  final RatedTimeControl tc;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return Opacity(
      opacity: dim ? 0.55 : 0.9,
      child: ColorFiltered(
        colorFilter: _kGreyscale,
        child: Image.asset(
          _assetFor(tc),
          width: size,
          height: size,
          fit: BoxFit.contain,
          cacheWidth: px,
          cacheHeight: px,
        ),
      ),
    );
  }
}

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
  _ProfileSection _section = _ProfileSection.prep;
  _PlayView _playView = _PlayView.overview;
  RatedTimeControl? _ratingsTc;
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
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _kGutter,
                          22,
                          _kGutter,
                          0,
                        ),
                        child: _IdentityHeader(
                          profile: profile,
                          playTabId: widget.playTabId,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _kGutter,
                        ),
                        child: _SectionBar(
                          section: _section,
                          onChanged: (s) => setState(() => _section = s),
                        ),
                      ),
                      Expanded(
                        child: PersistentIndexedStack(
                          index: _section.index,
                          sizing: StackFit.expand,
                          children: [
                            _PrepSection(
                              hostTabId: widget.hostTabId ?? widget.playTabId,
                            ),
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
                              ratingsTc:
                                  _ratingsTc ?? profile.headlineTimeControl,
                              onViewChanged: _showPlay,
                              onRatingsTcChanged:
                                  (tc) => setState(() => _ratingsTc = tc),
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
// Identity header
// ---------------------------------------------------------------------------

class _IdentityHeader extends ConsumerStatefulWidget {
  const _IdentityHeader({required this.profile, required this.playTabId});

  final PlayUserProfile profile;
  final String? playTabId;

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
    final joined = p.createdAt;
    final meta = [
      isPermanent ? 'ChessEver player' : 'Guest profile',
      if (joined != null) 'joined ${_formatDate(joined)}',
    ].join(' · ');
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
                style: playSecondaryActionButtonStyle(),
                prefix: const Icon(Icons.edit_outlined, size: 16),
                onPress: _startEditing,
                child: const Text('Edit'),
              ),
              const SizedBox(width: 8),
              FButton(
                style: playPrimaryActionButtonStyle(),
                prefix: const Icon(Icons.play_arrow_rounded, size: 16),
                onPress: _play,
                child: const Text('Play'),
              ),
            ];
    return Row(
      children: [
        DesktopUserAvatar(size: 56, displayName: displayName, borderRadius: 14),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_editing)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: FTextField(
                    controller: _name,
                    focusNode: _nameFocus,
                    hint: 'Display name',
                    autofocus: true,
                    inputFormatters: [LengthLimitingTextInputFormatter(42)],
                  ),
                )
              else
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
                ),
              const SizedBox(height: 5),
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
        const SizedBox(width: 16),
        ...actions,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Section bar: Prep | Play stats, plus the prep profile's own action.
// ---------------------------------------------------------------------------

class _SectionBar extends ConsumerWidget {
  const _SectionBar({required this.section, required this.onChanged});

  final _ProfileSection section;
  final ValueChanged<_ProfileSection> onChanged;

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
                value: _ProfileSection.prep,
                label: 'Prep',
                icon: Icons.person_search_outlined,
              ),
              DesktopSegmentedTab(
                value: _ProfileSection.play,
                label: 'Play stats',
                icon: Icons.insights_outlined,
              ),
            ],
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

/// Shown until the user has a prep profile of their own: create one, or
/// adopt a profile already built in Players.
class _PrepSetup extends ConsumerWidget {
  const _PrepSetup();

  Future<void> _create(BuildContext context, WidgetRef ref) {
    return showCreatePrepProfileDialog(
      context,
      ref,
      title: 'Your prep profile',
      onCreated:
          (playerId) => unawaited(
            ref.read(myPrepPlayerIdProvider.notifier).link(playerId),
          ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final players = ref.watch(
      playerWorkspaceProvider.select((state) => state.players),
    );
    return LayoutBuilder(
      builder:
          (context, constraints) => SingleChildScrollView(
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
            const Text(
              'Prepare against yourself',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Connect the Lichess, Chess.com or FIDE identity you play '
              'under. Your openings, results and repertoire are built here '
              'the same way you prep an opponent.',
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
                onPress: () => unawaited(_create(context, ref)),
                child: const Text('Create my prep profile'),
              ),
            ),
            if (players.isNotEmpty) ...[
              const SizedBox(height: 36),
              const Text(
                'Or choose a profile you already prepared',
                style: _kHeading,
              ),
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
                                ref
                                    .read(myPrepPlayerIdProvider.notifier)
                                    .link(player.id),
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

class _PlayStatsSection extends StatelessWidget {
  const _PlayStatsSection({
    required this.profile,
    required this.achievements,
    required this.games,
    required this.historyLoading,
    required this.view,
    required this.ratingsTc,
    required this.onViewChanged,
    required this.onRatingsTcChanged,
    this.historyError,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final List<PlayGameRecord> games;
  final bool historyLoading;
  final String? historyError;
  final _PlayView view;
  final RatedTimeControl ratingsTc;
  final ValueChanged<_PlayView> onViewChanged;
  final ValueChanged<RatedTimeControl> onRatingsTcChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_kGutter - 6, 14, _kGutter, 10),
          child: Row(
            children: [
              for (final v in _PlayView.values)
                _ViewLink(
                  label: v.label,
                  selected: v == view,
                  onTap: () => onViewChanged(v),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: _kGutter),
            child: PersistentIndexedStack(
              index: view.index,
              sizing: StackFit.expand,
              children: [
                _PlayOverview(
                  profile: profile,
                  achievements: achievements,
                  games: games,
                  selectedTc: ratingsTc,
                  onTcChanged: onRatingsTcChanged,
                  onShowGames: () => onViewChanged(_PlayView.games),
                  onShowAchievements:
                      () => onViewChanged(_PlayView.achievements),
                ),
                _GamesBody(
                  games: games,
                  loading: historyLoading,
                  error: historyError,
                ),
                _AchievementsBody(state: achievements),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Secondary navigation inside Play stats: plain words, the current one in
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
            child: Text(
              label,
              style: TextStyle(
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
          ),
    );
  }
}

class _PlayOverview extends StatelessWidget {
  const _PlayOverview({
    required this.profile,
    required this.achievements,
    required this.games,
    required this.selectedTc,
    required this.onTcChanged,
    required this.onShowGames,
    required this.onShowAchievements,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final List<PlayGameRecord> games;
  final RatedTimeControl selectedTc;
  final ValueChanged<RatedTimeControl> onTcChanged;
  final VoidCallback onShowGames;
  final VoidCallback onShowAchievements;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RatingLadder(
            profile: profile,
            selected: selectedTc,
            onSelected: onTcChanged,
          ),
          const SizedBox(height: 12),
          _RatingChartPanel(profile: profile, tc: selectedTc),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _RecordPanel(profile: profile)),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: _FactsPanel(
                    profile: profile,
                    achievements: achievements,
                    onShowGames: onShowGames,
                    onShowAchievements: onShowAchievements,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
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
    );
  }
}

/// The four ratings side by side on one surface. The chosen time control
/// sits on a raised step and drives the chart below.
class _RatingLadder extends StatelessWidget {
  const _RatingLadder({
    required this.profile,
    required this.selected,
    required this.onSelected,
  });

  final PlayUserProfile profile;
  final RatedTimeControl selected;
  final ValueChanged<RatedTimeControl> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: _surface(),
      child: Row(
        children: [
          for (final tc in _kTimeControls) ...[
            Expanded(
              child: _LadderCell(
                tc: tc,
                stats: profile.statsFor(tc),
                selected: tc == selected,
                onTap: () => onSelected(tc),
              ),
            ),
            if (tc != _kTimeControls.last) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _LadderCell extends StatelessWidget {
  const _LadderCell({
    required this.tc,
    required this.stats,
    required this.selected,
    required this.onTap,
  });

  final RatedTimeControl tc;
  final PlayRatingStats stats;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unplayed = stats.gamesPlayed == 0;
    return _Hoverable(
      onTap: onTap,
      builder:
          (hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kBlack3Color
                      : hovered
                      ? kBlack3Color.withValues(alpha: 0.5)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _TcMark(tc, dim: !selected),
                    const SizedBox(width: 7),
                    Text(
                      tc.displayName,
                      style: TextStyle(
                        color: selected ? kWhiteColor : kSecondaryTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${stats.rating}',
                  style: TextStyle(
                    color:
                        selected
                            ? kPrimaryColor
                            : unplayed
                            ? kWhiteColor70
                            : kWhiteColor,
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  unplayed
                      ? 'Provisional · no games'
                      : 'Peak ${stats.peak} · ${stats.gamesPlayed} '
                          '${stats.gamesPlayed == 1 ? 'game' : 'games'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _kMuted,
                ),
              ],
            ),
          ),
    );
  }
}

class _RatingChartPanel extends ConsumerStatefulWidget {
  const _RatingChartPanel({required this.profile, required this.tc});

  final PlayUserProfile profile;
  final RatedTimeControl tc;

  @override
  ConsumerState<_RatingChartPanel> createState() => _RatingChartPanelState();
}

class _RatingChartPanelState extends ConsumerState<_RatingChartPanel> {
  PlayRatingChartRange _range = PlayRatingChartRange.last90Days;

  @override
  Widget build(BuildContext context) {
    final tc = widget.tc;
    final stats = widget.profile.statsFor(tc);
    final historyAsync = ref.watch(playRatingHistoryProvider(tc));
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: _surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('${tc.displayName} rating', style: _kHeading),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${stats.wins} won · ${stats.draws} drawn · '
                  '${stats.losses} lost',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _kMuted,
                ),
              ),
              for (final range in PlayRatingChartRange.values)
                _FilterChip(
                  label: range.label,
                  selected: range == _range,
                  onTap: () => setState(() => _range = range),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 260,
            child: historyAsync.when(
              loading: () => const _Loading(),
              error:
                  (e, _) => Center(
                    child: Text(
                      '$e',
                      style: const TextStyle(color: kRedColor, fontSize: 12),
                    ),
                  ),
              data:
                  (points) => PlayRatingChart(
                    points: points,
                    accent: kPrimaryColor,
                    range: _range,
                    height: double.infinity,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordPanel extends StatelessWidget {
  const _RecordPanel({required this.profile});

  final PlayUserProfile profile;

  @override
  Widget build(BuildContext context) {
    final wins = profile.winsTotal;
    final draws = profile.drawsTotal;
    final losses = profile.lossesTotal;
    final total = wins + draws + losses;
    final winRate = total == 0 ? 0 : (100 * wins / total).round();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: _surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Record', style: _kHeading),
              const Spacer(),
              Text(
                total == 0 ? 'No games yet' : '$winRate% win rate',
                style: _kMuted,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _RecordFigure(label: 'Won', value: wins)),
              Expanded(child: _RecordFigure(label: 'Drawn', value: draws)),
              Expanded(child: _RecordFigure(label: 'Lost', value: losses)),
            ],
          ),
          const Spacer(),
          const SizedBox(height: 16),
          _RecordBar(wins: wins, draws: draws, losses: losses),
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
            fontSize: 26,
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

/// Won / drawn / lost as one rounded bar: teal for wins, two grey steps for
/// the rest.
class _RecordBar extends StatelessWidget {
  const _RecordBar({
    required this.wins,
    required this.draws,
    required this.losses,
  });

  final int wins;
  final int draws;
  final int losses;

  @override
  Widget build(BuildContext context) {
    final total = wins + draws + losses;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 6,
        child:
            total == 0
                ? const ColoredBox(color: kBlack3Color)
                : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wins > 0)
                      Expanded(
                        flex: wins,
                        child: const ColoredBox(color: kPrimaryColor),
                      ),
                    if (draws > 0)
                      Expanded(
                        flex: draws,
                        child: ColoredBox(
                          color: kWhiteColor.withValues(alpha: 0.42),
                        ),
                      ),
                    if (losses > 0)
                      Expanded(
                        flex: losses,
                        child: ColoredBox(
                          color: kWhiteColor.withValues(alpha: 0.14),
                        ),
                      ),
                  ],
                ),
      ),
    );
  }
}

class _FactsPanel extends StatelessWidget {
  const _FactsPanel({
    required this.profile,
    required this.achievements,
    required this.onShowGames,
    required this.onShowAchievements,
  });

  final PlayUserProfile profile;
  final PlayAchievementsState achievements;
  final VoidCallback onShowGames;
  final VoidCallback onShowAchievements;

  @override
  Widget build(BuildContext context) {
    var peak = 0;
    for (final tc in _kTimeControls) {
      final value = profile.statsFor(tc).peak;
      if (value > peak) peak = value;
    }
    final last = profile.lastGameAt;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      decoration: _surface(),
      child: Column(
        children: [
          _FactRow(
            label: 'Games played',
            value: '${profile.gamesPlayedTotal}',
            onTap: onShowGames,
          ),
          _FactRow(label: 'Peak rating', value: '$peak'),
          _FactRow(
            label: 'Badges',
            value:
                '${achievements.unlocked.length} of '
                '${kPlayAchievementDefinitions.length}',
            onTap: onShowAchievements,
          ),
          if (last != null)
            _FactRow(
              label: 'Last game',
              value: _formatDate(last),
              onTap: onShowGames,
            ),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      onTap: onTap,
      builder:
          (hovered) => AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: hovered ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                SizedBox(
                  width: 20,
                  child:
                      onTap == null
                          ? null
                          : Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: hovered ? kWhiteColor : kLightGreyColor,
                          ),
                ),
              ],
            ),
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? kBlack3Color : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
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

enum _GameSort { newest, oldest, highRated, lowRated, longest, shortest }

extension on _GameSort {
  String get label {
    switch (this) {
      case _GameSort.newest:
        return 'Newest';
      case _GameSort.oldest:
        return 'Oldest';
      case _GameSort.highRated:
        return 'Highest';
      case _GameSort.lowRated:
        return 'Lowest';
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
      case _GameSort.highRated:
        list.sort((a, b) => (b.ratingAfter ?? 0).compareTo(a.ratingAfter ?? 0));
        break;
      case _GameSort.lowRated:
        list.sort((a, b) => (a.ratingAfter ?? 0).compareTo(b.ratingAfter ?? 0));
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
                  child: CircularProgressIndicator(color: kPrimaryColor),
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
    if (game.ratingAfter != null) '${game.ratingAfter} rating',
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
// Achievements tab -- reuses the badge gallery + a summary hero.
// ---------------------------------------------------------------------------

class _AchievementsBody extends ConsumerWidget {
  const _AchievementsBody({required this.state});
  final PlayAchievementsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A sliver grid lays out only the cards on screen. The old shrink-wrapped
    // grid inside a scroll view laid out all of them on every width change.
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: 4),
          sliver: SliverToBoxAdapter(child: _AchievementHero(state: state)),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 340,
            mainAxisExtent: 128,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: kPlayAchievementDefinitions.length,
          itemBuilder: (context, index) {
            final def = kPlayAchievementDefinitions[index];
            final unlocked = state.unlocked.contains(def.id);
            final claimable = state.claimable.contains(def.id);
            final earned = unlocked || claimable;
            final progress = state.stats.progressFor(def.id);
            final value = (progress / def.target).clamp(0.0, 1.0);
            final card = AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: _surface(raised: claimable),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  PlayAchievementBadgeArt(
                    definition: def,
                    unlocked: earned,
                    size: 64,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                def.title,
                                style: TextStyle(
                                  color: earned ? kWhiteColor : kWhiteColor70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Text(
                              unlocked
                                  ? 'CLAIMED'
                                  : claimable
                                  ? 'CLAIM'
                                  : '${(value * 100).round()}%',
                              style: TextStyle(
                                color:
                                    claimable
                                        ? kPrimaryColor
                                        : unlocked
                                        ? kWhiteColor70
                                        : kSecondaryTextColor,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          def.description,
                          style: const TextStyle(
                            color: kSecondaryTextColor,
                            fontSize: 11,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          def.group.label,
                          style: TextStyle(
                            color: kSecondaryTextColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: value.toDouble(),
                            minHeight: 5,
                            color:
                                earned
                                    ? kPrimaryColor
                                    : kWhiteColor.withValues(alpha: 0.38),
                            backgroundColor: kBlackColor.withValues(
                              alpha: 0.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
            if (!claimable) return card;
            return _Hoverable(
              onTap: () async {
                await ref
                    .read(playAchievementsProvider.notifier)
                    .claimAchievements([def.id]);
                ref.invalidate(playUserProfileProvider);
              },
              builder: (_) => card,
            );
          },
        ),
        // Lets the last row scroll fully clear of the pane's bottom edge.
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _AchievementHero extends ConsumerWidget {
  const _AchievementHero({required this.state});
  final PlayAchievementsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final total = kPlayAchievementDefinitions.length;
    final unlocked = state.unlocked.length;
    final claimable = state.claimable.length;
    final value = total == 0 ? 0.0 : unlocked / total;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: _surface(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Achievement cabinet',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                claimable == 0
                    ? '$unlocked / $total'
                    : '$unlocked / $total · $claimable ready',
                style: const TextStyle(
                  color: kPrimaryColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 7,
              color: kPrimaryColor,
              backgroundColor: kBlack3Color,
            ),
          ),
          if (claimable > 0) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FButton(
                style: playPrimaryActionButtonStyle(),
                prefix: const Icon(Icons.inventory_2_outlined),
                onPress: () async {
                  await ref
                      .read(playAchievementsProvider.notifier)
                      .claimAllPending();
                  ref.invalidate(playUserProfileProvider);
                },
                child: const Text('Claim ready badges'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator(color: kPrimaryColor));
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
