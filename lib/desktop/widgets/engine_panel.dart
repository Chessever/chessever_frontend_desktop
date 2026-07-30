import 'dart:async';

import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/services/engine/game_analysis_report.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/screens/chessboard/game_review/evaluation_graph_markers.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_toolbar_pill_button.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/engine_settings_popover.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/stockfish_singleton.dart';
import 'package:chessever/theme/app_theme.dart';

@visibleForTesting
const String desktopEngineReportSplitStorageKey =
    'board_pane.engine.live_report.v1';

@visibleForTesting
const double desktopEngineReportGutterThickness = 10;

/// Live engine evaluation panel for the active board position.
///
/// Reads from `boardEvalProvider` — the same shared Stockfish source the
/// evaluation bar is bound to — so both stay perfectly in sync without
/// running a second engine subprocess. Renders every principal variation
/// (up to the user's configured `multiPV`) so desktop users can compare
/// alternatives the way desktop database and web analysis boards analysis boards do.
///
/// Each PV row is interactive:
///  - Click → plays the line's first move on the active board
///  - Right-click → context menu (play / copy SAN / copy first / copy UCI)
class EnginePanel extends ConsumerStatefulWidget {
  const EnginePanel({
    super.key,
    required this.fen,
    required this.sideToMove,
    this.onPlayUci,
    this.game,
    this.headers = const <String, String>{},
    this.activePly = 0,
    this.onJumpToPly,
    this.onReportRunningChanged,
    this.onReportChanged,
    this.reportVisible = false,
    this.isForegroundTab = true,
    this.autoAnalysisAllowed = true,
    this.reportController,
  });

  final String fen;

  /// `'w'` or `'b'`. Unused now that the singleton normalizes evaluations to
  /// white-perspective; kept on the API to avoid touching every call site.
  final String sideToMove;

  /// Caller-supplied move dispatcher. When non-null, PV rows become
  /// clickable and play their first UCI through this callback. The Board
  /// pane wires it to the same `playUci` it uses for opening-explorer
  /// taps so both surfaces share the legality + onMove path.
  final void Function(String uci)? onPlayUci;

  /// Loaded game snapshot used only by the session-scoped Report tab.
  final ChessGame? game;
  final Map<String, String> headers;
  final int activePly;
  final ValueChanged<int>? onJumpToPly;
  final ValueChanged<bool>? onReportRunningChanged;
  final ValueChanged<GameAnalysisReport?>? onReportChanged;

  /// Whether the session-scoped game-analysis report is currently shown.
  /// Fully independent of the engine on/off state — closing the engine lines
  /// never removes the report, and vice versa. The toggle itself lives beside
  /// the explorer button in the notation panel's segment bar.
  final bool reportVisible;

  /// Only the foreground board tab may own the live Stockfish search. Board
  /// tabs stay mounted in the desktop tab stack, so this prevents hidden tabs
  /// from occupying the single engine queue.
  final bool isForegroundTab;

  final bool autoAnalysisAllowed;

  /// Test seam for driving report lifecycle transitions without spawning a
  /// real Stockfish process. The controller must remain stable for this
  /// widget's lifetime and is owned by the caller when supplied.
  @visibleForTesting
  final GameAnalysisReportController? reportController;

  @override
  ConsumerState<EnginePanel> createState() => _EnginePanelState();
}

class _EnginePanelState extends ConsumerState<EnginePanel> {
  late final GameAnalysisReportController _reportController;
  late final bool _ownsReportController;
  bool _lastReportedRunning = false;
  GameAnalysisReport? _lastPublishedReport;
  String? _autoStartedFingerprint;
  String? _gameFingerprint;

  @override
  void initState() {
    super.initState();
    _ownsReportController = widget.reportController == null;
    _reportController =
        widget.reportController ?? GameAnalysisReportController();
    _reportController.addListener(_onReport);
    _gameFingerprint = _fingerprint(widget.game);
  }

