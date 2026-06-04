import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' hide Board;
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/board_editor_pgn_import.dart';
import 'package:chessever/desktop/services/local_chess_drop_zone.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/services/play/play_from_here.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/opening_explorer_seed.dart';
import 'package:chessever/desktop/widgets/board_editor_import_chooser_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/desktop/widgets/desktop_play_from_here_button.dart';
import 'package:chessever/desktop/widgets/desktop_position_games_table.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/pressable_scale.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/screens/board_editor/board_editor_state.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/services/pgn_file_intake_service.dart';
import 'package:chessever/theme/app_theme.dart';

/// Desktop-native board editor pane.
///
/// Replaces the mobile-first [BoardEditorScreen] with a layout designed
/// for keyboard+mouse: a large board on the left and a compact control
/// rail on the right. All chrome uses forui per AGENTS.md §7.
class BoardEditorPane extends ConsumerStatefulWidget {
  const BoardEditorPane({super.key});

  @override
  ConsumerState<BoardEditorPane> createState() => _BoardEditorPaneState();
}

Future<String?> showBoardPositionSetupDialog(
  BuildContext context, {
  required WidgetRef ref,
  required String initialFen,
}) {
  ref.read(boardEditorProvider.notifier).loadFen(initialFen);
  return showDesktopModal<String>(
    context,
    title: 'Position Setup',
    maxWidth: 1160,
    maxHeight: 900,
    barrierDismissible: true,
    builder:
        (dialogContext) => BoardPositionSetupDialog(
          initialFen: initialFen,
          onApply: (fen) => Navigator.of(dialogContext).pop(fen),
          onCancel: () => Navigator.of(dialogContext).pop(),
        ),
  );
}

class BoardPositionSetupDialog extends ConsumerStatefulWidget {
  const BoardPositionSetupDialog({
    super.key,
    required this.initialFen,
    required this.onApply,
    required this.onCancel,
  });

  final String initialFen;
  final ValueChanged<String> onApply;
  final VoidCallback onCancel;

  @override
  ConsumerState<BoardPositionSetupDialog> createState() =>
      _BoardPositionSetupDialogState();
}

