import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/bot_identity.dart';
import 'package:chessever/desktop/services/play/engine_installer.dart';
import 'package:chessever/desktop/services/play/play_models.dart';
import 'package:chessever/desktop/services/play/play_strength.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/play_session.dart';
import 'package:chessever/desktop/state/play_setup.dart';
import 'package:chessever/desktop/widgets/desktop_segmented_tabs.dart';
import 'package:chessever/desktop/widgets/play_forui_styles.dart';
import 'package:chessever/desktop/widgets/play_strength_control.dart';
import 'package:chessever/theme/app_theme.dart';

/// Seed payload for "Play from here" — passed in via the helper below.
@immutable
class PlayFromHereSeed {
  const PlayFromHereSeed({
    required this.fen,
    this.startingFen,
    this.movesUci = const <String>[],
    this.inheritedWhiteBaseSeconds,
    this.inheritedWhiteIncrementSeconds,
    this.inheritedBlackBaseSeconds,
    this.inheritedBlackIncrementSeconds,
  });

  /// The position to continue from.
  final String fen;

  /// Root position for [movesUci]. When null, [fen] itself is used as the
  /// session root and notation starts empty.
  final String? startingFen;

  /// Moves from [startingFen] to [fen], used to prefill notation in the new
  /// Play tab.
  final List<String> movesUci;

  /// Per-side clocks for the new game. When the user opens the dialog from a
  /// live game these come from that game's remaining clocks so the experience
  /// is continuous; when there is no live game (analysis, opening explorer)
  /// these stay null and the dialog falls back to setup defaults.
  final int? inheritedWhiteBaseSeconds;
  final int? inheritedWhiteIncrementSeconds;
  final int? inheritedBlackBaseSeconds;
  final int? inheritedBlackIncrementSeconds;
}

/// Picks the default human color for "Play from here".
///
/// The selected bot owns the side-to-move by default so confirming the dialog
/// produces an immediate engine move from the board the user chose. The user
/// can still switch sides before starting.
PlayColorChoice defaultPlayFromHereHumanColor(String fen) {
  final fields = fen.trim().split(RegExp(r'\s+'));
  if (fields.length >= 2) {
    if (fields[1] == 'w') return PlayColorChoice.black;
    if (fields[1] == 'b') return PlayColorChoice.white;
  }
  return PlayColorChoice.white;
}

/// Opens the "Play from here" mini-dialog, then — if the user confirms —
/// starts a new Play tab with the chosen config when the bot is ready.
Future<void> showPlayFromHereDialog(
  BuildContext context,
  WidgetRef ref, {
  required PlayFromHereSeed seed,
}) async {
  final result = await showFDialog<_PlayFromHereDecision>(
    context: context,
    builder:
        (ctx, _, animation) =>
            _PlayFromHereDialog(seed: seed, animation: animation),
  );
  if (result == null) return;

  final tabId = ref
      .read(desktopTabsProvider.notifier)
      .open(TabKind.play, reuseExisting: false);
  final elo = normalizePlayStrength(result.engine, result.elo);
  final symmetricBase = result.whiteBaseSeconds == result.blackBaseSeconds;
  final symmetricInc =
      result.whiteIncrementSeconds == result.blackIncrementSeconds;
  final config = PlayConfig.defaults.copyWith(
    engine: result.engine,
    elo: elo,
    category: TimeControlCategory.custom,
    baseSeconds: result.whiteBaseSeconds,
    incrementSeconds: result.whiteIncrementSeconds,
    blackBaseSeconds: symmetricBase ? null : result.blackBaseSeconds,
    blackIncrementSeconds: symmetricInc ? null : result.blackIncrementSeconds,
    clearBlackBaseSeconds: symmetricBase,
    clearBlackIncrementSeconds: symmetricInc,
    color: result.color,
    startingFen: seed.startingFen ?? seed.fen,
    startingMovesUci: List<String>.unmodifiable(seed.movesUci),
    // Game must feel live the moment the user lands on the board. Without
    // this, the clocks sit frozen until the first move is played, which
    // looks broken when the user came from a live position.
    startClockImmediately: true,
  );

  final binaryPath = engineBinaryPathFor(ref, result.engine);
  if (binaryPath != null) {
    final identity = BotIdentityGenerator().next(elo: config.elo);
    ref
        .read(playSessionArgsByTabIdProvider.notifier)
        .update(
          (m) => <String, PlaySessionArgs>{
            ...m,
            tabId: PlaySessionArgs(
              config: config,
              engineBinaryPath: binaryPath,
              botIdentity: identity,
            ),
          },
        );
    ref.read(playSetupProvider.notifier).clearStartingSeed();
    return;
  }

  // If the selected bot is not prepared yet, preserve the previous behavior:
  // open the setup form seeded from this board so the user can install it.
  // The setup pane only supports symmetric clocks, so we seed it with White's
  // values and rely on the dialog to re-apply per-side overrides next time.
  final setup = ref.read(playSetupProvider.notifier);
  setup.seedFromFen(
    seed.fen,
    startingFen: seed.startingFen,
    startingMovesUci: seed.movesUci,
  );
  setup.setCustomTime(
    baseSeconds: result.whiteBaseSeconds,
    incrementSeconds: result.whiteIncrementSeconds,
  );
  setup.setEngine(result.engine);
  setup.setElo(result.elo);
  setup.setColor(result.color);
}