  @override
  void didUpdateWidget(covariant EnginePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isForegroundTab &&
        !widget.isForegroundTab &&
        _reportController.state.isRunning) {
      unawaited(_reportController.cancel());
    }
    final nextFingerprint = _fingerprint(widget.game);
    if (_gameFingerprint != nextFingerprint) {
      _gameFingerprint = nextFingerprint;
      _autoStartedFingerprint = null;
      _reportController.invalidate();
    }
  }

  String? _fingerprint(ChessGame? game) =>
      game == null ? null : gameReportFingerprint(game);

  void _onReport() {
    if (!mounted) return;
    final reportState = _reportController.state;
    final running = reportState.isRunning;
    final runningChanged = running != _lastReportedRunning;
    if (runningChanged) {
      _lastReportedRunning = running;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _lastReportedRunning != running) return;
        widget.onReportRunningChanged?.call(running);
      });
    }
    final report = reportState.report;
    final reportChanged = !identical(report, _lastPublishedReport);
    if (reportChanged) {
      _lastPublishedReport = report;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_lastPublishedReport, report)) return;
        widget.onReportChanged?.call(report);
      });
    }
    // Progress-only ticks stream in as fast as the engine reports; those are
    // absorbed by the scoped ListenableBuilder around the progress bar (see
    // GameReportView), so the whole panel only rebuilds on structural
    // transitions — start, finish, cancel, fail — never per node update.
    if (runningChanged || reportChanged) setState(() {});
  }

  Future<void> _analyze() async {
    final game = widget.game;
    if (!widget.isForegroundTab || game == null || game.mainline.isEmpty) {
      return;
    }
    await _reportController.analyze(
      game,
      whiteRating: _headerRating('WhiteElo'),
      blackRating: _headerRating('BlackElo'),
    );
  }

  int? _headerRating(String key) {
    final raw = widget.headers[key]?.replaceAll(RegExp(r'[^0-9]'), '');
    return raw == null ? null : int.tryParse(raw);
  }

  void _scheduleAutomaticAnalysis(EngineSettings settings) {
    final game = widget.game;
    if (!widget.autoAnalysisAllowed ||
        !settings.autoGameAnalysis ||
        game == null ||
        game.mainline.isEmpty) {
      return;
    }
    final fingerprint = gameReportFingerprint(game);
    if (_autoStartedFingerprint == fingerprint ||
        _reportController.state.isRunning ||
        _reportController.state.report?.fingerprint == fingerprint) {
      return;
    }
    _autoStartedFingerprint = fingerprint;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.autoAnalysisAllowed ||
          widget.game == null ||
          gameReportFingerprint(widget.game!) != fingerprint) {
        return;
      }
      unawaited(_analyze());
    });
  }

  @override
  void dispose() {
    if (_lastReportedRunning) {
      final callback = widget.onReportRunningChanged;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => callback?.call(false),
      );
    }
    _reportController.removeListener(_onReport);
    if (_ownsReportController) _reportController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncSettings = ref.watch(engineSettingsProviderNew);
    final settings = asyncSettings.valueOrNull;
    if (settings != null) _scheduleAutomaticAnalysis(settings);
    final engineOn =
        settings?.showEngineAnalysis ??
        const EngineSettings().showEngineAnalysis;
    final reportOn = widget.reportVisible;
    final reportState = _reportController.state;
    final liveAnalysisPausedForReport = reportOn && reportState.isRunning;
    final runLiveBoardAnalysis = shouldRunLiveBoardAnalysis(
      isForeground: widget.isForegroundTab,
      reportVisible: reportOn,
      reportRunning: reportState.isRunning,
    );

    // The engine readout (live dot / score / depth) only means anything once
    // Stockfish can search this position. When it can't we still keep the
    // header on screen so both independent toggles stay reachable.
    final engineReady = StockfishSingleton().isEngineHealthy;
    final engineActive =
        engineOn &&
        runLiveBoardAnalysis &&
        (engineReady || widget.fen.isNotEmpty);
    final evalState =
        engineActive ? ref.watch(boardEvalProvider(widget.fen)) : null;

    final engineContent =
        liveAnalysisPausedForReport
            ? const _EnginePausedForReport()
            : engineActive
            ? _buildEngineLines(evalState!)
            : const _EngineNotReady();
    final reportContent = GameReportView(
      state: reportState,
      progressController: _reportController,
      game: widget.game,
      headers: widget.headers,
      activePly: widget.activePly,
      onAnalyze: _analyze,
      onCancel: _reportController.cancel,
      onJumpToPly: widget.onJumpToPly,
    );

    final Widget? body =
        engineOn && reportOn
            ? ResizableSplitView(
              axis: Axis.vertical,
              storageKey: desktopEngineReportSplitStorageKey,
              gutterThickness: desktopEngineReportGutterThickness,
              gutterColor: kPrimaryColor,
              children: [
                SplitChild(
                  minSize: 80,
                  initialWeight: 0.40,
                  label: 'Live engine',
                  dismissible: false,
                  child: engineContent,
                ),
                SplitChild(
                  minSize: 140,
                  initialWeight: 0.60,
                  label: 'Game report',
                  dismissible: false,
                  child: reportContent,
                ),
              ],
            )
            : engineOn
            ? engineContent
            : reportOn
            ? reportContent
            : null;

    // Engine lines and the report remain independently toggled; when both
    // are visible, either can be resized without moving the notation boundary.
    return Container(
      color: kBlack2Color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(
            engineOn: engineOn,
            engineActive: engineActive,
            evalState: evalState,
          ),
          if (body != null) Expanded(child: body),
        ],
      ),
    );
  }

  /// Persistent header carrying the two independent toggles (engine on/off
  /// and report on/off) plus the engine gear. The engine readout collapses
  /// away when the engine is off so the report can own the panel alone.
  Widget _buildHeader({
    required bool engineOn,
    required bool engineActive,
    required BoardEvalState? evalState,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          if (engineActive) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: evalState!.isEvaluating ? kGreenColor : kLightGreyColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              'Stockfish',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: engineOn ? kWhiteColor : kWhiteColor70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (engineActive) ...[
            const SizedBox(width: 8),
            Text(
              _formatScore(evalState!.evaluation, evalState.mate),
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            _DepthChip(
              depth: evalState.depth,
              isEvaluating: evalState.isEvaluating,
            ),
          ],
          const SizedBox(width: 6),
          _EngineQuickToggle(enabled: engineOn),
          const SizedBox(width: 4),
          const EngineSettingsPopover(),
        ],
      ),
    );
  }

  Widget _buildEngineLines(BoardEvalState state) {
    final pvs = state.pvs;
    if (pvs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 12),
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(
            state.isEvaluating
                ? 'Searching…'
                : (state.statusText ?? 'No engine line for this position.'),
            style: const TextStyle(color: kWhiteColor70, fontSize: 12),
          ),
        ),
      );
    }
    return ListView.separated(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      itemCount: pvs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder:
          (context, i) => _PvLine(
            rank: i + 1,
            pv: pvs[i],
            fen: widget.fen,
            onPlayUci: widget.onPlayUci,
          ),
    );
  }
}

