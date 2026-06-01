import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/providers/auto_pin_preferences_provider.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/local_storage/auto_pin_preferences/auto_pin_preferences_repository.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/board_customization_utils.dart';

/// Desktop board preferences. Driven by the same providers as the mobile
/// page (`engineSettingsProviderNew`, `boardSettingsProviderNew`,
/// `autoPinPreferencesProvider`) but with desktop chrome (forui FSwitch,
/// segmented controls, inline theme/piece grids — no bottom sheets).
class BoardSettingsPane extends ConsumerWidget {
  const BoardSettingsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engineAsync = ref.watch(engineSettingsProviderNew);
    final boardAsync = ref.watch(boardSettingsProviderNew);
    final autoPinAsync = ref.watch(autoPinPreferencesProvider);

    return FTheme(
      data: FThemes.zinc.dark,
      child: Container(
        color: kBackgroundColor,
        child: _content(ref, engineAsync, boardAsync, autoPinAsync),
      ),
    );
  }

  Widget _content(
    WidgetRef ref,
    AsyncValue<EngineSettings> engineAsync,
    AsyncValue<BoardSettingsNew> boardAsync,
    AsyncValue<AutoPinPreferences> autoPinAsync,
  ) {
    final engine = engineAsync.valueOrNull;
    final board = boardAsync.valueOrNull;
    final autoPin = autoPinAsync.valueOrNull ?? AutoPinPreferences.defaults;

    if (engineAsync.isLoading || boardAsync.isLoading) {
      return const Center(child: _Loading());
    }
    if (engine == null || board == null) {
      return const Center(
        child: _ErrorMessage(
          text: 'Could not load board settings — try signing out and back in.',
        ),
      );
    }

    return _SettingsShell(
      engine: engine,
      board: board,
      autoPin: autoPin,
      ref: ref,
    );
  }
}

class _SettingsShell extends StatelessWidget {
  const _SettingsShell({
    required this.engine,
    required this.board,
    required this.autoPin,
    required this.ref,
  });

  final EngineSettings engine;
  final BoardSettingsNew board;
  final AutoPinPreferences autoPin;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 284,
          child: _SettingsSidebar(
            engine: engine,
            board: board,
            autoPin: autoPin,
          ),
        ),
        Container(width: 1, color: kDividerColor),
        Expanded(
          child: SingleChildScrollView(
            physics: const DesktopScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(28, 24, 32, 32),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final twoColumns = constraints.maxWidth >= 980;
                    if (!twoColumns) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _engineColumn(),
                          const SizedBox(height: 18),
                          _appearanceColumn(),
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: _engineColumn()),
                        const SizedBox(width: 20),
                        Expanded(flex: 4, child: _appearanceColumn()),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _engineColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EngineCard(settings: engine, ref: ref),
        const SizedBox(height: 16),
        _DisplayCard(settings: board, ref: ref),
        const SizedBox(height: 16),
        _AutoPinCard(prefs: autoPin, ref: ref),
      ],
    );
  }

  Widget _appearanceColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BoardThemeCard(currentIndex: board.boardThemeIndex, ref: ref),
        const SizedBox(height: 16),
        _PieceSetCard(
          currentIndex: board.pieceStyleIndex,
          themeIndex: board.boardThemeIndex,
          ref: ref,
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Board Settings',
          style: TextStyle(
            color: kWhiteColor,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Engine, appearance, and board workflow preferences.',
          style: TextStyle(color: kWhiteColor70, fontSize: 13),
        ),
      ],
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  const _SettingsSidebar({
    required this.engine,
    required this.board,
    required this.autoPin,
  });

  final EngineSettings engine;
  final BoardSettingsNew board;
  final AutoPinPreferences autoPin;

  @override
  Widget build(BuildContext context) {
    final theme = getBoardThemeByIndex(board.boardThemeIndex);
    final pieces = getPieceSetByIndex(board.pieceStyleIndex);
    final autoPinCount =
        [
          autoPin.favoritePlayersAutoPinEnabled,
          autoPin.countrymenAutoPinEnabled,
        ].where((enabled) => enabled).length;

    return Container(
      color: kBlack2Color.withValues(alpha: 0.72),
      padding: const EdgeInsets.fromLTRB(22, 24, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              physics: const DesktopScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Header(),
                  const SizedBox(height: 24),
                  _SidebarItem(
                    icon: Icons.memory_rounded,
                    title: 'Engine',
                    value:
                        engine.showEngineAnalysis
                            ? '${engine.principalVariationLabel()} lines · ${engine.maxArrowsLabel()} arrows'
                            : 'Off',
                    selected: true,
                  ),
                  const SizedBox(height: 8),
                  _SidebarItem(
                    icon: Icons.dashboard_customize_outlined,
                    title: 'Board',
                    value: theme.name,
                  ),
                  const SizedBox(height: 8),
                  _SidebarItem(
                    icon: Icons.style_outlined,
                    title: 'Pieces',
                    value: pieces.label,
                  ),
                  const SizedBox(height: 8),
                  _SidebarItem(
                    icon: Icons.push_pin_outlined,
                    title: 'Auto pin',
                    value: '$autoPinCount of 2 rules',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _SidebarFooter(
            soundEnabled: board.soundEnabled,
            arrowsEnabled: engine.showPvArrows,
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.icon,
    required this.title,
    required this.value,
    this.selected = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color:
            selected
                ? kPrimaryColor.withValues(alpha: 0.12)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.36)
                  : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: selected ? kPrimaryColor : kWhiteColor70),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: selected ? kWhiteColor : kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kLightGreyColor, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({
    required this.soundEnabled,
    required this.arrowsEnabled,
  });

  final bool soundEnabled;
  final bool arrowsEnabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MiniStatus(label: 'Sound', enabled: soundEnabled),
          const SizedBox(height: 8),
          _MiniStatus(label: 'Engine arrows', enabled: arrowsEnabled),
        ],
      ),
    );
  }
}