/// Rehydrate the config the user just finished playing (from PGN headers
/// stamped onto the finished-game Board pane) and launch a fresh Play tab.
/// When the engine is still ready, the new session starts immediately; when
/// it isn't, the setup form is pre-filled so the user can Prepare and start.
void startPlayAgainFromBoardHeaders(
  WidgetRef ref,
  Map<String, String> headers,
) {
  final kindName = headers['ChessEverEngineKind'];
  if (kindName == null || kindName.isEmpty) return;
  final engine = BotEngineKind.values.firstWhere(
    (k) => k.name == kindName,
    orElse: () => BotEngineKind.stockfish,
  );
  final elo = normalizePlayStrength(
    engine,
    int.tryParse(headers['ChessEverEngineElo'] ?? '') ?? 1500,
  );
  final baseSeconds =
      int.tryParse(headers['ChessEverBaseSeconds'] ?? '') ??
      PlayConfig.defaults.baseSeconds;
  final incrementSeconds =
      int.tryParse(headers['ChessEverIncSeconds'] ?? '') ??
      PlayConfig.defaults.incrementSeconds;
  final categoryName = headers['ChessEverCategory'];
  final category = TimeControlCategory.values.firstWhere(
    (c) => c.name == categoryName,
    orElse: () => TimeControlCategory.custom,
  );
  final humanColor = switch (headers['ChessEverHumanColor']) {
    'white' => PlayColorChoice.white,
    'black' => PlayColorChoice.black,
    _ => PlayColorChoice.random,
  };
  final startingFen = headers['ChessEverStartingFen'];

  final tabId = ref
      .read(desktopTabsProvider.notifier)
      .open(TabKind.play, reuseExisting: false);

  final config = PlayConfig.defaults.copyWith(
    engine: engine,
    elo: elo,
    category: category,
    baseSeconds: baseSeconds,
    incrementSeconds: incrementSeconds,
    color: humanColor,
    startingFen: startingFen,
    clearStartingFen: startingFen == null,
    clearStartingMoves: true,
  );

  final binaryPath = engineBinaryPathFor(ref, engine);
  if (binaryPath != null) {
    final identity = BotIdentityGenerator().next(elo: config.elo);
    ref
        .read(playSessionArgsByTabIdProvider.notifier)
        .update(
          (m) => <String, PlaySessionArgs>{
            ...m,
            tabId: PlaySessionArgs(
              config: config,
              engineBinaryPath: binaryPath,
              botIdentity: identity,
            ),
          },
        );
    ref.read(playSetupProvider.notifier).clearStartingSeed();
    return;
  }

  final setup = ref.read(playSetupProvider.notifier);
  if (startingFen != null) {
    setup.seedFromFen(startingFen, startingFen: startingFen);
  } else {
    setup.clearStartingSeed();
  }
  if (category == TimeControlCategory.custom) {
    setup.setCustomTime(
      baseSeconds: baseSeconds,
      incrementSeconds: incrementSeconds,
    );
  } else {
    setup.applyPreset(
      TimeControlPreset(
        category: category,
        baseSeconds: baseSeconds,
        incrementSeconds: incrementSeconds,
      ),
    );
  }
  setup.setEngine(engine);
  setup.setElo(elo);
  setup.setColor(humanColor);
}