class GameReportView extends StatefulWidget {
  const GameReportView({
    super.key,
    required this.state,
    required this.game,
    required this.headers,
    required this.activePly,
    required this.onAnalyze,
    required this.onCancel,
    required this.onJumpToPly,
    this.progressController,
  });

  final GameReportState state;

  /// Optional live source for the running progress bar. When provided, only the
  /// bar re-renders on each engine tick (via a scoped ListenableBuilder) so the
  /// high-frequency node updates never rebuild the surrounding panel. Tests may
  /// omit it and drive the view purely off [state].
  final GameAnalysisReportController? progressController;
  final ChessGame? game;
  final Map<String, String> headers;
  final int activePly;
  final Future<void> Function() onAnalyze;
  final Future<void> Function() onCancel;
  final ValueChanged<int>? onJumpToPly;

  @override
  State<GameReportView> createState() => _GameReportViewState();
}

class _GameReportViewState extends State<GameReportView> {
  final Map<String, int> _recapCycle = <String, int>{};

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
        child: _body(),
      ),
    );
  }

  Widget _body() {
    final game = widget.game;
    if (game == null || game.mainline.isEmpty) {
      return _ReportMessage(
        icon: Icons.analytics_outlined,
        title: 'No game to analyze',
        body:
            'Load a game with at least one main-line move to create a report.',
      );
    }

    return switch (widget.state.status) {
      GameReportStatus.idle => _ReportStart(
        moveCount: game.mainline.length,
        onAnalyze: widget.onAnalyze,
      ),
      GameReportStatus.running => _runningProgress(),
      GameReportStatus.cancelled => _ReportMessage(
        icon: Icons.cancel_outlined,
        title: 'Analysis cancelled',
        body:
            widget.state.message ??
            'No partial report was saved. You can start again when ready.',
        actionLabel: 'Analyze Game',
        onAction: widget.onAnalyze,
      ),
      GameReportStatus.failed => _ReportMessage(
        icon: Icons.error_outline_rounded,
        title: 'Could not create report',
        body: widget.state.message ?? 'Stockfish did not complete the report.',
        actionLabel: 'Try Again',
        onAction: widget.onAnalyze,
      ),
      GameReportStatus.completed => _completed(widget.state.report!),
    };
  }

  /// Renders the running progress bar. When a live controller is available the
  /// bar subscribes to it directly, so the stream of node-count ticks rebuilds
  /// only this subtree — the surrounding panel stays put until the report ends.
  Widget _runningProgress() {
    final controller = widget.progressController;
    if (controller == null) {
      return _ReportProgress(state: widget.state, onCancel: widget.onCancel);
    }
    return ListenableBuilder(
      listenable: controller,
      builder:
          (context, _) => _ReportProgress(
            state: controller.state,
            onCancel: widget.onCancel,
          ),
    );
  }

  Widget _completed(GameAnalysisReport report) {
    final white = _header('White', 'White');
    final black = _header('Black', 'Black');
    final opening = [
      _header('ECO', ''),
      _header('Opening', ''),
    ].where((part) => part.isNotEmpty && part != '?').join(' · ');

    return ListView(
      physics: const DesktopScrollPhysics(),
      padding: const EdgeInsets.only(right: 4),
      children: [
        Row(
          children: [
            const Icon(
              Icons.analytics_outlined,
              color: kPrimaryColor,
              size: 17,
            ),
            const SizedBox(width: 7),
            const Text(
              'Game report',
              style: TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            DesktopToolbarPillButton(
              label: 'Analyze Again',
              icon: Icons.refresh_rounded,
              onPress: widget.onAnalyze,
              tooltip: 'Re-run Stockfish analysis on this game',
            ),
          ],
        ),
        if (opening.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            opening,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: kWhiteColor70, fontSize: 11),
          ),
        ],
        const SizedBox(height: 10),
        _ReportMetrics(white: white, black: black, report: report),
        const SizedBox(height: 12),
        _ReportEvaluationGraph(
          report: report,
          activePly: widget.activePly,
          onJumpToPly: widget.onJumpToPly,
        ),
        const SizedBox(height: 12),
        _classificationRecap(report, white, black),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _classificationRecap(
    GameAnalysisReport report,
    String white,
    String black,
  ) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: kDividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            color: kBlack3Color,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    white,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kWhiteColor70, fontSize: 10),
                  ),
                ),
                const SizedBox(width: 104),
                Expanded(
                  child: Text(
                    black,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: kWhiteColor70, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          for (final classification in GameMoveClassification.values)
            _ReportRecapRow(
              classification: classification,
              whiteCount: report.count(classification, white: true),
              blackCount: report.count(classification, white: false),
              onWhite:
                  () => _jumpToClassification(report, classification, true),
              onBlack:
                  () => _jumpToClassification(report, classification, false),
            ),
        ],
      ),
    );
  }

  void _jumpToClassification(
    GameAnalysisReport report,
    GameMoveClassification classification,
    bool white,
  ) {
    final jump = widget.onJumpToPly;
    if (jump == null) return;
    final matches = report.moves
        .where(
          (move) =>
              move.isWhite == white && move.classification == classification,
        )
        .toList(growable: false);
    if (matches.isEmpty) return;
    final key = '${classification.name}:$white';
    final current = _recapCycle[key] ?? 0;
    jump(matches[current % matches.length].ply);
    setState(() => _recapCycle[key] = current + 1);
  }

  String _header(String key, String fallback) {
    final value = widget.headers[key]?.trim();
    return value == null || value.isEmpty ? fallback : value;
  }
}