class _MiniStatus extends StatelessWidget {
  const _MiniStatus({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: enabled ? kPrimaryColor : kLightGreyColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: kWhiteColor70, fontSize: 11)),
        const Spacer(),
        Text(
          enabled ? 'On' : 'Off',
          style: const TextStyle(
            color: kLightGreyColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ─── Engine ──────────────────────────────────────────────────────────────────

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.settings, required this.ref});

  final EngineSettings settings;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(engineSettingsProviderNew.notifier);
    return _SectionCard(
      icon: Icons.memory_rounded,
      title: 'Engine experience',
      subtitle: 'Stockfish analysis, evaluation gauge, and PV arrows.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SwitchRow(
            label: 'Computer analysis',
            description:
                'Run Stockfish on the active position. Disable to free CPU.',
            value: settings.showEngineAnalysis,
            onChange: notifier.toggleEngineAnalysis,
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'Evaluation gauge',
            description:
                'Show the bar beside the board indicating who stands better.',
            value: settings.showEngineGauge,
            onChange: notifier.toggleEngineGauge,
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'Depth indicator',
            description: 'Display the current Stockfish search depth.',
            value: settings.showDepthOverlay,
            onChange: notifier.toggleDepthOverlay,
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'PV arrows on board',
            description: 'Draw arrows for the engine\'s top moves.',
            value: settings.showPvArrows,
            onChange: notifier.togglePvArrows,
          ),
          const SizedBox(height: 18),
          _SegmentedField(
            label: 'Thinking time',
            helpText: 'Longer per-move budgets produce stronger lines.',
            options: EngineSettings.searchTimeLabels,
            selectedIndex: settings.searchTimeIndex,
            onSelect: notifier.setSearchTimeIndex,
          ),
          const SizedBox(height: 14),
          _SegmentedField(
            label: 'Number of lines',
            helpText: 'How many alternative variations the engine reports.',
            options: EngineSettings.principalVariationLabels,
            selectedIndex: settings.principalVariationIndex,
            onSelect: notifier.setPrincipalVariationIndex,
          ),
          const SizedBox(height: 14),
          _SegmentedField(
            label: 'Max arrows on board',
            helpText: 'Caps how many suggestion arrows are drawn at once.',
            options: EngineSettings.maxArrowsLabels,
            selectedIndex: settings.maxArrowsOnBoard,
            onSelect: notifier.setMaxArrowsOnBoard,
          ),
        ],
      ),
    );
  }
}

class _AutoPinCard extends StatelessWidget {
  const _AutoPinCard({required this.prefs, required this.ref});