@immutable
class _PlayFromHereDecision {
  const _PlayFromHereDecision({
    required this.engine,
    required this.elo,
    required this.color,
    required this.whiteBaseSeconds,
    required this.whiteIncrementSeconds,
    required this.blackBaseSeconds,
    required this.blackIncrementSeconds,
  });
  final BotEngineKind engine;
  final int elo;
  final PlayColorChoice color;
  final int whiteBaseSeconds;
  final int whiteIncrementSeconds;
  final int blackBaseSeconds;
  final int blackIncrementSeconds;
}

@visibleForTesting
({
  int whiteBaseSeconds,
  int whiteIncrementSeconds,
  int blackBaseSeconds,
  int blackIncrementSeconds,
  bool mirror,
  bool inherited,
})
initialPlayFromHereClockDraft(PlayFromHereSeed seed) {
  final whiteBase =
      seed.inheritedWhiteBaseSeconds ?? PlayConfig.defaults.baseSeconds;
  final whiteInc =
      seed.inheritedWhiteIncrementSeconds ??
      PlayConfig.defaults.incrementSeconds;
  final blackBase =
      seed.inheritedBlackBaseSeconds ?? PlayConfig.defaults.baseSeconds;
  final blackInc =
      seed.inheritedBlackIncrementSeconds ??
      PlayConfig.defaults.incrementSeconds;
  return (
    whiteBaseSeconds: whiteBase,
    whiteIncrementSeconds: whiteInc,
    blackBaseSeconds: blackBase,
    blackIncrementSeconds: blackInc,
    mirror: whiteBase == blackBase && whiteInc == blackInc,
    inherited:
        seed.inheritedWhiteBaseSeconds != null ||
        seed.inheritedBlackBaseSeconds != null,
  );
}

class _PlayFromHereDialog extends ConsumerStatefulWidget {
  const _PlayFromHereDialog({required this.seed, required this.animation});

  final PlayFromHereSeed seed;
  final Animation<double> animation;

  @override
  ConsumerState<_PlayFromHereDialog> createState() =>
      _PlayFromHereDialogState();
}

class _PlayFromHereDialogState extends ConsumerState<_PlayFromHereDialog> {
  BotEngineKind _engine = BotEngineKind.stockfish;
  int _elo = 1500;
  late PlayColorChoice _color = defaultPlayFromHereHumanColor(widget.seed.fen);

  late final _clockDraft = initialPlayFromHereClockDraft(widget.seed);

  // Per-side clock fields. When [_mirror] is on, editing one side also updates
  // the other. Inherited live clocks usually differ after play has begun, so
  // the dialog only mirrors when the two seeded sides are actually equal.
  late int _whiteBase = _clockDraft.whiteBaseSeconds;
  late int _whiteInc = _clockDraft.whiteIncrementSeconds;
  late int _blackBase = _clockDraft.blackBaseSeconds;
  late int _blackInc = _clockDraft.blackIncrementSeconds;
  late bool _mirror = _clockDraft.mirror;

  bool get _inheritedClockAvailable => _clockDraft.inherited;

  void _setWhiteBase(int v) {
    setState(() {
      _whiteBase = v;
      if (_mirror) _blackBase = v;
    });
  }