class _ReportStart extends StatelessWidget {
  const _ReportStart({required this.moveCount, required this.onAnalyze});

  final int moveCount;
  final Future<void> Function() onAnalyze;

  @override
  Widget build(BuildContext context) {
    return _ReportMessage(
      icon: Icons.query_stats_rounded,
      title: 'Analyze this game',
      body:
          'Stockfish will evaluate ${moveCount + 1} positions at depth 16 with '
          'three candidate lines. Live move analysis pauses while it runs.',
      actionLabel: 'Analyze Game',
      onAction: onAnalyze,
    );
  }
}

class _ReportProgress extends StatelessWidget {
  const _ReportProgress({required this.state, required this.onCancel});

  final GameReportState state;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final target = state.progress.clamp(0.0, 1.0);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.memory_rounded, color: kPrimaryColor, size: 25),
        const SizedBox(height: 10),
        Text(
          state.message ?? 'Analyzing game…',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: kWhiteColor,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 9),
        // Ease between the progress values the controller streams so the bar
        // glides rather than snapping. The node-driven updates already arrive
        // densely, so a short ease is enough to smooth the micro-steps and the
        // occasional whole-slice jump (cached or terminal positions). On each
        // new target the builder animates from the current displayed value, so
        // it never jumps backwards.
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: target),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          builder: (context, value, _) {
            final percentage = (value * 100).clamp(0, 100).round();
            return Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: SizedBox(
                    height: 6,
                    child: LinearProgressIndicator(
                      value: value,
                      color: kPrimaryColor,
                      backgroundColor: kBlack3Color,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$percentage% · ${state.completedPositions}/${state.totalPositions}',
                  style: const TextStyle(color: kWhiteColor70, fontSize: 11),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        FButton(
          style: FButtonStyle.outline(),
          onPress: onCancel,
          prefix: const Icon(Icons.stop_rounded, size: 14),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

class _ReportMessage extends StatelessWidget {
  const _ReportMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final Future<void> Function()? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: kPrimaryColor, size: 26),
            const SizedBox(height: 9),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 11,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 11),
              FButton(
                onPress: onAction,
                prefix: const Icon(Icons.analytics_outlined, size: 14),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReportMetrics extends StatelessWidget {
  const _ReportMetrics({
    required this.white,
    required this.black,
    required this.report,
  });

  final String white;
  final String black;
  final GameAnalysisReport report;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDividerColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _name(white, true)),
              const SizedBox(width: 76),
              Expanded(child: _name(black, false)),
            ],
          ),
          const SizedBox(height: 7),
          _metric(
            report.whiteAccuracy.toStringAsFixed(1),
            'Accuracy',
            report.blackAccuracy.toStringAsFixed(1),
            suffix: '%',
          ),
          if (report.whiteEstimatedRating != null &&
              report.blackEstimatedRating != null) ...[
            const SizedBox(height: 5),
            _metric(
              '${report.whiteEstimatedRating}',
              'Game rating',
              '${report.blackEstimatedRating}',
            ),
          ],
        ],
      ),
    );
  }

  Widget _name(String value, bool white) => Text(
    value,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: white ? kWhiteColor : kWhiteColor70,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _metric(
    String left,
    String label,
    String right, {
    String suffix = '',
  }) {
    const valueStyle = TextStyle(
      color: kWhiteColor,
      fontSize: 13,
      fontWeight: FontWeight.w700,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            '$left$suffix',
            textAlign: TextAlign.center,
            style: valueStyle,
          ),
        ),
        SizedBox(
          width: 76,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(color: kWhiteColor70, fontSize: 9),
          ),
        ),
        Expanded(
          child: Text(
            '$right$suffix',
            textAlign: TextAlign.center,
            style: valueStyle,
          ),
        ),
      ],
    );
  }
}

class _ReportEvaluationGraph extends StatefulWidget {
  const _ReportEvaluationGraph({
    required this.report,
    required this.activePly,
    required this.onJumpToPly,
  });

  final GameAnalysisReport report;
  final int activePly;
  final ValueChanged<int>? onJumpToPly;

  @override
  State<_ReportEvaluationGraph> createState() => _ReportEvaluationGraphState();
}

class _ReportEvaluationGraphState extends State<_ReportEvaluationGraph> {
  int? _hoveredPly;

  int _plyAt(double dx, double width) {
    final maxPly = widget.report.positions.length - 1;
    if (maxPly <= 0 || width <= 0) return 0;
    return ((dx / width).clamp(0.0, 1.0) * maxPly).round();
  }