  final AutoPinPreferences prefs;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(autoPinPreferencesProvider.notifier);
    return _SectionCard(
      icon: Icons.push_pin_outlined,
      title: 'Auto pin',
      subtitle: 'Surface specific games at the top of tournament views.',
      child: Column(
        children: [
          _SwitchRow(
            label: 'Favourite players',
            description: 'Pin games of players you have starred.',
            value: prefs.favoritePlayersAutoPinEnabled,
            onChange: notifier.setFavoritePlayersAutoPin,
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'Countrymen',
            description: 'Pin games of players from your country.',
            value: prefs.countrymenAutoPinEnabled,
            onChange: notifier.setCountrymenAutoPin,
          ),
        ],
      ),
    );
  }
}

class _DisplayCard extends StatelessWidget {
  const _DisplayCard({required this.settings, required this.ref});

  final BoardSettingsNew settings;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(boardSettingsProviderNew.notifier);
    return _SectionCard(
      icon: Icons.dashboard_customize_outlined,
      title: 'Display & sound',
      subtitle: 'Move sounds, notation style, and tournament list view.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SwitchRow(
            label: 'Sound effects',
            description: 'Play audio for moves, captures, and game events.',
            value: settings.soundEnabled,
            onChange: notifier.toggleSound,
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'Figurine notation',
            description:
                'Show piece glyphs (♞f3) instead of letters (Nf3) in move lists.',
            value: settings.useFigurine,
            onChange: notifier.toggleFigurine,
            trailingPreview: _NotationBadge(useFigurine: settings.useFigurine),
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'Inline notation layout',
            description:
                'Render moves as a flowing paragraph instead of the indented ladder.',
            value: settings.notationInline,
            onChange: notifier.toggleNotationInline,
          ),
          const _RowDivider(),
          _SwitchRow(
            label: 'Move navigation controls',
            description:
                'Show the mouse step buttons under the board. Off by default so the board uses that space; keyboard navigation still works.',
            value: settings.showMoveNavigation,
            onChange: notifier.toggleMoveNavigation,
          ),
          const SizedBox(height: 18),
          _SegmentedField(
            label: 'Tournament games view',
            helpText: 'Default layout for game lists across the app.',
            options: const ['List', 'Grid', 'Board'],
            selectedIndex: settings.gamesListViewModeIndex,
            onSelect: notifier.setGamesListViewModeIndex,
          ),
        ],
      ),
    );
  }
}

class _NotationBadge extends StatelessWidget {
  const _NotationBadge({required this.useFigurine});
  final bool useFigurine;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kPrimaryColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kPrimaryColor.withValues(alpha: 0.35)),
      ),
      child: Text(
        useFigurine ? '♞f3' : 'Nf3',
        style: const TextStyle(
          color: kPrimaryColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─── Theme + piece grids (inline, no dialogs) ───────────────────────────────

class _BoardThemeCard extends StatelessWidget {
  const _BoardThemeCard({required this.currentIndex, required this.ref});

  final int currentIndex;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(boardSettingsProviderNew.notifier);
    final current = getBoardThemeByIndex(currentIndex);
    return _SectionCard(
      icon: Icons.palette_outlined,
      title: 'Board theme',
      subtitle:
          '${kBoardThemes.length} square palettes — currently ${current.name}.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = _columnsFor(constraints.maxWidth, target: 120);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.95,
            ),
            itemCount: kBoardThemes.length,
            itemBuilder: (context, index) {
              final theme = kBoardThemes[index];
              return _BoardThemeTile(
                theme: theme,
                isSelected: currentIndex == index,
                onTap: () => notifier.setBoardThemeIndex(index),
              );
            },
          );
        },
      ),
    );
  }
}

class _BoardThemeTile extends StatefulWidget {
  const _BoardThemeTile({
    required this.theme,
    required this.isSelected,
    required this.onTap,
  });

  final BoardThemeOption theme;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_BoardThemeTile> createState() => _BoardThemeTileState();
}

