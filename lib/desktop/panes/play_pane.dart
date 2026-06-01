import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/play_active_game.dart';
import 'package:chessever/desktop/panes/play_events_pane.dart';
import 'package:chessever/desktop/panes/play_profile_pane.dart';
import 'package:chessever/desktop/panes/play_tournaments_pane.dart';
import 'package:chessever/desktop/services/play/play_achievements.dart';
import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/services/play/play_strength.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_setup.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/play_achievement_badge.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/play_strength_control.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/audio_player_service.dart';

/// Which face of the Play pane is showing — single-game flow vs the
/// engine-tournament browser.
enum PlayPaneTab { single, tournaments, events, profile }

final playPaneTabProvider = StateProvider<PlayPaneTab>(
  (ref) => PlayPaneTab.single,
);

final playPaneTabByTabIdProvider = StateProvider.family<PlayPaneTab, String>(
  (ref, _) => PlayPaneTab.single,
);

/// Entry point for play-vs-bot sessions and the local engine tournament
/// browser.
///
/// Each Play tab owns its own session. While no game is in progress for this
/// tab, the pane shows the setup form. Pressing `Start Game` stores a
/// [PlaySessionArgs] under the tab's id in
/// [playSessionArgsByTabIdProvider], which mounts [PlayActiveGameView] for
/// that tab while leaving other Play tabs untouched. Closing the tab clears
/// the entry and auto-disposes the engine subprocess.
class PlayPane extends ConsumerWidget {
  const PlayPane({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<List<PlayAchievementId>>(
      playAchievementsProvider.select((state) => state.lastEarned),
      (previous, next) {
        if (next.isEmpty || identical(previous, next)) return;
        _showBadgeClaimOverlay(context, ref, next);
      },
    );
    final sessionArgs = ref.watch(
      playSessionArgsByTabIdProvider.select((m) => m[tabId]),
    );
    final sessionActive = sessionArgs != null;
    final showTournamentArena = sessionArgs?.tournamentContext != null;
    final tab = ref.watch(playPaneTabByTabIdProvider(tabId));
    Widget content =
        sessionActive
            ? (showTournamentArena
                ? PlayTournamentsPane(tabId: tabId)
                : PlayActiveGameView(tabId: tabId))
            : switch (tab) {
              PlayPaneTab.single => _PlaySetupScreen(tabId: tabId),
              PlayPaneTab.tournaments => PlayTournamentsPane(tabId: tabId),
              PlayPaneTab.events => const PlayEventsPane(),
              PlayPaneTab.profile => PlayProfilePane(playTabId: tabId),
            };
    if (sessionActive) {
      content = PlaySessionLifecycleListener(tabId: tabId, child: content);
    }
    return Container(
      color: kBackgroundColor,
      child: Column(
        children: [
          if (!sessionActive)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
              child: _PlayTopTabs(
                selected: tab,
                onChanged:
                    (value) =>
                        ref
                            .read(playPaneTabByTabIdProvider(tabId).notifier)
                            .state = value,
              ),
            ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _PlayTopTabs extends StatelessWidget {
  const _PlayTopTabs({required this.selected, required this.onChanged});

  final PlayPaneTab selected;
  final ValueChanged<PlayPaneTab> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.sports_esports_rounded,
          size: 18,
          color: kPrimaryColor,
        ),
        const SizedBox(width: 10),
        const Text(
          'Play',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
        const Spacer(),
        DesktopSegmentedTabs<PlayPaneTab>(
          selected: selected,
          onChanged: onChanged,
          tabs: const [
            DesktopSegmentedTab(
              value: PlayPaneTab.single,
              label: 'Single game',
              icon: Icons.sports_esports_outlined,
            ),
            DesktopSegmentedTab(
              value: PlayPaneTab.tournaments,
              label: 'Tournaments',
              icon: Icons.emoji_events_outlined,
            ),
            DesktopSegmentedTab(
              value: PlayPaneTab.events,
              label: 'Events',
              icon: Icons.event_available_outlined,
            ),
            DesktopSegmentedTab(
              value: PlayPaneTab.profile,
              label: 'Profile',
              icon: Icons.military_tech_outlined,
            ),
          ],
        ),
      ],
    );
  }
}

void _showBadgeClaimOverlay(
  BuildContext context,
  WidgetRef ref,
  List<PlayAchievementId> earned,
) {
  AudioPlayerService.instance.playSound(SfxType.takeover);
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  var removed = false;

  Future<void> claim() async {
    if (removed) return;
    removed = true;
    await ref.read(playAchievementsProvider.notifier).claimAchievements(earned);
    ref.invalidate(playUserProfileProvider);
    entry.remove();
  }

  entry = OverlayEntry(
    builder:
        (context) => Positioned.fill(
          child: _AchievementClaimOverlay(earned: earned, onClaim: claim),
        ),
  );
  overlay.insert(entry);
}

class _AchievementClaimOverlay extends StatefulWidget {
  const _AchievementClaimOverlay({required this.earned, required this.onClaim});

  final List<PlayAchievementId> earned;
  final Future<void> Function() onClaim;

  @override
  State<_AchievementClaimOverlay> createState() =>
      _AchievementClaimOverlayState();
}

class _AchievementClaimOverlayState extends State<_AchievementClaimOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _entry = AnimationController.unbounded(
    vsync: this,
  )..animateWith(
    SpringSimulation(
      SpringDescription.withDampingRatio(mass: 1, stiffness: 240, ratio: 0.68),
      0,
      1,
      0,
    ),
  );
  late final AnimationController _effects = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();
  bool _claiming = false;

  @override
  void dispose() {
    _entry.dispose();
    _effects.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final definitions = widget.earned
        .map(achievementDefinition)
        .toList(growable: false);
    final primary = definitions.isEmpty ? null : definitions.last;
    if (primary == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: Listenable.merge([_entry, _effects]),
      builder: (context, child) {
        final t = _entry.value.clamp(0.0, 1.0);
        return Material(
          color: Colors.transparent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _claim,
            child: Stack(
              children: [
                Opacity(
                  opacity: t,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: kBlackColor.withValues(alpha: 0.78),
                    ),
                    child: CustomPaint(
                      painter: _ClaimBurstPainter(
                        accent: primary.color,
                        progress: t,
                        pulse: _effects.value,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                Center(
                  child: Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * 34),
                      child: Transform.scale(
                        scale: 0.86 + t * 0.14,
                        child: child,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: _ClaimCard(
        definitions: definitions,
        claiming: _claiming,
        onClaim: _claim,
      ),
    );
  }

  Future<void> _claim() async {
    if (_claiming) return;
    setState(() => _claiming = true);
    await widget.onClaim();
  }
}

class _ClaimCard extends StatelessWidget {
  const _ClaimCard({
    required this.definitions,
    required this.claiming,
    required this.onClaim,
  });

  final List<PlayAchievementDefinition> definitions;
  final bool claiming;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final primary = definitions.last;
    final extras = definitions.take(definitions.length - 1).toList();
    return FTheme(
      data: FThemes.zinc.dark,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: primary.color.withValues(alpha: 0.70)),
            color: kBlack2Color,
            boxShadow: [
              BoxShadow(
                color: primary.color.withValues(alpha: 0.20),
                blurRadius: 54,
                spreadRadius: 4,
              ),
              BoxShadow(
                color: kBlackColor.withValues(alpha: 0.52),
                blurRadius: 40,
                offset: const Offset(0, 24),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Badge earned',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    for (var i = 0; i < extras.take(4).length; i++)
                      Positioned(
                        left: -118 + i * 42,
                        top: i.isEven ? 14 : 40,
                        child: Opacity(
                          opacity: 0.72,
                          child: Transform.rotate(
                            angle: (i - 1.5) * 0.12,
                            child: PlayAchievementBadgeArt(
                              definition: extras[i],
                              unlocked: true,
                              size: 70,
                            ),
                          ),
                        ),
                      ),
                    Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: primary.color.withValues(alpha: 0.10),
                        border: Border.all(
                          color: primary.color.withValues(alpha: 0.36),
                        ),
                      ),
                    ),
                    PlayAchievementBadgeArt(
                      definition: primary,
                      unlocked: true,
                      size: 126,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                primary.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                definitions.length == 1
                    ? primary.description
                    : '${definitions.length} badges are ready for your cabinet.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              if (extras.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final definition in definitions)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: definition.color.withValues(alpha: 0.12),
                          border: Border.all(
                            color: definition.color.withValues(alpha: 0.42),
                          ),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          definition.title,
                          style: TextStyle(
                            color: definition.color,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 22),
              Align(
                alignment: Alignment.center,
                child: FButton(
                  style: playPrimaryActionButtonStyle(),
                  prefix: const Icon(Icons.inventory_2_outlined),
                  onPress: claiming ? null : onClaim,
                  child: Text(
                    claiming
                        ? 'Claiming...'
                        : definitions.length == 1
                        ? 'Claim to cabinet'
                        : 'Claim all to cabinet',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Tap anywhere to claim',
                textAlign: TextAlign.center,
                style: TextStyle(color: kSecondaryTextColor, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClaimBurstPainter extends CustomPainter {
  const _ClaimBurstPainter({
    required this.accent,
    required this.progress,
    required this.pulse,
  });

  final Color accent;
  final double progress;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * (0.18 + progress * 0.34);
    final rayPaint =
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = accent.withValues(alpha: 0.12 * progress);
    for (var i = 0; i < 32; i++) {
      final angle = (i / 32) * math.pi * 2 + pulse * math.pi * 0.25;
      final start = center + Offset(math.cos(angle), math.sin(angle)) * 82;
      final end =
          center +
          Offset(math.cos(angle), math.sin(angle)) *
              (radius + (i.isEven ? 36 : 12));
      canvas.drawLine(start, end, rayPaint);
    }

    final boardPaint =
        Paint()..color = kWhiteColor.withValues(alpha: 0.025 * progress);
    const square = 58.0;
    for (var y = -square; y < size.height + square; y += square) {
      for (var x = -square; x < size.width + square; x += square) {
        final file = (x / square).floor();
        final rank = (y / square).floor();
        if ((file + rank).isEven) {
          canvas.drawRect(Rect.fromLTWH(x, y, square, square), boardPaint);
        }
      }
    }

    final sparkPaint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 46; i++) {
      final seed = i * 41.0;
      final angle = (seed % 360) * math.pi / 180 + pulse * math.pi * 2;
      final distance = radius * (0.42 + ((i * 17) % 100) / 120);
      final shimmer = (math.sin((pulse * math.pi * 2) + i) + 1) / 2;
      sparkPaint.color = Color.lerp(
        accent,
        kWhiteColor,
        shimmer,
      )!.withValues(alpha: (0.18 + shimmer * 0.34) * progress);
      final point =
          center + Offset(math.cos(angle), math.sin(angle)) * distance;
      canvas.drawCircle(point, 1.4 + shimmer * 2.2, sparkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ClaimBurstPainter oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.progress != progress ||
        oldDelegate.pulse != pulse;
  }
}

/// Setup form: time control, engine, engine-specific strength mode, color.
class _PlaySetupScreen extends ConsumerWidget {
  const _PlaySetupScreen({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(playSetupProvider);
    final notifier = ref.read(playSetupProvider.notifier);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The form scales: at desktop widths the two columns sit side by side,
        // at narrower windows they stack. No fixed pixel breakpoints inside
        // child panels — those let Padding/Expanded handle the rest.
        final stacked = constraints.maxWidth < 980;
        final left = _SetupColumnLeft(config: config, notifier: notifier);
        final right = _SetupColumnRight(config: config, notifier: notifier);
        final body =
            stacked
                ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [left, const SizedBox(height: 24), right],
                )
                : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: left),
                    const SizedBox(width: 28),
                    Expanded(child: right),
                  ],
                );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(40, 36, 40, 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SetupHeader(),
                const SizedBox(height: 28),
                body,
                const SizedBox(height: 32),
                _StartBar(config: config, notifier: notifier, tabId: tabId),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SetupHeader extends StatelessWidget {
  const _SetupHeader();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Play vs bot',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 30,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        SizedBox(height: 6),
        Text(
          'Pick a time control, bot, and matching strength mode. Stockfish '
          'uses exact ELO; Leela and Maia use engine-specific profiles.',
          style: TextStyle(color: kWhiteColor70, fontSize: 14, height: 1.5),
        ),
      ],
    );
  }
}

class _SetupColumnLeft extends StatelessWidget {
  const _SetupColumnLeft({required this.config, required this.notifier});

  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return _SetupCard(
      title: 'Time control',
      child: _TimeControlSection(config: config, notifier: notifier),
    );
  }
}

class _SetupColumnRight extends StatelessWidget {
  const _SetupColumnRight({required this.config, required this.notifier});

  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetupCard(
          title: 'Bot',
          child: _EngineSection(config: config, notifier: notifier),
        ),
        const SizedBox(height: 18),
        _SetupCard(
          title: 'Color',
          child: _ColorSection(config: config, notifier: notifier),
        ),
      ],
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _TimeControlSection extends StatelessWidget {
  const _TimeControlSection({required this.config, required this.notifier});

  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopSegmentedTabs<TimeControlCategory>(
          tabs: const [
            DesktopSegmentedTab(
              value: TimeControlCategory.bullet,
              label: 'Bullet',
              icon: Icons.bolt_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.blitz,
              label: 'Blitz',
              icon: Icons.flash_on_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.rapid,
              label: 'Rapid',
              icon: Icons.timer_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.classical,
              label: 'Classical',
              icon: Icons.hourglass_bottom_outlined,
            ),
            DesktopSegmentedTab(
              value: TimeControlCategory.custom,
              label: 'Custom',
              icon: Icons.tune_outlined,
            ),
          ],
          selected: config.category,
          onChanged: (cat) {
            if (cat == TimeControlCategory.custom) {
              notifier.setCustomTime(
                baseSeconds: config.baseSeconds,
                incrementSeconds: config.incrementSeconds,
              );
            } else {
              final presets = kTimeControlPresets[cat]!;
              notifier.applyPreset(presets.first);
            }
          },
          expand: true,
          wrap: true,
        ),
        const SizedBox(height: 16),
        if (config.category == TimeControlCategory.custom)
          _CustomTimeEditor(config: config, notifier: notifier)
        else
          _PresetGrid(
            category: config.category,
            config: config,
            notifier: notifier,
          ),
      ],
    );
  }
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({
    required this.category,
    required this.config,
    required this.notifier,
  });

  final TimeControlCategory category;
  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final presets = kTimeControlPresets[category] ?? const [];
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final p in presets)
          _PresetChip(
            preset: p,
            selected:
                config.category == p.category &&
                config.baseSeconds == p.baseSeconds &&
                config.incrementSeconds == p.incrementSeconds,
            onTap: () => notifier.applyPreset(p),
          ),
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final TimeControlPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton(
        style: _playChoiceButtonStyle(
          selected: selected,
          radius: 8,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          fontSize: 14,
          tabularFigures: true,
        ),
        mainAxisSize: MainAxisSize.min,
        onPress: onTap,
        child: Text(preset.shorthand),
      ),
    );
  }
}

class _CustomTimeEditor extends StatelessWidget {
  const _CustomTimeEditor({required this.config, required this.notifier});

  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final h = config.baseSeconds ~/ 3600;
    final m = (config.baseSeconds % 3600) ~/ 60;
    final s = config.baseSeconds % 60;
    return Row(
      children: [
        Expanded(
          child: _NumberField(
            label: 'Hours',
            value: h,
            min: 0,
            max: 6,
            onChanged:
                (v) => notifier.setCustomTime(
                  baseSeconds: v * 3600 + m * 60 + s,
                  incrementSeconds: config.incrementSeconds,
                ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _NumberField(
            label: 'Minutes',
            value: m,
            min: 0,
            max: 59,
            onChanged:
                (v) => notifier.setCustomTime(
                  baseSeconds: h * 3600 + v * 60 + s,
                  incrementSeconds: config.incrementSeconds,
                ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _NumberField(
            label: 'Seconds',
            value: s,
            min: 0,
            max: 59,
            onChanged:
                (v) => notifier.setCustomTime(
                  baseSeconds: h * 3600 + m * 60 + v,
                  incrementSeconds: config.incrementSeconds,
                ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: _NumberField(
            label: 'Increment (s)',
            value: config.incrementSeconds,
            min: 0,
            max: 180,
            onChanged:
                (v) => notifier.setCustomTime(
                  baseSeconds: config.baseSeconds,
                  incrementSeconds: v,
                ),
          ),
        ),
      ],
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value.toString(),
  );

  @override
  void didUpdateWidget(covariant _NumberField old) {
    super.didUpdateWidget(old);
    final current = int.tryParse(_controller.text);
    if (current != widget.value) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            color: kSecondaryTextColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: kBlack3Color,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(color: kDividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(color: kDividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(7),
              borderSide: const BorderSide(color: kPrimaryColor),
            ),
          ),
          onChanged: (raw) {
            final n = int.tryParse(raw);
            if (n == null) return;
            widget.onChanged(n.clamp(widget.min, widget.max));
          },
        ),
      ],
    );
  }
}

class _EngineSection extends StatelessWidget {
  const _EngineSection({required this.config, required this.notifier});

  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final engine in BotEngineKind.values) ...[
          _EngineRow(
            engine: engine,
            selected: config.engine == engine,
            onTap: () => notifier.setEngine(engine),
          ),
          if (engine != BotEngineKind.values.last) const SizedBox(height: 8),
        ],
        const SizedBox(height: 18),
        PlayStrengthControl(
          engine: config.engine,
          value: config.elo,
          onChanged: notifier.setElo,
        ),
      ],
    );
  }
}

class _EngineRow extends ConsumerWidget {
  const _EngineRow({
    required this.engine,
    required this.selected,
    required this.onTap,
  });

  final BotEngineKind engine;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = ref.watch(engineInstallProvider(engine));
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton.raw(
        style: _playChoiceButtonStyle(
          selected: selected,
          radius: 8,
          padding: EdgeInsets.zero,
        ),
        onPress: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected ? kPrimaryColor : kSubtleIconColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      engine.displayName,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      engine.tagline,
                      style: const TextStyle(
                        color: kSecondaryTextColor,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _EngineInstallBadge(
                install: install,
                onInstall:
                    () =>
                        ref
                            .read(engineInstallProvider(engine).notifier)
                            .install(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Live bot readiness badge for the Play setup screen.
class _EngineInstallBadge extends StatelessWidget {
  const _EngineInstallBadge({required this.install, required this.onInstall});

  final EngineInstallState install;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color, tappable) = switch (install.status) {
      EngineInstallStatus.installed => (
        Icons.check_circle_outline,
        'Ready',
        kGreenColor,
        false,
      ),
      EngineInstallStatus.downloading => (
        Icons.downloading_outlined,
        describeEngineState(install),
        kPrimaryColor,
        false,
      ),
      EngineInstallStatus.verifying => (
        Icons.verified_outlined,
        'Checking…',
        kPrimaryColor,
        false,
      ),
      EngineInstallStatus.failed => (
        Icons.error_outline,
        'Try again',
        kRedColor,
        true,
      ),
      EngineInstallStatus.notInstalled => (
        Icons.download_outlined,
        'Prepare',
        kWhiteColor,
        true,
      ),
      EngineInstallStatus.unsupported => (
        Icons.block_outlined,
        'Unavailable',
        kLightGreyColor,
        false,
      ),
    };
    return FTheme(
      data: FThemes.zinc.dark,
      child: FButton(
        style: _playBadgeButtonStyle(color: color),
        onPress: tappable ? onInstall : null,
        mainAxisSize: MainAxisSize.min,
        prefix: Icon(icon),
        child: Text(label),
      ),
    );
  }
}

class _ColorSection extends StatelessWidget {
  const _ColorSection({required this.config, required this.notifier});

  final PlayConfig config;
  final PlaySetupNotifier notifier;

  @override
  Widget build(BuildContext context) {
    return DesktopSegmentedTabs<PlayColorChoice>(
      tabs: const [
        DesktopSegmentedTab(
          value: PlayColorChoice.white,
          label: 'White',
          icon: Icons.brightness_high_outlined,
        ),
        DesktopSegmentedTab(
          value: PlayColorChoice.random,
          label: 'Random',
          icon: Icons.shuffle_outlined,
        ),
        DesktopSegmentedTab(
          value: PlayColorChoice.black,
          label: 'Black',
          icon: Icons.brightness_2_outlined,
        ),
      ],
      selected: config.color,
      onChanged: notifier.setColor,
      expand: true,
    );
  }
}

class _StartBar extends ConsumerWidget {
  const _StartBar({
    required this.config,
    required this.notifier,
    required this.tabId,
  });

  final PlayConfig config;
  final PlaySetupNotifier notifier;
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final install = ref.watch(engineInstallProvider(config.engine));
    final canStart = engineReady(install);
    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        decoration: BoxDecoration(
          color: kBlack2Color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kDividerColor),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${config.engine.displayName} • '
                    '${playStrengthStartSummary(config.engine, config.elo)} • '
                    '${config.timeControlShorthand} '
                    '(${config.category.displayName})',
                    style: const TextStyle(
                      color: kWhiteColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Playing as ${config.color.displayName}'
                    '${config.hasStartingPositionSeed ? ' • from position' : ''}',
                    style: const TextStyle(
                      color: kSecondaryTextColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            FButton(
              style: playPrimaryActionButtonStyle(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
              ),
              prefix: const Icon(Icons.play_arrow_rounded),
              onPress:
                  canStart
                      ? () =>
                          _startGame(ref, config, install.binaryPath!, tabId)
                      : null,
              child: Text(canStart ? 'Play now' : 'Prepare bot first'),
            ),
          ],
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _playChoiceButtonStyle({
  required bool selected,
  required double radius,
  required EdgeInsetsGeometry padding,
  double fontSize = 12,
  bool tabularFigures = false,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _playChoiceDecoration(selected: selected, radius: radius),
      contentStyle:
          (content) => content.copyWith(
            padding: padding,
            spacing: 7,
            textStyle: _playChoiceTextStyle(
              selected: selected,
              fontSize: fontSize,
              tabularFigures: tabularFigures,
            ),
            iconStyle: _playChoiceIconStyle(selected: selected),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _playBadgeButtonStyle({
  required Color color,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.72)),
          borderRadius: BorderRadius.circular(999),
        ),
        WidgetState.disabled: BoxDecoration(
          color: kBlack2Color,
          border: Border.all(color: color.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(999),
        ),
        WidgetState.any: BoxDecoration(
          color: kBlack2Color,
          border: Border.all(color: color.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(999),
        ),
      }),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            spacing: 5,
            textStyle: FWidgetStateMap({
              WidgetState.any: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            }),
            iconStyle: FWidgetStateMap({
              WidgetState.any: IconThemeData(color: color, size: 13),
            }),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _playChoiceDecoration({
  required bool selected,
  required double radius,
}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.18) : kBlack3Color,
      border: Border.all(
        color: selected ? kPrimaryColor : kWhiteColor.withValues(alpha: 0.16),
        width: selected ? 1.5 : 1,
      ),
      borderRadius: BorderRadius.circular(radius),
    ),
    WidgetState.any: BoxDecoration(
      color: selected ? kPrimaryColor.withValues(alpha: 0.12) : kBlack3Color,
      border: Border.all(
        color: selected ? kPrimaryColor : kDividerColor,
        width: selected ? 1.5 : 1,
      ),
      borderRadius: BorderRadius.circular(radius),
    ),
  });
}

FWidgetStateMap<TextStyle> _playChoiceTextStyle({
  required bool selected,
  required double fontSize,
  required bool tabularFigures,
}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: selected ? kPrimaryColor : kWhiteColor,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
      fontFeatures:
          tabularFigures ? const [FontFeature.tabularFigures()] : null,
    ),
    WidgetState.any: TextStyle(
      color: selected ? kPrimaryColor : kWhiteColor,
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
      fontFeatures:
          tabularFigures ? const [FontFeature.tabularFigures()] : null,
    ),
  });
}

FWidgetStateMap<IconThemeData> _playChoiceIconStyle({required bool selected}) {
  return FWidgetStateMap({
    WidgetState.hovered | WidgetState.pressed: IconThemeData(
      color: selected ? kPrimaryColor : kWhiteColor,
      size: 15,
    ),
    WidgetState.any: IconThemeData(
      color: selected ? kPrimaryColor : kLightGreyColor,
      size: 15,
    ),
  });
}

void _startGame(
  WidgetRef ref,
  PlayConfig config,
  String binaryPath,
  String tabId,
) {
  // Generate a fresh bot persona for this session — same seed produces the
  // same person if you replay, but each Start spawns a new one.
  final identity = BotIdentityGenerator().next(elo: config.elo);
  final args = PlaySessionArgs(
    config: config,
    engineBinaryPath: binaryPath,
    botIdentity: identity,
  );
  ref
      .read(playSessionArgsByTabIdProvider.notifier)
      .update((m) => <String, PlaySessionArgs>{...m, tabId: args});
  ref.read(playSetupProvider.notifier).clearStartingSeed();
}