class _BoardPositionSetupDialogState
    extends ConsumerState<BoardPositionSetupDialog> {
  String? _validationError(BoardEditorState editorState) {
    bool hasWhiteKing = false;
    bool hasBlackKing = false;
    for (final piece in editorState.pieces.values) {
      if (piece.role == Role.king) {
        if (piece.color == Side.white) hasWhiteKing = true;
        if (piece.color == Side.black) hasBlackKing = true;
      }
    }
    if (!hasWhiteKing || !hasBlackKing) {
      return 'Position must include both kings.';
    }
    try {
      final setup = Setup.parseFen(editorState.fullFen);
      Chess.fromSetup(setup);
    } catch (_) {
      return 'Illegal position. Check king safety, side to move, and castling rights.';
    }
    return null;
  }

  void _showToast(String message, {bool error = false}) {
    if (!mounted) return;
    showDesktopToast(context, message, error: error);
  }

  Future<void> _pasteFen() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clipboard?.text;
    if (raw == null || raw.trim().isEmpty) {
      _showToast('Clipboard is empty');
      return;
    }
    final extracted = _extractFen(raw);
    if (extracted == null) {
      _showToast('Invalid FEN', error: true);
      return;
    }
    ref.read(boardEditorProvider.notifier).loadFen(extracted);
    _showToast('FEN pasted');
  }

  void _copyFen(String fen) {
    Clipboard.setData(ClipboardData(text: fen));
    _showToast('FEN copied to clipboard');
  }

  void _apply(BoardEditorState editorState) {
    final error = _validationError(editorState);
    if (error != null) {
      _showToast(error, error: true);
      return;
    }
    widget.onApply(editorState.fullFen);
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(boardEditorProvider);
    final boardSettings =
        ref.watch(boardSettingsProviderNew).valueOrNull ??
        const BoardSettingsNew();
    final validationError = _validationError(editorState);

    return SizedBox(
      width: 1140,
      height: 820,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ColoredBox(
                    color: kBlack3Color,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
                      child: Center(
                        child: _BoardWithEvalBar(
                          editorState: editorState,
                          boardSettings: boardSettings,
                          showEvalBar: false,
                        ),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1, color: kDividerColor),
                SizedBox(
                  width: 102,
                  child: _PositionSetupPieceRail(
                    boardSettings: boardSettings,
                    selectedPiece: editorState.selectedPiece,
                    isDeleteMode: editorState.isDeleteMode,
                    onSelectPiece:
                        (piece) => ref
                            .read(boardEditorProvider.notifier)
                            .selectPiece(piece),
                    onToggleDeleteMode:
                        () =>
                            ref
                                .read(boardEditorProvider.notifier)
                                .toggleDeleteMode(),
                  ),
                ),
                const VerticalDivider(width: 1, color: kDividerColor),
                SizedBox(
                  width: 300,
                  child: _PositionSetupModalInspector(
                    editorState: editorState,
                    onLastPawnMove:
                        (move) => ref
                            .read(boardEditorProvider.notifier)
                            .setLastPawnMove(move),
                    onMoveNumber:
                        (moveNumber) => ref
                            .read(boardEditorProvider.notifier)
                            .setFullmoves(moveNumber),
                    onSideToMove:
                        (side) => ref
                            .read(boardEditorProvider.notifier)
                            .setSideToMove(side),
                    onToggleCastling: ({
                      bool? whiteKingside,
                      bool? whiteQueenside,
                      bool? blackKingside,
                      bool? blackQueenside,
                    }) {
                      ref
                          .read(boardEditorProvider.notifier)
                          .toggleCastling(
                            whiteKingside: whiteKingside,
                            whiteQueenside: whiteQueenside,
                            blackKingside: blackKingside,
                            blackQueenside: blackQueenside,
                          );
                    },
                    onCopyFen: () => _copyFen(editorState.fullFen),
                    onPasteFen: _pasteFen,
                  ),
                ),
              ],
            ),
          ),
          const FDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Row(
              children: [
                DesktopDialogButton(
                  label: 'Reset',
                  onPress:
                      () => ref
                          .read(boardEditorProvider.notifier)
                          .loadFen(widget.initialFen),
                ),
                const SizedBox(width: 8),
                DesktopDialogButton(
                  label: 'Clear board',
                  onPress: () => ref.read(boardEditorProvider.notifier).clear(),
                ),
                const SizedBox(width: 12),
                if (validationError != null)
                  Expanded(
                    child: Text(
                      validationError,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kRedColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 12),
                DesktopDialogButton(label: 'Cancel', onPress: widget.onCancel),
                const SizedBox(width: 8),
                DesktopDialogButton(
                  label: 'OK',
                  tone: DesktopDialogButtonTone.primary,
                  onPress:
                      validationError == null
                          ? () => _apply(editorState)
                          : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BoardEditorPaneState extends ConsumerState<BoardEditorPane> {
  String? _analysisPgnOverride;
  String? _analysisPgnStartFen;
  String _analysisWhiteName = 'White';
  String _analysisBlackName = 'Black';
  GamesTourModel? _analysisGameOverride;

  String _fenPositionKey(String fen) =>
      fen.trim().split(RegExp(r'\s+')).take(4).join(' ');

  void _clearPgnOverride() {
    _analysisPgnOverride = null;
    _analysisPgnStartFen = null;
    _analysisWhiteName = 'White';
    _analysisBlackName = 'Black';
    _analysisGameOverride = null;
  }

  String? _analysisValidationError(BoardEditorState editorState) {
    bool hasWhiteKing = false;
    bool hasBlackKing = false;
    for (final piece in editorState.pieces.values) {
      if (piece.role == Role.king) {
        if (piece.color == Side.white) hasWhiteKing = true;
        if (piece.color == Side.black) hasBlackKing = true;
      }
    }
    if (!hasWhiteKing || !hasBlackKing) {
      return 'Position must include both kings before analysis.';
    }
    try {
      final setup = Setup.parseFen(editorState.fullFen);
      Chess.fromSetup(setup);
    } catch (_) {
      return 'Illegal position. Check king safety, side to move, and castling rights.';
    }
    return null;
  }

  void _showToast(String message, {bool error = false}) {
    if (!mounted) return;
    showDesktopToast(context, message, error: error);
  }

  void _onAnalyze() {
    final editorState = ref.read(boardEditorProvider);
    final validationError = _analysisValidationError(editorState);
    if (validationError != null) {
      _showToast(validationError, error: true);
      return;
    }

    final fen = editorState.fullFen;
    final usePgnOverride =
        _analysisPgnOverride != null &&
        _analysisPgnStartFen != null &&
        _fenPositionKey(_analysisPgnStartFen!) == _fenPositionKey(fen);

    final whiteName = usePgnOverride ? _analysisWhiteName : 'White';
    final blackName = usePgnOverride ? _analysisBlackName : 'Black';

    final pgn =
        usePgnOverride
            ? _analysisPgnOverride!
            : '[Event "Board Editor"]\n'
                '[Site "ChessEver"]\n'
                '[Date "${DateTime.now().toIso8601String().split('T')[0]}"]\n'
                '[White "$whiteName"]\n'
                '[Black "$blackName"]\n'
                '[Result "*"]\n'
                '[FEN "$fen"]\n'
                '[SetUp "1"]\n'
                '\n*';

    final importedGame =
        usePgnOverride
            ? _analysisGameOverride?.copyWith(pgn: pgn, fen: fen)
            : null;
    openBoardGameTab(
      ref,
      _boardTabArgsForEditorPgn(
        pgn: pgn,
        whiteName: whiteName,
        blackName: blackName,
        fenSeed: fen,
        importedGame: importedGame,
      ),
      reuseExisting: false,
      focus: true,
    );
  }

  void _onSearchGames() {
    final editorState = ref.read(boardEditorProvider);
    final fen = editorState.fullFen;
    final validationError = _analysisValidationError(editorState);
    if (validationError != null) {
      _showToast(validationError, error: true);
      return;
    }
    ref.read(openingExplorerSeedProvider.notifier).state = OpeningExplorerSeed(
      fen: fen,
      exactFenSearch: true,
    );
    ref
        .read(desktopTabsProvider.notifier)
        .navigateActive(TabKind.openingExplorer);
  }

  void _onPlayFromHere() {
    final editorState = ref.read(boardEditorProvider);
    final validationError = _analysisValidationError(editorState);
    if (validationError != null) {
      _showToast(validationError, error: true);
      return;
    }
    showPlayFromHereDialog(
      context,
      ref,
      seed: PlayFromHereSeed(fen: editorState.fullFen),
    );
  }

  Future<void> _pasteFen() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final raw = clipboard?.text;
    if (raw == null || raw.trim().isEmpty) {
      _showToast('Clipboard is empty');
      return;
    }
    final extracted = _extractFen(raw);
    if (extracted == null) {
      _showToast('Invalid FEN', error: true);
      return;
    }
    if (!mounted) return;
    setState(_clearPgnOverride);
    ref.read(boardEditorProvider.notifier).loadFen(extracted);
    _showToast('FEN pasted');
  }

  Future<void> _pastePgn() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final pgn = clipboard?.text?.trim();
    if (pgn == null || pgn.isEmpty) {
      _showToast('Clipboard is empty');
      return;
    }

    await _handlePgnImport(
      parseBoardEditorPgnText(pgn, sourceLabel: 'clipboard'),
      emptyMessage: 'Failed to parse PGN',
    );
  }

  Future<void> _openLocalFiles() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Open chess files in Board Editor',
      type: FileType.custom,
      allowedExtensions: localChessPickerExtensions,
      allowMultiple: true,
      withData: false,
      lockParentWindow: true,
    );
    if (result == null || result.files.isEmpty) return;
    final paths = result.files
        .map((file) => file.path)
        .whereType<String>()
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    if (paths.isEmpty) return;
    await _openLocalChessPaths(
      paths,
      sourceLabel: paths.length == 1 ? null : 'Board Editor files',
    );
  }

  Future<void> _openLocalFolder() async {
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Open chess folder in Board Editor',
      lockParentWindow: true,
    );
    if (directory == null || directory.isEmpty) return;
    await _openLocalChessPaths(<String>[directory]);
  }

  Future<void> _openLocalChessPaths(
    List<String> paths, {
    String? sourceLabel,
  }) async {
    try {
      final result = await scanBoardEditorLocalChessPaths(
        paths,
        sourceLabel: sourceLabel,
      );
      await _handlePgnImport(
        result,
        emptyMessage:
            result.legacyDatabaseShellCount > 0
                ? localChessUnsupportedFormatMessage
                : 'No playable PGN entries were found.',
      );
    } catch (e) {
      _showToast('Could not open local chess files: $e', error: true);
    }
  }

  Future<void> _handlePgnImport(
    BoardEditorPgnImportResult result, {
    required String emptyMessage,
  }) async {
    if (!mounted) return;
    if (!result.hasEntries) {
      _showToast(emptyMessage, error: true);
      return;
    }

    if (result.entries.length > 1) {
      final selected = await showBoardEditorImportChooserDialog(
        context: context,
        result: result,
      );
      if (!mounted || selected == null) return;
      _loadSinglePgnEntry(selected);
      return;
    }

    _loadSinglePgnEntry(result.entries.single);
  }

  void _loadSinglePgnEntry(BoardEditorPgnImportEntry entry) {
    final rawPgn = entry.rawPgn;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final gameId =
        entry.game.gameId.isEmpty ? 'editor_$timestamp' : entry.game.gameId;
    // Scanner produces light entries with empty mainlines. Re-parse the
    // single chosen PGN here so position-vs-game routing stays accurate.
    ChessGame parsedGame;
    try {
      parsedGame = ChessGame.fromPgn(gameId, rawPgn);
    } catch (_) {
      parsedGame = entry.game.copyWith(gameId: gameId);
    }
    final finalFen =
        parsedGame.mainline.isNotEmpty
            ? parsedGame.mainline.last.fen
            : parsedGame.startingFen;
    final importedGame = chessGameToImportedGamesTourModel(
      parsedGame,
    ).copyWith(gameId: gameId, pgn: rawPgn, fen: finalFen);

    setState(() {
      _analysisPgnOverride = rawPgn;
      _analysisPgnStartFen = finalFen;
      _analysisWhiteName = importedGame.whitePlayer.name;
      _analysisBlackName = importedGame.blackPlayer.name;
      _analysisGameOverride = importedGame;
    });

    ref.read(boardEditorProvider.notifier).loadFen(finalFen);

    if (!mounted) return;
    if (parsedGame.mainline.isNotEmpty) {
      ref.read(chessboardViewFromProviderNew.notifier).state =
          ChessboardView.tour;
      openBoardGameTab(
        ref,
        _boardTabArgsForEditorPgn(
          pgn: rawPgn,
          whiteName: importedGame.whitePlayer.name,
          blackName: importedGame.blackPlayer.name,
          fenSeed: finalFen,
          importedGame: importedGame,
        ),
        reuseExisting: false,
        focus: true,
      );
    } else {
      _showToast('Loaded position from PGN');
    }
  }

  void _copyFen(String fen) {
    Clipboard.setData(ClipboardData(text: fen));
    _showToast('FEN copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final editorState = ref.watch(boardEditorProvider);
    final boardSettingsAsync = ref.watch(boardSettingsProviderNew);
    final boardSettings =
        boardSettingsAsync.valueOrNull ?? const BoardSettingsNew();
    final validationError = _analysisValidationError(editorState);

    return LocalChessDropZone(
      onChessPathsDropped:
          (paths) => _openLocalChessPaths(
            paths,
            sourceLabel: 'Dropped Board Editor files',
          ),
      child: FTheme(
        data: FThemes.zinc.dark,
        child: ColoredBox(
          color: kBackgroundColor,
          child: ResizableSplitView(
            axis: Axis.horizontal,
            storageKey: 'board_editor.main',
            children: [
              SplitChild(
                minSize: 380,
                initialWeight: 0.46,
                label: 'Board',
                dismissible: false,
                child: _BoardWorkspace(
                  editorState: editorState,
                  boardSettings: boardSettings,
                  validationError: validationError,
                  onCopyFen: () => _copyFen(editorState.fullFen),
                  onAnalyze: _onAnalyze,
                  onOpenExplorer: _onSearchGames,
                  onPlayFromHere:
                      validationError == null ? _onPlayFromHere : null,
                ),
              ),
              SplitChild(
                minSize: 280,
                initialWeight: 0.28,
                label: 'Inspector',
                child: _EditorInspector(
                  editorState: editorState,
                  boardSettings: boardSettings,
                  validationError: validationError,
                  onReset: () {
                    setState(_clearPgnOverride);
                    ref.read(boardEditorProvider.notifier).reset();
                  },
                  onClear: () {
                    setState(_clearPgnOverride);
                    ref.read(boardEditorProvider.notifier).clear();
                  },
                  onLastPawnMove: (move) {
                    setState(_clearPgnOverride);
                    ref
                        .read(boardEditorProvider.notifier)
                        .setLastPawnMove(move);
                  },
                  onMoveNumber: (moveNumber) {
                    setState(_clearPgnOverride);
                    ref
                        .read(boardEditorProvider.notifier)
                        .setFullmoves(moveNumber);
                  },
                  onSideToMove: (side) {
                    setState(_clearPgnOverride);
                    ref.read(boardEditorProvider.notifier).setSideToMove(side);
                  },
                  onToggleCastling: ({
                    bool? whiteKingside,
                    bool? whiteQueenside,
                    bool? blackKingside,
                    bool? blackQueenside,
                  }) {
                    setState(_clearPgnOverride);
                    ref
                        .read(boardEditorProvider.notifier)
                        .toggleCastling(
                          whiteKingside: whiteKingside,
                          whiteQueenside: whiteQueenside,
                          blackKingside: blackKingside,
                          blackQueenside: blackQueenside,
                        );
                  },
                  onSelectPiece: (piece) {
                    setState(_clearPgnOverride);
                    ref.read(boardEditorProvider.notifier).selectPiece(piece);
                  },
                  onToggleDeleteMode: () {
                    setState(_clearPgnOverride);
                    ref.read(boardEditorProvider.notifier).toggleDeleteMode();
                  },
                  onCopyFen: () => _copyFen(editorState.fullFen),
                  onPasteFen: _pasteFen,
                  onPastePgn: _pastePgn,
                  onOpenLocalFiles: _openLocalFiles,
                  onOpenLocalFolder: _openLocalFolder,
                ),
              ),
              SplitChild(
                minSize: 260,
                initialWeight: 0.26,
                label: 'Games',
                child: _PositionGamesRail(
                  fen: editorState.fullFen,
                  enabled: validationError == null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Board workspace
// ─────────────────────────────────────────────────────────────────────────────

class _BoardWorkspace extends StatelessWidget {
  const _BoardWorkspace({
    required this.editorState,
    required this.boardSettings,
    required this.validationError,
    required this.onCopyFen,
    required this.onAnalyze,
    required this.onOpenExplorer,
    required this.onPlayFromHere,
  });

  final BoardEditorState editorState;
  final BoardSettingsNew boardSettings;
  final String? validationError;
  final VoidCallback onCopyFen;
  final VoidCallback onAnalyze;
  final VoidCallback onOpenExplorer;
  final VoidCallback? onPlayFromHere;

  @override
  Widget build(BuildContext context) {
    final sideLabel =
        editorState.sideToMove == Side.white
            ? 'White to move'
            : 'Black to move';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WorkspaceHeader(
          sideLabel: sideLabel,
          isValid: validationError == null,
          onCopyFen: onCopyFen,
          onAnalyze: onAnalyze,
          onOpenExplorer: onOpenExplorer,
          onPlayFromHere: onPlayFromHere,
        ),
        const FDivider(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: _BoardWithEvalBar(
                editorState: editorState,
                boardSettings: boardSettings,
              ),
            ),
          ),
        ),
        if (validationError != null) ...[
          const FDivider(),
          _InlineIssue(message: validationError!),
        ],
      ],
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.sideLabel,
    required this.isValid,
    required this.onCopyFen,
    required this.onAnalyze,
    required this.onOpenExplorer,
    required this.onPlayFromHere,
  });

  final String sideLabel;
  final bool isValid;
  final VoidCallback onCopyFen;
  final VoidCallback onAnalyze;
  final VoidCallback onOpenExplorer;
  final VoidCallback? onPlayFromHere;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 14, 12),
          child: Row(
            children: [
              _StatusDot(isValid: isValid),
              const SizedBox(width: 10),
              const Text(
                'Board Editor',
                style: TextStyle(
                  color: kWhiteColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 12),
                Text(
                  sideLabel,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const Spacer(),
              DesktopPlayFromHereButton(
                onPress: onPlayFromHere,
                label: compact ? 'Play' : 'Play from here',
              ),
              const SizedBox(width: 8),
              _EditorIconButton(
                message: 'Copy FEN',
                icon: Icons.copy_rounded,
                tone: _EditorButtonTone.ghost,
                onPress: onCopyFen,
              ),
              const SizedBox(width: 6),
              if (compact) ...[
                _EditorIconButton(
                  message: 'Open in Explorer',
                  icon: Icons.travel_explore_rounded,
                  tone: _EditorButtonTone.secondary,
                  onPress: onOpenExplorer,
                ),
                const SizedBox(width: 6),
                _EditorIconButton(
                  message: 'Analyze',
                  icon: Icons.play_arrow_rounded,
                  tone: _EditorButtonTone.primary,
                  onPress: onAnalyze,
                ),
              ] else ...[
                _EditorActionButton(
                  icon: Icons.travel_explore_rounded,
                  label: 'Explorer',
                  tone: _EditorButtonTone.secondary,
                  onPress: onOpenExplorer,
                ),
                const SizedBox(width: 8),
                _EditorActionButton(
                  icon: Icons.play_arrow_rounded,
                  label: 'Analyze',
                  tone: _EditorButtonTone.primary,
                  onPress: onAnalyze,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Board + Eval Bar
// ─────────────────────────────────────────────────────────────────────────────

class _BoardWithEvalBar extends ConsumerWidget {
  const _BoardWithEvalBar({
    required this.editorState,
    required this.boardSettings,
    this.showEvalBar = true,
  });

  final BoardEditorState editorState;
  final BoardSettingsNew boardSettings;
  final bool showEvalBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    double? evaluation;
    int? mate;
    bool isEvaluating = false;
    final fen = editorState.fullFen;

    if (showEvalBar && editorState.isEvaluatable) {
      final evalAsync = ref.watch(
        gameCardEvalWithStockfishFallbackProvider(fen),
      );
      evalAsync.when(
        data: (cloud) {
          final pv = cloud.pvs.firstOrNull;
          if (pv != null) {
            final normalized = _normalizePvToWhitePerspective(pv);
            evaluation = normalized.eval;
            if (normalized.isMate && normalized.mate != 0) {
              mate = normalized.mate;
            }
          }
        },
        loading: () => isEvaluating = true,
        error: (_, __) {},
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSize =
            constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
        final evalBarWidth = showEvalBar ? 24.0 : 0.0;
        final boardSize = maxSize - evalBarWidth;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showEvalBar) ...[
              if (editorState.isEvaluatable)
                SizedBox(
                  width: evalBarWidth,
                  height: boardSize,
                  child: DesktopEvalBar(
                    width: evalBarWidth,
                    height: boardSize,
                    evaluation: evaluation,
                    mate: mate,
                    isEvaluating: isEvaluating,
                    isFlipped: editorState.orientation == Side.black,
                    positionKey: fen,
                  ),
                )
              else
                SizedBox(width: evalBarWidth, height: boardSize),
            ],
            _EditorTapWrapper(
              boardSize: boardSize,
              orientation: editorState.orientation,
              pointerMode: editorState.pointerMode,
              pieces: editorState.pieces,
              onTapSquare: (square) {
                ref.read(boardEditorProvider.notifier).onTapSquare(square);
              },
              onSecondaryTapSquare: (square) {
                ref
                    .read(boardEditorProvider.notifier)
                    .onEditedSquareWithOppositeColor(square);
              },
              child: ChessboardEditor(
                size: boardSize,
                orientation: editorState.orientation,
                pieces: editorState.pieces,
                pointerMode: editorState.pointerMode,
                squareHighlights:
                    editorState.selectedDragSquare != null
                        ? IMap({
                          editorState.selectedDragSquare!: SquareHighlight(
                            details: boardSettings.colorScheme.selected,
                          ),
                        })
                        : const IMap.empty(),
                settings: ChessboardSettings(
                  colorScheme: boardSettings.colorScheme,
                  pieceAssets: boardSettings.pieceAssets,
                  enableCoordinates: true,
                  dragFeedbackScale: 2.0,
                  dragFeedbackOffset: const Offset(0.0, -1.0),
                ),
                onEditedSquare: (square) {
                  ref.read(boardEditorProvider.notifier).onEditedSquare(square);
                },
                onDroppedPiece: (origin, dest, piece) {
                  ref
                      .read(boardEditorProvider.notifier)
                      .onDroppedPiece(origin, dest, piece);
                },
                onDiscardedPiece: (square) {
                  ref
                      .read(boardEditorProvider.notifier)
                      .onDiscardedPiece(square);
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EditorTapWrapper extends StatefulWidget {
  const _EditorTapWrapper({
    required this.boardSize,
    required this.orientation,
    required this.pointerMode,
    required this.pieces,
    required this.onTapSquare,
    required this.onSecondaryTapSquare,
    required this.child,
  });

  final double boardSize;
  final Side orientation;
  final EditorPointerMode pointerMode;
  final Pieces pieces;
  final void Function(Square square) onTapSquare;
  final void Function(Square square) onSecondaryTapSquare;
  final Widget child;

  @override
  State<_EditorTapWrapper> createState() => _EditorTapWrapperState();
}

class _EditorTapWrapperState extends State<_EditorTapWrapper> {
  Offset? _pointerDownPos;
  Offset? _secondaryPointerDownPos;

  Square? _offsetToSquare(Offset offset) {
    final squareSize = widget.boardSize / 8;
    final x = (offset.dx / squareSize).floor();
    final y = (offset.dy / squareSize).floor();
    final orientX = widget.orientation == Side.black ? 7 - x : x;
    final orientY = widget.orientation == Side.black ? y : 7 - y;
    if (orientX >= 0 && orientX <= 7 && orientY >= 0 && orientY <= 7) {
      return Square.fromCoords(File(orientX), Rank(orientY));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return DesktopBoardHoverAffordance(
      size: widget.boardSize,
      pieces: widget.pieces,
      orientation: widget.orientation,
      enabled: widget.pointerMode == EditorPointerMode.drag,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton &&
              widget.pointerMode == EditorPointerMode.drag) {
            _pointerDownPos = event.localPosition;
          } else if (event.buttons == kSecondaryButton &&
              widget.pointerMode == EditorPointerMode.edit) {
            _secondaryPointerDownPos = event.localPosition;
          }
        },
        onPointerUp: (event) {
          final primaryDownPos = _pointerDownPos;
          final secondaryDownPos = _secondaryPointerDownPos;
          _pointerDownPos = null;
          _secondaryPointerDownPos = null;
          final downPos = primaryDownPos ?? secondaryDownPos;
          if (downPos == null) return;
          if (primaryDownPos != null &&
              widget.pointerMode != EditorPointerMode.drag) {
            return;
          }
          if (secondaryDownPos != null &&
              widget.pointerMode != EditorPointerMode.edit) {
            return;
          }
          final delta = (event.localPosition - downPos).distance;
          if (delta > widget.boardSize / 8 * 0.5) return;
          final square = _offsetToSquare(event.localPosition);
          if (square == null) return;
          if (secondaryDownPos != null) {
            widget.onSecondaryTapSquare(square);
          } else {
            widget.onTapSquare(square);
          }
        },
        onPointerCancel: (_) {
          _pointerDownPos = null;
          _secondaryPointerDownPos = null;
        },
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Inspector + position games rail
// ─────────────────────────────────────────────────────────────────────────────

class _PositionSetupModalInspector extends StatelessWidget {
  const _PositionSetupModalInspector({
    required this.editorState,
    required this.onLastPawnMove,
    required this.onMoveNumber,
    required this.onSideToMove,
    required this.onToggleCastling,
    required this.onCopyFen,
    required this.onPasteFen,
  });

  final BoardEditorState editorState;
  final ValueChanged<String> onLastPawnMove;
  final ValueChanged<int> onMoveNumber;
  final void Function(Side side) onSideToMove;
  final void Function({
    bool? whiteKingside,
    bool? whiteQueenside,
    bool? blackKingside,
    bool? blackQueenside,
  })
  onToggleCastling;
  final VoidCallback onCopyFen;
  final VoidCallback onPasteFen;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack2Color,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        child: SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _CompactInspectorSection(
                title: 'Castling',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const _SideGlyph(side: Side.white),
                        const SizedBox(width: 7),
                        Expanded(
                          child: _CastlingSymbolButton(
                            side: 'White',
                            label: 'O-O',
                            value: editorState.whiteKingsideCastle,
                            onChanged:
                                (v) => onToggleCastling(whiteKingside: v),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _CastlingSymbolButton(
                            side: 'White',
                            label: 'O-O-O',
                            value: editorState.whiteQueensideCastle,
                            onChanged:
                                (v) => onToggleCastling(whiteQueenside: v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const _SideGlyph(side: Side.black),
                        const SizedBox(width: 7),
                        Expanded(
                          child: _CastlingSymbolButton(
                            side: 'Black',
                            label: 'O-O',
                            value: editorState.blackKingsideCastle,
                            onChanged:
                                (v) => onToggleCastling(blackKingside: v),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _CastlingSymbolButton(
                            side: 'Black',
                            label: 'O-O-O',
                            value: editorState.blackQueensideCastle,
                            onChanged:
                                (v) => onToggleCastling(blackQueenside: v),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _CompactInspectorSection(
                title: 'Side to move',
                child: _SideToMoveToggle(
                  sideToMove: editorState.sideToMove,
                  onChanged: onSideToMove,
                ),
              ),
              const SizedBox(height: 8),
              _CompactInspectorSection(
                title: 'En passant',
                child: _PositionMetadataFields(
                  editorState: editorState,
                  onLastPawnMove: onLastPawnMove,
                  onMoveNumber: onMoveNumber,
                  showMoveNumber: false,
                ),
              ),
              const SizedBox(height: 8),
              _CompactInspectorSection(
                title: 'FEN',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _FenBlock(fen: editorState.fullFen, onCopyFen: onCopyFen),
                    const SizedBox(height: 7),
                    _EditorActionButton(
                      icon: Icons.content_paste_go_rounded,
                      label: 'Paste FEN',
                      tone: _EditorButtonTone.secondary,
                      fillWidth: true,
                      onPress: onPasteFen,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactInspectorSection extends StatelessWidget {
  const _CompactInspectorSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kDividerColor.withValues(alpha: 0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(9, 7, 9, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.55,
              ),
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

class _SideGlyph extends StatelessWidget {
  const _SideGlyph({required this.side});

  final Side side;

  @override
  Widget build(BuildContext context) {
    final isWhite = side == Side.white;
    return Semantics(
      label: isWhite ? 'White' : 'Black',
      child: SizedBox(
        width: 24,
        height: 30,
        child: Center(
          child: Container(
            width: 17,
            height: 17,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isWhite ? kWhiteColor : kBackgroundColor,
              border: Border.all(
                color:
                    isWhite
                        ? kBlack2Color.withValues(alpha: 0.65)
                        : kWhiteColor.withValues(alpha: 0.36),
                width: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CastlingSymbolButton extends StatelessWidget {
  const _CastlingSymbolButton({
    required this.side,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String side;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: value,
      label: '$side castling $label',
      child: PressableScale(
        pressedScale: 0.97,
        hoveredScale: 1.01,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(!value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    value
                        ? kPrimaryColor.withValues(alpha: 0.15)
                        : kBackgroundColor.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      value
                          ? kPrimaryColor.withValues(alpha: 0.72)
                          : kDividerColor,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: value ? kPrimaryColor : kWhiteColor70,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorInspector extends StatelessWidget {
  const _EditorInspector({
    required this.editorState,
    required this.boardSettings,
    required this.validationError,
    required this.onReset,
    required this.onClear,
    required this.onLastPawnMove,
    required this.onMoveNumber,
    required this.onSideToMove,
    required this.onToggleCastling,
    required this.onSelectPiece,
    required this.onToggleDeleteMode,
    required this.onCopyFen,
    required this.onPasteFen,
    required this.onPastePgn,
    required this.onOpenLocalFiles,
    required this.onOpenLocalFolder,
  });

  final BoardEditorState editorState;
  final BoardSettingsNew boardSettings;
  final String? validationError;
  final VoidCallback onReset;
  final VoidCallback onClear;
  final ValueChanged<String> onLastPawnMove;
  final ValueChanged<int> onMoveNumber;
  final void Function(Side) onSideToMove;
  final void Function({
    bool? whiteKingside,
    bool? whiteQueenside,
    bool? blackKingside,
    bool? blackQueenside,
  })
  onToggleCastling;
  final void Function(Piece?) onSelectPiece;
  final VoidCallback onToggleDeleteMode;
  final VoidCallback onCopyFen;
  final VoidCallback onPasteFen;
  final VoidCallback onPastePgn;
  final VoidCallback onOpenLocalFiles;
  final VoidCallback onOpenLocalFolder;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack2Color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RailHeader(
            icon: Icons.tune_rounded,
            title: 'Setup',
            trailing:
                validationError == null
                    ? const _HeaderBadge(label: 'Ready', accent: kPrimaryColor)
                    : const _HeaderBadge(label: 'Check', accent: kRedColor),
          ),
          const FDivider(),
          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InspectorSection(
                    title: 'Position',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _ToolbarButton(
                                icon: Icons.refresh_rounded,
                                label: 'Reset',
                                onPress: onReset,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _ToolbarButton(
                                icon: Icons.delete_sweep_outlined,
                                label: 'Clear',
                                tone: _EditorButtonTone.danger,
                                onPress: onClear,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _SideToMoveToggle(
                          sideToMove: editorState.sideToMove,
                          onChanged: onSideToMove,
                        ),
                        const SizedBox(height: 12),
                        _PositionMetadataFields(
                          editorState: editorState,
                          onLastPawnMove: onLastPawnMove,
                          onMoveNumber: onMoveNumber,
                        ),
                      ],
                    ),
                  ),
                  const FDivider(),
                  _InspectorSection(
                    title: 'Castling',
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _CastlingSwitch(
                                side: 'White',
                                flank: 'Kingside',
                                badge: 'K',
                                notation: 'O-O',
                                value: editorState.whiteKingsideCastle,
                                onChanged:
                                    (v) => onToggleCastling(whiteKingside: v),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _CastlingSwitch(
                                side: 'White',
                                flank: 'Queenside',
                                badge: 'Q',
                                notation: 'O-O-O',
                                value: editorState.whiteQueensideCastle,
                                onChanged:
                                    (v) => onToggleCastling(whiteQueenside: v),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _CastlingSwitch(
                                side: 'Black',
                                flank: 'Kingside',
                                badge: 'K',
                                notation: 'O-O',
                                value: editorState.blackKingsideCastle,
                                onChanged:
                                    (v) => onToggleCastling(blackKingside: v),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _CastlingSwitch(
                                side: 'Black',
                                flank: 'Queenside',
                                badge: 'Q',
                                notation: 'O-O-O',
                                value: editorState.blackQueensideCastle,
                                onChanged:
                                    (v) => onToggleCastling(blackQueenside: v),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const FDivider(),
                  _InspectorSection(
                    title: 'Pieces',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PieceRow(
                          color: Side.white,
                          pieceAssets: boardSettings.pieceAssets,
                          selectedPiece: editorState.selectedPiece,
                          isDeleteMode: editorState.isDeleteMode,
                          onSelectPiece: onSelectPiece,
                        ),
                        const SizedBox(height: 8),
                        _PieceRow(
                          color: Side.black,
                          pieceAssets: boardSettings.pieceAssets,
                          selectedPiece: editorState.selectedPiece,
                          isDeleteMode: editorState.isDeleteMode,
                          onSelectPiece: onSelectPiece,
                        ),
                        const SizedBox(height: 12),
                        _EditorActionButton(
                          icon: Icons.delete_outline_rounded,
                          label:
                              editorState.isDeleteMode
                                  ? 'Done deleting'
                                  : 'Delete mode',
                          tone: _EditorButtonTone.danger,
                          selected: editorState.isDeleteMode,
                          fillWidth: true,
                          onPress: onToggleDeleteMode,
                        ),
                      ],
                    ),
                  ),
                  const FDivider(),
                  _InspectorSection(
                    title: 'FEN',
                    child: _FenBlock(
                      fen: editorState.fullFen,
                      onCopyFen: onCopyFen,
                    ),
                  ),
                  const FDivider(),
                  _InspectorSection(
                    title: 'Import',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _EditorActionButton(
                                icon: Icons.content_paste_go_rounded,
                                label: 'Paste FEN',
                                tone: _EditorButtonTone.secondary,
                                fillWidth: true,
                                onPress: onPasteFen,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _EditorActionButton(
                                icon: Icons.upload_file_rounded,
                                label: 'Paste PGN',
                                tone: _EditorButtonTone.secondary,
                                fillWidth: true,
                                onPress: onPastePgn,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _EditorActionButton(
                                icon: Icons.file_open_outlined,
                                label: 'Open files',
                                tone: _EditorButtonTone.secondary,
                                fillWidth: true,
                                onPress: onOpenLocalFiles,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _EditorActionButton(
                                icon: Icons.folder_open_outlined,
                                label: 'Open folder',
                                tone: _EditorButtonTone.secondary,
                                fillWidth: true,
                                onPress: onOpenLocalFolder,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PositionGamesRail extends StatelessWidget {
  const _PositionGamesRail({required this.fen, required this.enabled});

  final String fen;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack2Color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _RailHeader(
            icon: Icons.table_rows_rounded,
            title: 'Position games',
            trailing: _HeaderBadge(label: 'FEN', accent: kPrimaryColor),
          ),
          const FDivider(),
          Expanded(
            child:
                enabled
                    ? DesktopPositionGamesTable(fen: fen, exactFenSearch: true)
                    : const _RailEmptyState(
                      icon: Icons.rule_rounded,
                      title: 'Position not searchable',
                      message: 'Add both kings and resolve the illegal setup.',
                    ),
          ),
        ],
      ),
    );
  }
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
      child: Row(
        children: [
          Icon(icon, size: 14, color: kPrimaryColor),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: kWhiteColor,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _InspectorSection extends StatelessWidget {
  const _InspectorSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: kLightGreyColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.65,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPress,
    this.tone = _EditorButtonTone.secondary,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPress;
  final _EditorButtonTone tone;

  @override
  Widget build(BuildContext context) {
    return _EditorActionButton(
      icon: icon,
      label: label,
      tone: tone,
      fillWidth: true,
      onPress: onPress,
    );
  }
}

class _SideToMoveToggle extends StatelessWidget {
  const _SideToMoveToggle({required this.sideToMove, required this.onChanged});

  final Side sideToMove;
  final void Function(Side) onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _EditorActionButton(
            icon: Icons.circle_outlined,
            label: 'W',
            selected: sideToMove == Side.white,
            fillWidth: true,
            onPress: () => onChanged(Side.white),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _EditorActionButton(
            icon: Icons.circle,
            label: 'B',
            selected: sideToMove == Side.black,
            fillWidth: true,
            onPress: () => onChanged(Side.black),
          ),
        ),
      ],
    );
  }
}

class _PositionMetadataFields extends StatefulWidget {
  const _PositionMetadataFields({
    required this.editorState,
    required this.onLastPawnMove,
    required this.onMoveNumber,
    this.showMoveNumber = true,
  });

  final BoardEditorState editorState;
  final ValueChanged<String> onLastPawnMove;
  final ValueChanged<int> onMoveNumber;
  final bool showMoveNumber;

  @override
  State<_PositionMetadataFields> createState() =>
      _PositionMetadataFieldsState();
}

class _PositionMetadataFieldsState extends State<_PositionMetadataFields> {
  late final TextEditingController _lastPawnMoveController;
  late final TextEditingController _moveNumberController;
  String? _lastPawnMoveError;

  @override
  void initState() {
    super.initState();
    _lastPawnMoveController = TextEditingController(
      text: _lastPawnMoveText(widget.editorState),
    );
    _moveNumberController = TextEditingController(
      text: widget.editorState.fullmoves.toString(),
    );
  }

  @override
  void didUpdateWidget(covariant _PositionMetadataFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState.epSquare != widget.editorState.epSquare ||
        oldWidget.editorState.sideToMove != widget.editorState.sideToMove) {
      final nextLastPawnMove = _lastPawnMoveText(widget.editorState);
      if (nextLastPawnMove != _lastPawnMoveController.text) {
        _lastPawnMoveController.text = nextLastPawnMove;
      }
    }
    if (oldWidget.editorState.fullmoves != widget.editorState.fullmoves) {
      final nextMoveNumber = widget.editorState.fullmoves.toString();
      if (nextMoveNumber != _moveNumberController.text) {
        _moveNumberController.text = nextMoveNumber;
      }
    }
  }

  @override
  void dispose() {
    _lastPawnMoveController.dispose();
    _moveNumberController.dispose();
    super.dispose();
  }

  String _lastPawnMoveText(BoardEditorState state) {
    final ep = state.epSquare;
    if (ep == null) return '';
    final name = ep.name;
    if (name.length != 2) return '';
    final rank = int.tryParse(name[1]);
    final destinationRank = switch (rank) {
      3 => 4,
      6 => 5,
      _ => null,
    };
    if (destinationRank == null) return '';
    return '${name[0]}$destinationRank';
  }

  String? _validateLastPawnMove(String raw) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    if (!RegExp(r'^[a-h][1-8]$').hasMatch(trimmed) &&
        !RegExp(r'^[a-h][a-h]$').hasMatch(trimmed)) {
      return 'Use en passant shorthand like ed, or a pawn square like e5.';
    }
    final lastMover =
        widget.editorState.sideToMove == Side.white ? Side.black : Side.white;
    if (RegExp(r'^[a-h][a-h]$').hasMatch(trimmed)) {
      final fromFile = trimmed.codeUnitAt(0);
      final capturedFile = trimmed.codeUnitAt(1);
      if ((fromFile - capturedFile).abs() != 1) {
        return 'Use adjacent files, e.g. ed.';
      }
      return null;
    }
    final rank = int.parse(trimmed[1]);
    final valid =
        (lastMover == Side.white && rank == 4) ||
        (lastMover == Side.black && rank == 5);
    if (!valid) {
      return widget.editorState.sideToMove == Side.white
          ? 'Black last pawn move must end on rank 5, e.g. e5.'
          : 'White last pawn move must end on rank 4, e.g. e4.';
    }
    return null;
  }

  void _submitLastPawnMove(String raw) {
    final error = _validateLastPawnMove(raw);
    setState(() => _lastPawnMoveError = error);
    if (error == null) widget.onLastPawnMove(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: FTextField(
                controller: _lastPawnMoveController,
                label: const Text('Last pawn move'),
                hint: 'ed',
                onChange: (raw) {
                  final error = _validateLastPawnMove(raw);
                  setState(() => _lastPawnMoveError = error);
                  if (error == null) widget.onLastPawnMove(raw);
                },
                onSubmit: _submitLastPawnMove,
              ),
            ),
            if (widget.showMoveNumber) ...[
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: FTextField(
                  controller: _moveNumberController,
                  label: const Text('Move no.'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChange: (raw) {
                    final n = int.tryParse(raw);
                    if (n != null && n > 0) widget.onMoveNumber(n);
                  },
                  onSubmit: (raw) {
                    final n = int.tryParse(raw);
                    if (n != null && n > 0) widget.onMoveNumber(n);
                  },
                ),
              ),
            ],
          ],
        ),
        if (_lastPawnMoveError != null) ...[
          const SizedBox(height: 6),
          Text(
            _lastPawnMoveError!,
            style: const TextStyle(
              color: kRedColor,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _CastlingSwitch extends StatelessWidget {
  const _CastlingSwitch({
    required this.side,
    required this.flank,
    required this.badge,
    required this.notation,
    required this.value,
    required this.onChanged,
  });

  final String side;
  final String flank;
  final String badge;
  final String notation;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = value ? kPrimaryColor : kLightGreyColor;
    final sideIsWhite = side == 'White';
    final badgeFg = sideIsWhite ? kBackgroundColor : kWhiteColor;
    final badgeBg = sideIsWhite ? kWhiteColor : kBlack2Color;

    return Semantics(
      button: true,
      toggled: value,
      label: '$side $flank castling $notation',
      child: PressableScale(
        pressedScale: 0.96,
        hoveredScale: 1.01,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(!value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              height: 44,
              padding: const EdgeInsets.fromLTRB(9, 7, 9, 7),
              decoration: BoxDecoration(
                color:
                    value
                        ? kPrimaryColor.withValues(alpha: 0.12)
                        : kBlack3Color.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color:
                      value
                          ? kPrimaryColor.withValues(alpha: 0.62)
                          : kDividerColor,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color:
                            sideIsWhite
                                ? kWhiteColor.withValues(alpha: 0.2)
                                : kWhiteColor.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: badgeFg,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          side,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: value ? kWhiteColor : kWhiteColor70,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          flank,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                value
                                    ? kWhiteColor.withValues(alpha: 0.78)
                                    : kLightGreyColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            height: 1,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          value
                              ? accent
                              : kBackgroundColor.withValues(alpha: 0.7),
                      border: Border.all(
                        color:
                            value
                                ? kPrimaryColor.withValues(alpha: 0.9)
                                : kLightGreyColor.withValues(alpha: 0.38),
                      ),
                    ),
                    child:
                        value
                            ? const Icon(
                              Icons.check_rounded,
                              size: 12,
                              color: kBackgroundColor,
                            )
                            : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FenBlock extends StatelessWidget {
  const _FenBlock({required this.fen, required this.onCopyFen});

  final String fen;
  final VoidCallback onCopyFen;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kBlack3Color.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: kDividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SelectableText(
                fen,
                style: const TextStyle(
                  color: kWhiteColor70,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.35,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _EditorIconButton(
              message: 'Copy FEN',
              icon: Icons.copy_rounded,
              tone: _EditorButtonTone.ghost,
              dense: true,
              onPress: onCopyFen,
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineIssue extends StatelessWidget {
  const _InlineIssue({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 15, color: kRedColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailEmptyState extends StatelessWidget {
  const _RailEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: kLightGreyColor),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderBadge extends StatelessWidget {
  const _HeaderBadge({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: accent,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.55,
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.isValid});

  final bool isValid;

  @override
  Widget build(BuildContext context) {
    final color = isValid ? kPrimaryColor : kRedColor;
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.34),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

enum _EditorButtonTone { primary, secondary, ghost, danger }

class _EditorActionButton extends StatelessWidget {
  const _EditorActionButton({
    required this.icon,
    required this.label,
    required this.onPress,
    this.tone = _EditorButtonTone.secondary,
    this.selected = false,
    this.fillWidth = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPress;
  final _EditorButtonTone tone;
  final bool selected;
  final bool fillWidth;

  @override
  Widget build(BuildContext context) {
    final button = FButton(
      style: _editorButtonStyle(tone: tone, selected: selected),
      onPress: onPress,
      mainAxisSize: fillWidth ? MainAxisSize.max : MainAxisSize.min,
      prefix: Icon(icon),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );

    return PressableScale(
      enabled: onPress != null,
      pressedScale: 0.96,
      hoveredScale: tone == _EditorButtonTone.primary ? 1.014 : 1.01,
      child: button,
    );
  }
}

class _EditorIconButton extends StatelessWidget {
  const _EditorIconButton({
    required this.message,
    required this.icon,
    required this.onPress,
    this.tone = _EditorButtonTone.secondary,
    this.dense = false,
  });

  final String message;
  final IconData icon;
  final VoidCallback? onPress;
  final _EditorButtonTone tone;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: message,
      child: PressableScale(
        enabled: onPress != null,
        pressedScale: 0.96,
        hoveredScale: 1.018,
        child: FButton.icon(
          style: _editorIconButtonStyle(
            tone: tone,
            selected: false,
            dense: dense,
          ),
          onPress: onPress,
          child: Icon(icon),
        ),
      ),
    );
  }
}

FBaseButtonStyle Function(FButtonStyle style) _editorButtonStyle({
  required _EditorButtonTone tone,
  required bool selected,
}) {
  final base = switch (tone) {
    _EditorButtonTone.primary => FButtonStyle.primary,
    _EditorButtonTone.secondary => FButtonStyle.outline,
    _EditorButtonTone.ghost => FButtonStyle.ghost,
    _EditorButtonTone.danger => FButtonStyle.outline,
  };

  return base(
    (style) => style.copyWith(
      decoration: _editorButtonDecoration(tone: tone, selected: selected),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            spacing: 7,
            textStyle: _editorButtonTextStyle(tone: tone, selected: selected),
            iconStyle: _editorButtonIconStyle(tone: tone, selected: selected),
          ),
    ),
  );
}

FBaseButtonStyle Function(FButtonStyle style) _editorIconButtonStyle({
  required _EditorButtonTone tone,
  required bool selected,
  required bool dense,
}) {
  final base = switch (tone) {
    _EditorButtonTone.primary => FButtonStyle.primary,
    _EditorButtonTone.secondary => FButtonStyle.outline,
    _EditorButtonTone.ghost => FButtonStyle.ghost,
    _EditorButtonTone.danger => FButtonStyle.outline,
  };

  return base(
    (style) => style.copyWith(
      decoration: _editorButtonDecoration(tone: tone, selected: selected),
      iconContentStyle:
          (content) => content.copyWith(
            padding: EdgeInsets.all(dense ? 7 : 9),
            iconStyle: _editorButtonIconStyle(tone: tone, selected: selected),
          ),
    ),
  );
}

FWidgetStateMap<BoxDecoration> _editorButtonDecoration({
  required _EditorButtonTone tone,
  required bool selected,
}) {
  final primary = tone == _EditorButtonTone.primary;
  final danger = tone == _EditorButtonTone.danger;
  final ghost = tone == _EditorButtonTone.ghost;
  final accent = danger ? kRedColor : kPrimaryColor;
  final active = selected || primary;

  return FWidgetStateMap({
    WidgetState.disabled: BoxDecoration(
      color:
          active
              ? accent.withValues(alpha: 0.22)
              : kBlack2Color.withValues(alpha: 0.40),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            active
                ? accent.withValues(alpha: 0.18)
                : kDividerColor.withValues(alpha: 0.50),
      ),
    ),
    WidgetState.hovered | WidgetState.pressed: BoxDecoration(
      color:
          primary
              ? const Color(0xFF22C4F4)
              : danger
              ? kRedColor.withValues(alpha: selected ? 0.24 : 0.18)
              : ghost
              ? kBlack3Color.withValues(alpha: 0.74)
              : (selected
                  ? kPrimaryColor.withValues(alpha: 0.18)
                  : kBlack3Color),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            primary
                ? kLightYellowColor.withValues(alpha: 0.60)
                : danger
                ? kRedColor.withValues(alpha: 0.58)
                : (selected
                    ? kPrimaryColor.withValues(alpha: 0.48)
                    : kWhiteColor.withValues(alpha: ghost ? 0.10 : 0.16)),
      ),
      boxShadow: [
        BoxShadow(
          color:
              primary
                  ? kPrimaryColor.withValues(alpha: 0.20)
                  : danger
                  ? kRedColor.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: ghost ? 0.10 : 0.24),
          blurRadius: primary ? 18 : 14,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    WidgetState.any: BoxDecoration(
      color:
          primary
              ? kPrimaryColor
              : danger
              ? kRedColor.withValues(alpha: selected ? 0.18 : 0.09)
              : selected
              ? kPrimaryColor.withValues(alpha: 0.13)
              : ghost
              ? Colors.transparent
              : kBlack3Color.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color:
            primary
                ? kPrimaryColor.withValues(alpha: 0.62)
                : danger
                ? kRedColor.withValues(alpha: selected ? 0.50 : 0.26)
                : selected
                ? kPrimaryColor.withValues(alpha: 0.38)
                : ghost
                ? kWhiteColor.withValues(alpha: 0.06)
                : kDividerColor.withValues(alpha: 0.88),
      ),
      boxShadow: [
        BoxShadow(
          color:
              primary
                  ? kPrimaryColor.withValues(alpha: 0.11)
                  : Colors.black.withValues(alpha: ghost ? 0 : 0.12),
          blurRadius: primary ? 12 : 9,
          offset: const Offset(0, 3),
        ),
      ],
    ),
  });
}

FWidgetStateMap<TextStyle> _editorButtonTextStyle({
  required _EditorButtonTone tone,
  required bool selected,
}) {
  final primary = tone == _EditorButtonTone.primary;
  final danger = tone == _EditorButtonTone.danger;
  final ghost = tone == _EditorButtonTone.ghost;

  return FWidgetStateMap({
    WidgetState.disabled: TextStyle(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.48)
              : kWhiteColor.withValues(alpha: 0.34),
      fontSize: 12,
      fontWeight: FontWeight.w800,
      height: 1,
      letterSpacing: 0,
    ),
    WidgetState.hovered | WidgetState.pressed: TextStyle(
      color: primary ? kBackgroundColor : kWhiteColor,
      fontSize: 12,
      fontWeight: FontWeight.w800,
      height: 1,
      letterSpacing: 0,
    ),
    WidgetState.any: TextStyle(
      color:
          primary
              ? kBackgroundColor
              : danger
              ? (selected ? kWhiteColor : kWhiteColor70)
              : selected
              ? kPrimaryColor
              : (ghost ? kWhiteColor70 : kWhiteColor),
      fontSize: 12,
      fontWeight: selected || primary ? FontWeight.w800 : FontWeight.w700,
      height: 1,
      letterSpacing: 0,
    ),
  });
}

FWidgetStateMap<IconThemeData> _editorButtonIconStyle({
  required _EditorButtonTone tone,
  required bool selected,
}) {
  final primary = tone == _EditorButtonTone.primary;
  final danger = tone == _EditorButtonTone.danger;

  return FWidgetStateMap({
    WidgetState.disabled: IconThemeData(
      color:
          primary
              ? kBackgroundColor.withValues(alpha: 0.48)
              : kWhiteColor.withValues(alpha: 0.34),
      size: 15,
    ),
    WidgetState.hovered | WidgetState.pressed: IconThemeData(
      color:
          primary
              ? kBackgroundColor
              : danger
              ? kRedColor
              : kPrimaryColor,
      size: 15,
    ),
    WidgetState.any: IconThemeData(
      color:
          primary
              ? kBackgroundColor
              : danger
              ? kRedColor
              : selected
              ? kPrimaryColor
              : kLightGreyColor,
      size: 15,
    ),
  });
}

FBaseButtonStyle Function(FButtonStyle style) _pieceButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.ghost(
    (style) => style.copyWith(
      decoration: _editorButtonDecoration(
        tone: _EditorButtonTone.ghost,
        selected: selected,
      ),
      contentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            spacing: 0,
          ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Piece Palette
// ─────────────────────────────────────────────────────────────────────────────

class _PositionSetupPieceRail extends StatelessWidget {
  const _PositionSetupPieceRail({
    required this.boardSettings,
    required this.selectedPiece,
    required this.isDeleteMode,
    required this.onSelectPiece,
    required this.onToggleDeleteMode,
  });

  final BoardSettingsNew boardSettings;
  final Piece? selectedPiece;
  final bool isDeleteMode;
  final ValueChanged<Piece?> onSelectPiece;
  final VoidCallback onToggleDeleteMode;

  static const _roles = [
    Role.pawn,
    Role.knight,
    Role.bishop,
    Role.rook,
    Role.queen,
    Role.king,
  ];

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: kBlack2Color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 3.0;
            const deleteExtent = 42.0;
            const deleteMargins = 28.0;
            final pieceExtent =
                ((constraints.maxHeight -
                            deleteExtent -
                            deleteMargins -
                            (gap * 10)) /
                        12)
                    .clamp(34.0, 46.0)
                    .toDouble();
            final pieceSize = (pieceExtent - 6).clamp(30.0, 40.0).toDouble();

            return Column(
              children: [
                _RailPieceGroup(
                  color: Side.black,
                  roles: _roles,
                  pieceAssets: boardSettings.pieceAssets,
                  selectedPiece: selectedPiece,
                  isDeleteMode: isDeleteMode,
                  pieceExtent: pieceExtent,
                  pieceSize: pieceSize,
                  gap: gap,
                  onSelectPiece: onSelectPiece,
                ),
                const Spacer(),
                _PaletteDeleteButton(
                  selected: isDeleteMode,
                  onPress: onToggleDeleteMode,
                ),
                const Spacer(),
                _RailPieceGroup(
                  color: Side.white,
                  roles: _roles.reversed,
                  pieceAssets: boardSettings.pieceAssets,
                  selectedPiece: selectedPiece,
                  isDeleteMode: isDeleteMode,
                  pieceExtent: pieceExtent,
                  pieceSize: pieceSize,
                  gap: gap,
                  onSelectPiece: onSelectPiece,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RailPieceGroup extends StatelessWidget {
  const _RailPieceGroup({
    required this.color,
    required this.roles,
    required this.pieceAssets,
    required this.selectedPiece,
    required this.isDeleteMode,
    required this.pieceExtent,
    required this.pieceSize,
    required this.gap,
    required this.onSelectPiece,
  });

  final Side color;
  final Iterable<Role> roles;
  final PieceAssets pieceAssets;
  final Piece? selectedPiece;
  final bool isDeleteMode;
  final double pieceExtent;
  final double pieceSize;
  final double gap;
  final ValueChanged<Piece?> onSelectPiece;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final role in roles)
          Padding(
            padding: EdgeInsets.only(bottom: role == roles.last ? 0 : gap),
            child: _RailPalettePiece(
              piece: Piece(color: color, role: role),
              pieceAssets: pieceAssets,
              isSelected:
                  !isDeleteMode &&
                  selectedPiece?.color == color &&
                  selectedPiece?.role == role,
              extent: pieceExtent,
              pieceSize: pieceSize,
              onTap: () => onSelectPiece(Piece(color: color, role: role)),
            ),
          ),
      ],
    );
  }
}

class _RailPalettePiece extends StatelessWidget {
  const _RailPalettePiece({
    required this.piece,
    required this.pieceAssets,
    required this.isSelected,
    required this.extent,
    required this.pieceSize,
    required this.onTap,
  });

  final Piece piece;
  final PieceAssets pieceAssets;
  final bool isSelected;
  final double extent;
  final double pieceSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pieceWidget = PieceWidget(
      piece: piece,
      size: pieceSize,
      pieceAssets: pieceAssets,
    );

    return Draggable<Piece>(
      data: piece,
      feedback: PieceDragFeedback(
        piece: piece,
        squareSize: 50,
        pieceAssets: pieceAssets,
      ),
      childWhenDragging: Opacity(opacity: 0.32, child: pieceWidget),
      child: PressableScale(
        pressedScale: 0.94,
        hoveredScale: 1.03,
        child: FButton(
          style: _pieceButtonStyle(selected: isSelected),
          onPress: onTap,
          mainAxisSize: MainAxisSize.min,
          child: SizedBox(
            width: extent,
            height: extent,
            child: Center(child: pieceWidget),
          ),
        ),
      ),
    );
  }
}

class _PaletteDeleteButton extends StatelessWidget {
  const _PaletteDeleteButton({required this.selected, required this.onPress});

  final bool selected;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return DesktopTooltip(
      message: selected ? 'Done deleting' : 'Delete pieces',
      child: PressableScale(
        pressedScale: 0.94,
        hoveredScale: 1.03,
        child: FButton.icon(
          style: _editorIconButtonStyle(
            tone: _EditorButtonTone.danger,
            selected: selected,
            dense: true,
          ),
          onPress: onPress,
          child: const Icon(Icons.close_rounded, size: 26),
        ),
      ),
    );
  }
}

class _PieceRow extends StatelessWidget {
  const _PieceRow({
    required this.color,
    required this.pieceAssets,
    required this.selectedPiece,
    required this.isDeleteMode,
    required this.onSelectPiece,
  });

  final Side color;
  final PieceAssets pieceAssets;
  final Piece? selectedPiece;
  final bool isDeleteMode;
  final void Function(Piece?) onSelectPiece;

  static const _roles = [
    Role.king,
    Role.queen,
    Role.rook,
    Role.bishop,
    Role.knight,
    Role.pawn,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final role in _roles) ...[
          if (role != _roles.first) const SizedBox(width: 6),
          Expanded(
            child: _PalettePiece(
              piece: Piece(color: color, role: role),
              pieceAssets: pieceAssets,
              isSelected:
                  !isDeleteMode &&
                  selectedPiece?.color == color &&
                  selectedPiece?.role == role,
              onTap: () => onSelectPiece(Piece(color: color, role: role)),
            ),
          ),
        ],
      ],
    );
  }
}

class _PalettePiece extends StatelessWidget {
  const _PalettePiece({
    required this.piece,
    required this.pieceAssets,
    required this.isSelected,
    required this.onTap,
  });

  final Piece piece;
  final PieceAssets pieceAssets;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pieceWidget = PieceWidget(
      piece: piece,
      size: 34,
      pieceAssets: pieceAssets,
    );

    return Draggable<Piece>(
      data: piece,
      feedback: PieceDragFeedback(
        piece: piece,
        squareSize: 44,
        pieceAssets: pieceAssets,
      ),
      childWhenDragging: Opacity(opacity: 0.32, child: pieceWidget),
      child: PressableScale(
        pressedScale: 0.96,
        hoveredScale: 1.018,
        child: FButton(
          style: _pieceButtonStyle(selected: isSelected),
          onPress: onTap,
          mainAxisSize: MainAxisSize.max,
          child: SizedBox(height: 38, child: Center(child: pieceWidget)),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────────────────────

({double eval, bool isMate, int mate}) _normalizePvToWhitePerspective(Pv pv) {
  final sign = pv.whitePerspective ? 1 : -1;
  final isMate = pv.isMate && pv.mate != null;
  final normalizedMate = (pv.mate ?? 0) * sign;
  final normalizedEval = (pv.cp * sign) / 100.0;
  return (eval: normalizedEval, isMate: isMate, mate: normalizedMate);
}

BoardTabGameArgs _boardTabArgsForEditorPgn({
  required String pgn,
  required String whiteName,
  required String blackName,
  required String fenSeed,
  GamesTourModel? importedGame,
}) {
  final white = importedGame?.whitePlayer;
  final black = importedGame?.blackPlayer;
  final effectiveWhite =
      white?.name.trim().isNotEmpty == true ? white!.name : whiteName;
  final effectiveBlack =
      black?.name.trim().isNotEmpty == true ? black!.name : blackName;

  return BoardTabGameArgs(
    pgn: pgn,
    label: '$effectiveWhite — $effectiveBlack',
    whiteName: effectiveWhite,
    blackName: effectiveBlack,
    whiteFederation: _playerFederation(white),
    blackFederation: _playerFederation(black),
    whiteTitle: white?.title ?? '',
    blackTitle: black?.title ?? '',
    whiteRating: white?.rating ?? 0,
    blackRating: black?.rating ?? 0,
    whiteFideId: white?.fideId,
    blackFideId: black?.fideId,
    fenSeed: fenSeed,
  );
}

String _playerFederation(PlayerCard? player) {
  if (player == null) return '';
  final country = player.countryCode.trim();
  if (country.isNotEmpty) return country;
  return player.federation.trim();
}

String? _extractFen(String input) {
  final trimmed = input.trim();
  if (_isValidFen(trimmed)) return trimmed;

  final pgnMatch = RegExp(r'\[\s*FEN\s+"([^"]+)"\s*\]').firstMatch(input);
  if (pgnMatch != null) {
    final inside = pgnMatch.group(1)!.trim();
    if (_isValidFen(inside)) return inside;
  }

  final unwrapped = _stripFenWrappers(trimmed);
  if (unwrapped != trimmed && _isValidFen(unwrapped)) return unwrapped;

  final boardPattern = RegExp(
    r'[rnbqkpRNBQKP1-8]+(?:/[rnbqkpRNBQKP1-8]+){7}'
    r'(?:\[[^\]]*\])?'
    r'(?:[\s_]+[^\s_]+){0,7}',
  );
  for (final match in boardPattern.allMatches(input)) {
    final candidate = match.group(0)!.trim();
    if (_isValidFen(candidate)) return candidate;
    final tokens = candidate.split(RegExp(r'[\s_]+'));
    for (var i = tokens.length - 1; i > 0; i--) {
      final reduced = tokens.take(i).join(' ');
      if (_isValidFen(reduced)) return reduced;
    }
  }
  return null;
}

bool _isValidFen(String text) {
  if (text.isEmpty) return false;
  try {
    Setup.parseFen(text);
    return true;
  } catch (_) {
    return false;
  }
}

String _stripFenWrappers(String s) {
  var current = s.trim();
  current = current.replaceFirst(
    RegExp(r'^\s*(?:FEN|Position|fen)\s*[:=]\s*', caseSensitive: false),
    '',
  );
  while (current.length >= 2) {
    final first = current[0];
    final last = current[current.length - 1];
    final isMatchingPair =
        (first == '"' && last == '"') ||
        (first == "'" && last == "'") ||
        (first == '`' && last == '`');
    if (!isMatchingPair) break;
    current = current.substring(1, current.length - 1).trim();
  }
  return current;
}