  void _setWhiteInc(int v) {
    setState(() {
      _whiteInc = v;
      if (_mirror) _blackInc = v;
    });
  }

  void _setBlackBase(int v) {
    setState(() {
      _blackBase = v;
      if (_mirror) _whiteBase = v;
    });
  }

  void _setBlackInc(int v) {
    setState(() {
      _blackInc = v;
      if (_mirror) _whiteInc = v;
    });
  }

  void _toggleMirror(bool v) {
    setState(() {
      _mirror = v;
      if (v) {
        // When re-enabling mirror, snap Black to White so the two sides match.
        _blackBase = _whiteBase;
        _blackInc = _whiteInc;
      }
    });
  }

  void _applyPreset(int baseSeconds, int inc) {
    setState(() {
      _whiteBase = baseSeconds;
      _whiteInc = inc;
      _blackBase = baseSeconds;
      _blackInc = inc;
      _mirror = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final install = ref.watch(engineInstallProvider(_engine));
    return FDialog.raw(
      animation: widget.animation,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _DialogHeader(),
              const SizedBox(height: 16),
              _EngineDropdown(
                value: _engine,
                onChanged:
                    (v) => setState(() {
                      _engine = v;
                      _elo = normalizePlayStrength(v, _elo);
                    }),
              ),
              const SizedBox(height: 14),
              PlayStrengthControl(
                engine: _engine,
                value: _elo,
                onChanged:
                    (v) => setState(
                      () => _elo = normalizePlayStrength(_engine, v),
                    ),
                compact: true,
              ),
              const SizedBox(height: 14),
              _ColorField(
                value: _color,
                onChanged: (v) => setState(() => _color = v),
              ),
              const SizedBox(height: 16),
              _ClockSection(
                whiteBase: _whiteBase,
                whiteInc: _whiteInc,
                blackBase: _blackBase,
                blackInc: _blackInc,
                mirror: _mirror,
                inherited: _inheritedClockAvailable,
                onWhiteBaseChanged: _setWhiteBase,
                onWhiteIncChanged: _setWhiteInc,
                onBlackBaseChanged: _setBlackBase,
                onBlackIncChanged: _setBlackInc,
                onMirrorChanged: _toggleMirror,
                onPreset: _applyPreset,
              ),
              const SizedBox(height: 18),
              _EngineHint(install: install),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FButton(
                      style: playSecondaryActionButtonStyle(),
                      prefix: const Icon(Icons.close_rounded),
                      onPress: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      style: playPrimaryActionButtonStyle(),
                      prefix: const Icon(Icons.play_arrow_rounded),
                      onPress:
                          () => Navigator.of(context).pop(
                            _PlayFromHereDecision(
                              engine: _engine,
                              elo: _elo,
                              color: _color,
                              whiteBaseSeconds: _whiteBase,
                              whiteIncrementSeconds: _whiteInc,
                              blackBaseSeconds: _blackBase,
                              blackIncrementSeconds: _blackInc,
                            ),
                          ),
                      child: Text(
                        engineReady(install) ? 'Start game' : 'Open setup',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader();
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Play from here',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Continue from the current board position against a bot. A ready bot '
          'starts immediately in a new Play tab.',
          style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }
}

class _EngineDropdown extends StatelessWidget {
  const _EngineDropdown({required this.value, required this.onChanged});

  final BotEngineKind value;
  final ValueChanged<BotEngineKind> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel('Bot'),
        const SizedBox(height: 6),
        DesktopSegmentedTabs<BotEngineKind>(
          tabs: const [
            DesktopSegmentedTab(
              value: BotEngineKind.stockfish,
              label: 'Stockfish',
              icon: Icons.memory_outlined,
            ),
            DesktopSegmentedTab(
              value: BotEngineKind.leela,
              label: 'Leela',
              icon: Icons.psychology_alt_outlined,
            ),
            DesktopSegmentedTab(
              value: BotEngineKind.maia,
              label: 'Maia',
              icon: Icons.auto_awesome_outlined,
            ),
          ],
          selected: value,
          onChanged: onChanged,
          expand: true,
        ),
      ],
    );
  }
}

class _ColorField extends StatelessWidget {
  const _ColorField({required this.value, required this.onChanged});
  final PlayColorChoice value;
  final ValueChanged<PlayColorChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel('Color'),
        const SizedBox(height: 6),
        DesktopSegmentedTabs<PlayColorChoice>(
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
          selected: value,
          onChanged: onChanged,
          expand: true,
        ),
      ],
    );
  }
}