class _BoardThemeTileState extends State<_BoardThemeTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.isSelected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.10)
                      : (_hovered ? kBlack3Color : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    selected
                        ? kPrimaryColor
                        : (_hovered ? kDividerColor : Colors.transparent),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CustomPaint(
                      painter: _BoardPreviewPainter(
                        light: widget.theme.colorScheme.lightSquare,
                        dark: widget.theme.colorScheme.darkSquare,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.theme.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? kPrimaryColor : kWhiteColor,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BoardPreviewPainter extends CustomPainter {
  const _BoardPreviewPainter({required this.light, required this.dark});
  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 4;
    final paintLight = Paint()..color = light;
    final paintDark = Paint()..color = dark;
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        final paint = (r + c).isEven ? paintLight : paintDark;
        canvas.drawRect(
          Rect.fromLTWH(c * cell, r * (size.height / 4), cell, size.height / 4),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_BoardPreviewPainter old) =>
      old.light != light || old.dark != dark;
}

class _PieceSetCard extends StatelessWidget {
  const _PieceSetCard({
    required this.currentIndex,
    required this.themeIndex,
    required this.ref,
  });

  final int currentIndex;
  final int themeIndex;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(boardSettingsProviderNew.notifier);
    final current = getPieceSetByIndex(currentIndex);
    final boardScheme = getBoardThemeByIndex(themeIndex).colorScheme;
    return _SectionCard(
      icon: Icons.style_outlined,
      title: 'Piece set',
      subtitle:
          '${kPieceSets.length} piece styles — currently ${current.label}.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = _columnsFor(constraints.maxWidth, target: 130);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.9,
            ),
            itemCount: kPieceSets.length,
            itemBuilder: (context, index) {
              final pieceSet = kPieceSets[index];
              return _PieceSetTile(
                pieceSet: pieceSet,
                isSelected: currentIndex == index,
                lightSquare: boardScheme.lightSquare,
                darkSquare: boardScheme.darkSquare,
                onTap: () => notifier.setPieceSetIndex(index),
              );
            },
          );
        },
      ),
    );
  }
}

class _PieceSetTile extends StatefulWidget {
  const _PieceSetTile({
    required this.pieceSet,
    required this.isSelected,
    required this.lightSquare,
    required this.darkSquare,
    required this.onTap,
  });

  final PieceSet pieceSet;
  final bool isSelected;
  final Color lightSquare;
  final Color darkSquare;
  final VoidCallback onTap;

  @override
  State<_PieceSetTile> createState() => _PieceSetTileState();
}

class _PieceSetTileState extends State<_PieceSetTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.isSelected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor.withValues(alpha: 0.10)
                      : (_hovered ? kBlack3Color : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    selected
                        ? kPrimaryColor
                        : (_hovered ? kDividerColor : Colors.transparent),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(
                          painter: _BoardPreviewPainter(
                            light: widget.lightSquare,
                            dark: widget.darkSquare,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Image(
                                  image:
                                      widget.pieceSet.assets[PieceKind
                                          .whiteKing]!,
                                  fit: BoxFit.contain,
                                ),
                              ),
                              Expanded(
                                child: Image(
                                  image:
                                      widget.pieceSet.assets[PieceKind
                                          .blackQueen]!,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.pieceSet.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: selected ? kPrimaryColor : kWhiteColor,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shared chrome ───────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: kBlack2Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: kWhiteColor70),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          const Divider(color: kDividerColor, height: 1),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.description,
    required this.value,
    required this.onChange,
    this.trailingPreview,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChange;
  final Widget? trailingPreview;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: kWhiteColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (trailingPreview != null) ...[
                      const SizedBox(width: 8),
                      trailingPreview!,
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FSwitch(value: value, onChange: onChange),
        ],
      ),
    );
  }
}

class _SegmentedField extends StatelessWidget {
  const _SegmentedField({
    required this.label,
    required this.helpText,
    required this.options,
    required this.selectedIndex,
    required this.onSelect,
  });

  final String label;
  final String helpText;
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          helpText,
          style: const TextStyle(color: kWhiteColor70, fontSize: 11),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: kBlack3Color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kDividerColor),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(
            children: [
              for (var i = 0; i < options.length; i++)
                Expanded(
                  child: _SegmentOption(
                    label: options[i],
                    selected: i == selectedIndex,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SegmentOption extends StatefulWidget {
  const _SegmentOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SegmentOption> createState() => _SegmentOptionState();
}

class _SegmentOptionState extends State<_SegmentOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color:
                  selected
                      ? kPrimaryColor
                      : (_hovered ? kBlack2Color : Colors.transparent),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                color: selected ? kBackgroundColor : kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(color: kDividerColor, height: 1);
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 64),
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: kWhiteColor70,
          ),
        ),
      ),
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(color: kWhiteColor70, fontSize: 13),
        ),
      ),
    );
  }
}

int _columnsFor(double width, {required double target}) {
  final raw = (width / target).floor();
  return raw.clamp(2, 6);
}