  void _updateHover(double dx, double width) {
    final ply = _plyAt(dx, width);
    if (ply == _hoveredPly) return;
    setState(() => _hoveredPly = ply);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final hoveredPly = _hoveredPly;
          return MouseRegion(
            cursor:
                widget.onJumpToPly == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
            onHover:
                (event) =>
                    _updateHover(event.localPosition.dx, constraints.maxWidth),
            onExit: (_) => setState(() => _hoveredPly = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown:
                  widget.onJumpToPly == null
                      ? null
                      : (details) => widget.onJumpToPly!(
                        _plyAt(details.localPosition.dx, constraints.maxWidth),
                      ),
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      key: const ValueKey('game-report-evaluation-graph'),
                      painter: _ReportGraphPainter(
                        positions: widget.report.positions,
                        moves: widget.report.moves,
                        activePly: widget.activePly,
                        hoveredPly: hoveredPly,
                      ),
                    ),
                  ),
                  if (hoveredPly != null && hoveredPly > 0)
                    _ReportGraphHoverLabel(
                      report: widget.report,
                      ply: hoveredPly,
                      graphWidth: constraints.maxWidth,
                      graphHeight: constraints.maxHeight,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ReportGraphPainter extends CustomPainter {
  const _ReportGraphPainter({
    required this.positions,
    required this.moves,
    required this.activePly,
    required this.hoveredPly,
  });

  final List<GameReportPosition> positions;
  final List<GameReportMove> moves;
  final int activePly;
  final int? hoveredPly;

  static const double _classificationDotRadius = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = kBlack3Color,
    );
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = kDividerColor
        ..strokeWidth = 1,
    );
    if (positions.isEmpty) return;
    final maxIndex = positions.length - 1;
    final path = Path();
    for (var i = 0; i < positions.length; i++) {
      final x = maxIndex <= 0 ? 0.0 : size.width * i / maxIndex;
      final win = gameReportWinPercentage(positions[i].bestLine);
      final y = size.height - (win / 100 * size.height);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final fill =
        Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
    canvas.drawPath(fill, Paint()..color = kWhiteColor.withValues(alpha: 0.10));
    canvas.drawPath(
      path,
      Paint()
        ..color = kWhiteColor70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Classification markers sit on the curve (chess.com-style). Paint before
    // the active scrubber so the white active point stays readable on top.
    final classificationMarkers = buildEvaluationGraphClassificationMarkers(
      moves: moves,
      positions: positions,
    );
    final outline =
        Paint()
          ..color = kBlack3Color.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
    for (final marker in classificationMarkers) {
      final x = maxIndex <= 0 ? 0.0 : size.width * marker.ply / maxIndex;
      final y = size.height - marker.winPercentage / 100 * size.height;
      final center = Offset(x, y);
      canvas.drawCircle(
        center,
        _classificationDotRadius,
        Paint()..color = marker.color,
      );
      canvas.drawCircle(center, _classificationDotRadius, outline);
    }

    final safePly = activePly.clamp(0, maxIndex);
    final markerX = maxIndex <= 0 ? 0.0 : size.width * safePly / maxIndex;
    canvas.drawLine(
      Offset(markerX, 0),
      Offset(markerX, size.height),
      Paint()
        ..color = kPrimaryColor.withValues(alpha: 0.75)
        ..strokeWidth = 2,
    );
    final hover = hoveredPly;
    if (hover != null && hover >= 0 && hover < positions.length) {
      final hoverX = maxIndex <= 0 ? 0.0 : size.width * hover / maxIndex;
      final hoverY =
          size.height -
          (gameReportWinPercentage(positions[hover].bestLine) /
              100 *
              size.height);
      canvas.drawLine(
        Offset(hoverX, 0),
        Offset(hoverX, size.height),
        Paint()
          ..color = kWhiteColor.withValues(alpha: 0.28)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        Offset(hoverX, hoverY),
        5,
        Paint()..color = kBlackColor,
      );
      canvas.drawCircle(
        Offset(hoverX, hoverY),
        3,
        Paint()..color = kWhiteColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReportGraphPainter oldDelegate) =>
      oldDelegate.activePly != activePly ||
      oldDelegate.hoveredPly != hoveredPly ||
      oldDelegate.positions != positions ||
      oldDelegate.moves != moves;
}

class _ReportGraphHoverLabel extends StatelessWidget {
  const _ReportGraphHoverLabel({
    required this.report,
    required this.ply,
    required this.graphWidth,
    required this.graphHeight,
  });

  final GameAnalysisReport report;
  final int ply;
  final double graphWidth;
  final double graphHeight;

  @override
  Widget build(BuildContext context) {
    final move = report.moves[ply - 1];
    final line = report.positions[ply].bestLine;
    final win = gameReportWinPercentage(line);
    final x = graphWidth * ply / (report.positions.length - 1);
    final y = graphHeight - (win / 100 * graphHeight);
    final width = (graphWidth - 8).clamp(1.0, 244.0);
    const height = 25.0;
    final left = (x - width / 2).clamp(4.0, graphWidth - width - 4);
    final top = (y - height - 9).clamp(4.0, graphHeight - height - 4);
    final moveNumber = (ply + 1) ~/ 2;
    final movePrefix = move.isWhite ? '$moveNumber.' : '$moveNumber...';
    final evaluation =
        line.mate != null
            ? 'M${line.mate}'
            : ((line.centipawns ?? 0) / 100).toStringAsFixed(2);
    final classification = move.classification?.label;
    final description = [
      '$movePrefix ${move.san}',
      evaluation,
      '${win.round()}% White',
      if (classification != null) classification,
    ].join(' ');

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: IgnorePointer(
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF303034),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 5,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportRecapRow extends StatelessWidget {
  const _ReportRecapRow({
    required this.classification,
    required this.whiteCount,
    required this.blackCount,
    required this.onWhite,
    required this.onBlack,
  });

  final GameMoveClassification classification;
  final int whiteCount;
  final int blackCount;
  final VoidCallback onWhite;
  final VoidCallback onBlack;

  @override
  Widget build(BuildContext context) {
    final color = _classificationColor(classification);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kDividerColor)),
      ),
      child: Row(
        children: [
          Expanded(child: _count(whiteCount, onWhite, color)),
          SizedBox(
            width: 104,
            child: Row(
              children: [
                _GameReportClassificationIcon(
                  classification: classification,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    classification.label,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _count(blackCount, onBlack, color)),
        ],
      ),
    );
  }

  Widget _count(int count, VoidCallback onTap, Color color) => ClickCursor(
    enabled: count > 0,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: count > 0 ? onTap : null,
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

class _GameReportClassificationIcon extends StatelessWidget {
  const _GameReportClassificationIcon({
    required this.classification,
    required this.size,
  });

  final GameMoveClassification classification;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Badge SVG already carries its own coloured disc — render bare, no circle.
    return DesktopTooltip(
      message: classification.label,
      child: SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          classificationIconAsset(classification),
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

String _classificationIconAsset(GameMoveClassification classification) =>
    classificationIconAsset(classification);

Color _classificationColor(GameMoveClassification classification) =>
    classificationColor(classification);

class _PvLine extends StatefulWidget {
  const _PvLine({
    required this.rank,
    required this.pv,
    required this.fen,
    required this.onPlayUci,
  });

  final int rank;
  final BoardPv pv;
  final String fen;
  final void Function(String uci)? onPlayUci;

  @override
  State<_PvLine> createState() => _PvLineState();
}

class _PvLineState extends State<_PvLine> {
  final GlobalKey _lineAnchorKey = GlobalKey();
  bool _hovered = false;
  bool _expanded = false;
  int? _hoveredTokenIndex;
  String? _cachedFen;
  String? _cachedMoves;
  String? _cachedFirstUci;
  String _cachedDisplayLine = '';
  List<_PvToken> _cachedTokens = const <_PvToken>[];

  static final RegExp _pvWhitespace = RegExp(r'\s+');

  @override
  void initState() {
    super.initState();
    _refreshCachedLine();
  }

  @override
  void didUpdateWidget(covariant _PvLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen || oldWidget.pv.moves != widget.pv.moves) {
      _refreshCachedLine();
      _hoveredTokenIndex = null;
    } else if (_hoveredTokenIndex != null &&
        _hoveredTokenIndex! >= _cachedTokens.length) {
      _hoveredTokenIndex = null;
    }
  }

  void _refreshCachedLine() {
    final moves = widget.pv.moves;
    final parts =
        moves.split(_pvWhitespace).where((s) => s.trim().isNotEmpty).toList();
    _cachedFen = widget.fen;
    _cachedMoves = moves;
    _cachedFirstUci = parts.isEmpty ? null : parts.first.trim();

    final tokens = _tokensFor(widget.fen, parts);
    _cachedTokens = tokens;
    _cachedDisplayLine =
        tokens.isEmpty ? moves : tokens.map((t) => t.san).join(' ');
  }

  /// First UCI move of the line. The bar's `pv.moves` is a space-
  /// separated UCI string ("e2e4 e7e5 g1f3 …"); the first token is what
  /// gets played when the user clicks the row.
  String? get _firstUci {
    if (_cachedFen != widget.fen || _cachedMoves != widget.pv.moves) {
      _refreshCachedLine();
    }
    return _cachedFirstUci;
  }

  /// Render the PV line as numbered SAN ("8.dxc3 Bc5 9.Qe2+ Qe7 10.O-O …")
  /// — readable, copy-friendly, and matches how desktop database and web analysis boards print
  /// engine lines. Move numbers are derived from the queried FEN's full-
  /// move + side-to-move fields (same logic as the position-games table's
  /// Notation column). Falls back to the raw UCI string when the position
  /// can't be parsed (e.g. a stale snapshot mid-position-update).
  /// Walks the UCI line on top of [fen] and emits one [_PvToken] per
  /// move with the formatted SAN label, the move's UCI, and the
  /// cumulative UCI list up to (and including) that token. The hover
  /// preview reads `ucisUpTo` to render the position after the hovered
  /// move; the visible label uses `san`.
  List<_PvToken> _tokensFor(String fen, List<String> uciMoves) {
    try {
      final position = Chess.fromSetup(Setup.parseFen(fen));
      final parts = fen.trim().split(_pvWhitespace);
      final initialFullMove =
          parts.length >= 6 ? int.tryParse(parts[5]) ?? 1 : 1;
      final whiteFirst = parts.length >= 2 ? parts[1] == 'w' : true;

      final out = <_PvToken>[];
      Position cursor = position;
      var fullMove = initialFullMove;
      var whiteToMove = whiteFirst;
      final ucisSoFar = <String>[];
      for (final raw in uciMoves) {
        final uci = raw.trim();
        if (uci.isEmpty) continue;
        final move = Move.parse(uci);
        if (move == null) break;
        if (!cursor.isLegal(move)) break;
        final san = cursor.makeSan(move).$2;
        final String label;
        if (whiteToMove) {
          label = '$fullMove.$san';
        } else if (out.isEmpty) {
          label = '$fullMove…$san';
        } else {
          label = san;
        }
        ucisSoFar.add(uci);
        out.add(
          _PvToken(
            san: label,
            uci: uci,
            ucisUpTo: List<String>.unmodifiable(ucisSoFar),
          ),
        );
        cursor = cursor.playUnchecked(move);
        if (!whiteToMove) fullMove += 1;
        whiteToMove = !whiteToMove;
      }
      return out;
    } catch (_) {
      return uciMoves
          .map((u) => _PvToken(san: u, uci: u, ucisUpTo: const <String>[]))
          .toList(growable: false);
    }
  }

  String _sanLineString() {
    if (_cachedFen != widget.fen || _cachedMoves != widget.pv.moves) {
      _refreshCachedLine();
    }
    return _cachedDisplayLine;
  }

  Future<void> _showContextMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final firstUci = _firstUci;
    final selected = await showMenu<_PvAction>(
      context: context,
      color: kBlack2Color,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      items: [
        if (firstUci != null && widget.onPlayUci != null)
          const PopupMenuItem<_PvAction>(
            value: _PvAction.play,
            child: _MenuRow(
              icon: Icons.play_arrow_rounded,
              label: 'Play this move',
            ),
          ),
        const PopupMenuItem<_PvAction>(
          value: _PvAction.copySan,
          child: _MenuRow(icon: Icons.copy_rounded, label: 'Copy SAN line'),
        ),
        const PopupMenuItem<_PvAction>(
          value: _PvAction.copyFirst,
          child: _MenuRow(
            icon: Icons.first_page_rounded,
            label: 'Copy first move',
          ),
        ),
        const PopupMenuItem<_PvAction>(
          value: _PvAction.copyUci,
          child: _MenuRow(
            icon: Icons.format_quote_rounded,
            label: 'Copy UCI line',
          ),
        ),
      ],
    );
    if (selected == null) return;
    switch (selected) {
      case _PvAction.play:
        if (firstUci != null) widget.onPlayUci?.call(firstUci);
      case _PvAction.copySan:
        await Clipboard.setData(ClipboardData(text: _sanLineString()));
      case _PvAction.copyFirst:
        if (firstUci != null) {
          await Clipboard.setData(ClipboardData(text: firstUci));
        }
      case _PvAction.copyUci:
        await Clipboard.setData(ClipboardData(text: widget.pv.moves));
    }
  }

  void _previewToken(int index) {
    if (index < 0 || index >= _cachedTokens.length) return;
    if (_hoveredTokenIndex == index) return;
    setState(() => _hoveredTokenIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final score = _formatScore(widget.pv.evaluation, widget.pv.mate);
    final isAdvantage =
        (widget.pv.mate ?? 0) > 0 || widget.pv.evaluation > 0.05;
    final scoreColor =
        (widget.pv.mate ?? 0) != 0
            ? kPrimaryColor
            : (isAdvantage
                ? kWhiteColor
                : (widget.pv.evaluation < -0.05 ? kRedColor : kWhiteColor70));

    if (_cachedFen != widget.fen || _cachedMoves != widget.pv.moves) {
      _refreshCachedLine();
    }
    final displayLine = _cachedDisplayLine;

    final clickable = widget.onPlayUci != null && _firstUci != null;

    final movesUpToHover =
        (_hoveredTokenIndex == null ||
                _hoveredTokenIndex! >= _cachedTokens.length)
            ? const <String>[]
            : _cachedTokens[_hoveredTokenIndex!].ucisUpTo;

    final body = KeyedSubtree(
      key: _lineAnchorKey,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color:
              widget.rank == 1
                  ? (_hovered
                      ? kBlack2Color.withValues(alpha: 0.6)
                      : kBlack3Color)
                  : (_hovered ? kBlack3Color : Colors.transparent),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color:
                _hovered
                    ? kPrimaryColor.withValues(alpha: 0.4)
                    : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 56,
              child: Text(
                score,
                style: TextStyle(
                  color: scoreColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child:
                  _cachedTokens.isEmpty
                      ? Text(
                        displayLine,
                        maxLines: _expanded ? 4 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: kWhiteColor70,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      )
                      : _PvTokensLine(
                        tokens: _cachedTokens,
                        expanded: _expanded,
                        onPreviewToken: _previewToken,
                      ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: DesktopTooltip(
                message:
                    _expanded ? 'Collapse engine line' : 'Expand engine line',
                child: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: kWhiteColor70,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final preview = MoveHoverPreview(
      startingFen: widget.fen,
      movesUpToHover: movesUpToHover,
      enabled: _hovered && _cachedTokens.isNotEmpty,
      placement: MoveHoverPreviewPlacement.engineLine,
      placementAnchorKey: _lineAnchorKey,
      child: body,
    );

    // Subtle hover scale on PV rows (1.005) — too tiny to be a
    // distraction during the engine's high-frequency updates, but enough
    // to make the row feel like a real button when the user mouses
    // toward it. We don't track press here — these rows update many
    // times a second, and a press-down spring would conflict with the
    // ongoing redraws.
    return ClickCursor(
      enabled: clickable,
      child: MouseRegion(
        onEnter:
            (_) => setState(() {
              _hovered = true;
              _hoveredTokenIndex ??= _cachedTokens.isEmpty ? null : 0;
            }),
        onHover: (_) {
          if (_hoveredTokenIndex == null && _cachedTokens.isNotEmpty) {
            setState(() => _hoveredTokenIndex = 0);
          }
        },
        onExit:
            (_) => setState(() {
              _hovered = false;
              _hoveredTokenIndex = null;
            }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: clickable ? () => widget.onPlayUci!(_firstUci!) : null,
          onSecondaryTapUp:
              (details) => _showContextMenu(details.globalPosition),
          child: SingleMotionBuilder(
            value: clickable && _hovered ? 1.005 : 1.0,
            motion: DesktopMotion.hover,
            builder:
                (context, scale, child) => Transform.scale(
                  scale: scale,
                  filterQuality: FilterQuality.medium,
                  child: child,
                ),
            child: preview,
          ),
        ),
      ),
    );
  }
}

/// Tiny chip showing the current Stockfish search depth next to the
/// evaluation score. Lives in the side panel only — never on the board
/// surface — so analysis output stays out of the playing surface (#461).
class _DepthChip extends StatelessWidget {
  const _DepthChip({required this.depth, required this.isEvaluating});

  final int depth;
  final bool isEvaluating;

  @override
  Widget build(BuildContext context) {
    if (depth <= 0 && !isEvaluating) {
      return const SizedBox.shrink();
    }
    final visible = depth.clamp(0, 99).toInt();
    final label = visible > 0 ? 'd$visible' : '…';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kDividerColor),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: kLightGreyColor.withValues(alpha: isEvaluating ? 0.9 : 0.65),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

enum _PvAction { play, copySan, copyFirst, copyUci }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: kWhiteColor70),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: kWhiteColor, fontSize: 13)),
      ],
    );
  }
}

/// One-tap on/off toggle for engine analysis. Maps to the same
/// `showEngineAnalysis` switch the gear popover exposes, but lives where
/// users actually look for an engine switch — right next to the eval read-
/// out. Single global Stockfish process; toggling here pauses/resumes the
/// search for whichever board tab is focused (#461).
class _EngineQuickToggle extends ConsumerStatefulWidget {
  const _EngineQuickToggle({required this.enabled});

  final bool enabled;

  @override
  ConsumerState<_EngineQuickToggle> createState() => _EngineQuickToggleState();
}

class _EngineQuickToggleState extends ConsumerState<_EngineQuickToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final tooltip = enabled ? 'Pause engine' : 'Resume engine';
    final fg =
        enabled ? kPrimaryColor : (_hovered ? kWhiteColor : kWhiteColor70);
    final bg =
        enabled
            ? kPrimaryColor.withValues(alpha: _hovered ? 0.22 : 0.14)
            : (_hovered ? kBlack3Color : Colors.transparent);
    final border =
        enabled
            ? kPrimaryColor.withValues(alpha: 0.55)
            : (_hovered ? kWhiteColor.withValues(alpha: 0.20) : kDividerColor);

    Future<void> toggle() async {
      await ref
          .read(engineSettingsProviderNew.notifier)
          .toggleEngineAnalysis(!enabled);
    }

    return DesktopTooltip(
      message: tooltip,
      child: ClickCursor(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit:
              (_) => setState(() {
                _hovered = false;
                _pressed = false;
              }),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: toggle,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: SingleMotionBuilder(
              value: _pressed ? 0.97 : (_hovered ? 1.012 : 1.0),
              motion: _pressed ? DesktopMotion.tap : DesktopMotion.hover,
              builder:
                  (context, scale, child) => Transform.scale(
                    scale: scale,
                    filterQuality: FilterQuality.medium,
                    child: child,
                  ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 110),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: border),
                ),
                alignment: Alignment.center,
                child: Icon(
                  enabled
                      ? Icons.power_settings_new_rounded
                      : Icons.power_settings_new_outlined,
                  size: 14,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EngineNotReady extends StatelessWidget {
  const _EngineNotReady();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Engine off',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Open Settings → Engine to initialize Stockfish, '
            'or install via brew (macOS) / put on PATH.',
            style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _EnginePausedForReport extends StatelessWidget {
  const _EnginePausedForReport();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.all(16),
      alignment: Alignment.topLeft,
      child: const Text(
        'Live analysis paused while the game report runs.',
        style: TextStyle(color: kWhiteColor70, fontSize: 12, height: 1.4),
      ),
    );
  }
}

/// Per-token PV line model. Cached on `_PvLineState` and used by
/// [_PvTokensLine] so the hover preview can replay the cumulative line
/// without recomputing dartchess on every pointer move.
class _PvToken {
  const _PvToken({
    required this.san,
    required this.uci,
    required this.ucisUpTo,
  });

  final String san;
  final String uci;
  final List<String> ucisUpTo;
}

/// Renders the PV move list as a Wrap of SAN chips. Hovering a token updates
/// the row-owned preview without dispatching [onPlayUci].
class _PvTokensLine extends StatelessWidget {
  const _PvTokensLine({
    required this.tokens,
    required this.expanded,
    required this.onPreviewToken,
  });

  final List<_PvToken> tokens;
  final bool expanded;
  final ValueChanged<int> onPreviewToken;

  @override
  Widget build(BuildContext context) {
    final line = Wrap(
      spacing: 5,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < tokens.length; i++)
          MouseRegion(
            onEnter: (_) => onPreviewToken(i),
            child: Text(
              tokens[i].san,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                height: 1.35,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );

    if (expanded) return line;
    return SizedBox(height: 18, child: ClipRect(child: line));
  }
}

String _formatScore(double? evaluation, int? mate) {
  if (mate != null) {
    return mate > 0 ? '#$mate' : '#$mate';
  }
  if (evaluation == null) {
    return '—';
  }
  // Treat near-zero as exactly zero for display stability.
  final value = evaluation.abs() < 0.05 ? 0.0 : evaluation;
  if (value == 0.0) return '0.00';
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(2)}';
}