/// Min base clock allowed (seconds). 10s matches the previous behavior.
const int _kMinBase = 10;

/// Max base clock allowed (6h). Bigger than this isn't a real game; keep the
/// UI sane and prevent overflow when multiplied by 1000.
const int _kMaxBase = 6 * 3600;

/// Max Fischer increment (3 min). Matches Lichess's hard cap.
const int _kMaxInc = 180;

String _formatBase(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}';
}

class _ClockSection extends StatelessWidget {
  const _ClockSection({
    required this.whiteBase,
    required this.whiteInc,
    required this.blackBase,
    required this.blackInc,
    required this.mirror,
    required this.inherited,
    required this.onWhiteBaseChanged,
    required this.onWhiteIncChanged,
    required this.onBlackBaseChanged,
    required this.onBlackIncChanged,
    required this.onMirrorChanged,
    required this.onPreset,
  });

  final int whiteBase;
  final int whiteInc;
  final int blackBase;
  final int blackInc;
  final bool mirror;
  final bool inherited;
  final ValueChanged<int> onWhiteBaseChanged;
  final ValueChanged<int> onWhiteIncChanged;
  final ValueChanged<int> onBlackBaseChanged;
  final ValueChanged<int> onBlackIncChanged;
  final ValueChanged<bool> onMirrorChanged;
  final void Function(int baseSeconds, int inc) onPreset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _FieldLabel('Clock'),
            const SizedBox(width: 8),
            if (inherited)
              const Text(
                'inherited from live game',
                style: TextStyle(color: kSecondaryTextColor, fontSize: 11),
              ),
            const Spacer(),
            _MirrorToggle(value: mirror, onChanged: onMirrorChanged),
          ],
        ),
        const SizedBox(height: 8),
        _ClockPresetsRow(onPick: onPreset),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SideClockCard(
                title: 'White',
                icon: Icons.brightness_high_outlined,
                baseSeconds: whiteBase,
                incrementSeconds: whiteInc,
                onBaseChanged: onWhiteBaseChanged,
                onIncChanged: onWhiteIncChanged,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SideClockCard(
                title: 'Black',
                icon: Icons.brightness_2_outlined,
                baseSeconds: blackBase,
                incrementSeconds: blackInc,
                onBaseChanged: onBlackBaseChanged,
                onIncChanged: onBlackIncChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MirrorToggle extends StatelessWidget {
  const _MirrorToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.link_rounded : Icons.link_off_rounded,
              size: 14,
              color: value ? kPrimaryColor : kSecondaryTextColor,
            ),
            const SizedBox(width: 4),
            Text(
              value ? 'Mirror sides' : 'Independent',
              style: TextStyle(
                color: value ? kPrimaryColor : kSecondaryTextColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClockPresetsRow extends StatelessWidget {
  const _ClockPresetsRow({required this.onPick});
  final void Function(int baseSeconds, int inc) onPick;

  static const _presets = <(String, int, int)>[
    ('1+0', 60, 0),
    ('3+0', 180, 0),
    ('3+2', 180, 2),
    ('5+0', 300, 0),
    ('10+0', 600, 0),
    ('15+10', 900, 10),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final p in _presets)
          InkWell(
            onTap: () => onPick(p.$2, p.$3),
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kDividerColor),
              ),
              child: Text(
                p.$1,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SideClockCard extends StatelessWidget {
  const _SideClockCard({
    required this.title,
    required this.icon,
    required this.baseSeconds,
    required this.incrementSeconds,
    required this.onBaseChanged,
    required this.onIncChanged,
  });

  final String title;
  final IconData icon;
  final int baseSeconds;
  final int incrementSeconds;
  final ValueChanged<int> onBaseChanged;
  final ValueChanged<int> onIncChanged;

  @override
  Widget build(BuildContext context) {
    final h = baseSeconds ~/ 3600;
    final m = (baseSeconds % 3600) ~/ 60;
    final s = baseSeconds % 60;

    void setHms({int? newH, int? newM, int? newS}) {
      final hh = (newH ?? h).clamp(0, 6);
      final mm = (newM ?? m).clamp(0, 59);
      final ss = (newS ?? s).clamp(0, 59);
      final total = (hh * 3600 + mm * 60 + ss).clamp(_kMinBase, _kMaxBase);
      onBaseChanged(total);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: kWhiteColor70),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                _formatBase(baseSeconds),
                style: const TextStyle(
                  color: kSecondaryTextColor,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _HmsField(
                  label: 'H',
                  value: h,
                  min: 0,
                  max: 6,
                  onChanged: (v) => setHms(newH: v),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  ':',
                  style: TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: _HmsField(
                  label: 'M',
                  value: m,
                  min: 0,
                  max: 59,
                  onChanged: (v) => setHms(newM: v),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  ':',
                  style: TextStyle(
                    color: kSecondaryTextColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: _HmsField(
                  label: 'S',
                  value: s,
                  min: 0,
                  max: 59,
                  onChanged: (v) => setHms(newS: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _HmsField(
            label: '+ increment (s)',
            value: incrementSeconds,
            min: 0,
            max: _kMaxInc,
            onChanged: onIncChanged,
            wide: true,
          ),
        ],
      ),
    );
  }
}

class _HmsField extends StatefulWidget {
  const _HmsField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.wide = false,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final bool wide;

  @override
  State<_HmsField> createState() => _HmsFieldState();
}

class _HmsFieldState extends State<_HmsField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value.toString(),
  );
  late final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void didUpdateWidget(covariant _HmsField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reflect external changes (mirror toggle, preset pick) without stomping
    // mid-edit: only re-sync the text when the field is not focused.
    if (!_focusNode.hasFocus && widget.value.toString() != _controller.text) {
      _controller.text = widget.value.toString();
    }
  }

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) _commit();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text) ?? widget.min;
    final clamped = parsed.clamp(widget.min, widget.max);
    if (clamped != widget.value) widget.onChanged(clamped);
    if (clamped.toString() != _controller.text) {
      _controller.text = clamped.toString();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
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
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(widget.wide ? 3 : 2),
          ],
          textAlign: TextAlign.center,
          onSubmitted: (_) => _commit(),
          onChanged: (_) => _commit(),
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              vertical: 9,
              horizontal: 6,
            ),
            filled: true,
            fillColor: kBlackColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: kDividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: kDividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: kPrimaryColor),
            ),
          ),
        ),
      ],
    );
  }
}

class _EngineHint extends StatelessWidget {
  const _EngineHint({required this.install});
  final EngineInstallState install;

  @override
  Widget build(BuildContext context) {
    if (engineReady(install)) {
      return Row(
        children: const [
          Icon(Icons.check_circle_outline, size: 14, color: kGreenColor),
          SizedBox(width: 6),
          Text('Bot ready', style: TextStyle(color: kGreenColor, fontSize: 12)),
        ],
      );
    }
    return Row(
      children: [
        const Icon(Icons.info_outline, size: 14, color: kSecondaryTextColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'This bot needs to be prepared first. Open setup, then choose Prepare on that bot.',
            style: const TextStyle(color: kSecondaryTextColor, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: kSecondaryTextColor,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );
  }
}
