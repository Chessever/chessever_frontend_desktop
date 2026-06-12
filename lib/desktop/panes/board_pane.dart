import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:chessground/chessground.dart' as cg;
import 'package:file_picker/file_picker.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:motor/motor.dart';

import 'package:chessever/desktop/panes/board_editor_pane.dart';
import 'package:chessever/desktop/panes/player_score_card_pane.dart';
import 'package:chessever/desktop/services/board_pgn_clipboard.dart';
import 'package:chessever/desktop/services/board_pgn_paste.dart';
import 'package:chessever/desktop/services/board_tab_pgn_resolver.dart';
import 'package:chessever/desktop/services/desktop_game_library_saver.dart';
import 'package:chessever/desktop/services/desktop_share_actions.dart';
import 'package:chessever/desktop/services/local_library_game_updater.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/active_board_shortcuts.dart';
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/board_annotations.dart';
import 'package:chessever/desktop/state/board_eval.dart';
import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/board_focus_mode.dart';
import 'package:chessever/desktop/state/board_keyboard_shortcuts.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/desktop/state/board_tab_sound_mute.dart';
import 'package:chessever/desktop/state/cloud_library_refresh.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/opening_explorer_seed.dart';
import 'package:chessever/desktop/state/pgn_intake.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/state/user_move_nags.dart';
import 'package:chessever/desktop/utils/mainline_annotation_index.dart';
import 'package:chessever/desktop/utils/notation_vertical_navigation.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game_navigator.dart';
import 'package:chessever/screens/chessboard/notation/notation_tree.dart'
    show exportGameToPgn;
import 'package:chessever/screens/chessboard/provider/game_pgn_stream_provider.dart';
import 'package:chessever/desktop/widgets/board_actions_popover.dart';
import 'package:chessever/desktop/services/play/play_from_here.dart';
import 'package:chessever/desktop/widgets/board_context_menu.dart';
import 'package:chessever/desktop/widgets/board_share_dialog.dart';
import 'package:chessever/desktop/widgets/board_annotation_layer.dart';
import 'package:chessever/desktop/widgets/board_wheel_navigation.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_chess_board.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/desktop/widgets/desktop_eval_bar.dart';
import 'package:chessever/desktop/widgets/desktop_modal.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/engine_panel.dart';
import 'package:chessever/desktop/widgets/engine_pv_arrow_palette.dart';
import 'package:chessever/desktop/widgets/event_games_table.dart';
import 'package:chessever/desktop/widgets/event_info_popover.dart';
import 'package:chessever/desktop/widgets/library/library_save_to_folder_dialog.dart';
import 'package:chessever/desktop/widgets/move_navigation_bar.dart';
import 'package:chessever/desktop/widgets/notation_ladder_view.dart';
import 'package:chessever/desktop/widgets/notation_opening_panel.dart';
import 'package:chessever/desktop/widgets/resizable_split_view.dart';
import 'package:chessever/desktop/widgets/variation_fork_chooser.dart';
import 'package:chessever/desktop/widgets/spring_tokens.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/e2e/e2e_ids.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/library/library_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/repository/supabase/game/game_repository.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/chessboard/provider/lichess_move_annotations_provider.dart';
import 'package:chessever/screens/library/providers/library_folders_provider.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/chessboard/widgets/nag_display.dart';
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardHasEventContextProvider,
        scoreCardPlayerProfileDataSourceProvider;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/widgets/game_card_wrapper/live_game_card_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_mode_provider.dart'
    show selectedBroadcastModelProvider;
import 'package:chessever/services/lichess_move_annotations_service.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/utils/audio_player_service.dart';
import 'package:chessever/utils/date_time_provider.dart';
import 'package:chessever/utils/pgn_clock_utils.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart'
    as fic;
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/broadcast_custom_scoring.dart';
import 'package:chessever/widgets/backfilled_federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

const _boardSizePreferenceKey = 'desktop_board_size_px_v1';
const _defaultDesktopBoardSize = 760.0;
const _minDesktopBoardSize = 300.0;
const _maxDesktopBoardSize = 1200.0;
const _focusButtonSize = 32.0;
const _resizeHandleSize = 22.0;
const _boardFocusBoardWeight = 0.60;
const _boardFocusRightPaneWeight = 0.40;
const _boardAreaPadding = 16.0;
const _boardFocusPadding = 10.0;
// When the user drags the board past this width the shell auto-enters
// focus mode (sidebar, top bar, tab strip, games rail, move-nav cluster all
// fold away) so the resize stays meaningful instead of just running out of
// room. Mirrors lichess' implicit-focus heuristic.
const _autoFocusBoardSizeThreshold = 760.0;
const _resizeFocusOvershoot = 12.0;

final _desktopBoardPlayerPhotoProvider = FutureProvider.autoDispose
    .family<String?, int>(
      (ref, fideId) => FidePhotoService.getPhotoUrlOrNull('$fideId'),
    );

@visibleForTesting
bool shouldShowDesktopBoardEvalBar(EngineSettings settings) {
  return settings.showEngineAnalysis && settings.showEngineGauge;
}

@visibleForTesting
bool shouldEnterBoardFocusAfterResize({
  required double requestedSize,
  required bool grewPastResizeLimit,
  required bool isAlreadyFocused,
}) {
  if (isAlreadyFocused) return false;
  return grewPastResizeLimit || requestedSize >= _autoFocusBoardSizeThreshold;
}

@visibleForTesting
bool shouldApplyEmptyBoardArgsSeed({
  required bool hasRestoredSession,
  required bool hasCurrentMoves,
  required bool dirtySinceLoad,
  required String? loadedFrom,
}) {
  if (!hasRestoredSession) return true;
  if (hasCurrentMoves || dirtySinceLoad) return false;
  final source = loadedFrom?.trim();
  return source == null || source.isEmpty;
}

bool shouldConfirmBoardTabCloseForLocalNotationEdits({
  required bool dirtySinceLoad,
  required String currentPgn,
  required String? lastAppliedPgn,
}) {
  if (!dirtySinceLoad) return false;
  final current = currentPgn.trim();
  final applied = lastAppliedPgn?.trim();
  if (applied == null || applied.isEmpty) return current.isNotEmpty;
  return current != applied;
}

@visibleForTesting
bool shouldPersistHydratedBoardTabPgn({
  required String hydratedTabId,
  required BoardTabGameArgs? currentArgs,
  required String expectedGameId,
}) {
  final tabId = hydratedTabId.trim();
  final currentGameId = currentArgs?.gameId?.trim();
  final expected = expectedGameId.trim();
  return tabId.isNotEmpty &&
      currentArgs != null &&
      currentGameId != null &&
      currentGameId.isNotEmpty &&
      currentGameId == expected;
}

@visibleForTesting
bool shouldApplyHydratedBoardTabPgn({
  required String? activeTabId,
  required String hydratedTabId,
}) {
  return activeTabId != null && activeTabId == hydratedTabId;
}

@visibleForTesting
bool shouldPlaySoundForBoardMove({
  required bool soundGateAllows,
  bool suppressSound = false,
}) {
  return soundGateAllows && !suppressSound;
}

@visibleForTesting
double desktopBoardResizeDragDelta(Offset offset) {
  // Use the dominant magnitude for the bottom-right grip. When axes disagree
  // (right+up or left+down), horizontal intent wins so rightward grow-drags
  // cannot be cancelled by upward pointer drift.
  if (offset.dx == 0) return offset.dy;
  if (offset.dy == 0) return offset.dx;
  final magnitude = math.max(offset.dx.abs(), offset.dy.abs());
  final horizontalSign = offset.dx.isNegative ? -1.0 : 1.0;
  if (offset.dx.isNegative != offset.dy.isNegative) {
    return magnitude * horizontalSign;
  }
  return magnitude * (offset.dy.isNegative ? -1.0 : 1.0);
}

@visibleForTesting
({
  bool hasHeaders,
  double topRowHeight,
  double bottomRowHeight,
  double headerGapTotal,
  double outerPadding,
})
computeBoardAreaChromeMetrics({
  required bool focusMode,
  required bool hasPlayerInfo,
}) {
  final hasHeaders = focusMode || hasPlayerInfo;
  final topRowHeight = hasHeaders ? _BoardArea.headerHeight : _focusButtonSize;
  final bottomRowHeight =
      hasHeaders ? _BoardArea.headerHeight : _resizeHandleSize;
  return (
    hasHeaders: hasHeaders,
    topRowHeight: topRowHeight,
    bottomRowHeight: bottomRowHeight,
    headerGapTotal: _BoardArea.headerGap * 2,
    outerPadding: focusMode ? _boardFocusPadding : _boardAreaPadding,
  );
}

/// Self-contained desktop board pane.
///
/// Holds its own move history (a `Position` per ply plus the SAN move that
/// produced it) so the user can play moves freely with mouse or keyboard
/// and step through them with the arrow bar / arrow keys. This pane is the
/// drag-to-play demo asked for; it stays standalone so subsequent
/// iterations can replace it with a wrapper around the live broadcast
/// state without breaking shell navigation.
///
/// Why not reuse the mobile screen directly: that screen is 14k lines and
/// hard-codes `PieceShiftMethod.tapTwoSquares` plus PageView swipes. Per
/// `CLAUDE.md`, desktop wraps and replaces, it does not edit mobile
/// widgets in place.
class BoardPane extends HookConsumerWidget {
  const BoardPane({super.key, this.tabId});

  final String? tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeTabId =
        tabId ?? ref.watch(desktopTabsProvider.select((s) => s.activeId));
    final restoredSession =
        activeTabId == null
            ? null
            : ref.read(boardPaneSessionByTabIdProvider)[activeTabId];
    final boardArgs =
        activeTabId == null
            ? null
            : ref.watch(
              boardTabGameArgsByTabIdProvider.select((m) => m[activeTabId]),
            );
    final boardExplorerScope =
        activeTabId == null
            ? null
            : ref.watch(
              boardExplorerScopeByTabIdProvider.select((m) => m[activeTabId]),
            );

    // Source of truth for the analysis tree. `chessGame` carries the
    // mainline + sublines parsed from the most recent PGN (or grown by
    // the user playing moves on the board); `pointer` indexes into it
    // with the same scheme as `ChessGameNavigatorState.movePointer` —
    // `[]` is the start position, `[i]` mainline move i, `[i, v, m, …]`
    // the m-th move of variation v branching off mainline[i], etc.
    //
    // Everything else the build needs (current `Position`, the active
    // line of `_Ply`s, the cursor inside it, `lineUcis` for the opening
    // explorer) is derived from these two each frame so the ladder, the
    // board, the engine, and the eval bar can never disagree.
    final chessGame = useState<ChessGame>(
      restoredSession?.game ?? _emptyChessGame,
    );
    final pointer = useState<ChessMovePointer>(
      restoredSession?.pointer ?? const <int>[],
    );
    // Holds the pawn move chessground deferred for promotion. While
    // non-null, chessground renders the piece-picker overlay; clearing
    // it (via the picker callback below) closes the overlay. The board
    // *position* is intentionally not advanced until the user picks —
    // mobile uses the same staging pattern.
    final promotionMove = useState<NormalMove?>(null);
    final flipped = useState<bool>(
      restoredSession?.flipped ?? boardArgs?.initialBoardFlipped ?? false,
    );
    final autoReplay = useState<bool>(false);
    final focusNode = useFocusNode();
    final explorerPreviewUci = useState<String?>(null);
    final explorerPreviewLine = useState<List<String>>(const <String>[]);
    final explorerPreviewLineStep = useState<int>(0);
    final explorerPreviewLineAutoplay = useState<bool>(true);
    final explorerPreviewSoundKey = useRef<String?>(null);
    final loadedFrom = useState<String?>(restoredSession?.loadedFrom);
    final pgnHeaders = useState<Map<String, String>>(
      restoredSession?.pgnHeaders ?? const {},
    );
    // De-dupes Realtime echoes and lets the activeGameId-reset useEffect
    // know whether a fresh PGN has already landed for the new game id.
    final lastAppliedPgn = useRef<String?>(restoredSession?.lastAppliedPgn);
    final lastAppliedGameId = useRef<String?>(
      restoredSession?.lastAppliedGameId,
    );
    final lastAppliedInitialFenKey = useRef<String?>(
      restoredSession?.lastAppliedInitialFenKey,
    );
    final boardTabPgnHydrationToken = useRef<int>(0);
    final boardSessionWriteToken = useRef<int>(0);
    final dirtySinceLoad = useState<bool>(
      restoredSession?.dirtySinceLoad ?? false,
    );
    final undoStack = useRef<List<BoardUndoSnapshot>>(
      List<BoardUndoSnapshot>.of(
        restoredSession?.undoStack ?? const <BoardUndoSnapshot>[],
      ),
    );
    final latestBoardActionInvoker =
        useRef<bool Function(BoardActionKey action)?>(null);
    // Live-game "new move arrived" indicator. Set to true inside [applyPgn]
    // when a broadcast tick grows the mainline AND the user is not at the
    // tip — i.e. they are exploring an earlier move. Reset when the user
    // navigates back to the tip via any path (button, arrow keys, ladder
    // click, the floating "Jump to live" pill below the board).
    final hasUnseenMoves = useState<bool>(
      restoredSession?.hasUnseenMoves ?? false,
    );
    final notationScrollController = useScrollController();
    final visibleNotationMoveOrderController =
        useMemoized<ValueNotifier<List<ChessMovePointer>>>(
          () =>
              ValueNotifier<List<ChessMovePointer>>(const <ChessMovePointer>[]),
          const [],
        );
    useEffect(() => visibleNotationMoveOrderController.dispose, const []);
    final rightRailAnalysisKey = useMemoized(GlobalKey.new, const []);
    // Controller for the outer board pane split — used so the in-pane
    // close button on the left games rail can collapse the rail itself.
    final mainSplitController = useMemoized<ResizableSplitViewController>(
      () => ResizableSplitViewController(),
      const [],
    );
    final boardFocusMode = ref.watch(boardFocusModeProvider);
    final boardSizePreference = useState<double?>(null);
    final lastPersistedBoardSize = useRef<int?>(null);
    final boardResizeHitSplitLimit = useRef<bool>(false);
    useEffect(() {
      var disposed = false;
      AppDatabase.instance.getInt(_boardSizePreferenceKey).then((value) {
        if (disposed || value == null) return;
        final clamped =
            value
                .clamp(
                  _minDesktopBoardSize.round(),
                  _maxDesktopBoardSize.round(),
                )
                .toDouble();
        boardSizePreference.value = clamped;
        lastPersistedBoardSize.value = clamped.round();
      });
      return () => disposed = true;
    }, const []);
    void setBoardSizePreference(double? size) {
      if (size == null) {
        boardSizePreference.value = null;
        lastPersistedBoardSize.value = null;
        unawaited(AppDatabase.instance.remove(_boardSizePreferenceKey));
        return;
      }
      boardSizePreference.value =
          size.clamp(_minDesktopBoardSize, _maxDesktopBoardSize).toDouble();
    }

    void persistBoardSizePreference({bool grewPastResizeLimit = false}) {
      final size = boardSizePreference.value;
      if (size == null) return;
      final rounded = size.round();
      if (lastPersistedBoardSize.value != rounded) {
        lastPersistedBoardSize.value = rounded;
        unawaited(
          AppDatabase.instance.setInt(_boardSizePreferenceKey, rounded),
        );
      }
      // Crossing the threshold on grip-release latches the shell into
      // focus mode (sidebar, top bar, tab strip, games rail, nav cluster
      // all fold). Triggering on release — not mid-drag — keeps the
      // resize handle mounted for the full drag gesture.
      if (shouldEnterBoardFocusAfterResize(
        requestedSize: size,
        grewPastResizeLimit: grewPastResizeLimit,
        isAlreadyFocused: ref.read(boardFocusModeProvider),
      )) {
        ref.read(boardFocusModeProvider.notifier).state = true;
      }
    }

    // When focus mode flips on, reset the board/right-pane split to the
    // fullscreen default. postFrameCallback because the split-view rebuild
    // that drops the games rail must land before index 0 can be targeted.
    useEffect(() {
      if (!boardFocusMode) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        mainSplitController.setFraction(
          0,
          _boardFocusBoardWeight,
          persist: false,
        );
      });
      return null;
    }, [boardFocusMode]);

    // Layout-mode for the notation pane is persisted in boardSettings so
    // the Settings pane switch and the Tab shortcut share state and
    // survive restarts. Controller mirrors the provider value for the
    // notation view; writes go through the notifier.
    final notationInline = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.notationInline ??
            const BoardSettingsNew().notationInline,
      ),
    );
    final notationLayoutController = useMemoized(
      () => ValueNotifier<NotationLayoutMode>(
        notationInline ? NotationLayoutMode.inline : NotationLayoutMode.ladder,
      ),
      const <Object?>[],
    );
    final notationVariationCollapseController = useMemoized(
      NotationVariationCollapseController.new,
      const <Object?>[],
    );
    useEffect(() {
      notationLayoutController.value =
          notationInline
              ? NotationLayoutMode.inline
              : NotationLayoutMode.ladder;
      return null;
    }, [notationInline]);
    useEffect(() {
      return notationLayoutController.dispose;
    }, [notationLayoutController]);
    final notationUseFigurine = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.useFigurine ?? const BoardSettingsNew().useFigurine,
      ),
    );
    final showMoveNavigation = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.showMoveNavigation ??
            const BoardSettingsNew().showMoveNavigation,
      ),
    );
    final notationPieceAssets = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.pieceAssets ?? const BoardSettingsNew().pieceAssets,
      ),
    );

    final latestPgnImport = ref.watch(pgnIntakeProvider);
    final legacyActiveGameId = ref.watch(
      tournamentGamesProvider.select((s) => s?.activeGameId),
    );
    final legacyHasGameRail = ref.watch(
      tournamentGamesProvider.select((s) => s?.games.isNotEmpty ?? false),
    );
    final hasLocalGameRail =
        (boardArgs?.eventGames.isNotEmpty ?? false) ||
        (boardArgs?.routeGames.isNotEmpty ?? false) ||
        (boardArgs?.databaseGames.isNotEmpty ?? false);
    final hasGameRail =
        hasLocalGameRail || (boardArgs == null && legacyHasGameRail);

    // Prefer the active tab's own game id. For legacy flows that still go
    // through `pgnIntakeProvider`, use the import's game id when present.
    // A detached file/library PGN has `gameId == null`; in that case do not
    // accidentally subscribe to or merge with a stale global tournament id.
    final activeGameId =
        boardArgs != null
            ? boardArgs.gameId
            : (latestPgnImport == null
                ? legacyActiveGameId
                : latestPgnImport.gameId);
    final boardRenderKey = _boardRenderKey(
      activeTabId: activeTabId,
      activeGameId: activeGameId,
      boardArgs: boardArgs,
      latestPgnImport: latestPgnImport,
      lastAppliedGameId: lastAppliedGameId.value,
      lastAppliedPgn: lastAppliedPgn.value,
    );

    useEffect(
      () {
        final token = ++boardSessionWriteToken.value;
        final tabId = activeTabId;
        if (tabId == null) return null;
        final session = BoardPaneSession(
          game: chessGame.value,
          pointer: List<int>.unmodifiable(pointer.value),
          pgnHeaders: Map<String, String>.unmodifiable(pgnHeaders.value),
          flipped: flipped.value,
          loadedFrom: loadedFrom.value,
          lastAppliedPgn: lastAppliedPgn.value,
          lastAppliedGameId: lastAppliedGameId.value,
          lastAppliedInitialFenKey: lastAppliedInitialFenKey.value,
          dirtySinceLoad: dirtySinceLoad.value,
          hasUnseenMoves: hasUnseenMoves.value,
          undoStack: List<BoardUndoSnapshot>.unmodifiable(undoStack.value),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted || token != boardSessionWriteToken.value) {
            return;
          }
          ref
              .read(boardPaneSessionByTabIdProvider.notifier)
              .put(tabId, session);
        });
        return null;
      },
      [
        activeTabId,
        chessGame.value,
        pointer.value,
        pgnHeaders.value,
        flipped.value,
        loadedFrom.value,
        dirtySinceLoad.value,
        hasUnseenMoves.value,
      ],
    );

    // We watch `activeGameId` here rather than after the listeners so
    // applyPgn can sync `lastAppliedGameId` to it. Without that sync, the
    // useEffect below races with the pgnIntake listener and stomps the
    // freshly-replayed tree back to the initial position right after the
    // PGN was applied — surfaced as "no moves played" when tapping a
    // finished or live game card.
    void applyPgn(String pgn, {required String origin, String? gameId}) {
      final trimmed = pgn.trim();
      if (trimmed.isEmpty) return;
      final initialFenKey = _nullableFenPositionKey(boardArgs?.initialFen);
      final previousInitialFenKey = lastAppliedInitialFenKey.value;
      if (trimmed == lastAppliedPgn.value &&
          initialFenKey == previousInitialFenKey) {
        return;
      }
      final ChessGame parsed;
      try {
        parsed = ChessGame.fromPgn('', trimmed);
      } catch (e) {
        // Silent failure swallows the empty-notation bug if a malformed
        // PGN ever lands here (e.g. truncated row, corrupted stream
        // payload). Surface it in debug builds so we can spot which
        // game is poisoning the tab; release builds keep the previous
        // best-effort behaviour and leave the board on its prior state.
        if (kDebugMode) {
          debugPrint(
            'BoardPane.applyPgn parse failed [$origin gameId=$gameId]: $e',
          );
        }
        return;
      }

      final result = (parsed.metadata['Result']?.toString() ?? '').trim();
      final isLive = result.isEmpty || result == '*';
      // Finished games: extending the mainline is what users expect when
      // they play moves at the tip. Live games: never extend mainline —
      // the live feed owns it; user-played moves at the tip create new
      // sub-variations and the mainline keeps tracking the broadcast.
      final updatedMetadata = Map<String, dynamic>.of(parsed.metadata);
      void putIfMissing(String key, Object? value) {
        final text = value?.toString().trim() ?? '';
        if (text.isEmpty) return;
        final current = updatedMetadata[key]?.toString().trim() ?? '';
        if (current.isEmpty || current == '?') {
          updatedMetadata[key] = text;
        }
      }

      final tabArgs = boardArgs;
      if (tabArgs != null &&
          (gameId == null ||
              tabArgs.gameId == null ||
              tabArgs.gameId == gameId)) {
        putIfMissing('White', tabArgs.whiteName);
        putIfMissing('Black', tabArgs.blackName);
        putIfMissing('WhiteFed', tabArgs.whiteFederation);
        putIfMissing('BlackFed', tabArgs.blackFederation);
        putIfMissing('WhiteTitle', tabArgs.whiteTitle);
        putIfMissing('BlackTitle', tabArgs.blackTitle);
        if (tabArgs.whiteFideId != null && tabArgs.whiteFideId! > 0) {
          putIfMissing('WhiteFideId', tabArgs.whiteFideId);
        }
        if (tabArgs.blackFideId != null && tabArgs.blackFideId! > 0) {
          putIfMissing('BlackFideId', tabArgs.blackFideId);
        }
        if (tabArgs.whiteRating > 0) {
          putIfMissing('WhiteElo', tabArgs.whiteRating);
        }
        if (tabArgs.blackRating > 0) {
          putIfMissing('BlackElo', tabArgs.blackRating);
        }
      }
      updatedMetadata[ChessGame.metadataAllowMainlineExtensionKey] = !isLive;
      updatedMetadata[ChessGame.metadataIsLiveKey] = isLive;
      final freshGame = parsed.copyWith(metadata: updatedMetadata);

      final oldGame = chessGame.value;
      final oldPointer = pointer.value;
      final oldMainlineLen = oldGame.mainline.length;
      final wasAtMainlineTip =
          oldPointer.length == 1 &&
          oldMainlineLen > 0 &&
          oldPointer.first == oldMainlineLen - 1;

      // Merge user-grown variations into broadcast updates so the same
      // game's PGN tick can't wipe out sub-lines the user just added.
      // Detached drops (drag-drop a `.pgn` file, no `gameId`) are
      // genuinely new games — those replace the tree wholesale.
      final game =
          (gameId != null && oldMainlineLen > 0)
              ? _mergeBroadcastUpdate(oldGame, freshGame)
              : freshGame;

      final keepLocalEdits =
          gameId != null && oldMainlineLen > 0 && dirtySinceLoad.value;
      dirtySinceLoad.value = keepLocalEdits;
      lastAppliedPgn.value = trimmed;
      lastAppliedInitialFenKey.value = initialFenKey;
      if (gameId != null) lastAppliedGameId.value = gameId;
      chessGame.value = game;
      pgnHeaders.value = game.metadata.map(
        (k, v) => MapEntry(k, v?.toString() ?? ''),
      );
      loadedFrom.value = origin;

      // Pointer placement on PGN reload:
      //  - first apply for this tree → live games jump to the tip so the
      //    user sees the current position; finished games stay at the root
      //    so the user can play through from the beginning. Detected by
      //    `oldMainlineLen == 0` so subsequent live updates don't yank a
      //    user who has navigated back to the start.
      //  - root → root (user was looking at the start; respect that)
      //  - mainline tip → new tip (live-feed follow behaviour)
      //  - any other valid pointer → preserve (user was exploring; don't
      //    yank them away). If invalid in the new tree, fall back to tip.
      final initialPointer = _pointerForInitialFen(game, boardArgs?.initialFen);
      final shouldApplyInitialPointer =
          initialPointer != null &&
          (oldMainlineLen == 0 ||
              (initialFenKey != null &&
                  initialFenKey != previousInitialFenKey));
      ChessMovePointer newPointer;
      if (shouldApplyInitialPointer) {
        newPointer = initialPointer;
      } else if (oldMainlineLen == 0 && game.mainline.isNotEmpty) {
        newPointer = isLive ? <int>[game.mainline.length - 1] : const <int>[];
      } else if (oldPointer.isEmpty) {
        newPointer = const <int>[];
      } else if (game.mainline.isEmpty) {
        newPointer = const <int>[];
      } else if (wasAtMainlineTip) {
        newPointer = <int>[game.mainline.length - 1];
      } else {
        newPointer =
            _isPointerValid(game, oldPointer)
                ? oldPointer
                : <int>[game.mainline.length - 1];
      }
      pointer.value = newPointer;

      // SFX for the new move landed at the live tip — only fires when
      // the mainline grew so identical PGN echoes don't double-trigger.
      // Skip the very first apply (oldMainlineLen == 0) so opening a board
      // with an existing PGN doesn't blast a move sound.
      final mainlineGrew = game.mainline.length > oldMainlineLen;
      if (mainlineGrew && oldMainlineLen > 0) {
        final landed = game.mainline.last.san;
        if (_shouldPlaySounds(ref, activeTabId)) {
          AudioPlayerService.instance.playSfxForSan(landed);
        }
      }

      // New-move indicator. If the live mainline grew and the user is not
      // sitting on the brand-new tip, raise the flag so the floating
      // "Jump to live" pill appears. If the new pointer happens to land
      // on the tip (auto-follow case), clear it instead.
      final landedOnTip =
          newPointer.length == 1 &&
          game.mainline.isNotEmpty &&
          newPointer.first == game.mainline.length - 1;
      if (mainlineGrew && isLive && !landedOnTip) {
        hasUnseenMoves.value = true;
      } else if (landedOnTip) {
        hasUnseenMoves.value = false;
      }
    }

    bool tryApplyIncrementalLiveUpdate(
      Map<String, dynamic> data, {
      required String gameId,
      required String origin,
    }) {
      final pgn = (data['pgn'] as String?)?.trim();
      final liveFen = (data['fen'] as String?)?.trim();
      final liveUci = (data['last_move'] as String?)?.trim();
      if (pgn == null ||
          pgn.isEmpty ||
          liveFen == null ||
          liveFen.isEmpty ||
          liveUci == null ||
          liveUci.isEmpty ||
          pgn == lastAppliedPgn.value) {
        return false;
      }

      final oldGame = chessGame.value;
      final oldMainlineLen = oldGame.mainline.length;
      if (oldMainlineLen == 0) return false;

      final plies = _pliesFromPath(oldGame.startingFen, oldGame.mainline);
      if (plies.length != oldMainlineLen + 1) return false;
      final finalPosition = plies.last.position;
      final extraMove = Move.parse(liveUci);
      if (extraMove == null || !finalPosition.isLegal(extraMove)) {
        return false;
      }

      final made = finalPosition.makeSan(extraMove);
      final nextPosition = made.$1;
      if (_fenPositionKey(nextPosition.fen) != _fenPositionKey(liveFen)) {
        return false;
      }

      final oldPointer = pointer.value;
      final wasAtMainlineTip =
          oldPointer.length == 1 && oldPointer.first == oldMainlineLen - 1;
      final clockSeconds =
          finalPosition.turn == Side.white
              ? data['last_clock_white'] as num?
              : data['last_clock_black'] as num?;
      final nextMove = ChessMove(
        num: finalPosition.fullmoves,
        fen: nextPosition.fen,
        san: made.$2,
        uci: extraMove.uci,
        turn:
            finalPosition.turn == Side.black
                ? ChessColor.black
                : ChessColor.white,
        clockTime:
            clockSeconds == null
                ? null
                : formatClockDisplayFromSeconds(clockSeconds.round()),
      );

      final status = (data['status'] as String?)?.trim();
      final isLive = status == null || status.isEmpty || status == '*';
      final metadata = Map<String, dynamic>.of(oldGame.metadata);
      if (status != null && status.isNotEmpty) {
        metadata['Result'] = status;
      }
      metadata[ChessGame.metadataAllowMainlineExtensionKey] = !isLive;
      metadata[ChessGame.metadataIsLiveKey] = isLive;

      final updatedGame = oldGame.copyWith(
        metadata: metadata,
        mainline: <ChessMove>[...oldGame.mainline, nextMove],
      );
      final initialFenKey = _nullableFenPositionKey(boardArgs?.initialFen);
      dirtySinceLoad.value = gameId.isNotEmpty && dirtySinceLoad.value;
      lastAppliedPgn.value = pgn;
      lastAppliedInitialFenKey.value = initialFenKey;
      lastAppliedGameId.value = gameId;
      chessGame.value = updatedGame;
      pgnHeaders.value = updatedGame.metadata.map(
        (k, v) => MapEntry(k, v?.toString() ?? ''),
      );
      loadedFrom.value = origin;

      if (oldPointer.isEmpty) {
        pointer.value = const <int>[];
      } else if (wasAtMainlineTip) {
        pointer.value = <int>[updatedGame.mainline.length - 1];
      } else {
        pointer.value =
            _isPointerValid(updatedGame, oldPointer)
                ? oldPointer
                : <int>[updatedGame.mainline.length - 1];
      }

      if (_shouldPlaySounds(ref, activeTabId)) {
        AudioPlayerService.instance.playSfxForSan(nextMove.san);
      }

      final landedOnTip =
          pointer.value.length == 1 &&
          pointer.value.first == updatedGame.mainline.length - 1;
      if (isLive && !landedOnTip) {
        hasUnseenMoves.value = true;
      } else if (landedOnTip) {
        hasUnseenMoves.value = false;
      }

      return true;
    }

    void syncLiveGameRowWithDesktopSurfaces(
      String gameId,
      Map<String, dynamic> data,
    ) {
      if (gameId.trim().isEmpty) return;
      final update = LiveGameUpdate.fromLegacyMap(gameId, data);
      final sourceGame =
          boardArgs?.sourceGame ?? ref.read(baseGameProvider(gameId));
      final mergedGame =
          sourceGame == null
              ? null
              : mergeLiveGameUpdateWithBase(
                baseGame: sourceGame,
                update: update,
              );

      if (mergedGame != null) {
        ref.read(baseGameProvider(gameId).notifier).state = mergedGame;
      }

      final updatePgn = update.pgn?.trim();
      final mergedPgn = mergedGame?.pgn?.trim();
      final livePgn =
          mergedPgn != null && mergedPgn.isNotEmpty ? mergedPgn : updatePgn;
      final updateFen = update.fen?.trim();
      final liveFen =
          (mergedGame?.fen?.trim().isNotEmpty ?? false)
              ? mergedGame!.fen!.trim()
              : updateFen;
      final liveStatus =
          mergedGame?.effectiveGameStatus ??
          GameStatus.fromString(update.status);
      final liveLastMoveTime =
          mergedGame?.lastMoveTime ??
          (update.lastMoveTime == null
              ? null
              : DateTime.tryParse(update.lastMoveTime!));
      final hasStarted =
          mergedGame?.hasStarted ??
          ((update.lastMove?.trim().isNotEmpty ?? false) ||
              (livePgn?.isNotEmpty ?? false));

      ref.read(boardTabGameArgsByTabIdProvider.notifier).update((tabs) {
        var changed = false;
        final nextTabs = <String, BoardTabGameArgs>{};
        for (final entry in tabs.entries) {
          final args = entry.value;
          final updatedEventGames = _syncLiveGameSummaryList(
            args.eventGames,
            gameId: gameId,
            pgn: livePgn,
            fen: liveFen,
            status: liveStatus,
            lastMoveTime: liveLastMoveTime,
            hasStarted: hasStarted,
          );
          final updatedRouteGames = _syncLiveGameSummaryList(
            args.routeGames,
            gameId: gameId,
            pgn: livePgn,
            fen: liveFen,
            status: liveStatus,
            lastMoveTime: liveLastMoveTime,
            hasStarted: hasStarted,
          );
          final ownsGame = args.gameId == gameId;
          final shouldUpdatePgn =
              ownsGame && livePgn != null && livePgn.isNotEmpty;
          final shouldUpdateFen =
              ownsGame && liveFen != null && liveFen.isNotEmpty;
          final shouldUpdateSourceGame = ownsGame && mergedGame != null;
          if (!shouldUpdatePgn &&
              !shouldUpdateFen &&
              !shouldUpdateSourceGame &&
              identical(updatedEventGames, args.eventGames) &&
              identical(updatedRouteGames, args.routeGames)) {
            nextTabs[entry.key] = args;
            continue;
          }
          final nextArgs = args.copyWith(
            pgn: shouldUpdatePgn ? livePgn : null,
            fenSeed: shouldUpdateFen ? liveFen : null,
            sourceGame: shouldUpdateSourceGame ? mergedGame : null,
            eventGames:
                identical(updatedEventGames, args.eventGames)
                    ? null
                    : updatedEventGames,
            routeGames:
                identical(updatedRouteGames, args.routeGames)
                    ? null
                    : updatedRouteGames,
          );
          changed = true;
          nextTabs[entry.key] = nextArgs;
        }
        return changed ? nextTabs : tabs;
      });
    }

    // Pull in any newly dropped/tapped PGN. The drop zone and the
    // TournamentPgnLoader both push imports into this provider.
    ref.listen<PgnImport?>(pgnIntakeProvider, (previous, next) {
      if (next == null || next == previous) return;
      // Game-bearing Board tabs are isolated by `BoardTabGameArgs`; a global
      // import from another tab must not overwrite this tab's analysis tree.
      if (boardArgs != null) return;
      // Wipe stale arrows/circles + NAGs before replacing the tree so a
      // drag-drop of a fresh PGN does not inherit the previous game's ink.
      if (chessGame.value.mainline.isNotEmpty) {
        final tabId = activeTabId ?? 'board-default';
        ref.read(boardAnnotationsProvider(tabId).notifier).clear();
        ref.read(userMoveNagsProvider.notifier).clearTab(tabId);
      }
      applyPgn(next.pgn, origin: next.path, gameId: next.gameId);
    });

    // Seed from the active tab first. This is the desktop equivalent of the
    // mobile screen provider owning one navigator state per route instance:
    // each game tab has its own immutable open args, while the scratch Board
    // tab falls back to the legacy global PGN intake.
    useEffect(
      () {
        final args = boardArgs;
        if (args != null) {
          Future.microtask(() {
            if (!context.mounted) return;
            if (args.pgn.trim().isNotEmpty) {
              applyPgn(
                args.pgn,
                origin: 'tab:${args.label}',
                gameId: args.gameId,
              );
              return;
            }
            // Build-tree tabs are opened with an empty PGN plus a starting
            // FEN. On remount, the saved session is the source of truth; do
            // not let those initial args reseed the board and erase user moves.
            if (!shouldApplyEmptyBoardArgsSeed(
              hasRestoredSession: restoredSession != null,
              hasCurrentMoves: chessGame.value.mainline.isNotEmpty,
              dirtySinceLoad: dirtySinceLoad.value,
              loadedFrom: loadedFrom.value,
            )) {
              return;
            }
            final headers = _headersFromBoardArgs(args);
            final fenSeed = (args.initialFen ?? args.fenSeed)?.trim();
            chessGame.value = _emptyChessGame.copyWith(
              startingFen:
                  (fenSeed == null || fenSeed.isEmpty)
                      ? _emptyChessGame.startingFen
                      : fenSeed,
              metadata: <String, dynamic>{
                ..._emptyChessGame.metadata,
                ...headers,
              },
            );
            pgnHeaders.value = headers;
            pointer.value = const <int>[];
            loadedFrom.value = 'tab:${args.label}';
          });
          return null;
        }

        final seed = latestPgnImport;
        if (seed != null && seed.pgn.trim().isNotEmpty) {
          Future.microtask(() {
            if (!context.mounted) return;
            applyPgn(
              seed.pgn,
              origin: 'seed:${seed.path}',
              gameId: seed.gameId,
            );
          });
        }
        return null;
      },
      [
        activeTabId,
        boardArgs?.gameId,
        boardArgs?.pgn,
        boardArgs?.fenSeed,
        boardArgs?.initialFen,
        latestPgnImport?.path,
        latestPgnImport?.pgn,
        latestPgnImport?.gameId,
      ],
    );

    // Gamebase / position-search rows frequently open Board tabs with only a
    // game id and header metadata. Hydrate those tabs before the notation pane
    // concludes the game has no moves.
    useEffect(() {
      final args = boardArgs;
      final tabId = activeTabId;
      final gameId = args?.gameId?.trim();
      if (args == null ||
          tabId == null ||
          gameId == null ||
          gameId.isEmpty ||
          pgnHasMoves(args.pgn)) {
        return null;
      }

      final requestToken = ++boardTabPgnHydrationToken.value;
      Future.microtask(() async {
        final hydratedPgn = await resolveBoardTabPgn(
          gameId: gameId,
          initialPgn: args.pgn,
          fetchSupabasePgn:
              (id) => ref.read(gameRepositoryProvider).getGamePgn(id),
          fetchGamebaseGameWithPgn:
              (id) => ref.read(gamebaseRepositoryProvider).getGameWithPgn(id),
        );

        if (!context.mounted ||
            requestToken != boardTabPgnHydrationToken.value ||
            !pgnHasMoves(hydratedPgn)) {
          return;
        }

        final currentActiveId = ref.read(desktopTabsProvider).activeId;
        final currentArgs = ref.read(boardTabGameArgsByTabIdProvider)[tabId];
        if (!shouldPersistHydratedBoardTabPgn(
          hydratedTabId: tabId,
          currentArgs: currentArgs,
          expectedGameId: gameId,
        )) {
          return;
        }

        final pgn = hydratedPgn!.trim();
        final argsToHydrate = currentArgs!;
        ref
            .read(boardTabGameArgsByTabIdProvider.notifier)
            .update(
              (m) => <String, BoardTabGameArgs>{
                ...m,
                tabId: argsToHydrate.copyWith(
                  pgn: pgn,
                  sourceGame: argsToHydrate.sourceGame?.copyWith(pgn: pgn),
                ),
              },
            );

        if (!shouldApplyHydratedBoardTabPgn(
          activeTabId: currentActiveId,
          hydratedTabId: tabId,
        )) {
          return;
        }
        applyPgn(pgn, origin: 'hydrate:${argsToHydrate.label}', gameId: gameId);
      });

      return null;
    }, [activeTabId, boardArgs?.gameId, boardArgs?.pgn, boardArgs?.initialFen]);

    // Subscribe to live updates for the currently active tournament
    // game. When the user taps a card, `activeGameId` is set; open a
    // Supabase Realtime channel for it and reparse the PGN on every
    // update. Reset state only when the gameId genuinely changed AND no
    // PGN has been applied for it yet — the intake listener can fire in
    // the same build, in which case we leave the just-replayed tree
    // alone.
    final lastShapeTabId = useRef<String?>(null);
    useEffect(() {
      final currentTabId = activeTabId;
      final isTabSwitched = currentTabId != lastShapeTabId.value;
      if (activeGameId != lastAppliedGameId.value) {
        final priorGameId = lastAppliedGameId.value;
        lastAppliedGameId.value = activeGameId;
        if (activeGameId != null) {
          lastAppliedPgn.value = null;
          lastAppliedInitialFenKey.value = null;
          chessGame.value = _emptyChessGame;
          pgnHeaders.value = const {};
          pointer.value = const <int>[];
        }
        // Within-tab game switch: wipe stale user-drawn arrows / circles
        // and NAGs so annotations from the previous game don't bleed into
        // the new one. Skip when the tab itself changed (each tab owns its
        // own annotation state, keyed by tabId) and skip first-ever load
        // (no priorGameId).
        if (!isTabSwitched && priorGameId != null && currentTabId != null) {
          ref.read(boardAnnotationsProvider(currentTabId).notifier).clear();
          ref.read(userMoveNagsProvider.notifier).clearTab(currentTabId);
        }
      }
      lastShapeTabId.value = currentTabId;
      return null;
    }, [activeGameId, activeTabId]);

    // Live broadcast snapshot for PGN sync. Do not watch this provider in the
    // root pane: every broadcast push would rebuild the board, notation, and
    // engine rail. The player headers below watch just the clock fields they
    // need.
    if (activeGameId != null) {
      ref.listen<AsyncValue<Map<String, dynamic>?>>(
        gameUpdatesStreamProvider(activeGameId),
        (previous, next) {
          next.whenData((data) {
            if (data == null) return;
            syncLiveGameRowWithDesktopSurfaces(activeGameId, data);
            final pgn = data['pgn'] as String?;
            if (pgn == null || pgn.trim().isEmpty) return;
            final appliedIncrementally = tryApplyIncrementalLiveUpdate(
              data,
              gameId: activeGameId,
              origin: 'live:$activeGameId',
            );
            if (!appliedIncrementally) {
              applyPgn(pgn, origin: 'live:$activeGameId', gameId: activeGameId);
            }
          });
        },
      );
      final liveBroadcast =
          ref.read(gameUpdatesStreamProvider(activeGameId)).valueOrNull;
      final seedPgn = liveBroadcast?['pgn'] as String?;
      if (seedPgn != null && seedPgn.trim().isNotEmpty) {
        Future.microtask(
          () => applyPgn(
            seedPgn,
            origin: 'seed:$activeGameId',
            gameId: activeGameId,
          ),
        );
      }
    }

    // ---- Derive the active line from (chessGame, pointer) -----------
    // This is the single recomputation point. Everything below reads
    // from `history`/`cursor`/`position` exactly like before.
    final path = _pathFromPointer(chessGame.value, pointer.value);
    // UCI line from the start position to the current pointer along the
    // *active* line. Feeds the opening explorer games/aggregates so they line
    // up with whatever the user is looking at, mainline or variation.
    final lineUcis = path.map((m) => m.uci).toList(growable: false);
    final history = _pliesFromPath(chessGame.value.startingFen, path);
    final cursor = history.length - 1;
    final currentPly = history[cursor];
    final position = currentPly.position;
    final canBack = pointer.value.isNotEmpty;
    final canForward = _nextPointer(chessGame.value, pointer.value) != null;

    // ---- Per-side clocks at the active pointer ---------------------
    // Walk the active line *backwards* once and pick up the most
    // recent `[%clk …]` annotation we find for each colour. Clock
    // values decay via player → so the latest entry up to the cursor
    // is what we want to display. Values are formatted by the
    // `_PlayerClock` widget; here we only carry the raw string.
    String? whiteClockRaw;
    String? blackClockRaw;
    for (var i = path.length - 1; i >= 0; i--) {
      final m = path[i];
      if (m.clockTime == null) continue;
      if (m.turn == ChessColor.white && whiteClockRaw == null) {
        whiteClockRaw = m.clockTime;
      } else if (m.turn == ChessColor.black && blackClockRaw == null) {
        blackClockRaw = m.clockTime;
      }
      if (whiteClockRaw != null && blackClockRaw != null) break;
    }

    // Mirror the current FEN into the board-tab FEN map so the tab bar
    // can render a live eval bar on this Board tab's chip.
    useEffect(() {
      if (activeTabId != null) {
        Future.microtask(() {
          ref
              .read(boardTabFenProvider.notifier)
              .setFen(activeTabId, position.fen);
        });
      }
      return null;
    }, [activeTabId, position.fen]);

    // Whenever the user navigates onto the live mainline tip — by any
    // route (goLast, goNext into the last move, ladder click, the
    // floating pill below the board) — clear the new-move indicator.
    // Cheap to recompute every build; keeps the flag honest without
    // having to thread a "did you just land on the tip?" check through
    // every navigation action.
    final mainlineLen = chessGame.value.mainline.length;
    final isAtMainlineTip =
        pointer.value.length == 1 &&
        mainlineLen > 0 &&
        pointer.value.first == mainlineLen - 1;
    final isLiveGame =
        chessGame.value.metadata[ChessGame.metadataIsLiveKey] == true;
    final isLiveAtTip = isLiveGame && isAtMainlineTip;
    useEffect(() {
      if (isAtMainlineTip && hasUnseenMoves.value) {
        Future.microtask(() {
          if (!context.mounted) return;
          hasUnseenMoves.value = false;
        });
      }
      return null;
    }, [isAtMainlineTip]);

    bool setPointerFromNavigation(
      ChessMovePointer target, {
      bool requestPaneFocus = false,
    }) {
      if (_pointersEqual(target, pointer.value)) {
        // Already there — still grab focus so keyboard nav keeps working
        // after a click on the active chip.
        if (requestPaneFocus) focusNode.requestFocus();
        return true;
      }
      if (!_isPointerValid(chessGame.value, target)) return false;
      pointer.value = List<int>.unmodifiable(target);
      // Some callers want shell-level board shortcuts immediately after
      // navigation; notation-chip clicks keep focus inside the right rail.
      if (requestPaneFocus) focusNode.requestFocus();
      if (target.isNotEmpty && _shouldPlaySounds(ref, activeTabId)) {
        final move = _moveAtPointer(chessGame.value, target);
        if (move != null) AudioPlayerService.instance.playSfxForSan(move.san);
      }
      return true;
    }

    void jumpToPointer(ChessMovePointer target) {
      setPointerFromNavigation(target);
    }

    void goFirst() {
      if (pointer.value.isEmpty) return;
      pointer.value = const <int>[];
    }

    void goPrev() {
      final prev = _previousPointer(pointer.value);
      if (prev == null) return;
      pointer.value = prev;
      if (prev.isNotEmpty && _shouldPlaySounds(ref, activeTabId)) {
        final move = _moveAtPointer(chessGame.value, prev);
        if (move != null) AudioPlayerService.instance.playSfxForSan(move.san);
      }
    }

    void goNext() {
      final next = _nextPointer(chessGame.value, pointer.value);
      if (next == null) return;
      pointer.value = next;
      if (_shouldPlaySounds(ref, activeTabId)) {
        final move = _moveAtPointer(chessGame.value, next);
        if (move != null) AudioPlayerService.instance.playSfxForSan(move.san);
      }
    }

    // User-driven forward step. When the next move carries variations the
    // user is asked which continuation to follow via a hover-styled chooser
    // popup; otherwise this is a plain `goNext`. Used by the move-nav
    // "next" button, the keyboard ArrowRight shortcut, and the notation
    // tab's in-tab step handler. Auto-replay and `goLast` still call the
    // plain `goNext` so background traversal never blocks on a dialog.
    Future<void> goNextInteractive() async {
      final currentPointer = pointer.value;
      final next = _nextPointer(chessGame.value, currentPointer);
      if (next == null) return;
      final options = resolveVariationForkOptions(
        game: chessGame.value,
        current: currentPointer,
        next: next,
      );
      if (options == null) {
        goNext();
        return;
      }
      final picked = await showVariationForkChooser(
        context: context,
        options: options,
        targetContext: rightRailAnalysisKey.currentContext,
      );
      if (picked == null || !context.mounted) return;
      // Re-validate after the await: the broadcast feed may have shifted
      // the tree, in which case the saved pointer is stale and we fall
      // back to a plain step so the key press still feels live.
      if (!_isPointerValid(chessGame.value, picked)) {
        goNext();
        return;
      }
      jumpToPointer(picked);
    }

    bool stepNotationHorizontally(int delta) {
      if (delta > 0) {
        unawaited(goNextInteractive());
        return true;
      }
      if (delta < 0) {
        final before = pointer.value;
        goPrev();
        return !_pointersEqual(before, pointer.value);
      }
      return false;
    }

    void goNotationLine(NotationVerticalDirection direction) {
      final isInlineNotation =
          notationLayoutController.value == NotationLayoutMode.inline;
      final target =
          isInlineNotation
              ? notationVerticalPointer(
                game: chessGame.value,
                activePointer: pointer.value,
                direction: direction,
                visibleMoveOrder: visibleNotationMoveOrderController.value,
              )
              : notationLadderVerticalPointer(
                game: chessGame.value,
                activePointer: pointer.value,
                direction: direction,
              );
      if (target == null) return;
      setPointerFromNavigation(target);
    }

    void goLast() {
      var p = pointer.value;
      while (true) {
        final next = _nextPointer(chessGame.value, p);
        if (next == null) break;
        p = next;
      }
      if (_pointersEqual(p, pointer.value)) return;
      pointer.value = p;
      if (_shouldPlaySounds(ref, activeTabId)) {
        final move = _moveAtPointer(chessGame.value, p);
        if (move != null) AudioPlayerService.instance.playSfxForSan(move.san);
      }
    }

    // Up/Down: cycle through sibling lines at the current branch column.
    // PM brief: arrows should behave like ←/→ but with the ability to
    // switch between variations. When no sibling exists at this column
    // we fall back to stepping one move so the keys never feel dead.
    void goPrevVariation() {
      final swap = _siblingCycle(chessGame.value, pointer.value, -1);
      if (swap != null) {
        pointer.value = swap;
        if (_shouldPlaySounds(ref, activeTabId)) {
          final move = _moveAtPointer(chessGame.value, swap);
          if (move != null) AudioPlayerService.instance.playSfxForSan(move.san);
        }
        return;
      }
      goPrev();
    }

    void goNextVariation() {
      final swap = _siblingCycle(chessGame.value, pointer.value, 1);
      if (swap != null) {
        pointer.value = swap;
        if (_shouldPlaySounds(ref, activeTabId)) {
          final move = _moveAtPointer(chessGame.value, swap);
          if (move != null) AudioPlayerService.instance.playSfxForSan(move.san);
        }
        return;
      }
      goNext();
    }

    useEffect(() {
      if (!autoReplay.value) return null;
      final timer = Timer.periodic(const Duration(milliseconds: 700), (_) {
        if (!context.mounted) return;
        if (_nextPointer(chessGame.value, pointer.value) == null) {
          autoReplay.value = false;
          return;
        }
        goNext();
      });
      return timer.cancel;
    }, [autoReplay.value, chessGame.value, pointer.value]);

    void pushUndoSnapshot() {
      final stack = undoStack.value;
      stack.add(
        BoardUndoSnapshot(
          game: chessGame.value,
          pointer: List<int>.unmodifiable(pointer.value),
          dirtySinceLoad: dirtySinceLoad.value,
        ),
      );
      if (stack.length > 50) stack.removeAt(0);
    }

    // Moves from the board, engine, or right rail route through the
    // navigator's `makeOrGoToMove` so they follow the same rules mobile uses —
    //   - matches existing next move ⇒ advance pointer
    //   - matches an existing variation head ⇒ enter that variation
    //   - else (mid-line, or end-of-line on a live game) ⇒ branch a new
    //     sub-variation
    //   - end-of-line on a finished game with mainline-extension allowed
    //     ⇒ append to the current line
    void applyMove(
      NormalMove move, {
      bool requestPaneFocus = true,
      bool suppressSound = false,
    }) {
      // Snapshot game + pointer here so a mid-flight broadcast tick
      // can't replace `chessGame.value` between the navigator setup
      // and the resulting state read. If the pointer somehow became
      // invalid (e.g., a live update changed the tree before we got
      // here), fall back to the closest valid prefix so the navigator
      // can still grow a sub-variation from where we are now.
      final game = chessGame.value;
      final basePointer =
          _isPointerValid(game, pointer.value)
              ? pointer.value
              : _truncateToValidPointer(game, pointer.value);
      final nav = _LocalChessGameNavigator(game);
      nav.goToMovePointerUnchecked(basePointer);
      nav.makeOrGoToMove(move.uci);
      final newGame = nav.currentState.game;
      final newPointer = nav.currentState.movePointer;
      final didChange =
          !identical(newGame, game) || !_pointersEqual(newPointer, basePointer);
      if (!didChange) return;
      if (!identical(newGame, game)) {
        pushUndoSnapshot();
      }
      chessGame.value = newGame;
      pointer.value = newPointer;
      dirtySinceLoad.value = true;
      // Board drags and global move actions should keep board shortcuts live;
      // right-rail Explorer row activation keeps focus in the Explorer tab.
      if (requestPaneFocus) focusNode.requestFocus();
      if (shouldPlaySoundForBoardMove(
        soundGateAllows: _shouldPlaySounds(ref, activeTabId),
        suppressSound: suppressSound,
      )) {
        final landed = _moveAtPointer(newGame, newPointer);
        if (landed != null) {
          AudioPlayerService.instance.playSfxForSan(landed.san);
        }
      }
    }

    void onMove(
      Move move, {
      bool? viaDragAndDrop,
      bool requestPaneFocus = true,
    }) {
      // Standard chess only emits NormalMoves from chessground (drops
      // are crazyhouse-only). Bail instead of misroute on the off-
      // chance a variant slips in.
      if (move is! NormalMove) return;

      // Pawn-to-back-rank with no promotion role → defer the move and
      // raise the picker overlay. chessground reads `promotionMove`
      // on its next paint and overlays the four-piece selector;
      // without this staging step `Position.isLegal(move)` rejects the
      // bare e7e8 (legal pawn promotions in dartchess require a
      // promotion role) and the move silently no-ops.
      if (move.promotion == null && _isPromotionPawnMove(position, move)) {
        promotionMove.value = move;
        return;
      }

      applyMove(move, requestPaneFocus: requestPaneFocus);
    }

    void onPromotionSelection(Role? role) {
      final pending = promotionMove.value;
      if (role == null) {
        // Cancel — chessground passes `null` when the user dismisses
        // the picker (Esc / off-board click). Just close the overlay;
        // the pawn returns to its origin square because we never
        // applied the half-move in the first place.
        promotionMove.value = null;
        return;
      }
      if (pending == null) return;
      promotionMove.value = null;
      applyMove(pending.withPromotion(role));
    }

    void promoteVariation(ChessMovePointer head) {
      final beforeGame = chessGame.value;
      final beforePointer = pointer.value;
      final nav = _LocalChessGameNavigator(chessGame.value);
      nav.goToMovePointerUnchecked(pointer.value);
      nav.promoteVariationToMainline(head);
      final nextGame = nav.currentState.game;
      final nextPointer = nav.currentState.movePointer;
      if (identical(nextGame, beforeGame) &&
          _pointersEqual(nextPointer, beforePointer)) {
        return;
      }
      pushUndoSnapshot();
      chessGame.value = nextGame;
      pointer.value = nextPointer;
      dirtySinceLoad.value = true;
    }

    void deleteVariation(ChessMovePointer head) {
      final beforeGame = chessGame.value;
      final beforePointer = pointer.value;
      final nav = _LocalChessGameNavigator(chessGame.value);
      nav.goToMovePointerUnchecked(pointer.value);
      nav.deleteVariationAtPointer(head);
      final nextGame = nav.currentState.game;
      final nextPointer = nav.currentState.movePointer;
      if (identical(nextGame, beforeGame) &&
          _pointersEqual(nextPointer, beforePointer)) {
        return;
      }
      pushUndoSnapshot();
      chessGame.value = nextGame;
      pointer.value = nextPointer;
      dirtySinceLoad.value = true;
    }

    void trimContinuation(ChessMovePointer p) {
      final beforeGame = chessGame.value;
      final beforePointer = pointer.value;
      final nav = _LocalChessGameNavigator(chessGame.value);
      nav.goToMovePointerUnchecked(pointer.value);
      nav.deleteContinuationAfterPointer(p);
      final nextGame = nav.currentState.game;
      final nextPointer = nav.currentState.movePointer;
      if (identical(nextGame, beforeGame) &&
          _pointersEqual(nextPointer, beforePointer)) {
        return;
      }
      pushUndoSnapshot();
      chessGame.value = nextGame;
      pointer.value = nextPointer;
      dirtySinceLoad.value = true;
    }

    // ---- 3-dot menu / "More actions" handlers ---------------------------

    void showToast(String message, {bool error = false}) {
      showDesktopToast(context, message, error: error);
    }

    // Tab id used as the key for per-tab annotation/NAG state. Declared
    // here so the undo action below can reference it (the post-build
    // `hasShapes` / `hasUserNags` watches still read it further down).
    final editsTabId = activeTabId ?? 'board-default';

    void undoLastEditAction() {
      final stack = undoStack.value;
      if (stack.isEmpty) {
        showToast('Nothing to undo');
        focusNode.requestFocus();
        return;
      }
      final snapshot = stack.removeLast();
      chessGame.value = snapshot.game;
      pointer.value = snapshot.pointer;
      dirtySinceLoad.value = snapshot.dirtySinceLoad;
      // Restore shapes / NAGs only when the snapshot carries them. Move-
      // only snapshots leave the user's later annotation work untouched.
      // We swallow the listen-callback that fires for *our own* restore
      // by checking equality first — otherwise undoing once would push
      // a redundant snapshot of the just-undone state.
      if (snapshot.shapes != null) {
        final current = ref.read(boardAnnotationsProvider(editsTabId)).shapes;
        if (!_setsEqual(current, snapshot.shapes!)) {
          ref
              .read(boardAnnotationsProvider(editsTabId).notifier)
              .restore(snapshot.shapes!);
          // The listen above just captured a redundant "before restore"
          // snapshot. Drop it so a second Ctrl+Z keeps walking history
          // instead of toggling.
          if (stack.isNotEmpty) stack.removeLast();
        }
      }
      if (snapshot.userNags != null) {
        final current =
            ref.read(userMoveNagsProvider)[editsTabId] ??
            const <int, List<int>>{};
        if (!_nagMapsEqual(current, snapshot.userNags!)) {
          ref
              .read(userMoveNagsProvider.notifier)
              .restoreTab(editsTabId, snapshot.userNags!);
          if (stack.isNotEmpty) stack.removeLast();
        }
      }
      focusNode.requestFocus();
      showToast('Undo');
    }

    bool gameHasMainline() => chessGame.value.mainline.isNotEmpty;

    bool gameHasUserVariations() {
      return _gameHasUserVariations(chessGame.value);
    }

    Future<void> copyPgnAction() async {
      if (!gameHasMainline()) {
        showToast('No PGN to copy yet — load a game first.');
        return;
      }
      try {
        final pgn = boardClipboardPgn(
          game: chessGame.value,
          dirtySinceLoad: dirtySinceLoad.value,
          lastAppliedPgn: lastAppliedPgn.value,
        );
        await Clipboard.setData(ClipboardData(text: pgn));
        showToast('PGN copied to clipboard');
      } catch (e) {
        showToast('Failed to copy PGN: $e', error: true);
      }
    }

    Future<void> pastePgnAction() async {
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text?.trim();
        if (text == null || text.isEmpty) {
          showToast('Clipboard does not contain PGN text.', error: true);
          return;
        }
        try {
          ChessGame.fromPgn('', text);
        } catch (_) {
          showToast('Clipboard text is not a valid PGN.', error: true);
          return;
        }
        switch (resolveBoardPgnPasteMode(
          activeBoardHasNotation: gameHasMainline(),
        )) {
          case BoardPgnPasteMode.loadIntoCurrentBoard:
            applyPgn(text, origin: 'clipboard');
            showToast('PGN loaded from clipboard');
          case BoardPgnPasteMode.insertIntoCurrentNotation:
            ref
                .read(boardGameInsertRequestProvider.notifier)
                .state = BoardGameInsertRequest(
              id: DateTime.now().microsecondsSinceEpoch,
              pgn: text,
              sourceLabel: clipboardPgnSourceLabel(text),
            );
        }
      } catch (e) {
        showToast('Failed to paste PGN: $e', error: true);
      }
    }

    Future<void> copyFenAction() async {
      final fen = position.fen.trim();
      if (fen.isEmpty) {
        showToast('No FEN available for this position', error: true);
        return;
      }
      await Clipboard.setData(ClipboardData(text: fen));
      showToast('FEN copied to clipboard');
    }

    Future<void> saveGameToLibraryAction() async {
      if (!gameHasMainline()) {
        showToast('No game to save yet — load a game first.');
        return;
      }
      // When the board tab originated from a live tournament card, route
      // through the same `saveDesktopGameToLibrary` flow the right-click
      // "Save to library" menu item uses on the game cards. Keeps PGN
      // resolution + metadata enrichment identical across surfaces.
      final source = boardArgs?.sourceGame;
      final tournamentTitle = boardArgs?.tournamentTitle ?? '';
      if (source != null && canSaveDesktopGameToLibrary(source)) {
        await saveDesktopGameToLibrary(
          context: context,
          ref: ref,
          game: source,
          sourceLabel:
              tournamentTitle.trim().isEmpty
                  ? 'finished game'
                  : tournamentTitle,
        );
        return;
      }
      // Detached PGN (drag-drop, library re-open, scratch analysis) or a
      // live game still in progress. Build a snapshot from the current
      // analysis tree and hand it straight to the save dialog.
      try {
        final pgn = exportGameToPgn(chessGame.value);
        final headers = pgnHeaders.value;
        final snapshot = ChessGame.fromPgn(
          activeGameId ??
              'desktop-board-${DateTime.now().microsecondsSinceEpoch}',
          pgn,
        );
        final metadata = Map<String, dynamic>.from(snapshot.metadata);
        metadata[ChessGame.metadataIsLiveKey] = false;
        metadata[ChessGame.metadataAllowMainlineExtensionKey] = false;
        final eventLabel = headers['Event']?.trim();
        final gameSnapshot = snapshot.copyWith(metadata: metadata);
        final outcome = await showLibrarySaveToFolderDialog(
          context: context,
          ref: ref,
          games: [gameSnapshot],
          sourceLabel:
              (eventLabel != null && eventLabel.isNotEmpty)
                  ? eventLabel
                  : (tournamentTitle.trim().isEmpty
                      ? 'analysis'
                      : tournamentTitle),
          updateTarget: _libraryUpdateTargetForBoardArgs(
            ref: ref,
            boardArgs: boardArgs,
            game: gameSnapshot,
          ),
        );
        if (!context.mounted || outcome == null || !outcome.didSave) return;
        showToast(outcome.toToastMessage());
      } catch (e) {
        if (!context.mounted) return;
        showToast('Failed to save game: $e', error: true);
      }
    }

    Future<void> savePgnAction() async {
      if (!gameHasMainline()) {
        showToast('No PGN to save yet — load a game first.');
        return;
      }
      try {
        final pgn = exportGameToPgn(chessGame.value);
        final headers = pgnHeaders.value;
        final defaultName = _suggestPgnFileName(headers);
        final path = await FilePicker.platform.saveFile(
          dialogTitle: 'Save PGN',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: const ['pgn'],
        );
        if (path == null) return;
        final withExt =
            path.toLowerCase().endsWith('.pgn') ? path : '$path.pgn';
        await io.File(withExt).writeAsString(pgn, flush: true);
        // Guard the toast — the await above pumped the event loop
        // and the pane could have unmounted before the file write
        // completed (tab closed, navigation, etc.).
        if (!context.mounted) return;
        showToast('Saved to $withExt');
      } catch (e) {
        if (!context.mounted) return;
        showToast('Failed to save PGN: $e', error: true);
      }
    }

    void setMoveComment(ChessMovePointer target, String? comment) {
      if (target.isEmpty) return;
      final nextGame = _setMoveCommentAtPointer(
        chessGame.value,
        target,
        comment,
      );
      if (identical(nextGame, chessGame.value)) return;
      pushUndoSnapshot();
      chessGame.value = nextGame;
      dirtySinceLoad.value = true;
    }

    void setMoveNags(ChessMovePointer target, List<int> nags) {
      if (target.isEmpty) return;
      final nextGame = _setMoveNagsAtPointer(chessGame.value, target, nags);
      if (identical(nextGame, chessGame.value)) return;
      pushUndoSnapshot();
      chessGame.value = nextGame;
      dirtySinceLoad.value = true;
    }

    void toggleMoveNag(ChessMovePointer target, int nag) {
      final move = _moveAtPointer(chessGame.value, target);
      if (move == null) return;
      setMoveNags(target, _toggleNagList(move.nags ?? const <int>[], nag));
    }

    Future<void> commentAfterMoveAction() async {
      final move = _moveAtPointer(chessGame.value, pointer.value);
      if (move == null) {
        showToast('Select a move before adding a comment.', error: true);
        return;
      }
      final next = await showMoveCommentEditor(
        context,
        initialComment: _firstEditableComment(move.comments) ?? '',
      );
      if (!context.mounted || next == null) return;
      final comment = next.trim();
      setMoveComment(pointer.value, comment.isEmpty ? null : comment);
      showToast(comment.isEmpty ? 'Comment cleared' : 'Comment saved');
    }

    final hasShapes = ref.watch(
      boardAnnotationsProvider(editsTabId).select((s) => s.shapes.isNotEmpty),
    );
    final hasUserNags = ref.watch(
      userMoveNagsProvider.select(
        (m) => (m[editsTabId] ?? const <int, List<int>>{}).isNotEmpty,
      ),
    );

    // Push an undo snapshot whenever the user adds/removes a shape or
    // changes a NAG. ref.listen fires post-mutation, so [prev] is the
    // exact state to restore. Ctrl+Z then pops it back. (#461 — undo
    // covers moves, annotations, *and* arrows/highlights.)
    ref.listen<BoardAnnotations>(boardAnnotationsProvider(editsTabId), (
      prev,
      next,
    ) {
      if (prev == null) return;
      if (prev.shapes == next.shapes) return;
      if (_setsEqual(prev.shapes, next.shapes)) return;
      undoStack.value.add(
        BoardUndoSnapshot(
          game: chessGame.value,
          pointer: List<int>.unmodifiable(pointer.value),
          dirtySinceLoad: dirtySinceLoad.value,
          shapes: Set<cg.Shape>.unmodifiable(prev.shapes),
        ),
      );
      if (undoStack.value.length > 50) undoStack.value.removeAt(0);
    });
    ref.listen<Map<String, Map<int, List<int>>>>(userMoveNagsProvider, (
      prev,
      next,
    ) {
      if (prev == null) return;
      final prevTabNags = prev[editsTabId] ?? const <int, List<int>>{};
      final nextTabNags = next[editsTabId] ?? const <int, List<int>>{};
      if (_nagMapsEqual(prevTabNags, nextTabNags)) return;
      undoStack.value.add(
        BoardUndoSnapshot(
          game: chessGame.value,
          pointer: List<int>.unmodifiable(pointer.value),
          dirtySinceLoad: dirtySinceLoad.value,
          userNags: _cloneNagMap(prevTabNags),
        ),
      );
      if (undoStack.value.length > 50) undoStack.value.removeAt(0);
    });

    Future<void> resetEditsAction() async {
      final hasVars = gameHasUserVariations();
      if (!hasVars && !hasShapes && !hasUserNags) {
        showToast('Nothing to reset');
        return;
      }
      final confirmed = await showResetEditsConfirmation(
        context,
        hasVariations: hasVars,
        hasShapes: hasShapes,
        hasNags: hasUserNags,
      );
      if (!confirmed) return;
      if (!context.mounted) return;
      // Re-snapshot post-confirmation: a broadcast tick may have arrived
      // during the dialog and reshaped the tree (the merge in `applyPgn`
      // runs concurrently). Re-check before stripping so we don't wipe a
      // freshly-merged broadcaster variation.
      final freshGame = chessGame.value;
      if (_gameHasUserVariations(freshGame)) {
        pushUndoSnapshot();
        final stripped = freshGame.copyWith(
          mainline: _stripUserVariations(freshGame.mainline),
        );
        final nextPointer =
            _isPointerValid(stripped, pointer.value)
                ? pointer.value
                : _truncateToValidPointer(stripped, pointer.value);
        chessGame.value = stripped;
        pointer.value = nextPointer;
      }
      ref.read(boardAnnotationsProvider(editsTabId).notifier).clear();
      ref.read(userMoveNagsProvider.notifier).clearTab(editsTabId);
      dirtySinceLoad.value = true;
      showToast('Reset all edits');
    }

    void openBoardSettingsTab() {
      ref.read(desktopTabsProvider.notifier).open(TabKind.boardSettings);
    }

    Future<void> openPositionSetup() async {
      final nextFen = await showBoardPositionSetupDialog(
        context,
        ref: ref,
        initialFen: position.fen,
      );
      if (nextFen == null || !context.mounted) return;
      final trimmedFen = nextFen.trim();
      if (trimmedFen.isEmpty || trimmedFen == position.fen.trim()) {
        focusNode.requestFocus();
        return;
      }
      try {
        Chess.fromSetup(Setup.parseFen(trimmedFen));
      } catch (_) {
        showToast(
          'Illegal position. Check king safety and castling rights.',
          error: true,
        );
        focusNode.requestFocus();
        return;
      }
      pushUndoSnapshot();
      final nextMetadata = Map<String, dynamic>.of(chessGame.value.metadata);
      nextMetadata['FEN'] = trimmedFen;
      nextMetadata['SetUp'] = '1';
      chessGame.value = chessGame.value.copyWith(
        startingFen: trimmedFen,
        metadata: nextMetadata,
        mainline: const <ChessMove>[],
      );
      pgnHeaders.value = nextMetadata.map(
        (key, value) => MapEntry(key, value?.toString() ?? ''),
      );
      pointer.value = const <int>[];
      ref.read(boardAnnotationsProvider(editsTabId).notifier).clear();
      ref.read(userMoveNagsProvider.notifier).clearTab(editsTabId);
      dirtySinceLoad.value = true;
      showToast('Position setup applied');
      focusNode.requestFocus();
    }

    void openExplorerTab({bool toggle = false}) {
      final tabsState = ref.read(desktopTabsProvider);
      final activeTab = tabsState.active;
      if (toggle &&
          activeTab?.kind == TabKind.openingExplorer &&
          activeTab != null) {
        ref.read(desktopTabsProvider.notifier).close(activeTab.id);
        focusNode.requestFocus();
        return;
      }

      final exactFenSearch =
          _fenPositionKey(chessGame.value.startingFen) !=
          _fenPositionKey(Chess.initial.fen);
      ref
          .read(openingExplorerSeedProvider.notifier)
          .state = OpeningExplorerSeed(
        fen: position.fen,
        moves: exactFenSearch ? const <String>[] : lineUcis,
        exactFenSearch: exactFenSearch,
      );
      ref.read(desktopTabsProvider.notifier).open(TabKind.openingExplorer);
    }

    void switchRightRailPage(int delta) {
      final key = activeTabId ?? '__none__';
      final notifier = ref.read(rightRailActivePageProvider(key).notifier);
      final current = notifier.state.clamp(0, 2);
      notifier.state = (current + delta) % 3;
      focusNode.requestFocus();
    }

    Future<void> toggleEngineAction() async {
      final settings = ref.read(engineSettingsProviderNew).valueOrNull;
      final next = !(settings?.showEngineAnalysis ?? true);
      await ref
          .read(engineSettingsProviderNew.notifier)
          .toggleEngineAnalysis(next);
      showToast(next ? 'Engine analysis on' : 'Engine analysis off');
    }

    // Event-info popover is always rendered next to the action menu;
    // bumping this counter from a keyboard shortcut tells the popover
    // to toggle programmatically (without needing the user to mouse
    // over its trigger).
    final eventInfoTrigger = useState<int>(0);
    void requestEventInfo() => eventInfoTrigger.value++;

    void showUnsupportedReferenceShortcut(String feature) {
      showToast(
        '$feature is in the reference keymap; this desktop surface '
        'does not have that feature yet.',
      );
    }

    void scrollNotationByPage(int direction) {
      final controller = notationScrollController;
      if (!controller.hasClients) return;
      final viewport = controller.position.viewportDimension;
      if (viewport <= 0) return;
      final delta = viewport * 0.9 * direction;
      final next = (controller.offset + delta).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );
      controller.animateTo(
        next,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    }

    void toggleAutoReplayAction() {
      if (!autoReplay.value &&
          _nextPointer(chessGame.value, pointer.value) == null) {
        showToast('Already at the end of the game');
        return;
      }
      autoReplay.value = !autoReplay.value;
      showToast(autoReplay.value ? 'Auto-replay on' : 'Auto-replay off');
    }

    void pauseAutoReplayForManualNavigation() {
      if (autoReplay.value) autoReplay.value = false;
    }

    void goFirstManually() {
      pauseAutoReplayForManualNavigation();
      goFirst();
    }

    void goPrevManually() {
      pauseAutoReplayForManualNavigation();
      goPrev();
    }

    Future<void> goNextManually() async {
      pauseAutoReplayForManualNavigation();
      await goNextInteractive();
    }

    void goLastManually() {
      pauseAutoReplayForManualNavigation();
      goLast();
    }

    void navigatePreviousGameManually() {
      pauseAutoReplayForManualNavigation();
      unawaited(navigateActiveEventGame(ref, delta: -1));
    }

    void navigateNextGameManually() {
      pauseAutoReplayForManualNavigation();
      unawaited(navigateActiveEventGame(ref, delta: 1));
    }

    void takebackForVariationAction() {
      goPrev();
      showToast('Next board move will branch as a variation when applicable');
    }

    void deleteActiveVariationAction() {
      final head = _activeVariationHead(pointer.value);
      if (head == null) {
        showToast('No active variation to delete');
        return;
      }
      deleteVariation(head);
      showToast('Variation deleted');
    }

    void closeVariationAction() {
      final parent = _activeVariationParent(pointer.value);
      if (parent == null) {
        showToast('Already on the main line');
        return;
      }
      pointer.value = List<int>.unmodifiable(parent);
      focusNode.requestFocus();
      showToast('Returned to parent line');
    }

    Future<void> changeEngineLines(int delta) async {
      final settings =
          ref.read(engineSettingsProviderNew).valueOrNull ??
          const EngineSettings();
      final current = settings.principalVariationIndex;
      final next = (current + delta).clamp(
        0,
        EngineSettings.principalVariationLabels.length - 1,
      );
      if (next == current) {
        showToast(delta > 0 ? 'Maximum engine lines' : 'Minimum engine lines');
        return;
      }
      await ref
          .read(engineSettingsProviderNew.notifier)
          .setPrincipalVariationIndex(next);
      final count = EngineSettings.principalVariationLabels[next];
      if (context.mounted) {
        showToast('$count engine line${count == '1' ? '' : 's'}');
      }
    }

    void cutRemainingMovesAction() {
      trimContinuation(pointer.value);
      showToast('Remaining moves cut');
    }

    void clearGraphicCommentaryAction() {
      final current = ref.read(boardAnnotationsProvider(editsTabId)).shapes;
      if (current.isEmpty) {
        showToast('No graphic commentary to delete');
        return;
      }
      ref
          .read(boardAnnotationsProvider(editsTabId).notifier)
          .restore(const <cg.Shape>{});
      dirtySinceLoad.value = true;
      showToast('Graphic commentary deleted');
    }

    void clearVariationsAndCommentsAction() {
      final hasShapes =
          ref.read(boardAnnotationsProvider(editsTabId)).shapes.isNotEmpty;
      final hasNags =
          (ref.read(userMoveNagsProvider)[editsTabId] ?? const {}).isNotEmpty;
      if (!gameHasUserVariations() &&
          !hasShapes &&
          !hasNags &&
          !_gameHasCommentsOrNags(chessGame.value)) {
        showToast('Nothing to remove');
        return;
      }
      pushUndoSnapshot();
      final stripped = chessGame.value.copyWith(
        mainline: _stripVariationsCommentsAndNags(chessGame.value.mainline),
      );
      final nextPointer =
          _isPointerValid(stripped, pointer.value)
              ? pointer.value
              : _truncateToValidPointer(stripped, pointer.value);
      chessGame.value = stripped;
      pointer.value = nextPointer;
      ref
          .read(boardAnnotationsProvider(editsTabId).notifier)
          .restore(const <cg.Shape>{});
      ref
          .read(userMoveNagsProvider.notifier)
          .restoreTab(editsTabId, const <int, List<int>>{});
      dirtySinceLoad.value = true;
      showToast('Variations and commentary removed');
    }

    /// Apply (`nag != null`) or clear (`nag == null`) a quality NAG glyph
    /// on the current main-line move. Variation moves don't carry user
    /// NAGs in our model so we toast and bail.
    void setQualityNagAction(int? nag, String glyph) {
      final onMainline = pointer.value.length == 1;
      if (!onMainline || cursor <= 0) {
        showToast('Select a main-line move before annotating.', error: true);
        return;
      }
      ref
          .read(userMoveNagsProvider.notifier)
          .setQualityNag(editsTabId, cursor - 1, nag);
      dirtySinceLoad.value = true;
      showToast(nag == null ? 'Annotation cleared' : 'Annotated $glyph');
    }

    /// Promote the variation containing the current pointer. No-op on
    /// mainline.
    void promoteVariationAtCursorAction() {
      final head = _variationHeadForPointer(pointer.value);
      if (head == null) {
        showToast('Cursor is on the mainline.', error: true);
        return;
      }
      promoteVariation(head);
    }

    final lastMove = currentPly.uciMove;
    final shareUrl = buildDesktopGameShareUrl(
      game: boardArgs?.sourceGame,
      gameId: activeGameId,
    );

    void shareGameAction() {
      showBoardShareDialog(
        context,
        chessGame: chessGame.value,
        headers: pgnHeaders.value,
        position: position,
        lastMove: lastMove,
        pointer: pointer.value,
        shareUrl: shareUrl,
      );
    }

    final sideToMove = position.turn;
    final playerSide =
        position.isGameOver
            ? cg.PlayerSide.none
            : (sideToMove == Side.white
                ? cg.PlayerSide.white
                : cg.PlayerSide.black);
    final explorerPreview = _previewExplorerMove(
      position,
      explorerPreviewUci.value,
    );
    final explorerLinePreview = _previewExplorerLine(
      position,
      explorerPreviewLine.value,
      explorerPreviewLineStep.value,
    );
    final boardPosition =
        explorerLinePreview?.position ?? explorerPreview?.position ?? position;
    final boardLastMove =
        explorerLinePreview?.move ?? explorerPreview?.move ?? lastMove;
    final boardPlayerSide =
        explorerLinePreview == null && explorerPreview == null
            ? playerSide
            : cg.PlayerSide.none;

    useEffect(
      () {
        if (explorerPreviewUci.value != null && explorerPreview == null) {
          Future.microtask(() {
            if (!context.mounted) return;
            explorerPreviewUci.value = null;
          });
        }
        if (explorerPreviewLine.value.isNotEmpty &&
            explorerLinePreview == null) {
          Future.microtask(() {
            if (!context.mounted) return;
            explorerPreviewLine.value = const <String>[];
            explorerPreviewLineStep.value = 0;
            explorerPreviewLineAutoplay.value = true;
            explorerPreviewSoundKey.value = null;
          });
        }
        return null;
      },
      [
        position.fen,
        explorerPreviewUci.value,
        explorerPreviewLine.value,
        explorerPreviewLineStep.value,
      ],
    );

    useEffect(() {
      final line = explorerPreviewLine.value;
      if (line.isEmpty) return null;
      if (explorerPreviewLineStep.value >= line.length) {
        Future.microtask(() {
          if (!context.mounted) return;
          explorerPreviewLineStep.value = line.length - 1;
        });
      }
      if (line.length <= 1) return null;
      if (!explorerPreviewLineAutoplay.value) return null;
      final timer = Timer.periodic(const Duration(milliseconds: 520), (timer) {
        if (!context.mounted) {
          timer.cancel();
          return;
        }
        final next = explorerPreviewLineStep.value + 1;
        if (next >= line.length) {
          timer.cancel();
          return;
        }
        explorerPreviewLineStep.value = next;
      });
      return timer.cancel;
    }, [explorerPreviewLine.value, explorerPreviewLineAutoplay.value]);

    useEffect(() {
      final line = explorerPreviewLine.value;
      if (line.isEmpty || explorerLinePreview == null) return null;
      final key =
          '${position.fen}|${line.join(' ')}|${explorerPreviewLineStep.value}';
      if (explorerPreviewSoundKey.value == key) return null;
      explorerPreviewSoundKey.value = key;
      if (_shouldPlaySounds(ref, activeTabId)) {
        AudioPlayerService.instance.playSfxForSan(explorerLinePreview.san);
      }
      return null;
    }, [position.fen, explorerPreviewLine.value, explorerPreviewLineStep.value]);

    void playUci(String uci, {bool requestPaneFocus = true}) {
      explorerPreviewUci.value = null;
      explorerPreviewLine.value = const <String>[];
      explorerPreviewLineStep.value = 0;
      explorerPreviewLineAutoplay.value = true;
      explorerPreviewSoundKey.value = null;
      try {
        final move = Move.parse(uci);
        if (move == null) return;
        if (!position.isLegal(move)) return;
        onMove(move, requestPaneFocus: requestPaneFocus);
      } catch (_) {
        // Malformed UCI — ignore, the explorer occasionally hands out
        // promotion strings the current position can't accept.
      }
    }

    void playUciLine(ExplorerContinuationInsertion insertion) {
      explorerPreviewUci.value = null;
      explorerPreviewLine.value = const <String>[];
      explorerPreviewLineStep.value = 0;
      explorerPreviewLineAutoplay.value = true;
      explorerPreviewSoundKey.value = null;

      // Enrich the source label with the inserted continuation ply count so
      // the notation renderer can show "1-0 · 38 moves" alongside the names.
      // For full-game inserts from the start, ucis.length IS the game ply
      // count; for partial inserts it is still useful as the insertion size.
      final enrichedLabel = _withInsertionPlies(
        insertion.sourceLabel,
        insertion.ucis.length,
      );
      final sourceComment = _insertedLineSourceComment(enrichedLabel);
      // Track the pointer of the LAST successfully applied move so we attach
      // the game-source metadata to the tail of the inserted run (reference database
      // appends "1-0 · Players · Event · Year" at the end of the line).
      ChessMovePointer? lastInsertedPointer;
      var cursor = position;
      for (final raw in insertion.ucis) {
        final move = Move.parse(raw.trim().toLowerCase());
        if (move is! NormalMove || !cursor.isLegal(move)) break;
        final beforeGame = chessGame.value;
        applyMove(move, requestPaneFocus: false, suppressSound: true);
        if (!identical(chessGame.value, beforeGame) &&
            pointer.value.isNotEmpty) {
          lastInsertedPointer = List<int>.unmodifiable(pointer.value);
        }
        cursor = cursor.playUnchecked(move);
      }

      if (sourceComment != null && lastInsertedPointer != null) {
        final nextGame = _setMoveCommentAtPointer(
          chessGame.value,
          lastInsertedPointer,
          sourceComment,
        );
        if (!identical(nextGame, chessGame.value)) {
          chessGame.value = nextGame;
          dirtySinceLoad.value = true;
        }
      }
    }

    void insertGamePgn(BoardGameInsertRequest request) {
      final ucis = _continuationFromPgnAfterFen(request.pgn, position.fen);
      if (ucis.isEmpty) {
        showToast(
          'Game does not continue from the current position.',
          error: true,
        );
        return;
      }
      playUciLine(
        ExplorerContinuationInsertion(
          ucis: ucis,
          sourceLabel: request.sourceLabel,
        ),
      );
      showToast('Game inserted as variation');
    }

    ref.listen<BoardGameInsertRequest?>(boardGameInsertRequestProvider, (
      previous,
      next,
    ) {
      if (next == null || previous?.id == next.id) return;
      insertGamePgn(next);
      ref.read(boardGameInsertRequestProvider.notifier).state = null;
    });

    void playTopEngineMoveAction() {
      final settings = ref.read(engineSettingsProviderNew).valueOrNull;
      if (settings?.showEngineAnalysis == false) {
        showToast('Engine analysis is off.', error: true);
        return;
      }

      String? firstUci(String pvMoves) {
        for (final part in pvMoves.split(RegExp(r'\s+'))) {
          final first = part.trim();
          if (first.isNotEmpty) return first;
        }
        return null;
      }

      List<NormalMove>? legalMoveSequence(Position start, List<String> ucis) {
        if (ucis.isEmpty) return null;
        final out = <NormalMove>[];
        var cursor = start;
        for (final raw in ucis) {
          final move = Move.parse(raw.trim().toLowerCase());
          if (move is! NormalMove || !cursor.isLegal(move)) return null;
          out.add(move);
          cursor = cursor.playUnchecked(move);
        }
        return out;
      }

      List<String> visiblePreviewPrefix() {
        if (explorerLinePreview != null) {
          final line = explorerPreviewLine.value;
          if (line.isEmpty) return const <String>[];
          final end =
              explorerPreviewLineStep.value.clamp(0, line.length - 1).toInt();
          return List<String>.unmodifiable(line.take(end + 1));
        }
        if (explorerPreview != null) {
          final uci = explorerPreviewUci.value?.trim().toLowerCase();
          if (uci == null || uci.isEmpty) return const <String>[];
          return <String>[uci];
        }
        return const <String>[];
      }

      final visiblePvMoves =
          ref.read(boardEvalProvider(boardPosition.fen)).pvMoves.trim();
      final currentPvMoves =
          boardPosition.fen == position.fen
              ? visiblePvMoves
              : ref.read(boardEvalProvider(position.fen)).pvMoves.trim();
      final visibleFirst = firstUci(visiblePvMoves);
      final currentFirst = firstUci(currentPvMoves);
      if (visibleFirst == null && currentFirst == null) {
        showToast('No engine move ready yet.', error: true);
        return;
      }

      final visiblePrefix = visiblePreviewPrefix();
      if (visibleFirst != null && visiblePrefix.isNotEmpty) {
        final sequence = legalMoveSequence(position, [
          ...visiblePrefix,
          visibleFirst,
        ]);
        if (sequence != null) {
          explorerPreviewUci.value = null;
          explorerPreviewLine.value = const <String>[];
          explorerPreviewLineStep.value = 0;
          explorerPreviewLineAutoplay.value = true;
          explorerPreviewSoundKey.value = null;
          for (final move in sequence) {
            applyMove(move);
          }
          return;
        }
      }

      final directFirst =
          (visibleFirst != null &&
                  legalMoveSequence(position, [visibleFirst]) != null)
              ? visibleFirst
              : (currentFirst != null &&
                  legalMoveSequence(position, [currentFirst]) != null)
              ? currentFirst
              : null;
      if (directFirst == null) {
        showToast('Engine move is for a previewed position.', error: true);
        return;
      }
      playUci(directFirst);
    }

    // ---- Lichess move annotations -----------------------------------
    // Keyed off the *original* mainline SANs so the fetch signature
    // stays stable across variation switches; we just suppress display
    // when the user is exploring off-mainline.
    final headers = pgnHeaders.value;
    final originalMainlineSans = <String>[
      for (final m in chessGame.value.mainline) m.san,
    ];
    final isResultLive =
        (headers['Result'] ?? '').trim() == '*' ||
        (headers['Result'] ?? '').isEmpty;
    final lichessGameId = _extractLichessGameId(headers);
    final lichessSiteUrl = _extractLichessSiteUrl(headers);
    final movesSignature = _buildMovesSignature(originalMainlineSans);
    // We're "on the original mainline" when the pointer is exactly one
    // index deep — anything longer means we've descended into a sub-line.
    final isOnMainline = pointer.value.length == 1;
    final annotationsAsync =
        (lichessGameId == null || originalMainlineSans.isEmpty || isResultLive)
            ? const AsyncValue<Map<int, LichessMoveAnnotation>?>.data(null)
            : ref.watch(
              lichessMoveAnnotationsProvider(
                LichessMoveAnnotationsParams(
                  lichessGameId: lichessGameId,
                  siteUrl: lichessSiteUrl,
                  signature: movesSignature,
                  moveSans: originalMainlineSans,
                  isLiveGame: false,
                ),
              ),
            );
    final lichessAnnotations =
        annotationsAsync.valueOrNull ?? const <int, LichessMoveAnnotation>{};

    // Resolve the on-board badge for the current ply: user-applied NAGs
    // take precedence (the user just typed `!` and expects to see it),
    // then PGN-baked NAGs (author intent), then Lichess analysis (engine
    // classification). Only $1–$4 get the high-fidelity SVG; anything
    // else falls through to the Unicode-glyph badge.
    //
    // User NAGs are mainline-only and keyed by zero-based half-move
    // index; the move that arrived at this position is at index
    // `cursor - 1` (history[0] is the start position).
    LichessMoveAnnotation? boardAnnotation;
    NagDisplay? boardAnnotationGlyph;
    if (cursor > 0) {
      final userNagsForTab =
          ref.watch(userMoveNagsProvider)[activeTabId ?? '__none__'] ??
          const <int, List<int>>{};
      final userNagsForPly =
          isOnMainline
              ? (userNagsForTab[cursor - 1] ?? const <int>[])
              : const <int>[];
      // User NAGs win over PGN NAGs of the same quality slot; otherwise
      // both contribute (e.g. user `!` + PGN `±`). Dedupe via a Set.
      final mergedNags = <int>[
        ...userNagsForPly,
        ...currentPly.nags.where(
          (n) =>
              !userNagsForPly.contains(n) &&
              !(_isQualityNag(n) && userNagsForPly.any(_isQualityNag)),
        ),
      ];
      if (mergedNags.isNotEmpty) {
        final primary = primaryBoardNag(mergedNags) ?? mergedNags.first;
        final mapped = _mapNagToAnnotationType(primary);
        if (mapped != null) {
          boardAnnotation = LichessMoveAnnotation(type: mapped, comment: '');
        } else {
          boardAnnotationGlyph = getNagDisplay(primary);
        }
      } else if (isOnMainline) {
        // Lichess annotations are mainline-only and keyed by zero-based
        // half-move index, matching NotationDisplayToken.moveIndex.
        final annotationIndex = mainlineAnnotationIndexForPointer(
          pointer.value,
        );
        boardAnnotation =
            annotationIndex == null
                ? null
                : lichessAnnotations[annotationIndex];
      }
    }
    final boardAnnotationSquare = currentPly.lastMoveSquare;
    final pgnShapes = _shapesFromPgnComments(currentPly.comments).toList();

    // End-of-game effect: only fires on the final mainline ply of a
    // game with a decided Result header. While exploring backwards (or
    // off-mainline) the king stands upright; jumping back to the last
    // mainline move brings the falling-king / peace-icon overlay back.
    final isAtFinalMainline =
        isOnMainline &&
        chessGame.value.mainline.isNotEmpty &&
        pointer.value.first == chessGame.value.mainline.length - 1;
    final gameEnding =
        isAtFinalMainline
            ? _gameEndingFor(headers['Result'] ?? '', position)
            : null;

    // Pull the user's bindings from the sqflite-backed provider. We
    // build the (Activator → Intent) map once per binding-map change
    // rather than per build so chord-mash doesn't churn the Shortcuts
    // widget. Defaults from `defaultBoardShortcuts()` are merged in by
    // the provider itself.
    final shortcutsAsync = ref.watch(keyboardShortcutsProvider);
    final shortcutMap =
        shortcutsAsync.valueOrNull ?? BoardShortcutMap(defaultBoardShortcuts());
    final closeConfirmationOpen = useRef<bool>(false);
    String? shortcutLabelFor(BoardActionKey action) {
      final chords = shortcutMap.chordsFor(action);
      return chords.isEmpty ? null : chords.first.label;
    }

    final shortcuts = <ShortcutActivator, Intent>{};
    for (final action in BoardActionKey.values) {
      final intent = _intentFor(action);
      if (intent == null) continue;
      for (final chord in shortcutMap.chordsFor(action)) {
        shortcuts[chord.toActivator()] = intent;
      }
    }
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.bracketLeft,
          control: true,
        )] =
        const _CollapseAllVariationsIntent();
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.bracketLeft,
          meta: true,
        )] =
        const _CollapseAllVariationsIntent();
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          control: true,
        )] =
        const _ExpandAllVariationsIntent();
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.bracketRight,
          meta: true,
        )] =
        const _ExpandAllVariationsIntent();
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          shift: true,
        )] =
        const _FirstMoveIntent();
    shortcuts[const SingleActivator(
          LogicalKeyboardKey.arrowRight,
          shift: true,
        )] =
        const _LastMoveIntent();

    bool invokeBoardAction(BoardActionKey action) {
      bool hasLocalNotationEdits() {
        return shouldConfirmBoardTabCloseForLocalNotationEdits(
          dirtySinceLoad: dirtySinceLoad.value,
          currentPgn: exportGameToPgn(chessGame.value),
          lastAppliedPgn: lastAppliedPgn.value,
        );
      }

      Future<void> closeActiveBoardTab({required bool force}) async {
        final tabIdToClose = activeTabId;
        if (tabIdToClose == null) return;
        if (!force && hasLocalNotationEdits()) {
          if (closeConfirmationOpen.value) return;
          closeConfirmationOpen.value = true;
          final shouldClose = await showDesktopModal<bool>(
            context,
            title: 'Are you sure?',
            maxWidth: 360,
            maxHeight: 220,
            barrierDismissible: true,
            builder:
                (dialogContext) => _BoardCloseConfirmationDialog(
                  onConfirm: () => Navigator.of(dialogContext).pop(true),
                  onCancel: () => Navigator.of(dialogContext).pop(false),
                ),
          ).whenComplete(() => closeConfirmationOpen.value = false);
          if (shouldClose != true) return;
        }
        ref.read(desktopTabsProvider.notifier).close(tabIdToClose);
      }

      switch (action) {
        case BoardActionKey.prevMove:
          goPrevManually();
          return true;
        case BoardActionKey.nextMove:
          unawaited(goNextManually());
          return true;
        case BoardActionKey.previousNotationLine:
          goNotationLine(NotationVerticalDirection.up);
          return true;
        case BoardActionKey.nextNotationLine:
          goNotationLine(NotationVerticalDirection.down);
          return true;
        case BoardActionKey.firstMove:
          goFirstManually();
          return true;
        case BoardActionKey.lastMove:
          goLastManually();
          return true;
        case BoardActionKey.prevVariation:
          goPrevVariation();
          return true;
        case BoardActionKey.nextVariation:
          goNextVariation();
          return true;
        case BoardActionKey.undoLastEdit:
          undoLastEditAction();
          return true;
        case BoardActionKey.flipBoard:
          flipped.value = !flipped.value;
          return true;
        case BoardActionKey.copyPgn:
          unawaited(copyPgnAction());
          return true;
        case BoardActionKey.pastePgn:
          unawaited(pastePgnAction());
          return true;
        case BoardActionKey.savePgnFile:
          unawaited(savePgnAction());
          return true;
        case BoardActionKey.saveGameToLibrary:
          unawaited(saveGameToLibraryAction());
          return true;
        case BoardActionKey.commentAfterMove:
          unawaited(commentAfterMoveAction());
          return true;
        case BoardActionKey.playEngineMove:
          playTopEngineMoveAction();
          return true;
        case BoardActionKey.clearAnalysis:
          unawaited(resetEditsAction());
          return true;
        case BoardActionKey.showEventInfo:
          requestEventInfo();
          return true;
        case BoardActionKey.toggleEngine:
          unawaited(toggleEngineAction());
          return true;
        case BoardActionKey.openExplorer:
          openExplorerTab(toggle: true);
          return true;
        case BoardActionKey.openPositionSetup:
          unawaited(openPositionSetup());
          return true;
        case BoardActionKey.openBoardSettings:
          openBoardSettingsTab();
          return true;
        case BoardActionKey.prevGame:
          navigatePreviousGameManually();
          return true;
        case BoardActionKey.nextGame:
          navigateNextGameManually();
          return true;
        case BoardActionKey.autoReplay:
          toggleAutoReplayAction();
          return true;
        case BoardActionKey.goToMoveNumber:
          showUnsupportedReferenceShortcut('Go to move number');
          return true;
        case BoardActionKey.makeNextMoveVariation:
          takebackForVariationAction();
          return true;
        case BoardActionKey.enterNullMove:
          showUnsupportedReferenceShortcut('Null moves');
          return true;
        case BoardActionKey.deleteVariation:
          deleteActiveVariationAction();
          return true;
        case BoardActionKey.switchNotationView:
          final nextInline =
              notationLayoutController.value != NotationLayoutMode.inline;
          unawaited(
            ref
                .read(boardSettingsProviderNew.notifier)
                .toggleNotationInline(nextInline),
          );
          return true;
        case BoardActionKey.rightRailPreviousTab:
          switchRightRailPage(-1);
          return true;
        case BoardActionKey.rightRailNextTab:
          switchRightRailPage(1);
          return true;
        case BoardActionKey.rightRailPreviousTable:
        case BoardActionKey.rightRailNextTable:
        case BoardActionKey.rightRailActivateSelection:
          return false;
        case BoardActionKey.closeVariation:
          closeVariationAction();
          return true;
        case BoardActionKey.increaseEngineLines:
          unawaited(changeEngineLines(1));
          return true;
        case BoardActionKey.decreaseEngineLines:
          unawaited(changeEngineLines(-1));
          return true;
        case BoardActionKey.scrollNotationUp:
          scrollNotationByPage(-1);
          return true;
        case BoardActionKey.scrollNotationDown:
          scrollNotationByPage(1);
          return true;
        case BoardActionKey.cutRemainingMoves:
          cutRemainingMovesAction();
          return true;
        case BoardActionKey.cutPreviousMoves:
          showUnsupportedReferenceShortcut('Cut previous moves');
          return true;
        case BoardActionKey.clearVariationsAndComments:
          clearVariationsAndCommentsAction();
          return true;
        case BoardActionKey.commentBeforeMove:
          showUnsupportedReferenceShortcut('Comment before move');
          return true;
        case BoardActionKey.annotateGoodMove:
          setQualityNagAction(1, '!');
          return true;
        case BoardActionKey.annotateBrilliant:
          setQualityNagAction(3, '!!');
          return true;
        case BoardActionKey.annotateMistake:
          setQualityNagAction(2, '?');
          return true;
        case BoardActionKey.annotateBlunder:
          setQualityNagAction(4, '??');
          return true;
        case BoardActionKey.annotateInteresting:
          setQualityNagAction(5, '!?');
          return true;
        case BoardActionKey.annotateDubious:
          setQualityNagAction(6, '?!');
          return true;
        case BoardActionKey.clearAnnotation:
          setQualityNagAction(null, '');
          return true;
        case BoardActionKey.promoteVariation:
          promoteVariationAtCursorAction();
          return true;
        case BoardActionKey.deleteGraphicCommentary:
          clearGraphicCommentaryAction();
          return true;
        case BoardActionKey.trainingCommentary:
          showUnsupportedReferenceShortcut('Training commentary');
          return true;
        case BoardActionKey.correspondenceHeader:
          showUnsupportedReferenceShortcut('Correspondence headers');
          return true;
        case BoardActionKey.correspondenceMove:
          showUnsupportedReferenceShortcut('Correspondence move annotation');
          return true;
        case BoardActionKey.replaceGame:
          showUnsupportedReferenceShortcut('Database replace');
          return true;
        case BoardActionKey.insertBestVariation:
          playTopEngineMoveAction();
          return true;
        case BoardActionKey.showThreat:
          showUnsupportedReferenceShortcut('Threat calculation');
          return true;
        case BoardActionKey.calculateNextBestMove:
          showUnsupportedReferenceShortcut('Next-best-move calculation');
          return true;
        case BoardActionKey.togglePhotosWindow:
          showUnsupportedReferenceShortcut('Photos window');
          return true;
        case BoardActionKey.toggleNotationWindow:
          showUnsupportedReferenceShortcut('Notation window toggling');
          return true;
        case BoardActionKey.toggleBoardFocus:
          ref.read(boardFocusModeProvider.notifier).state = !boardFocusMode;
          return true;
        case BoardActionKey.closeWindow:
          if (boardFocusMode) {
            ref.read(boardFocusModeProvider.notifier).state = false;
            return true;
          }
          unawaited(closeActiveBoardTab(force: false));
          return true;
      }
    }

    latestBoardActionInvoker.value = invokeBoardAction;
    useEffect(() {
      final dispatcher = ActiveBoardShortcutDispatcher(
        tabId: activeTabId ?? 'board-default',
        invoke:
            (action) => latestBoardActionInvoker.value?.call(action) ?? false,
      );
      final notifier = ref.read(activeBoardShortcutDispatcherProvider.notifier);
      // useEffect on flutter_hooks fires its body synchronously inside
      // `initHook`. When BoardPane mounts inside a LayoutBuilder pass
      // (as it does when opening a game) writing provider state right
      // here trips Riverpod's "no provider modification during build"
      // guard. Defer the write to a microtask so it lands after the
      // current frame finishes flushing. Same teardown story.
      var assigned = false;
      Future.microtask(() {
        if (notifier.mounted) {
          notifier.state = dispatcher;
          assigned = true;
        }
      });
      return () {
        if (!assigned) return;
        if (identical(notifier.state, dispatcher)) {
          Future.microtask(() {
            if (notifier.mounted && identical(notifier.state, dispatcher)) {
              notifier.state = null;
            }
          });
        }
      };
    }, [activeTabId]);

    // Re-grab focus when this board tab becomes the active tab. The
    // outer `Focus(autofocus: true)` only fires on the *first* attach,
    // which isn't enough when the user swaps to another tab and back —
    // and #461 reports that arrow keys do not respond until the user
    // clicks the notation. Pulling focus here means ←/→ work the moment
    // the tab is visible, no notation click required.
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (focusNode.context != null) {
          focusNode.requestFocus();
        }
      });
      return null;
    }, [activeTabId]);

    bool primaryFocusIsEditableText() {
      final focusContext = FocusManager.instance.primaryFocus?.context;
      if (focusContext == null) return false;
      var editable = false;
      void visitor(Element element) {
        if (element.widget is EditableText) editable = true;
        element.visitChildElements(visitor);
      }

      focusContext.visitChildElements(visitor);
      return editable;
    }

    final actions = <Type, Action<Intent>>{
      _PrevMoveIntent: CallbackAction<_PrevMoveIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.prevMove);
          return null;
        },
      ),
      _NextMoveIntent: CallbackAction<_NextMoveIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.nextMove);
          return null;
        },
      ),
      _FirstMoveIntent: CallbackAction<_FirstMoveIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.firstMove);
          return null;
        },
      ),
      _LastMoveIntent: CallbackAction<_LastMoveIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.lastMove);
          return null;
        },
      ),
      _PrevVariationIntent: CallbackAction<_PrevVariationIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.prevVariation);
          return null;
        },
      ),
      _NextVariationIntent: CallbackAction<_NextVariationIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.nextVariation);
          return null;
        },
      ),
      _UndoLastEditIntent: CallbackAction<_UndoLastEditIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.undoLastEdit);
          return null;
        },
      ),
      _FlipBoardIntent: CallbackAction<_FlipBoardIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.flipBoard);
          return null;
        },
      ),
      _CopyPgnIntent: CallbackAction<_CopyPgnIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.copyPgn);
          return null;
        },
      ),
      _PastePgnIntent: CallbackAction<_PastePgnIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.pastePgn);
          return null;
        },
      ),
      _SavePgnIntent: CallbackAction<_SavePgnIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.savePgnFile);
          return null;
        },
      ),
      _SaveGameToLibraryIntent: CallbackAction<_SaveGameToLibraryIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.saveGameToLibrary);
          return null;
        },
      ),
      _CommentAfterMoveIntent: CallbackAction<_CommentAfterMoveIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.commentAfterMove);
          return null;
        },
      ),
      _PlayEngineMoveIntent: CallbackAction<_PlayEngineMoveIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.playEngineMove);
          return null;
        },
      ),
      _ClearAnalysisIntent: CallbackAction<_ClearAnalysisIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.clearAnalysis);
          return null;
        },
      ),
      _ShowEventInfoIntent: CallbackAction<_ShowEventInfoIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.showEventInfo);
          return null;
        },
      ),
      _ToggleEngineIntent: CallbackAction<_ToggleEngineIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.toggleEngine);
          return null;
        },
      ),
      _OpenExplorerIntent: CallbackAction<_OpenExplorerIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.openExplorer);
          return null;
        },
      ),
      _OpenBoardSettingsIntent: CallbackAction<_OpenBoardSettingsIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.openBoardSettings);
          return null;
        },
      ),
      _PrevGameIntent: CallbackAction<_PrevGameIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.prevGame);
          return null;
        },
      ),
      _NextGameIntent: CallbackAction<_NextGameIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.nextGame);
          return null;
        },
      ),
      _AutoReplayIntent: CallbackAction<_AutoReplayIntent>(
        onInvoke: (_) {
          invokeBoardAction(BoardActionKey.autoReplay);
          return null;
        },
      ),
      _CollapseAllVariationsIntent:
          CallbackAction<_CollapseAllVariationsIntent>(
            onInvoke: (_) {
              notationVariationCollapseController.collapseAll();
              return null;
            },
          ),
      _ExpandAllVariationsIntent: CallbackAction<_ExpandAllVariationsIntent>(
        onInvoke: (_) {
          notationVariationCollapseController.expandAll();
          return null;
        },
      ),
      _BoardActionIntent: CallbackAction<_BoardActionIntent>(
        onInvoke: (intent) {
          if (intent.action == BoardActionKey.openPositionSetup &&
              primaryFocusIsEditableText()) {
            return null;
          }
          invokeBoardAction(intent.action);
          return null;
        },
      ),
    };

    NotationLadderView buildNotationLadder({
      required ScrollController scrollController,
      required ChessMovePointer activePointer,
      required ValueChanged<ChessMovePointer> onJump,
      required ValueNotifier<NotationLayoutMode> layoutModeController,
    }) {
      return NotationLadderView(
        game: chessGame.value,
        activePointer: activePointer,
        onJump: onJump,
        scrollController: scrollController,
        visibleMoveOrderController: visibleNotationMoveOrderController,
        lichessAnnotations: lichessAnnotations,
        userNags:
            ref.watch(userMoveNagsProvider)[activeTabId ?? '__none__'] ??
            const <int, List<int>>{},
        onSetUserQualityNag: (ply, nag) {
          final id = activeTabId;
          if (id == null) return;
          ref.read(userMoveNagsProvider.notifier).setQualityNag(id, ply, nag);
          dirtySinceLoad.value = true;
        },
        onToggleUserNag: (ply, nag) {
          final id = activeTabId;
          if (id == null) return;
          ref.read(userMoveNagsProvider.notifier).toggleNag(id, ply, nag);
          dirtySinceLoad.value = true;
        },
        onClearUserNags: (ply) {
          final id = activeTabId;
          if (id == null) return;
          ref.read(userMoveNagsProvider.notifier).clearNags(id, ply);
          dirtySinceLoad.value = true;
        },
        onToggleMoveNag: toggleMoveNag,
        onClearMoveNags: (target) => setMoveNags(target, const <int>[]),
        onSetMoveComment: setMoveComment,
        onPromoteVariation: promoteVariation,
        onDeleteVariation: deleteVariation,
        onTrimContinuation: trimContinuation,
        useFigurine: notationUseFigurine,
        pieceAssets: notationPieceAssets,
        layoutModeController: layoutModeController,
        variationCollapseController: notationVariationCollapseController,
      );
    }

    final showGameRail = hasGameRail && !boardFocusMode;
    void openPlayFromHereDialog() {
      showPlayFromHereDialog(
        context,
        ref,
        seed: PlayFromHereSeed(
          fen: position.fen,
          startingFen: lineUcis.isEmpty ? null : chessGame.value.startingFen,
          movesUci: lineUcis,
          inheritedWhiteBaseSeconds: _baseSecondsFromClock(whiteClockRaw),
          inheritedWhiteIncrementSeconds: _incrementFromHeaders(
            pgnHeaders.value,
          ),
          inheritedBlackBaseSeconds: _baseSecondsFromClock(blackClockRaw),
          inheritedBlackIncrementSeconds: _incrementFromHeaders(
            pgnHeaders.value,
          ),
        ),
      );
    }

    final boardActionCluster =
        boardFocusMode
            ? null
            : _RightRailBoardActions(
              headers: pgnHeaders.value,
              eventInfoTrigger: eventInfoTrigger.value,
              onSaveGame: () => unawaited(saveGameToLibraryAction()),
              canSaveGame: chessGame.value.mainline.isNotEmpty,
              saveShortcutLabel:
                  shortcutMap
                          .chordsFor(BoardActionKey.saveGameToLibrary)
                          .isEmpty
                      ? null
                      : shortcutMap
                          .chordsFor(BoardActionKey.saveGameToLibrary)
                          .first
                          .label,
              onPlayAgain:
                  (pgnHeaders.value['ChessEverEngineKind']?.isNotEmpty ?? false)
                      ? () =>
                          startPlayAgainFromBoardHeaders(ref, pgnHeaders.value)
                      : null,
              onPlayFromHere: openPlayFromHereDialog,
            );

    final boardSplitIndex = showGameRail ? 1 : 0;
    // 13" MacBooks (1280–1366 logical) and other small laptops can't
    // afford the games rail by default — it eats over a third of the
    // usable board width. Default to collapsed on first mount when the
    // window is below this threshold; persisted layout (via storageKey)
    // overrides this once the user has expressed a preference.
    final screenWidth = MediaQuery.of(context).size.width;
    const smallScreenWidthThreshold = 1400.0;
    final gameRailInitialCollapsed = screenWidth < smallScreenWidthThreshold;

    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: Focus(
          focusNode: focusNode,
          autofocus: true,
          // Make sure focus comes back to the pane when the user clicks
          // empty space — chessground keeps its own focus while a piece
          // is selected, but everywhere else we want the shell-level
          // shortcuts to be live.
          canRequestFocus: true,
          child: ResizableSplitView(
            axis: Axis.horizontal,
            controller: mainSplitController,
            // Storage key flips between contextual and scratch modes so the
            // split view keeps independent persisted widths. Event and
            // database/library tabs both carry a left games rail; scratch
            // tabs do not. Focus mode deliberately uses NO storage key —
            // the maximise useEffect re-computes the layout from scratch
            // on every entry, and a persisted key was async-overriding
            // that maximise via `_restore()` after `setSize`.
            storageKey:
                boardFocusMode
                    ? null
                    : hasGameRail
                    ? 'board_pane.main.context.v2'
                    : 'board_pane.main.scratch',
            children: [
              // In-context games rail. Event tabs group by round; database
              // and library tabs use the source list that opened the board.
              if (showGameRail)
                SplitChild(
                  minSize: 220,
                  maxSize: 520,
                  initialWeight: 0.29,
                  label: 'Games',
                  collapsedIcon: Icons.view_list_rounded,
                  dismissible: true,
                  initialCollapsed: gameRailInitialCollapsed,
                  child: EventGamesTable(
                    tabId: activeTabId ?? 'board-default',
                    onClose: () => mainSplitController.collapse(0),
                  ),
                ),
              SplitChild(
                minSize: 380,
                initialWeight: boardFocusMode ? _boardFocusBoardWeight : 0.41,
                label: 'Board',
                collapsedIcon: Icons.grid_on_rounded,
                dismissible: false,
                child: Column(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onSecondaryTapUp: (details) {
                          // Modifier+Right is reserved for drawing circles /
                          // colour variants on the board annotation layer.
                          // Plain right-drag draws arrows; plain right-click
                          // still opens this context menu.
                          final pressed =
                              HardwareKeyboard.instance.logicalKeysPressed;
                          final annotationModifierHeld =
                              pressed.contains(LogicalKeyboardKey.shiftLeft) ||
                              pressed.contains(LogicalKeyboardKey.shiftRight) ||
                              pressed.contains(LogicalKeyboardKey.altLeft) ||
                              pressed.contains(LogicalKeyboardKey.altRight) ||
                              pressed.contains(
                                LogicalKeyboardKey.controlLeft,
                              ) ||
                              pressed.contains(
                                LogicalKeyboardKey.controlRight,
                              ) ||
                              pressed.contains(LogicalKeyboardKey.metaLeft) ||
                              pressed.contains(LogicalKeyboardKey.metaRight);
                          if (annotationModifierHeld) return;
                          showBoardContextMenu(
                            ref,
                            context,
                            position: details.globalPosition,
                            onShareGame: shareGameAction,
                            onCopyPgn: copyPgnAction,
                            onCopyFen: copyFenAction,
                            onSavePgn: savePgnAction,
                            onSaveGameToLibrary:
                                () => unawaited(saveGameToLibraryAction()),
                            onOpenBoardSettings: openBoardSettingsTab,
                            onOpenPositionSetup: openPositionSetup,
                            canCopyOrSavePgn:
                                chessGame.value.mainline.isNotEmpty,
                            onPlayFromHere: openPlayFromHereDialog,
                          );
                        },
                        child: _BoardArea(
                          tabId: activeTabId ?? 'board-default',
                          boardRenderKey: boardRenderKey,
                          fen: boardPosition.fen,
                          flipped: flipped.value,
                          sideToMove: boardPosition.turn,
                          playerSide: boardPlayerSide,
                          validMoves: makeLegalMoves(boardPosition),
                          isCheck: boardPosition.isCheck,
                          lastMove: boardLastMove,
                          onMove: onMove,
                          promotionMove: promotionMove.value,
                          onPromotionSelection: onPromotionSelection,
                          pgnHeaders: pgnHeaders.value,
                          pgnShapes:
                              explorerPreview == null
                                  ? pgnShapes
                                  : const <cg.Shape>[],
                          whiteClock: whiteClockRaw,
                          blackClock: blackClockRaw,
                          boardAnnotation:
                              explorerPreview == null ? boardAnnotation : null,
                          boardAnnotationGlyph:
                              explorerPreview == null
                                  ? boardAnnotationGlyph
                                  : null,
                          boardAnnotationSquare:
                              explorerPreview == null
                                  ? boardAnnotationSquare
                                  : null,
                          gameEnding:
                              explorerPreview == null ? gameEnding : null,
                          onWheelStep: stepNotationHorizontally,
                          isLiveAtTip: isLiveAtTip,
                          activeGameId: activeGameId,
                          boardArgs: boardArgs,
                          sourceGame: boardArgs?.sourceGame,
                          viewSource:
                              boardArgs?.viewSource ?? ChessboardView.tour,
                          focusMode: boardFocusMode,
                          focusShortcutLabel: shortcutLabelFor(
                            BoardActionKey.toggleBoardFocus,
                          ),
                          onFocusModeChanged: (value) {
                            ref.read(boardFocusModeProvider.notifier).state =
                                value;
                          },
                          boardSizePreference: boardSizePreference.value,
                          onBoardSizeChanged: (size) {
                            setBoardSizePreference(size);
                            final settings =
                                ref
                                    .read(engineSettingsProviderNew)
                                    .valueOrNull ??
                                const EngineSettings();
                            final evalBarReservation =
                                shouldShowDesktopBoardEvalBar(settings)
                                    ? _BoardArea.evalBarReservation
                                    : 0.0;
                            final targetColumnSize =
                                size + evalBarReservation + 48;
                            final appliedColumnSize = mainSplitController
                                .setSize(boardSplitIndex, targetColumnSize);
                            boardResizeHitSplitLimit.value =
                                appliedColumnSize != null &&
                                targetColumnSize >
                                    appliedColumnSize + _resizeFocusOvershoot;
                          },
                          onBoardSizeReset: () {
                            setBoardSizePreference(null);
                          },
                          onBoardSizeChangeEnd: () {
                            final grewPastSplitLimit =
                                boardResizeHitSplitLimit.value;
                            boardResizeHitSplitLimit.value = false;
                            persistBoardSizePreference(
                              grewPastResizeLimit: grewPastSplitLimit,
                            );
                          },
                        ),
                      ),
                    ),
                    // Optional move-nav cluster sits directly under the board.
                    // It is hidden by default so the board reclaims the
                    // vertical space; keyboard, mouse-wheel, and notation
                    // navigation remain active regardless of this visual row.
                    if (!boardFocusMode && showMoveNavigation)
                      MoveNavigationBar(
                        canGoBack: canBack,
                        canGoForward: canForward,
                        onFirst: goFirstManually,
                        onPrevious: goPrevManually,
                        onNext: () => unawaited(goNextManually()),
                        onLast: goLastManually,
                        onPlayPause: toggleAutoReplayAction,
                        onPreviousGame: navigatePreviousGameManually,
                        onNextGame: navigateNextGameManually,
                        isPlaying: autoReplay.value,
                        onFlipBoard: () => flipped.value = !flipped.value,
                        moveLabel: _moveLabel(history, cursor),
                        hasUnseenLiveMove: hasUnseenMoves.value,
                      ),
                  ],
                ),
              ),
              SplitChild(
                minSize: 280,
                initialWeight:
                    boardFocusMode ? _boardFocusRightPaneWeight : 0.30,
                label: 'Analysis',
                collapsedIcon: Icons.analytics_outlined,
                child: KeyedSubtree(
                  key: rightRailAnalysisKey,
                  child: _RightRailAnalysis(
                    showEngine: ref.watch(
                      engineSettingsProviderNew.select(
                        (s) =>
                            s.valueOrNull?.showEngineAnalysis ??
                            const EngineSettings().showEngineAnalysis,
                      ),
                    ),
                    notationPanel: NotationOpeningPanel(
                      tabId: activeTabId,
                      explorerScope: boardExplorerScope,
                      notationChild: buildNotationLadder(
                        scrollController: notationScrollController,
                        activePointer: pointer.value,
                        onJump: jumpToPointer,
                        layoutModeController: notationLayoutController,
                      ),
                      currentFen: position.fen,
                      startingFen: chessGame.value.startingFen,
                      lineUcis: lineUcis,
                      previewLineStep: explorerPreviewLineStep.value,
                      previewLineAutoplay: explorerPreviewLineAutoplay.value,
                      onPlayUciMove:
                          (uci) => playUci(uci, requestPaneFocus: false),
                      onPlayEngineMove: playTopEngineMoveAction,
                      onPlayUciLine: playUciLine,
                      onPreviewUciMove: (uci) {
                        explorerPreviewLine.value = const <String>[];
                        explorerPreviewLineStep.value = 0;
                        explorerPreviewLineAutoplay.value = true;
                        explorerPreviewSoundKey.value = null;
                        explorerPreviewUci.value = uci;
                      },
                      onPreviewUciLine: (ucis, {autoplay = true, step}) {
                        explorerPreviewUci.value = null;
                        explorerPreviewLineStep.value =
                            (step ?? 0)
                                .clamp(0, ucis.isEmpty ? 0 : ucis.length - 1)
                                .toInt();
                        explorerPreviewLineAutoplay.value = autoplay;
                        explorerPreviewSoundKey.value = null;
                        explorerPreviewLine.value = List<String>.unmodifiable(
                          ucis
                              .map((uci) => uci.trim().toLowerCase())
                              .where((uci) => uci.isNotEmpty),
                        );
                      },
                      onClearPreviewUciMove: () {
                        explorerPreviewUci.value = null;
                        explorerPreviewLine.value = const <String>[];
                        explorerPreviewLineStep.value = 0;
                        explorerPreviewLineAutoplay.value = true;
                        explorerPreviewSoundKey.value = null;
                      },
                      onNotationVertical: goNotationLine,
                      onNotationStep: stepNotationHorizontally,
                      onNotationJumpToHead: goFirst,
                      onNotationJumpToTip: goLast,
                      canGoBack: canBack,
                      canGoForward: canForward,
                      onFirstMove: goFirstManually,
                      onPreviousMove: goPrevManually,
                      onNextMove: () => unawaited(goNextManually()),
                      onLastMove: goLastManually,
                      onPreviousGame: navigatePreviousGameManually,
                      onNextGame: navigateNextGameManually,
                      trailingActions: boardActionCluster,
                    ),
                    enginePanel: EnginePanel(
                      fen: boardPosition.fen,
                      sideToMove: boardPosition.turn == Side.white ? 'w' : 'b',
                      onPlayUci: playUci,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Local subclass that exposes [ChessGameNavigator]'s `@protected`
/// `state` getter so the BoardPane build can drive the navigator's
/// mutation methods (`makeOrGoToMove`, `promoteVariationToMainline`,
/// `deleteVariationAtPointer`, `deleteContinuationAfterPointer`) and
/// pull the resulting `(game, pointer)` back into the pane's hooks.
/// Mobile would use the matching Riverpod provider instead — we don't
/// need a Riverpod instance because BoardPane already owns its own
/// `chessGame` / `pointer` `useState` hooks; the navigator here is a
/// one-shot mutator scoped to a single user gesture.
/// Right-rail analysis container. When the engine is disabled the engine
/// section collapses to the same restorable rail affordance used by dismissed
/// split panes, so the user has a clear one-click way to bring it back.
class _RightRailAnalysis extends ConsumerStatefulWidget {
  const _RightRailAnalysis({
    required this.showEngine,
    required this.notationPanel,
    required this.enginePanel,
  });

  final bool showEngine;
  final Widget notationPanel;
  final Widget enginePanel;

  @override
  ConsumerState<_RightRailAnalysis> createState() => _RightRailAnalysisState();
}

class _RightRailAnalysisState extends ConsumerState<_RightRailAnalysis> {
  final ResizableSplitViewController _splitController =
      ResizableSplitViewController();

  @override
  void initState() {
    super.initState();
    _syncEngineRailAfterLayout();
  }

  @override
  void didUpdateWidget(covariant _RightRailAnalysis oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showEngine != widget.showEngine) {
      _syncEngineRailAfterLayout(restoreWhenEnabled: !oldWidget.showEngine);
    }
  }

  void _syncEngineRailAfterLayout({bool restoreWhenEnabled = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.showEngine) {
        if (!restoreWhenEnabled) return;
        _splitController.restore(0);
        return;
      }
      _splitController.collapse(0, persist: false);
    });
  }

  void _resumeEngineFromRail() {
    unawaited(
      ref.read(engineSettingsProviderNew.notifier).toggleEngineAnalysis(true),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ResizableSplitView(
      axis: Axis.vertical,
      controller: _splitController,
      storageKey: 'board_pane.right_rail.engine_top.v1',
      children: [
        SplitChild(
          minSize: 120,
          initialWeight: 0.34,
          label: 'Engine',
          collapsedIcon: Icons.memory_rounded,
          onRestore: _resumeEngineFromRail,
          child: widget.enginePanel,
        ),
        SplitChild(
          minSize: 240,
          initialWeight: 0.66,
          label: 'Notation',
          collapsedIcon: Icons.format_list_numbered_rounded,
          child: widget.notationPanel,
        ),
      ],
    );
  }
}

class _LocalChessGameNavigator extends ChessGameNavigator {
  _LocalChessGameNavigator(super.game);
  ChessGameNavigatorState get currentState => state;
}

ChessMovePointer? _activeVariationHead(ChessMovePointer pointer) {
  if (pointer.length < 3) return null;
  for (var i = pointer.length - 2; i >= 1; i--) {
    if (i.isOdd) {
      return <int>[...pointer.sublist(0, i + 1), 0];
    }
  }
  return null;
}

ChessMovePointer? _activeVariationParent(ChessMovePointer pointer) {
  final head = _activeVariationHead(pointer);
  if (head == null) return null;
  final variationIndexPosition = head.length - 2;
  return List<int>.unmodifiable(head.sublist(0, variationIndexPosition));
}

bool _gameHasCommentsOrNags(ChessGame game) {
  bool walk(ChessLine line) {
    for (final move in line) {
      if ((move.comments?.isNotEmpty ?? false) ||
          (move.nags?.isNotEmpty ?? false)) {
        return true;
      }
      final variations = move.variations;
      if (variations != null) {
        for (final variation in variations) {
          if (walk(variation)) return true;
        }
      }
    }
    return false;
  }

  return walk(game.mainline);
}

ChessLine _stripVariationsCommentsAndNags(ChessLine line) {
  return [
    for (final move in line)
      move.copyWith(
        comments: const <String>[],
        nags: const <int>[],
        variations: null,
        overrideVariations: true,
      ),
  ];
}

/// Shallow set equality for `Set<cg.Shape>`. The chessground shape types
/// (Arrow / Circle) implement value equality, so a default `==` on the
/// containing set works — this helper just keeps the call sites readable.
/// Whether a NAG code is a move-quality glyph (`!`, `?`, `!!`, `??`, `!?`,
/// `?!`, `□`). Mirrors `UserMoveNagsNotifier._isQualityNag`'s range so the
/// board-pane merge logic doesn't accidentally suppress a PGN `±` (eval)
/// or `⟳` (observation) NAG just because the user added a quality glyph.
bool _isQualityNag(int nag) => nag >= 1 && nag <= 7;

bool _setsEqual(Set<cg.Shape> a, Set<cg.Shape> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final s in a) {
    if (!b.contains(s)) return false;
  }
  return true;
}

/// Value equality for per-half-move NAG maps. Used by the undo stack to
/// detect when a restore would be a no-op and skip the bookkeeping.
bool _nagMapsEqual(Map<int, List<int>> a, Map<int, List<int>> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null) return false;
    final l = entry.value;
    if (l.length != other.length) return false;
    for (var i = 0; i < l.length; i++) {
      if (l[i] != other[i]) return false;
    }
  }
  return true;
}

/// Deep-copy a NAG map so the undo stack holds a stable snapshot the
/// caller can't mutate after-the-fact.
Map<int, List<int>> _cloneNagMap(Map<int, List<int>> source) {
  return Map<int, List<int>>.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<int>.unmodifiable(entry.value),
  });
}

/// Empty seed used both for the very first build of a Board pane (no
/// PGN loaded yet) and for the activeGameId-reset flow. Has the
/// standard chess starting FEN and an empty mainline so the user can
/// immediately drag a piece to play; metadata enables mainline
/// extension by default since freeplay is "extend, don't branch".
final _emptyChessGame = ChessGame(
  gameId: '',
  startingFen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  metadata: const <String, dynamic>{
    ChessGame.metadataAllowMainlineExtensionKey: true,
    ChessGame.metadataIsLiveKey: false,
  },
  mainline: const <ChessMove>[],
);

LibraryUpdateTarget? _libraryUpdateTargetForBoardArgs({
  required WidgetRef ref,
  required BoardTabGameArgs? boardArgs,
  required ChessGame game,
}) {
  final origin = boardArgs?.librarySaveOrigin;
  if (origin == null) return null;
  switch (origin.kind) {
    case BoardTabLibrarySaveOriginKind.cloudSavedAnalysis:
      final analysisId = origin.analysisId?.trim();
      if (analysisId == null || analysisId.isEmpty) return null;
      return LibraryUpdateTarget(
        title:
            origin.title.trim().isEmpty
                ? _libraryGameTitle(game)
                : origin.title,
        subtitle: 'Cloud library',
        onUpdate: () async {
          final repo = ref.read(libraryRepositoryProvider);
          final existing = await repo.getSavedAnalysis(analysisId);
          if (existing == null) {
            throw StateError('Original cloud library game was not found.');
          }
          await repo.updateSavedAnalysis(
            existing.copyWith(
              title: _libraryGameTitle(game),
              chessGame: game,
              updatedAt: DateTime.now(),
            ),
          );
          ref.invalidate(libraryFoldersStreamProvider);
          ref.invalidate(subscribedBooksProvider);
          notifyCloudLibraryChanged(ref);
        },
      );
    case BoardTabLibrarySaveOriginKind.localPgnFile:
      final sourcePath = origin.sourcePath?.trim();
      final sourceIndex = origin.sourceIndex;
      final sourceFileGameCount = origin.sourceFileGameCount;
      if (sourcePath == null ||
          sourcePath.isEmpty ||
          sourceIndex == null ||
          sourceFileGameCount == null ||
          !isLocalLibraryPgnUpdateSupported(sourcePath)) {
        return null;
      }
      return LibraryUpdateTarget(
        title:
            origin.title.trim().isEmpty
                ? _libraryGameTitle(game)
                : origin.title,
        subtitle: 'Local PGN file',
        onUpdate: () async {
          await updateLocalLibraryPgnGame(
            target: LocalLibraryGameUpdateTarget(
              sourcePath: sourcePath,
              indexInFile: sourceIndex,
              fileGameCount: sourceFileGameCount,
            ),
            game: game,
          );
          unawaited(ref.read(localChessLibraryProvider.notifier).refresh());
        },
      );
  }
}

String _libraryGameTitle(ChessGame game) {
  final white = (game.metadata['White']?.toString().trim() ?? '');
  final black = (game.metadata['Black']?.toString().trim() ?? '');
  if (white.isEmpty && black.isEmpty) {
    final event = (game.metadata['Event']?.toString().trim() ?? '');
    return event.isEmpty || event == '?' ? 'Saved analysis' : event;
  }
  return '${white.isEmpty ? 'White' : white} vs ${black.isEmpty ? 'Black' : black}';
}

Map<String, String> _headersFromBoardArgs(BoardTabGameArgs args) {
  final headers = <String, String>{};
  void put(String key, Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty && text != '0') headers[key] = text;
  }

  put('White', args.whiteName);
  put('Black', args.blackName);
  put('WhiteFed', args.whiteFederation);
  put('BlackFed', args.blackFederation);
  put('WhiteTitle', args.whiteTitle);
  put('BlackTitle', args.blackTitle);
  if (args.whiteFideId != null && args.whiteFideId! > 0) {
    put('WhiteFideId', args.whiteFideId);
  }
  if (args.blackFideId != null && args.blackFideId! > 0) {
    put('BlackFideId', args.blackFideId);
  }
  if (args.whiteRating > 0) put('WhiteElo', args.whiteRating);
  if (args.blackRating > 0) put('BlackElo', args.blackRating);
  return headers;
}

GameStatus _resolveHeaderGameStatus({
  required String pgnResult,
  required GameStatus? sourceGameStatus,
}) {
  final headerStatus = GameStatus.fromString(pgnResult);
  if (headerStatus.isFinished) return headerStatus;
  if (sourceGameStatus != null && sourceGameStatus.isFinished) {
    return sourceGameStatus;
  }
  if (headerStatus.isOngoing || sourceGameStatus?.isOngoing == true) {
    return GameStatus.ongoing;
  }
  return GameStatus.unknown;
}

String? _resultScoreForSide(
  GameStatus status, {
  required bool isWhite,
  double? customPoints,
}) {
  return customAwareResultLabelForSide(
    status,
    isWhite: isWhite,
    customPoints: customPoints,
  );
}

bool _pointersEqual(ChessMovePointer a, ChessMovePointer b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Resolve the head pointer of the deepest variation containing [p].
/// Returns null when [p] is on the mainline (no enclosing variation).
///
/// Pointer shape recap: mainline = `[moveIdx]`. Inside a variation =
/// `[moveIdx, varIdx, subMoveIdx]` (length 3). Deeper = adds another
/// `varIdx, moveIdx` pair. The variation head we want is the prefix up
/// to and including the last `varIdx` slot, with `0` appended.
ChessMovePointer? _variationHeadForPointer(ChessMovePointer p) {
  if (p.length < 3) return null;
  final lastVarIdxSlot = p.length.isEven ? p.length - 1 : p.length - 2;
  if (lastVarIdxSlot < 1) return null;
  return <int>[...p.sublist(0, lastVarIdxSlot + 1), 0];
}

/// Merge a freshly-parsed broadcast PGN into the in-memory tree without
/// dropping user-added variations.
///
/// Walks both mainlines move-by-move:
/// - matching moves keep the OLD entry (preserves any sub-variations the
///   user attached to it),
/// - the first divergence converts old's continuation into a sub-variation
///   under the live move so user-added work doesn't vanish, and
/// - new moves at the tip are appended unchanged.
///
/// The metadata map (Result/IsLive/etc) and starting FEN come from
/// [freshGame] so live status flags stay accurate.
ChessGame _mergeBroadcastUpdate(ChessGame oldGame, ChessGame freshGame) {
  if (oldGame.mainline.isEmpty) return freshGame;
  if (freshGame.mainline.isEmpty) return freshGame;

  final merged = <ChessMove>[];
  final oldLine = oldGame.mainline;
  final newLine = freshGame.mainline;
  final upper = newLine.length;
  var diverged = false;

  for (var i = 0; i < upper; i++) {
    if (i >= oldLine.length) {
      merged.add(newLine[i]);
      continue;
    }
    if (oldLine[i].uci == newLine[i].uci) {
      // Same move — keep the OLD ChessMove so any user-added variations
      // (move.variations) ride along into the merged tree.
      merged.add(oldLine[i]);
      continue;
    }
    // Divergence: live played something different than what we had
    // staged. Treat the old continuation (and old's existing variations
    // on this move) as alternatives under the live move.
    final liveMove = newLine[i];
    final oldMove = oldLine[i];
    final variations = <ChessLine>[oldLine.sublist(i), ...?oldMove.variations];
    merged.add(
      liveMove.copyWith(variations: variations, overrideVariations: true),
    );
    if (i + 1 < newLine.length) {
      merged.addAll(newLine.sublist(i + 1));
    }
    diverged = true;
    break;
  }

  // No divergence and old was longer than new (live shrunk?) — keep
  // old's tail. Rare, but it preserves rather than truncates.
  if (!diverged && oldLine.length > newLine.length) {
    merged.addAll(oldLine.sublist(newLine.length));
  }

  return freshGame.copyWith(mainline: merged);
}

/// Walk [pointer] against [game]'s tree and return the longest prefix
/// that resolves. Used as a recovery path when a broadcast update has
/// already reshaped the tree under the user — the move flow stays alive
/// instead of silently no-op'ing on a stale pointer.
ChessMovePointer _truncateToValidPointer(
  ChessGame game,
  ChessMovePointer pointer,
) {
  if (pointer.isEmpty) return const <int>[];
  ChessLine? currentLine = game.mainline;
  ChessMove? currentMove;
  final out = <int>[];
  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];
    if (i.isEven) {
      if (currentLine == null || index < 0 || index >= currentLine.length) {
        break;
      }
      out.add(index);
      currentMove = currentLine[index];
    } else {
      if (currentMove == null ||
          currentMove.variations == null ||
          index < 0 ||
          index >= currentMove.variations!.length) {
        break;
      }
      out.add(index);
      currentLine = currentMove.variations![index];
    }
  }
  // Ensure we end on a move (even-indexed last position) — variation
  // indices alone are not a valid leaf.
  if (out.length.isEven && out.isNotEmpty) {
    out.removeLast();
  }
  return List<int>.unmodifiable(out);
}

/// True when [pointer] is a legal walk through [game]'s tree. Used to
/// decide whether a stale pointer can be preserved across a PGN reload
/// or whether we have to fall back to the new mainline tip.
bool _isPointerValid(ChessGame game, ChessMovePointer pointer) {
  if (pointer.isEmpty) return true;
  ChessLine? currentLine = game.mainline;
  ChessMove? currentMove;
  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];
    if (i.isEven) {
      if (currentLine == null || index < 0 || index >= currentLine.length) {
        return false;
      }
      currentMove = currentLine[index];
    } else {
      if (currentMove == null ||
          currentMove.variations == null ||
          index < 0 ||
          index >= currentMove.variations!.length) {
        return false;
      }
      currentLine = currentMove.variations![index];
    }
  }
  return true;
}

/// Returns the [ChessMove] sitting at [pointer], or `null` if [pointer]
/// is the start position or doesn't resolve cleanly.
ChessMove? _moveAtPointer(ChessGame game, ChessMovePointer pointer) {
  if (pointer.isEmpty) return null;
  ChessLine? currentLine = game.mainline;
  ChessMove? currentMove;
  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];
    if (i.isEven) {
      if (currentLine == null || index >= currentLine.length) return null;
      currentMove = currentLine[index];
    } else {
      if (currentMove == null ||
          currentMove.variations == null ||
          index >= currentMove.variations!.length) {
        return null;
      }
      currentLine = currentMove.variations![index];
    }
  }
  return currentMove;
}

ChessGame _updateMoveAtPointer(
  ChessGame game,
  ChessMovePointer pointer,
  ChessMove Function(ChessMove move) update,
) {
  if (pointer.isEmpty) return game;

  ChessLine rebuild(ChessLine line, int pointerIndex) {
    final moveIndex = pointer[pointerIndex];
    if (moveIndex < 0 || moveIndex >= line.length) return line;

    final nextLine = List<ChessMove>.of(line);
    final move = nextLine[moveIndex];
    if (pointerIndex == pointer.length - 1) {
      final updated = update(move);
      if (identical(updated, move)) return line;
      nextLine[moveIndex] = updated;
      return nextLine;
    }

    if (pointerIndex + 1 >= pointer.length) return line;
    final variationIndex = pointer[pointerIndex + 1];
    final variations = move.variations;
    if (variations == null ||
        variationIndex < 0 ||
        variationIndex >= variations.length) {
      return line;
    }

    final nextVariations = List<ChessLine>.of(variations);
    final nextVariationLine = rebuild(
      nextVariations[variationIndex],
      pointerIndex + 2,
    );
    if (identical(nextVariationLine, nextVariations[variationIndex])) {
      return line;
    }
    nextVariations[variationIndex] = nextVariationLine;
    nextLine[moveIndex] = move.copyWith(
      variations: nextVariations,
      overrideVariations: true,
    );
    return nextLine;
  }

  final nextMainline = rebuild(game.mainline, 0);
  if (identical(nextMainline, game.mainline)) return game;
  return game.copyWith(mainline: nextMainline);
}

ChessGame _setMoveCommentAtPointer(
  ChessGame game,
  ChessMovePointer pointer,
  String? comment,
) {
  return _updateMoveAtPointer(
    game,
    pointer,
    (move) => _withEditableComment(move, comment),
  );
}

ChessGame _setMoveNagsAtPointer(
  ChessGame game,
  ChessMovePointer pointer,
  List<int> nags,
) {
  return _updateMoveAtPointer(
    game,
    pointer,
    (move) => move.copyWith(nags: List<int>.unmodifiable(nags)),
  );
}

List<int> _toggleNagList(List<int> current, int nag) {
  final tapped = getNagDisplay(nag);
  if (tapped == null) return current;

  final next = List<int>.from(current);
  if (next.contains(nag)) {
    next.remove(nag);
  } else {
    next.removeWhere((other) {
      final display = getNagDisplay(other);
      return display != null && display.category == tapped.category;
    });
    next.add(nag);
  }
  return List<int>.unmodifiable(next);
}

ChessMove _withEditableComment(ChessMove move, String? comment) {
  final nextComment = comment?.trim() ?? '';
  final directives = <String>[];
  for (final existing in move.comments ?? const <String>[]) {
    directives.addAll(_extractNonClockDirectives(existing));
  }
  return move.copyWith(
    comments: <String>[...directives, if (nextComment.isNotEmpty) nextComment],
  );
}

String? _insertedLineSourceComment(String? sourceLabel) {
  final clean =
      sourceLabel
          ?.replaceAll(RegExp(r'[\[\]{}]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
  if (clean == null || clean.isEmpty) return null;
  return '[%src $clean]';
}

/// Tack `plies=N` onto a structured `key=value|...` source label without
/// disturbing existing fields. Returns the input unchanged for plain (legacy)
/// labels so old call-sites keep their flat string formatting.
List<String> _continuationFromPgnAfterFen(String pgn, String fen) {
  try {
    final game = ChessGame.fromPgn('insert-game', pgn);
    final target = _fenPositionKey(fen);
    final allUcis = [for (final move in game.mainline) move.uci];
    if (allUcis.isEmpty) return const <String>[];

    Position position = Chess.fromSetup(
      Setup.parseFen(game.startingFen),
      ignoreImpossibleCheck: true,
    );
    if (_fenPositionKey(position.fen) == target) {
      return List<String>.unmodifiable(allUcis);
    }

    for (var i = 0; i < allUcis.length; i++) {
      final move = Move.parse(allUcis[i]);
      if (move == null || !position.isLegal(move)) break;
      position = position.playUnchecked(move);
      if (_fenPositionKey(position.fen) == target) {
        return List<String>.unmodifiable(allUcis.skip(i + 1));
      }
    }
  } catch (_) {
    return const <String>[];
  }
  return const <String>[];
}

String? _withInsertionPlies(String? sourceLabel, int plies) {
  if (sourceLabel == null) return null;
  final trimmed = sourceLabel.trim();
  if (trimmed.isEmpty) return null;
  if (plies <= 0) return trimmed;
  if (!trimmed.contains('=')) return trimmed;
  if (RegExp(r'(^|\|)plies=').hasMatch(trimmed)) return trimmed;
  return '$trimmed|plies=$plies';
}

String? _firstEditableComment(List<String>? comments) {
  if (comments == null || comments.isEmpty) return null;
  for (final comment in comments) {
    final clean =
        comment
            .replaceAll(_pgnDirectiveRegex, '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (clean.isNotEmpty) return clean;
  }
  return null;
}

Iterable<String> _extractNonClockDirectives(String comment) sync* {
  for (final match in _pgnDirectiveRegex.allMatches(comment)) {
    final directive = match.group(0);
    if (directive == null) continue;
    if (directive.startsWith('[%clk') || directive.startsWith('[%eval')) {
      continue;
    }
    yield directive;
  }
}

final _pgnDirectiveRegex = RegExp(r'\[%[a-zA-Z]+\s+[^\]]+\]');

/// Returns the full sequence of moves played from the start of the game
/// to the position pointed to by [pointer], correctly following any
/// variation hops along the way. Mirrors
/// [ChessGameNavigatorState.fullMovePath] — when a variation begins
/// with a move played by the same colour as the move it branches off,
/// the parent move is replaced (e.g. d4 instead of e4 at ply 0) rather
/// than chained.
List<ChessMove> _pathFromPointer(ChessGame game, ChessMovePointer pointer) {
  final path = <ChessMove>[];
  if (pointer.isEmpty) return path;

  ChessLine? currentList = game.mainline;
  ChessMove? currentMove;

  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];

    if (i.isEven) {
      if (currentList == null || index >= currentList.length) break;
      path.addAll(currentList.take(index + 1));
      currentMove = currentList[index];
      if (i == pointer.length - 1) break;
    } else {
      if (currentMove == null ||
          currentMove.variations == null ||
          index >= currentMove.variations!.length) {
        break;
      }
      final variation = currentMove.variations![index];
      if (variation.isNotEmpty && variation.first.turn == currentMove.turn) {
        // Variation that *replaces* the parent move (same colour plays).
        path.removeLast();
      }
      currentList = variation;
    }
  }
  return path;
}

/// Replay [path] (a list of moves from the starting position) into a
/// flat list of [_Ply]s — one per visited position, including the
/// initial one. This is the seam between the tree-model state and the
/// rest of the desktop board build (board annotations, PGN comment
/// shapes, last-move squares, …) which all key off `_Ply`.
List<_Ply> _pliesFromPath(String startingFen, List<ChessMove> path) {
  Position position;
  try {
    position = Chess.fromSetup(Setup.parseFen(startingFen));
  } catch (_) {
    position = Chess.initial;
  }
  final out = <_Ply>[_Ply(position: position, san: null)];
  for (final m in path) {
    final move = Move.parse(m.uci);
    Position next;
    try {
      next = Chess.fromSetup(Setup.parseFen(m.fen));
    } catch (_) {
      if (move == null) break;
      next = position.playUnchecked(move);
    }
    out.add(
      _Ply(
        position: next,
        san: m.san,
        nags: m.nags ?? const <int>[],
        comments: m.comments ?? const <String>[],
        move: move,
        lastMoveSquare: _normaliseLastMoveSquare(move),
      ),
    );
    position = next;
  }
  return out;
}

/// Resolve the [ChessLine] sitting at [pointer]. Used by [_nextPointer]
/// to walk forward across line boundaries.
ChessLine? _lineAt(ChessGame game, ChessMovePointer pointer) {
  ChessLine? line = game.mainline;
  ChessMove? move;
  for (var i = 0; i < pointer.length; i++) {
    final index = pointer[i];
    if (i.isEven) {
      if (line == null || index >= line.length) return null;
      move = line[index];
    } else {
      final variations = move?.variations;
      if (variations == null || index >= variations.length) return null;
      line = variations[index];
    }
  }
  return line;
}

/// Step one move backward in the tree, popping out of a variation back
/// to the parent line when at the start of one. Returns `null` only at
/// the root.
ChessMovePointer? _previousPointer(ChessMovePointer pointer) {
  if (pointer.isEmpty) return null;

  final previous = List<int>.of(pointer);
  if (previous.last > 0) {
    previous.last--;
    return previous;
  }

  if (previous.length >= 3) {
    previous.removeLast(); // move index
    previous.removeLast(); // variation index
    return _previousPointer(previous);
  }

  return const <int>[];
}

/// Step one move forward in the tree, walking up through parent lines
/// when the current line is exhausted. Returns `null` at the leaf of
/// the mainline.
ChessMovePointer? _nextPointer(ChessGame game, ChessMovePointer pointer) {
  if (game.mainline.isEmpty) return null;

  if (pointer.isEmpty) return <int>[0];

  final currentLine = _lineAt(game, pointer);
  if (currentLine == null) return null;

  final lastIndex = pointer.last;
  if (lastIndex + 1 < currentLine.length) {
    final next = List<int>.of(pointer);
    next.last = lastIndex + 1;
    return next;
  }

  var parentPointer = List<int>.of(pointer);
  while (parentPointer.length >= 2) {
    parentPointer.removeLast(); // move index
    parentPointer.removeLast(); // variation index
    final parentLine = _lineAt(game, parentPointer);
    if (parentLine == null) continue;
    if (parentPointer.isEmpty) continue;
    final parentIndex = parentPointer.last;
    if (parentIndex + 1 < parentLine.length) {
      final next = List<int>.of(parentPointer);
      next.last = parentIndex + 1;
      return next;
    }
  }

  return null;
}

/// Cycle between sibling lines at the branch column the cursor sits on.
///
/// "Branch column" = the move position whose alternative continuations
/// are the variations attached to it. For a pointer on the mainline,
/// that move *is* the anchor; for a pointer inside a variation, the
/// anchor is the parent move that owns the containing variation.
///
/// Cycle order: anchor (mainline at this column) → variation 0 head →
/// variation 1 head → … . `delta == 1` moves to the next entry; `-1`
/// moves to the previous. Returns `null` when there are no siblings at
/// the column, or when the cycle step would fall off either end —
/// callers fall back to a plain `goPrev`/`goNext` step in that case so
/// the keys never feel dead.
ChessMovePointer? _siblingCycle(
  ChessGame game,
  ChessMovePointer pointer,
  int delta,
) {
  if (pointer.isEmpty) return null;
  final anchorLen = pointer.length == 1 ? 1 : pointer.length - 2;
  final anchorPtr = pointer.sublist(0, anchorLen);
  final anchorMove = _moveAtPointer(game, anchorPtr);
  if (anchorMove == null) return null;
  final vars = anchorMove.variations ?? const <ChessLine>[];
  if (vars.isEmpty) return null;
  final entries = <ChessMovePointer>[
    anchorPtr,
    for (var v = 0; v < vars.length; v++) <int>[...anchorPtr, v, 0],
  ];
  final currentRow = pointer.length == anchorLen ? 0 : pointer[anchorLen] + 1;
  final newRow = currentRow + delta;
  if (newRow < 0 || newRow >= entries.length) return null;
  return entries[newRow];
}

class _BoardCloseConfirmationDialog extends StatefulWidget {
  const _BoardCloseConfirmationDialog({
    required this.onConfirm,
    required this.onCancel,
  });

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  State<_BoardCloseConfirmationDialog> createState() =>
      _BoardCloseConfirmationDialogState();
}

class _BoardCloseConfirmationDialogState
    extends State<_BoardCloseConfirmationDialog> {
  final FocusNode _yesFocusNode = FocusNode(debugLabel: 'confirm close board');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _yesFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _yesFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
        const SingleActivator(LogicalKeyboardKey.enter): widget.onConfirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): widget.onConfirm,
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This board has a move that is not in the loaded notation. Close this tab and discard it?',
              style: TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesktopDialogButton(
                  label: 'No',
                  onPress: widget.onCancel,
                  tone: DesktopDialogButtonTone.secondary,
                ),
                const SizedBox(width: 10),
                Focus(
                  focusNode: _yesFocusNode,
                  child: DesktopDialogButton(
                    label: 'Yes',
                    onPress: widget.onConfirm,
                    tone: DesktopDialogButtonTone.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PrevMoveIntent extends Intent {
  const _PrevMoveIntent();
}

class _NextMoveIntent extends Intent {
  const _NextMoveIntent();
}

class _FirstMoveIntent extends Intent {
  const _FirstMoveIntent();
}

class _LastMoveIntent extends Intent {
  const _LastMoveIntent();
}

class _PrevVariationIntent extends Intent {
  const _PrevVariationIntent();
}

class _NextVariationIntent extends Intent {
  const _NextVariationIntent();
}

class _UndoLastEditIntent extends Intent {
  const _UndoLastEditIntent();
}

class _FlipBoardIntent extends Intent {
  const _FlipBoardIntent();
}

class _CopyPgnIntent extends Intent {
  const _CopyPgnIntent();
}

class _PastePgnIntent extends Intent {
  const _PastePgnIntent();
}

class _SavePgnIntent extends Intent {
  const _SavePgnIntent();
}

class _SaveGameToLibraryIntent extends Intent {
  const _SaveGameToLibraryIntent();
}

class _CommentAfterMoveIntent extends Intent {
  const _CommentAfterMoveIntent();
}

class _PlayEngineMoveIntent extends Intent {
  const _PlayEngineMoveIntent();
}

class _ClearAnalysisIntent extends Intent {
  const _ClearAnalysisIntent();
}

class _ShowEventInfoIntent extends Intent {
  const _ShowEventInfoIntent();
}

class _ToggleEngineIntent extends Intent {
  const _ToggleEngineIntent();
}

class _OpenExplorerIntent extends Intent {
  const _OpenExplorerIntent();
}

class _OpenBoardSettingsIntent extends Intent {
  const _OpenBoardSettingsIntent();
}

class _PrevGameIntent extends Intent {
  const _PrevGameIntent();
}

class _NextGameIntent extends Intent {
  const _NextGameIntent();
}

class _AutoReplayIntent extends Intent {
  const _AutoReplayIntent();
}

class _CollapseAllVariationsIntent extends Intent {
  const _CollapseAllVariationsIntent();
}

class _ExpandAllVariationsIntent extends Intent {
  const _ExpandAllVariationsIntent();
}

class _BoardActionIntent extends Intent {
  const _BoardActionIntent(this.action);

  final BoardActionKey action;
}

/// Maps the user-facing [BoardActionKey] enum onto a stable [Intent]
/// instance per action. Returning `null` means "this action has no
/// keyboard intent yet" — currently every action is bound, but the
/// helper keeps the door open for future entries.
Intent? _intentFor(BoardActionKey action) {
  switch (action) {
    case BoardActionKey.prevMove:
      return const _PrevMoveIntent();
    case BoardActionKey.nextMove:
      return const _NextMoveIntent();
    case BoardActionKey.previousNotationLine:
    case BoardActionKey.nextNotationLine:
      return _BoardActionIntent(action);
    case BoardActionKey.firstMove:
      return const _FirstMoveIntent();
    case BoardActionKey.lastMove:
      return const _LastMoveIntent();
    case BoardActionKey.prevVariation:
      return const _PrevVariationIntent();
    case BoardActionKey.nextVariation:
      return const _NextVariationIntent();
    case BoardActionKey.undoLastEdit:
      return const _UndoLastEditIntent();
    case BoardActionKey.flipBoard:
      return const _FlipBoardIntent();
    case BoardActionKey.copyPgn:
      return const _CopyPgnIntent();
    case BoardActionKey.pastePgn:
      return const _PastePgnIntent();
    case BoardActionKey.savePgnFile:
      return const _SavePgnIntent();
    case BoardActionKey.saveGameToLibrary:
      return const _SaveGameToLibraryIntent();
    case BoardActionKey.commentAfterMove:
      return const _CommentAfterMoveIntent();
    case BoardActionKey.playEngineMove:
      return const _PlayEngineMoveIntent();
    case BoardActionKey.clearAnalysis:
      return const _ClearAnalysisIntent();
    case BoardActionKey.showEventInfo:
      return const _ShowEventInfoIntent();
    case BoardActionKey.toggleEngine:
      return const _ToggleEngineIntent();
    case BoardActionKey.openExplorer:
      return const _OpenExplorerIntent();
    case BoardActionKey.openPositionSetup:
      return _BoardActionIntent(action);
    case BoardActionKey.openBoardSettings:
      return const _OpenBoardSettingsIntent();
    case BoardActionKey.prevGame:
      return const _PrevGameIntent();
    case BoardActionKey.nextGame:
      return const _NextGameIntent();
    case BoardActionKey.autoReplay:
      return const _AutoReplayIntent();
    case BoardActionKey.goToMoveNumber:
    case BoardActionKey.makeNextMoveVariation:
    case BoardActionKey.enterNullMove:
    case BoardActionKey.deleteVariation:
    case BoardActionKey.switchNotationView:
    case BoardActionKey.rightRailPreviousTab:
    case BoardActionKey.rightRailNextTab:
    case BoardActionKey.rightRailPreviousTable:
    case BoardActionKey.rightRailNextTable:
    case BoardActionKey.rightRailActivateSelection:
    case BoardActionKey.closeVariation:
    case BoardActionKey.increaseEngineLines:
    case BoardActionKey.decreaseEngineLines:
    case BoardActionKey.scrollNotationUp:
    case BoardActionKey.scrollNotationDown:
    case BoardActionKey.cutRemainingMoves:
    case BoardActionKey.cutPreviousMoves:
    case BoardActionKey.clearVariationsAndComments:
    case BoardActionKey.commentBeforeMove:
    case BoardActionKey.annotateGoodMove:
    case BoardActionKey.annotateBrilliant:
    case BoardActionKey.annotateMistake:
    case BoardActionKey.annotateBlunder:
    case BoardActionKey.annotateInteresting:
    case BoardActionKey.annotateDubious:
    case BoardActionKey.clearAnnotation:
    case BoardActionKey.promoteVariation:
    case BoardActionKey.deleteGraphicCommentary:
    case BoardActionKey.trainingCommentary:
    case BoardActionKey.correspondenceHeader:
    case BoardActionKey.correspondenceMove:
    case BoardActionKey.replaceGame:
    case BoardActionKey.insertBestVariation:
    case BoardActionKey.showThreat:
    case BoardActionKey.calculateNextBestMove:
    case BoardActionKey.togglePhotosWindow:
    case BoardActionKey.toggleNotationWindow:
    case BoardActionKey.toggleBoardFocus:
    case BoardActionKey.closeWindow:
      return _BoardActionIntent(action);
  }
}

/// Compact board actions hosted in the right-rail tab strip so the board
/// column keeps the extra vertical space. Icons stay Lichess-small; tooltips
/// carry the labels that used to be printed on the board chrome row.
class _RightRailBoardActions extends StatelessWidget {
  const _RightRailBoardActions({
    required this.headers,
    required this.eventInfoTrigger,
    required this.onPlayFromHere,
    required this.onSaveGame,
    required this.canSaveGame,
    required this.saveShortcutLabel,
    this.onPlayAgain,
  });

  final Map<String, String> headers;
  final int eventInfoTrigger;
  final VoidCallback onPlayFromHere;
  final VoidCallback onSaveGame;
  final bool canSaveGame;
  final String? saveShortcutLabel;
  final VoidCallback? onPlayAgain;

  @override
  Widget build(BuildContext context) {
    final saveTooltip =
        saveShortcutLabel == null
            ? 'Save game'
            : 'Save game  •  $saveShortcutLabel';
    return FTheme(
      data: FThemes.zinc.dark,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RailIconAction(
            tooltip: saveTooltip,
            icon: FIcons.bookmarkPlus,
            onPress: canSaveGame ? onSaveGame : null,
          ),
          const SizedBox(width: 4),
          if (onPlayAgain != null) ...[
            _RailIconAction(
              tooltip: 'Play again',
              icon: Icons.replay_rounded,
              primary: true,
              onPress: onPlayAgain,
            ),
            const SizedBox(width: 4),
          ],
          _RailIconAction(
            tooltip: 'Play from here',
            icon: FIcons.play,
            primary: true,
            onPress: onPlayFromHere,
          ),
          const SizedBox(width: 4),
          SizedBox.square(
            dimension: 28,
            child: EventInfoPopover(
              headers: headers,
              openTrigger: eventInfoTrigger,
            ),
          ),
        ],
      ),
    );
  }
}

class _RailIconAction extends StatelessWidget {
  const _RailIconAction({
    required this.tooltip,
    required this.icon,
    required this.onPress,
    this.primary = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPress;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final color = primary ? kPrimaryColor : kWhiteColor70;
    return DesktopTooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 28,
        child: FButton.icon(
          style: FButtonStyle.ghost(
            (style) => style.copyWith(
              contentStyle:
                  (content) => content.copyWith(padding: EdgeInsets.zero),
            ),
          ),
          onPress: onPress,
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }
}

/// True when [move] is a pawn moving from the 7th to the 8th rank
/// (white) or from the 2nd to the 1st rank (black) and carries no
/// promotion role yet — meaning chessground emitted it without
/// `withPromotion(...)` and the pane needs to raise the picker.
///
/// Mirrors `chess_board_screen_provider_new.dart`'s `isPromotionPawnMove`
/// so desktop and mobile classify promotion moves identically.
bool _isPromotionPawnMove(Position position, NormalMove move) {
  if (move.promotion != null) return false;
  if (position.board.roleAt(move.from) != Role.pawn) return false;
  return (move.to.rank == Rank.first && position.turn == Side.black) ||
      (move.to.rank == Rank.eighth && position.turn == Side.white);
}

/// True when [game]'s tree carries any user-grown sub-variations — i.e.
/// any move with a non-empty `variations` list. The shipped PGN may
/// also include broadcaster-authored variations; we don't try to
/// distinguish here so "Clear my variations" stays a single
/// destructive action.
bool _gameHasUserVariations(ChessGame game) {
  for (final move in game.mainline) {
    if (_moveHasVariations(move)) return true;
  }
  return false;
}

bool _moveHasVariations(ChessMove move) {
  final vars = move.variations;
  if (vars != null && vars.isNotEmpty) return true;
  return false;
}

/// Strip every variation from [line] recursively. Used by Clear analysis
/// to wipe both top-level branches and any nested sub-variations the
/// user grew under them.
ChessLine _stripUserVariations(ChessLine line) {
  return [
    for (final move in line)
      move.copyWith(variations: null, overrideVariations: true),
  ];
}

/// Suggest a default filename for "Save PGN to file…" — pulls from PGN
/// headers when available so the user gets `Carlsen-Nepo-2024-r5.pgn`
/// instead of an undifferentiated `game.pgn`.
String _suggestPgnFileName(Map<String, String> headers) {
  String sanitise(String s) {
    return s
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '')
        .replaceAll(RegExp(r'_+'), '_');
  }

  final parts = <String>[];
  final white = sanitise(headers['White'] ?? '');
  final black = sanitise(headers['Black'] ?? '');
  if (white.isNotEmpty || black.isNotEmpty) {
    parts.add(
      '${white.isEmpty ? 'White' : white}-${black.isEmpty ? 'Black' : black}',
    );
  }
  final round = sanitise(headers['Round'] ?? '');
  if (round.isNotEmpty) parts.add('R$round');
  final date = (headers['Date'] ?? '').replaceAll('.', '-');
  if (date.isNotEmpty && date != '????-??-??') {
    parts.add(sanitise(date));
  }
  if (parts.isEmpty) return 'game.pgn';
  return '${parts.join('_')}.pgn';
}

String? _firstClockDisplay(
  String? first,
  String? second,
  String? third,
  String? fallback,
) {
  for (final value in [first, second, third, fallback]) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

class _BoardArea extends ConsumerWidget {
  const _BoardArea({
    required this.tabId,
    required this.boardRenderKey,
    required this.fen,
    required this.flipped,
    required this.sideToMove,
    required this.playerSide,
    required this.validMoves,
    required this.isCheck,
    required this.lastMove,
    required this.onMove,
    required this.promotionMove,
    required this.onPromotionSelection,
    required this.pgnHeaders,
    required this.pgnShapes,
    required this.boardAnnotation,
    required this.boardAnnotationGlyph,
    required this.boardAnnotationSquare,
    required this.gameEnding,
    required this.onWheelStep,
    required this.isLiveAtTip,
    required this.focusMode,
    required this.focusShortcutLabel,
    required this.onFocusModeChanged,
    required this.boardSizePreference,
    required this.onBoardSizeChanged,
    required this.onBoardSizeReset,
    required this.onBoardSizeChangeEnd,
    this.activeGameId,
    this.boardArgs,
    this.whiteClock,
    this.blackClock,
    this.sourceGame,
    this.viewSource = ChessboardView.tour,
  });

  final String tabId;
  final String boardRenderKey;
  final String fen;
  final bool flipped;
  final Side sideToMove;
  final cg.PlayerSide playerSide;
  final cg.ValidMoves validMoves;
  final bool isCheck;
  final Move? lastMove;
  final void Function(Move move, {bool? viaDragAndDrop}) onMove;

  /// Pawn move that's pending a promotion-piece pick. Non-null means
  /// chessground will render the four-piece selector overlay; null
  /// means no pending pick. The board pane sets this from `onMove`
  /// when a pawn lands on the back rank without a promotion role.
  final NormalMove? promotionMove;

  /// Fired when the user picks a piece in the chessground promotion
  /// selector — or when they cancel (null role). The pane applies
  /// `pending.withPromotion(role)` and clears [promotionMove].
  final void Function(Role? role) onPromotionSelection;

  /// Headers parsed out of the currently-loaded PGN. The board pane
  /// stashes these in a hook ref each time `applyPgn` runs so we can
  /// derive player names/federation/title/rating from the PGN itself,
  /// independent of whether the user got here via a tournament card,
  /// drag-drop, or a saved Library analysis.
  final Map<String, String> pgnHeaders;

  /// Most recent PGN-baked clock annotations for each side at the
  /// active pointer. `null` means the loaded game has no `[%clk …]`
  /// markers (rare for broadcasts; common for old-master archives), in
  /// which case the clock badge is omitted altogether.
  final String? whiteClock;
  final String? blackClock;

  /// Active live game stream id. Only the player headers subscribe to its
  /// clock fields, so broadcast ticks don't rebuild the board surface.
  final String? activeGameId;

  /// Active Board tab args, including the event game list carried by the tab.
  final BoardTabGameArgs? boardArgs;

  /// Source tournament row for this board tab, when opened from a live
  /// tournament/feed card.
  final GamesTourModel? sourceGame;

  /// Mobile board source equivalent for the tab that opened this board.
  final ChessboardView viewSource;

  /// True iff the loaded game is a live broadcast AND the user is sitting
  /// on the mainline tip. Drives whether the player clocks tick down
  /// against wall-clock (live tip) or render a static PGN-baked figure
  /// (any earlier move, or finished game).
  final bool isLiveAtTip;

  /// `[%cal …]` arrows + `[%csl …]` square circles authored into the
  /// current move's PGN comment. Merged with user-drawn annotations.
  final List<cg.Shape> pgnShapes;

  /// Lichess analysis classification (or mapped quality NAG) to render as
  /// an SVG badge on [boardAnnotationSquare]. `null` when no badge.
  final LichessMoveAnnotation? boardAnnotation;

  /// Fallback glyph badge for NAGs that don't map to a Lichess SVG (=, ±,
  /// ⩲, !? etc.). Only used when [boardAnnotation] is null.
  final NagDisplay? boardAnnotationGlyph;

  /// Destination square the badge anchors to (the move's landing square,
  /// king square for castling). `null` outside of moves.
  final Square? boardAnnotationSquare;

  /// End-of-game effect descriptor. Non-null only at the final mainline
  /// ply of a finished game; drives the king-tilt / peace-icon overlay.
  final _GameEndingData? gameEnding;

  final ValueChanged<int> onWheelStep;
  final bool focusMode;
  final String? focusShortcutLabel;
  final ValueChanged<bool> onFocusModeChanged;
  final double? boardSizePreference;
  final ValueChanged<double> onBoardSizeChanged;
  final VoidCallback onBoardSizeReset;
  final VoidCallback onBoardSizeChangeEnd;

  static const double _evalBarWidth = 24.0;
  static const double _evalBarGap = 12.0;
  static const double headerHeight = 44.0;
  static const double headerGap = 4.0;
  static const double evalBarReservation = _evalBarWidth + _evalBarGap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engineSettings =
        ref.watch(engineSettingsProviderNew).valueOrNull ??
        const EngineSettings();
    final showEngineAnalysis = engineSettings.showEngineAnalysis;
    final evalState =
        showEngineAnalysis
            ? ref.watch(boardEvalProvider(fen))
            : const BoardEvalState(
              pvs: <BoardPv>[],
              isEvaluating: false,
              depth: 0,
            );
    final evalPvs = showEngineAnalysis ? evalState.pvs : const <BoardPv>[];
    final showEvalBar = shouldShowDesktopBoardEvalBar(engineSettings);
    final tournament = ref.watch(tournamentGamesProvider);
    final activeTournamentGameId = tournament?.activeGameId;
    final tournamentGame = tournament?.games.firstWhere(
      (g) => g.id == activeTournamentGameId,
      orElse:
          () => const TournamentGameSummary(
            id: '',
            name: '',
            whitePlayer: '',
            blackPlayer: '',
            hasPgn: false,
          ),
    );
    // Pull names out of the PGN first, fall back to the tournament-list
    // metadata when the PGN is missing the field. Either source is
    // enough on its own — the new game-card-tap path only fills the
    // tournament-list with the active game id (no full row), so we used
    // to render no headers at all when the user tapped a card.
    String pgn(String key, [String fallback = '']) =>
        (pgnHeaders[key] ?? fallback).trim();
    String firstPgn(List<String> keys) {
      for (final key in keys) {
        final value = pgn(key);
        if (value.isNotEmpty && value != '?') return value;
      }
      return '';
    }

    int pgnInt(String key) {
      final v = pgnHeaders[key];
      if (v == null) return 0;
      return int.tryParse(v.trim()) ?? 0;
    }

    final whiteName =
        pgn('White').isNotEmpty
            ? pgn('White')
            : (tournamentGame?.whitePlayer ?? '');
    final blackName =
        pgn('Black').isNotEmpty
            ? pgn('Black')
            : (tournamentGame?.blackPlayer ?? '');
    final sourceWhite = sourceGame?.whitePlayer;
    final sourceBlack = sourceGame?.blackPlayer;
    final whiteFed =
        firstPgn([
              'WhiteFed',
              'WhiteFederation',
              'WhiteCountry',
              'WhiteTeam',
            ]).isNotEmpty
            ? firstPgn([
              'WhiteFed',
              'WhiteFederation',
              'WhiteCountry',
              'WhiteTeam',
            ])
            : ((sourceWhite?.countryCode.trim().isNotEmpty ?? false)
                ? sourceWhite!.countryCode
                : ((sourceWhite?.federation.trim().isNotEmpty ?? false)
                    ? sourceWhite!.federation
                    : (tournamentGame?.whiteFederation ?? '')));
    final blackFed =
        firstPgn([
              'BlackFed',
              'BlackFederation',
              'BlackCountry',
              'BlackTeam',
            ]).isNotEmpty
            ? firstPgn([
              'BlackFed',
              'BlackFederation',
              'BlackCountry',
              'BlackTeam',
            ])
            : ((sourceBlack?.countryCode.trim().isNotEmpty ?? false)
                ? sourceBlack!.countryCode
                : ((sourceBlack?.federation.trim().isNotEmpty ?? false)
                    ? sourceBlack!.federation
                    : (tournamentGame?.blackFederation ?? '')));
    final whiteTitle =
        pgn('WhiteTitle').isNotEmpty
            ? pgn('WhiteTitle')
            : ((sourceWhite?.title.trim().isNotEmpty ?? false)
                ? sourceWhite!.title
                : (tournamentGame?.whiteTitle ?? ''));
    final blackTitle =
        pgn('BlackTitle').isNotEmpty
            ? pgn('BlackTitle')
            : ((sourceBlack?.title.trim().isNotEmpty ?? false)
                ? sourceBlack!.title
                : (tournamentGame?.blackTitle ?? ''));
    final whiteRating =
        pgnInt('WhiteElo') > 0
            ? pgnInt('WhiteElo')
            : ((sourceWhite?.rating ?? 0) > 0
                ? sourceWhite!.rating
                : (tournamentGame?.whiteRating ?? 0));
    final blackRating =
        pgnInt('BlackElo') > 0
            ? pgnInt('BlackElo')
            : ((sourceBlack?.rating ?? 0) > 0
                ? sourceBlack!.rating
                : (tournamentGame?.blackRating ?? 0));
    final whiteFideId =
        pgnInt('WhiteFideId') > 0
            ? pgnInt('WhiteFideId')
            : (sourceWhite?.fideId ?? boardArgs?.whiteFideId);
    final blackFideId =
        pgnInt('BlackFideId') > 0
            ? pgnInt('BlackFideId')
            : (sourceBlack?.fideId ?? boardArgs?.blackFideId);
    final gameStatus = _resolveHeaderGameStatus(
      pgnResult: pgn('Result'),
      sourceGameStatus: sourceGame?.gameStatus,
    );

    final displayWhiteName = whiteName.isNotEmpty ? whiteName : 'White';
    final displayBlackName = blackName.isNotEmpty ? blackName : 'Black';
    final whiteClockDisplay = _firstClockDisplay(
      whiteClock,
      pgn('WhiteTimeDisplay'),
      sourceGame?.whiteTimeDisplay,
      focusMode ? '--:--' : null,
    );
    final blackClockDisplay = _firstClockDisplay(
      blackClock,
      pgn('BlackTimeDisplay'),
      sourceGame?.blackTimeDisplay,
      focusMode ? '--:--' : null,
    );
    final hasPlayerInfo =
        whiteName.isNotEmpty ||
        blackName.isNotEmpty ||
        whiteClockDisplay != null ||
        blackClockDisplay != null;
    final chromeMetrics = computeBoardAreaChromeMetrics(
      focusMode: focusMode,
      hasPlayerInfo: hasPlayerInfo,
    );
    final hasHeaders = chromeMetrics.hasHeaders;
    // Focus mode still hides the surrounding board toolbar and move-nav
    // cluster, but it must reserve the player rows. Names and clocks remain
    // visible with a smaller outer margin so the board can still feel focused.
    final topRowHeight = chromeMetrics.topRowHeight;
    final bottomRowHeight = chromeMetrics.bottomRowHeight;
    final headerGapTotal = chromeMetrics.headerGapTotal;
    final extraVertical = topRowHeight + bottomRowHeight + headerGapTotal;

    return Container(
      color: kBackgroundColor,
      padding: EdgeInsets.all(chromeMetrics.outerPadding),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Player headers eat fixed vertical space; the board takes the
          // square of whatever is left after reserving room for the
          // optional left-side evaluation bar and the button strips.
          final evalBarReservation =
              showEvalBar ? _BoardArea.evalBarReservation : 0.0;
          final hLimit = math.max(
            0.0,
            constraints.biggest.width - evalBarReservation,
          );
          final vLimit = math.max(
            0.0,
            constraints.biggest.height - extraVertical,
          );
          final maxBoardSize = math.min(hLimit, vLimit);
          final defaultSize = math.min(maxBoardSize, _defaultDesktopBoardSize);
          // Fullscreen / focus mode forces the board to its biggest possible
          // square — equivalent to dragging the resize grip to its limit.
          // Honour the user's stored preference outside of focus so the
          // explicit toggle doesn't clobber it.
          final preferredSize =
              focusMode
                  ? math.min(vLimit, _maxDesktopBoardSize)
                  : (boardSizePreference ?? defaultSize);
          final minBoardSize = math.min(_minDesktopBoardSize, maxBoardSize);
          final boardSize =
              maxBoardSize <= 0
                  ? 0.0
                  : preferredSize
                      .clamp(
                        minBoardSize,
                        math.min(maxBoardSize, _maxDesktopBoardSize),
                      )
                      .toDouble();
          final boardWithBar = boardSize + evalBarReservation;

          // Top header is whichever player sits at the top of the board:
          // black when not flipped, white when flipped.
          final topIsWhite = flipped;
          final topName = topIsWhite ? displayWhiteName : displayBlackName;
          final topFed = topIsWhite ? whiteFed : blackFed;
          final topTitle = topIsWhite ? whiteTitle : blackTitle;
          final topRating = topIsWhite ? whiteRating : blackRating;
          final topClock = topIsWhite ? whiteClockDisplay : blackClockDisplay;
          final topResultScore = _resultScoreForSide(
            gameStatus,
            isWhite: topIsWhite,
            customPoints:
                topIsWhite
                    ? sourceGame?.whitePlayer.customPoints
                    : sourceGame?.blackPlayer.customPoints,
          );
          final bottomIsWhite = !flipped;
          final bottomName =
              bottomIsWhite ? displayWhiteName : displayBlackName;
          final bottomFed = bottomIsWhite ? whiteFed : blackFed;
          final bottomTitle = bottomIsWhite ? whiteTitle : blackTitle;
          final bottomRating = bottomIsWhite ? whiteRating : blackRating;
          final bottomClock =
              bottomIsWhite ? whiteClockDisplay : blackClockDisplay;
          final bottomResultScore = _resultScoreForSide(
            gameStatus,
            isWhite: bottomIsWhite,
            customPoints:
                bottomIsWhite
                    ? sourceGame?.whitePlayer.customPoints
                    : sourceGame?.blackPlayer.customPoints,
          );

          final boardRow = SizedBox(
            height: boardSize,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (showEvalBar) ...[
                  SizedBox(
                    key: e2eKey(E2eIds.boardEvalBar),
                    width: _evalBarWidth,
                    height: boardSize,
                    child: DesktopEvalBar(
                      width: _evalBarWidth,
                      height: boardSize,
                      isFlipped: flipped,
                      evaluation: evalState.evaluation,
                      mate: evalState.mate,
                      isEvaluating: evalState.isEvaluating,
                      positionKey: _fenPositionKey(fen),
                    ),
                  ),
                  const SizedBox(width: _evalBarGap),
                ],
                SizedBox(
                  width: boardSize,
                  height: boardSize,
                  child: _BoardWithAnnotations(
                    tabId: tabId,
                    boardRenderKey: boardRenderKey,
                    boardSize: boardSize,
                    fen: fen,
                    flipped: flipped,
                    playerSide: playerSide,
                    sideToMove: sideToMove,
                    validMoves: validMoves,
                    isCheck: isCheck,
                    lastMove: lastMove,
                    onMove: onMove,
                    promotionMove: promotionMove,
                    onPromotionSelection: onPromotionSelection,
                    pgnShapes: pgnShapes,
                    boardAnnotation: boardAnnotation,
                    boardAnnotationGlyph: boardAnnotationGlyph,
                    boardAnnotationSquare: boardAnnotationSquare,
                    gameEnding: gameEnding,
                    onWheelStep: onWheelStep,
                    evalPvs: evalPvs,
                  ),
                ),
              ],
            ),
          );

          final focusButton = _BoardFocusButton(
            focusMode: focusMode,
            shortcutLabel: focusShortcutLabel,
            onChanged: onFocusModeChanged,
          );
          final resizeHandle = _BoardResizeHandle(
            boardSize: boardSize,
            minSize: math.min(
              _minDesktopBoardSize,
              math.min(maxBoardSize, _maxDesktopBoardSize),
            ),
            // Grow's true bottleneck is vertical. Horizontal can always be
            // earned back via setSize on the split column, so bound by
            // vLimit alone — using maxBoardSize (min(hLimit, vLimit))
            // clamped grow-drags to the current column width and no-op'd.
            maxSize: math.min(vLimit, _maxDesktopBoardSize),
            onResize: onBoardSizeChanged,
            onResizeEnd: onBoardSizeChangeEnd,
            onGrowPastLimit: () => onFocusModeChanged(true),
            onReset: onBoardSizeReset,
          );

          Widget chromeRow({
            required double height,
            required Widget? header,
            required Widget? trailing,
          }) {
            return SizedBox(
              width: boardWithBar,
              height: height,
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: boardSize,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (header != null)
                        Expanded(child: header)
                      else
                        const Spacer(),
                      if (trailing != null) ...[
                        const SizedBox(width: 6),
                        trailing,
                      ],
                    ],
                  ),
                ),
              ),
            );
          }

          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                chromeRow(
                  height: topRowHeight,
                  header:
                      hasHeaders
                          ? _PlayerHeader(
                            name: topName,
                            federation: topFed,
                            title: topTitle,
                            rating: topRating,
                            fideId: topIsWhite ? whiteFideId : blackFideId,
                            resultScore: topResultScore,
                            isWhite: topIsWhite,
                            isToMove:
                                (topIsWhite && sideToMove == Side.white) ||
                                (!topIsWhite && sideToMove == Side.black),
                            clockText: topClock,
                            activeGameId: activeGameId,
                            useLiveClock: isLiveAtTip,
                            boardArgs: boardArgs,
                            sourceGame: sourceGame,
                            viewSource: viewSource,
                          )
                          : null,
                  trailing: focusButton,
                ),
                SizedBox(height: _BoardArea.headerGap),
                boardRow,
                SizedBox(height: _BoardArea.headerGap),
                chromeRow(
                  height: bottomRowHeight,
                  header:
                      hasHeaders
                          ? _PlayerHeader(
                            name: bottomName,
                            federation: bottomFed,
                            title: bottomTitle,
                            rating: bottomRating,
                            fideId: bottomIsWhite ? whiteFideId : blackFideId,
                            resultScore: bottomResultScore,
                            isWhite: bottomIsWhite,
                            isToMove:
                                (bottomIsWhite && sideToMove == Side.white) ||
                                (!bottomIsWhite && sideToMove == Side.black),
                            clockText: bottomClock,
                            activeGameId: activeGameId,
                            useLiveClock: isLiveAtTip,
                            boardArgs: boardArgs,
                            sourceGame: sourceGame,
                            viewSource: viewSource,
                          )
                          : null,
                  trailing: focusMode ? null : resizeHandle,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BoardFocusButton extends StatelessWidget {
  const _BoardFocusButton({
    required this.focusMode,
    required this.shortcutLabel,
    required this.onChanged,
  });

  final bool focusMode;
  final String? shortcutLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return FTheme(
      data: FThemes.zinc.dark,
      child: DesktopTooltip(
        message:
            '${focusMode ? 'Exit board focus' : 'Board focus'}'
            '${shortcutLabel == null ? '' : ' ($shortcutLabel)'}',
        child: SizedBox.square(
          dimension: _focusButtonSize,
          child: FButton.icon(
            key: const ValueKey<String>('desktop-board-focus-toggle'),
            style: _floatingBoardIconButtonStyle(selected: focusMode),
            onPress: () => onChanged(!focusMode),
            child: Icon(
              focusMode
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              size: 16,
            ),
          ),
        ),
      ),
    );
  }
}

class _BoardResizeHandle extends StatefulWidget {
  const _BoardResizeHandle({
    required this.boardSize,
    required this.minSize,
    required this.maxSize,
    required this.onResize,
    required this.onResizeEnd,
    required this.onGrowPastLimit,
    required this.onReset,
  });

  final double boardSize;
  final double minSize;
  final double maxSize;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onGrowPastLimit;
  final VoidCallback onReset;

  @override
  State<_BoardResizeHandle> createState() => _BoardResizeHandleState();
}

class _BoardResizeHandleState extends State<_BoardResizeHandle> {
  Offset? _dragStart;
  double? _sizeStart;
  bool _active = false;
  bool _grewPastLimit = false;

  void _begin(DragStartDetails details) {
    _dragStart = details.globalPosition;
    _sizeStart = widget.boardSize;
    _grewPastLimit = false;
    setState(() => _active = true);
  }

  void _update(DragUpdateDetails details) {
    final start = _dragStart;
    final sizeStart = _sizeStart;
    if (start == null || sizeStart == null) return;
    final offset = details.globalPosition - start;
    final delta = desktopBoardResizeDragDelta(offset);
    final rawSize = sizeStart + delta;
    if (rawSize > widget.maxSize + _resizeFocusOvershoot) {
      _grewPastLimit = true;
    }
    widget.onResize(rawSize.clamp(widget.minSize, widget.maxSize).toDouble());
  }

  void _end() {
    if (!_active) return;
    final grewPastLimit = _grewPastLimit;
    _dragStart = null;
    _sizeStart = null;
    _grewPastLimit = false;
    setState(() => _active = false);
    widget.onResizeEnd();
    if (grewPastLimit) widget.onGrowPastLimit();
  }

  @override
  Widget build(BuildContext context) {
    final handle = MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: _begin,
        onPanUpdate: _update,
        onPanEnd: (_) => _end(),
        onPanCancel: _end,
        onDoubleTap: widget.onReset,
        child: AnimatedContainer(
          key: const ValueKey<String>('desktop-board-resize-handle'),
          duration: const Duration(milliseconds: 120),
          width: _resizeHandleSize,
          height: _resizeHandleSize,
          decoration: BoxDecoration(
            color:
                _active
                    ? kPrimaryColor.withValues(alpha: 0.94)
                    : kBlack2Color.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  _active ? kPrimaryColor : kWhiteColor.withValues(alpha: 0.14),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _active ? 0.35 : 0.24),
                blurRadius: _active ? 14 : 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: CustomPaint(
            painter: _ResizeGripPainter(
              color: _active ? kBackgroundColor : kWhiteColor70,
            ),
          ),
        ),
      ),
    );
    return DesktopTooltip(
      message: 'Drag to resize board. Double-click to reset.',
      child: handle,
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color.withValues(alpha: 0.82)
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round;
    for (final inset in <double>[7, 11, 15]) {
      canvas.drawLine(
        Offset(size.width - inset, size.height - 4),
        Offset(size.width - 4, size.height - inset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeGripPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

FBaseButtonStyle Function(FButtonStyle style) _floatingBoardIconButtonStyle({
  required bool selected,
}) {
  return FButtonStyle.outline(
    (style) => style.copyWith(
      decoration: FWidgetStateMap({
        WidgetState.disabled: BoxDecoration(
          color: kBlack2Color.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kDividerColor.withValues(alpha: 0.5)),
        ),
        WidgetState.hovered | WidgetState.pressed: BoxDecoration(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.22)
                  : kBlack3Color.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.72)
                    : kWhiteColor.withValues(alpha: 0.18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        WidgetState.any: BoxDecoration(
          color:
              selected
                  ? kPrimaryColor.withValues(alpha: 0.16)
                  : kBlack2Color.withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color:
                selected
                    ? kPrimaryColor.withValues(alpha: 0.54)
                    : kWhiteColor.withValues(alpha: 0.12),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
      }),
      iconContentStyle:
          (content) => content.copyWith(
            padding: const EdgeInsets.all(8),
            iconStyle: FWidgetStateMap({
              WidgetState.disabled: const IconThemeData(
                color: Color(0x4DFFFFFF),
                size: 18,
              ),
              WidgetState.any: IconThemeData(
                color: selected ? kPrimaryColor : kWhiteColor70,
                size: 18,
              ),
            }),
          ),
    ),
  );
}

/// The chessboard plus its annotation layer (right-click drawing) and a
/// motor+shader impact overlay that fires per move. We isolate this in
/// its own widget so the parent layout stays clean and the annotation
/// state stays scoped to the active tab id.
class _BoardWithAnnotations extends ConsumerWidget {
  const _BoardWithAnnotations({
    required this.tabId,
    required this.boardRenderKey,
    required this.boardSize,
    required this.fen,
    required this.flipped,
    required this.playerSide,
    required this.sideToMove,
    required this.validMoves,
    required this.isCheck,
    required this.lastMove,
    required this.onMove,
    required this.promotionMove,
    required this.onPromotionSelection,
    required this.pgnShapes,
    required this.boardAnnotation,
    required this.boardAnnotationGlyph,
    required this.boardAnnotationSquare,
    required this.gameEnding,
    required this.onWheelStep,
    required this.evalPvs,
  });

  final String tabId;
  final String boardRenderKey;
  final double boardSize;
  final String fen;
  final bool flipped;
  final cg.PlayerSide playerSide;
  final Side sideToMove;
  final cg.ValidMoves validMoves;
  final bool isCheck;
  final Move? lastMove;
  final void Function(Move move, {bool? viaDragAndDrop}) onMove;
  final NormalMove? promotionMove;
  final void Function(Role? role) onPromotionSelection;
  final List<cg.Shape> pgnShapes;
  final LichessMoveAnnotation? boardAnnotation;
  final NagDisplay? boardAnnotationGlyph;
  final Square? boardAnnotationSquare;
  final _GameEndingData? gameEnding;
  final ValueChanged<int> onWheelStep;
  final List<BoardPv> evalPvs;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotations = ref.watch(boardAnnotationsProvider(tabId));
    final orientation = flipped ? Side.black : Side.white;
    final pieceAssets = ref.watch(
      boardSettingsProviderNew.select(
        (s) =>
            s.valueOrNull?.pieceAssets ?? const BoardSettingsNew().pieceAssets,
      ),
    );
    final engineSettings =
        ref.watch(engineSettingsProviderNew).valueOrNull ??
        const EngineSettings();
    final engineShapes = _enginePvArrowShapes(
      fen: fen,
      pvs: evalPvs,
      settings: engineSettings,
    );

    // Merge user-drawn shapes (right-click overlay) with author-baked PGN
    // arrows/circles and live engine PV arrows.
    final mergedShapes = <cg.Shape>[
      ...annotations.shapes,
      ...pgnShapes,
      ...engineShapes,
    ];
    final shapes =
        mergedShapes.isEmpty
            ? const fic.ISet<cg.Shape>.empty()
            : fic.ISet<cg.Shape>(mergedShapes);

    final highlights =
        gameEnding == null
            ? const fic.IMapConst<Square, cg.SquareHighlight>({})
            : fic.IMap<Square, cg.SquareHighlight>(
              gameEnding!.squareHighlights,
            );

    Widget? badge;
    if (boardAnnotationSquare != null) {
      if (boardAnnotation != null) {
        badge = _BoardBadge(
          boardSize: boardSize,
          square: boardAnnotationSquare!,
          flipped: flipped,
          color: _annotationColor(boardAnnotation!.type),
          sizeFactor: 0.40,
          child: SvgPicture.asset(
            _annotationIconAssetPath(boardAnnotation!.type),
            fit: BoxFit.contain,
          ),
        );
      } else if (boardAnnotationGlyph != null) {
        final glyph = boardAnnotationGlyph!;
        final badgeSize = (boardSize / 8) * 0.42;
        badge = _BoardBadge(
          boardSize: boardSize,
          square: boardAnnotationSquare!,
          flipped: flipped,
          color: glyph.color,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                glyph.symbol,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  fontSize: badgeSize * 0.62,
                ),
              ),
            ),
          ),
        );
      }
    }

    Widget? gameEndOverlay;
    if (gameEnding != null) {
      final squareSize = boardSize / 8;
      if (gameEnding!.isDraw) {
        // Draw — drop a peace-icon badge on each king. We re-derive king
        // squares directly from the parsed FEN via dartchess so the icons
        // follow the actual piece positions even on funky end states.
        final position = Chess.fromSetup(Setup.parseFen(fen));
        final whiteKing = position.board.kingOf(Side.white);
        final blackKing = position.board.kingOf(Side.black);
        if (whiteKing != null && blackKing != null) {
          gameEndOverlay = Stack(
            children: [
              _AnimatedPeaceIcon(
                square: whiteKing,
                boardSize: boardSize,
                flipped: flipped,
                delayMs: 0,
              ),
              _AnimatedPeaceIcon(
                square: blackKing,
                boardSize: boardSize,
                flipped: flipped,
                delayMs: 100,
              ),
            ],
          );
        }
      } else if (gameEnding!.loserKingSquare != null) {
        // Resolve the losing side from the king square: whichever king is
        // sitting on that square right now is the one that fell. Reading
        // from the FEN keeps us independent of any noise in the Result
        // header (capitalisation, stray spaces, FIDE notations).
        final loser = gameEnding!.loserKingSquare!;
        final position = Chess.fromSetup(Setup.parseFen(fen));
        final whiteKing = position.board.kingOf(Side.white);
        final blackKing = position.board.kingOf(Side.black);
        final side =
            loser == whiteKing
                ? Side.white
                : (loser == blackKing ? Side.black : null);
        if (side != null) {
          final pieceKind =
              side == Side.white ? PieceKind.whiteKing : PieceKind.blackKing;
          final image = pieceAssets[pieceKind];
          if (image != null) {
            final effectiveFile = flipped ? 7 - loser.file : loser.file;
            final effectiveRank = flipped ? loser.rank : 7 - loser.rank;
            gameEndOverlay = _FallenKingOverlay(
              left: effectiveFile * squareSize,
              top: effectiveRank * squareSize,
              squareSize: squareSize,
              pieceImage: image,
              squareColor: const Color(0xCCF53236),
            );
          }
        }
      }
    }

    return BoardWheelNavigation(
      onStep: onWheelStep,
      child: Stack(
        children: [
          BoardAnnotationLayer(
            tabId: tabId,
            size: boardSize,
            orientation: orientation,
            child: DesktopChessBoard(
              key: ValueKey<String>(boardRenderKey),
              size: boardSize,
              fen: fen,
              orientation: orientation,
              playerSide: playerSide,
              sideToMove: sideToMove,
              validMoves: validMoves,
              isCheck: isCheck,
              lastMove: lastMove,
              onMove: onMove,
              promotionMove: promotionMove,
              onPromotionSelection: onPromotionSelection,
              shapes: shapes,
              squareHighlights: highlights,
            ),
          ),
          if (badge != null) badge,
          if (gameEndOverlay != null) gameEndOverlay,
        ],
      ),
    );
  }
}

List<cg.Shape> _enginePvArrowShapes({
  required String fen,
  required List<BoardPv> pvs,
  required EngineSettings settings,
}) {
  if (!settings.showEngineAnalysis || !settings.showPvArrows || pvs.isEmpty) {
    return const <cg.Shape>[];
  }

  final Position position;
  try {
    position = Chess.fromSetup(Setup.parseFen(fen));
  } catch (_) {
    return const <cg.Shape>[];
  }

  final limit = math.min(settings.getMaxArrowsOnBoard(), pvs.length);
  final out = <cg.Shape>[];
  for (var i = 0; i < limit; i++) {
    final firstMove = pvs[i].moves
        .split(RegExp(r'\s+'))
        .firstWhere((move) => move.trim().isNotEmpty, orElse: () => '');
    final arrow = _engineArrowFromUci(
      position: position,
      rawUci: firstMove,
      color: enginePvArrowColor(i),
    );
    if (arrow != null) out.add(arrow);
  }
  return out;
}

cg.Arrow? _engineArrowFromUci({
  required Position position,
  required String rawUci,
  required Color color,
}) {
  final uci = rawUci.trim().toLowerCase();
  if (uci.isEmpty) return null;

  try {
    if (uci.contains('@')) {
      if (uci.length != 4 || uci[1] != '@') return null;
      final square = Square.fromName(uci.substring(2, 4));
      return cg.Arrow(color: color, orig: square, dest: square);
    }

    final move = Move.parse(uci);
    if (move is! NormalMove || !position.isLegal(move)) {
      return null;
    }
    return cg.Arrow(color: color, orig: move.from, dest: move.to);
  } catch (_) {
    return null;
  }
}

class _PlayerHeader extends ConsumerWidget {
  const _PlayerHeader({
    required this.name,
    required this.federation,
    required this.title,
    required this.rating,
    required this.fideId,
    required this.resultScore,
    required this.isWhite,
    required this.isToMove,
    this.clockText,
    this.activeGameId,
    this.useLiveClock = false,
    this.boardArgs,
    this.sourceGame,
    this.viewSource = ChessboardView.tour,
  });

  final String name;
  final String federation;
  final String title;
  final int rating;
  final int? fideId;
  final String? resultScore;
  final bool isWhite;
  final bool isToMove;

  /// Most recent PGN-baked clock annotation for this player at the
  /// active pointer (`null` when the game has no `[%clk …]` markers).
  /// Format follows what `formatPgnClockForDisplay` accepts —
  /// `1:23:45`, `12:30`, etc.
  final String? clockText;

  /// Live game stream id. The header reads only the clock snapshot so
  /// broadcast ticks rebuild this compact row instead of the full board pane.
  final String? activeGameId;

  /// Switch between the ticking live clock (live broadcast at the
  /// mainline tip) and the static PGN-baked clock string (any earlier
  /// move, or a finished game). Set by the board pane based on whether
  /// the user is sitting on the tip of a live broadcast.
  final bool useLiveClock;

  /// Full Board tab args. Used to keep score-card taps scoped to the
  /// tab's own event game list instead of a stale global tournament context.
  final BoardTabGameArgs? boardArgs;

  /// Original game row for this board tab. Null for detached PGNs.
  final GamesTourModel? sourceGame;

  /// Mobile-equivalent source view for this board tab.
  final ChessboardView viewSource;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveSnapshot =
        useLiveClock && activeGameId != null
            ? ref.watch(
              gameUpdatesStreamProvider(
                activeGameId!,
              ).select((async) => _LiveClockSnapshot.from(async.valueOrNull)),
            )
            : null;
    final liveClockSeconds =
        isWhite ? liveSnapshot?.whiteSeconds : liveSnapshot?.blackSeconds;
    final liveLastMoveTime = liveSnapshot?.lastMoveTime;
    final photoUrl =
        fideId == null
            ? null
            : ref
                .watch(_desktopBoardPlayerPhotoProvider(fideId!))
                .valueOrNull
                ?.trim();
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;

    final pieceDot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isWhite ? kWhiteColor : Colors.black,
        border: Border.all(color: kDividerColor, width: 1),
      ),
    );
    final hasName = name.isNotEmpty;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kBlack2Color,
        border: Border.symmetric(
          horizontal: BorderSide(
            color: kWhiteColor.withValues(alpha: 0.10),
            width: 0.75,
          ),
        ),
      ),
      child: Row(
        children: [
          if (resultScore != null) ...[
            SizedBox(
              width: 18,
              child: Text(
                resultScore!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kWhiteColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          pieceDot,
          const SizedBox(width: 8),
          if (hasPhoto) ...[
            Container(
              width: 40,
              height: 40,
              padding: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: kBlack3Color,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: kWhiteColor.withValues(alpha: 0.24)),
              ),
              child: PlayerInitialsAvatarCompact(
                photoUrl: photoUrl,
                initials: _playerHeaderInitials(name),
                size: 38,
                borderRadius: 19,
              ),
            ),
            const SizedBox(width: 8),
          ],
          BackfilledFederationFlag(
            federation: federation,
            fideId: fideId,
            width: 22,
            height: 16,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(width: 8),
          if (title.isNotEmpty) ...[
            Text(
              title,
              style: const TextStyle(
                color: kLightYellowColor,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              hasName ? name : '—',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (rating > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$rating',
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          if (useLiveClock &&
              (liveClockSeconds != null || liveLastMoveTime != null)) ...[
            const SizedBox(width: 10),
            _PlayerClock(
              text: clockText ?? '',
              isToMove: isToMove,
              liveClockSeconds: liveClockSeconds,
              liveLastMoveTime: liveLastMoveTime,
              liveCountdownActive: isToMove && liveLastMoveTime != null,
            ),
          ] else if (clockText != null && clockText!.trim().isNotEmpty) ...[
            const SizedBox(width: 10),
            _PlayerClock(text: clockText!, isToMove: isToMove),
          ],
        ],
      ),
    );

    if (!hasName) return body;
    return ClickCursor(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openPlayer(ref, name),
        child: body,
      ),
    );
  }

  void _openPlayer(WidgetRef ref, String playerName) {
    // Event-backed board tabs open the player's score card. Individual
    // library/saved-PGN boards have no event performance context, so their
    // player-name taps go straight to the player profile.
    final game = sourceGame;
    final sideCard =
        game == null ? null : (isWhite ? game.whitePlayer : game.blackPlayer);
    final player = synthesizePlayerStandingModel(
      name: playerName,
      title:
          title.isNotEmpty
              ? title
              : (sideCard?.title.isNotEmpty == true ? sideCard?.title : null),
      countryCode:
          federation.isNotEmpty
              ? federation
              : (sideCard?.countryCode.isNotEmpty == true
                  ? sideCard!.countryCode
                  : (sideCard?.federation ?? '')),
      rating: rating > 0 ? rating : sideCard?.rating,
      fideId: sideCard?.fideId ?? fideId,
    );
    final eventGame =
        boardPlayerTapEventContextGame(game) ??
        _boardArgsEventContextGame(boardArgs);
    final profileSource =
        eventGame == null
            ? PlayerProfileDataSource.supabase
            : _profileSourceFor(eventGame.source);

    if (eventGame == null) {
      ref.read(selectedBroadcastModelProvider.notifier).state = null;
      ref.read(scoreCardGamesContextProvider.notifier).state = null;
      ref.read(scoreCardHasEventContextProvider.notifier).state = false;
      ref.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
          profileSource;
      openPlayerProfile(
        ref,
        PlayerProfileArgs(
          playerName: player.name,
          fideId: player.fideId,
          title: player.title,
          federation: player.countryCode.isEmpty ? null : player.countryCode,
          rating: player.score > 0 ? player.score : null,
          dataSource: profileSource,
          gamebasePlayerId: player.gamebasePlayerId,
        ),
      );
      return;
    }

    ref.read(chessboardViewFromProviderNew.notifier).state = viewSource;
    ref.read(scoreCardHasEventContextProvider.notifier).state = true;
    ref.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
        profileSource;

    // Board tabs carry their own event list. Prefer it over the legacy
    // selected-broadcast global so a score card opened from a game cannot
    // inherit an unrelated player/history context after tab navigation.
    ref.read(selectedBroadcastModelProvider.notifier).state = null;
    ref
        .read(scoreCardGamesContextProvider.notifier)
        .state = _scoreCardGamesContextForBoardTap(eventGame, boardArgs);

    openPlayerScoreCard(ref, player, fromTournamentContext: true);
  }

  PlayerProfileDataSource _profileSourceFor(GameSource source) {
    return source == GameSource.twic
        ? PlayerProfileDataSource.twic
        : PlayerProfileDataSource.supabase;
  }
}

String _playerHeaderInitials(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final commaParts = trimmed.split(', ');
  if (commaParts.length >= 2 &&
      commaParts[0].isNotEmpty &&
      commaParts[1].isNotEmpty) {
    return '${commaParts[1][0]}${commaParts[0][0]}'.toUpperCase();
  }
  final words =
      trimmed.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (words.length >= 2) return '${words[0][0]}${words[1][0]}'.toUpperCase();
  return trimmed.substring(0, trimmed.length >= 2 ? 2 : 1).toUpperCase();
}

GamesTourModel? _boardArgsEventContextGame(BoardTabGameArgs? args) {
  final gameId = args?.gameId?.trim();
  if (args == null || gameId == null || gameId.isEmpty) {
    return null;
  }

  final summary =
      _findSummaryById(args.eventGames, gameId) ??
      _findSummaryById(args.routeGames, gameId);
  if (summary != null) {
    final model = _gamesTourModelFromSummary(summary);
    return model.tourId.trim().isEmpty ? null : model;
  }

  final tourId =
      _firstNonBlankTourId(args.eventGames) ??
      _firstNonBlankTourId(args.routeGames);
  if (tourId == null || tourId.isEmpty) {
    return null;
  }

  return GamesTourModel(
    gameId: gameId,
    whitePlayer: PlayerCard(
      name: args.whiteName,
      federation: args.whiteFederation,
      title: args.whiteTitle,
      rating: args.whiteRating,
      countryCode: args.whiteFederation,
      fideId: args.whiteFideId,
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: args.blackName,
      federation: args.blackFederation,
      title: args.blackTitle,
      rating: args.blackRating,
      countryCode: args.blackFederation,
      fideId: args.blackFideId,
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: GameStatus.unknown,
    roundId: '',
    tourId: tourId,
    pgn: args.pgn.trim().isEmpty ? null : args.pgn,
    fen: args.fenSeed,
  );
}

List<GamesTourModel> _scoreCardGamesContextForBoardTap(
  GamesTourModel eventGame,
  BoardTabGameArgs? args,
) {
  final summaries = args?.eventGames ?? const <TournamentGameSummary>[];
  if (summaries.isEmpty) {
    return <GamesTourModel>[eventGame];
  }

  final byId = <String, GamesTourModel>{};
  for (final summary in summaries) {
    final id = summary.id.trim();
    if (id.isEmpty) continue;
    byId[id] = _gamesTourModelFromSummary(summary, source: eventGame.source);
  }
  byId[eventGame.gameId] = eventGame;
  return byId.values.toList(growable: false);
}

TournamentGameSummary? _findSummaryById(
  List<TournamentGameSummary> summaries,
  String gameId,
) {
  for (final summary in summaries) {
    if (summary.id == gameId) return summary;
  }
  return null;
}

List<TournamentGameSummary> _syncLiveGameSummaryList(
  List<TournamentGameSummary> summaries, {
  required String gameId,
  required String? pgn,
  required String? fen,
  required GameStatus status,
  required DateTime? lastMoveTime,
  required bool hasStarted,
}) {
  var changed = false;
  final updated = <TournamentGameSummary>[
    for (final summary in summaries)
      if (summary.id == gameId)
        _summaryWithLiveState(
          summary,
          pgn: pgn,
          fen: fen,
          status: status,
          lastMoveTime: lastMoveTime,
          hasStarted: hasStarted,
          onChanged: () => changed = true,
        )
      else
        summary,
  ];
  return changed
      ? List<TournamentGameSummary>.unmodifiable(updated)
      : summaries;
}

TournamentGameSummary _summaryWithLiveState(
  TournamentGameSummary summary, {
  required String? pgn,
  required String? fen,
  required GameStatus status,
  required DateTime? lastMoveTime,
  required bool hasStarted,
  required VoidCallback onChanged,
}) {
  final nextPgn = pgn?.trim().isNotEmpty == true ? pgn!.trim() : summary.pgn;
  final nextFen = fen?.trim().isNotEmpty == true ? fen!.trim() : summary.fen;
  final nextStatus = status == GameStatus.unknown ? summary.status : status;
  final nextLastMoveTime = lastMoveTime ?? summary.lastMoveTime;
  final nextHasStarted = hasStarted || summary.hasStarted;
  final nextHasPgn = (nextPgn?.trim().isNotEmpty ?? false) || summary.hasPgn;
  if (nextPgn == summary.pgn &&
      nextFen == summary.fen &&
      nextStatus == summary.status &&
      nextLastMoveTime == summary.lastMoveTime &&
      nextHasStarted == summary.hasStarted &&
      nextHasPgn == summary.hasPgn) {
    return summary;
  }
  onChanged();
  return summary.copyWith(
    pgn: nextPgn,
    fen: nextFen,
    status: nextStatus,
    lastMoveTime: nextLastMoveTime,
    hasStarted: nextHasStarted,
  );
}

String? _firstNonBlankTourId(List<TournamentGameSummary> summaries) {
  for (final summary in summaries) {
    final tourId = summary.tourId.trim();
    if (tourId.isNotEmpty) return tourId;
  }
  return null;
}

GamesTourModel _gamesTourModelFromSummary(
  TournamentGameSummary summary, {
  GameSource source = GameSource.supabase,
}) {
  final whiteFederation = summary.whiteFederation.trim();
  final blackFederation = summary.blackFederation.trim();
  return GamesTourModel(
    gameId: summary.id,
    source: source,
    whitePlayer: PlayerCard(
      name: summary.whitePlayer,
      federation: whiteFederation,
      title: summary.whiteTitle,
      rating: summary.whiteRating,
      countryCode: whiteFederation,
      fideId: summary.whiteFideId,
      team: null,
    ),
    blackPlayer: PlayerCard(
      name: summary.blackPlayer,
      federation: blackFederation,
      title: summary.blackTitle,
      rating: summary.blackRating,
      countryCode: blackFederation,
      fideId: summary.blackFideId,
      team: null,
    ),
    whiteTimeDisplay: '--:--',
    blackTimeDisplay: '--:--',
    whiteClockCentiseconds: 0,
    blackClockCentiseconds: 0,
    gameStatus: summary.status,
    fen: summary.fen,
    pgn: summary.pgn,
    boardNr: summary.boardNumber,
    roundId: summary.roundId,
    roundSlug: summary.roundSlug.trim().isEmpty ? null : summary.roundSlug,
    tourId: summary.tourId,
    tourSlug: summary.tourSlug.trim().isEmpty ? null : summary.tourSlug,
    lastMoveTime: summary.lastMoveTime ?? summary.startsAt,
    dateStart: summary.startsAt,
    openingName: summary.openingName,
  );
}

class _LiveClockSnapshot {
  const _LiveClockSnapshot({
    required this.whiteSeconds,
    required this.blackSeconds,
    required this.lastMoveTime,
  });

  final int? whiteSeconds;
  final int? blackSeconds;
  final DateTime? lastMoveTime;

  static _LiveClockSnapshot? from(Map<String, dynamic>? data) {
    if (data == null) return null;
    return _LiveClockSnapshot(
      whiteSeconds: (data['last_clock_white'] as num?)?.round(),
      blackSeconds: (data['last_clock_black'] as num?)?.round(),
      lastMoveTime:
          data['last_move_time'] is String
              ? DateTime.tryParse(data['last_move_time'] as String)
              : null,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LiveClockSnapshot &&
            other.whiteSeconds == whiteSeconds &&
            other.blackSeconds == blackSeconds &&
            other.lastMoveTime == lastMoveTime;
  }

  @override
  int get hashCode => Object.hash(whiteSeconds, blackSeconds, lastMoveTime);
}

/// Spring-animated player clock badge.
///
/// Two motion stories layered together:
///
///  1. **Active-side glow** (motor state spring). When `isToMove` flips,
///     the badge background lerps from neutral to a faint primary tint
///     and the border picks up the brand colour, plus a soft halo blur
///     blooms in. Driven by [DesktopMotion.layout] so the swap is
///     smooth — feels like focus naturally migrating between the two
///     clocks instead of a hard toggle.
///
///  2. **Digit transition** (none). Per Trello #461 the clock counts
///     down in place — no per-second slide/fade animation. The displayed
///     time string is computed in this widget: for live boards it
///     subtracts wall-clock elapsed since `liveLastMoveTime` from the
///     last `liveClockSeconds` snapshot (1 Hz tick via
///     [dateTimeProvider]); for any earlier ply it uses the PGN-baked
///     `text`. Tabular-figures keeps every digit slot fixed during the
///     swap so the badge width never jitters.
///
/// Sizing: the badge is sized to its content. No `minHeight` is
/// imposed (the previous 26 px floor clipped the 13 px text inside the
/// 32 px header row); padding is tight enough that the badge fits
/// comfortably inside [_BoardArea.headerHeight] with room to spare.
class _PlayerClock extends ConsumerWidget {
  const _PlayerClock({
    required this.text,
    required this.isToMove,
    this.liveClockSeconds,
    this.liveLastMoveTime,
    this.liveCountdownActive = false,
  });

  /// PGN-baked clock string for this side at the active pointer
  /// (`1:23:45`, `12:30`, etc). Consulted only when no live snapshot
  /// is present.
  final String text;
  final bool isToMove;

  /// Live broadcast snapshot of this side's clock in seconds. When set
  /// (alongside [liveLastMoveTime]) the badge renders the live time
  /// instead of the PGN string.
  final int? liveClockSeconds;
  final DateTime? liveLastMoveTime;

  /// True iff this side is currently on move at the live tip — the
  /// badge then ticks the displayed time down once per second.
  final bool liveCountdownActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayText = _resolveDisplayText(ref);
    if (displayText.isEmpty) return const SizedBox.shrink();

    return SingleMotionBuilder(
      value: isToMove ? 1.0 : 0.0,
      motion: DesktopMotion.layout,
      builder: (context, t, _) {
        final bg = Color.lerp(
          kBlack3Color,
          kPrimaryColor.withValues(alpha: 0.18),
          t,
        );
        final borderColor =
            Color.lerp(kDividerColor, kPrimaryColor, t) ?? kDividerColor;
        final textColor =
            Color.lerp(kWhiteColor70, kWhiteColor, t * 0.6) ?? kWhiteColor70;
        final textStyle = TextStyle(
          color: textColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
          height: 1.0,
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: borderColor),
            boxShadow:
                t > 0.05
                    ? [
                      BoxShadow(
                        color: kPrimaryColor.withValues(alpha: 0.18 * t),
                        blurRadius: 6 * t,
                        offset: const Offset(0, 1),
                      ),
                    ]
                    : null,
          ),
          alignment: Alignment.center,
          // Plain Text — a clock face should count down in place, not
          // slide+fade every second. The badge background/border still
          // springs when the side-to-move flips; only the digits stay
          // calm. (#461 feedback: "Clock movement in the live game
          // should be like a normal one.")
          child: Text(
            displayText,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: textStyle,
          ),
        );
      },
    );
  }

  /// Compute the formatted string the badge should render at this
  /// frame. Live snapshots win over PGN — when both are absent we
  /// return an empty string and the caller hides the badge.
  String _resolveDisplayText(WidgetRef ref) {
    final useLive = liveClockSeconds != null || liveLastMoveTime != null;
    if (useLive) {
      final base = liveClockSeconds ?? 0;
      if (!liveCountdownActive || liveLastMoveTime == null) {
        return formatClockDisplayFromSeconds(base);
      }
      final now = ref.watch(
        dateTimeProvider.select((async) => async.valueOrNull),
      );
      if (now == null) return formatClockDisplayFromSeconds(base);
      final elapsed = now.difference(liveLastMoveTime!).inSeconds.abs();
      final remaining = base - elapsed;
      return formatClockDisplayFromSeconds(remaining < 0 ? 0 : remaining);
    }
    return formatPgnClockForDisplay(text);
  }
}

/// Internal record of one position in the analysis history.
class _Ply {
  const _Ply({
    required this.position,
    required this.san,
    this.nags = const <int>[],
    this.comments = const <String>[],
    this.move,
    this.lastMoveSquare,
  });

  final Position position;

  /// SAN for the move that produced this position. `null` for the initial
  /// position which has no preceding move.
  final String? san;

  /// PGN-baked NAG codes for the move that produced this position
  /// (e.g. `[1, 16]` for `!±`). Empty when the PGN had no annotations.
  /// Lichess-derived annotations are merged in at render time inside
  /// the move list — this list only carries what was authored into the
  /// PGN itself.
  final List<int> nags;

  /// Raw PGN comments attached to the move that produced this position.
  /// Used to extract `[%cal …]` arrows and `[%csl …]` square highlights
  /// the broadcast author baked into the PGN.
  final List<String> comments;

  /// The dartchess [Move] that produced this position. Used both for the
  /// last-move highlight on chessground and for placing NAG/Lichess
  /// annotation badges on the destination square. `null` for the initial
  /// position.
  final Move? move;

  /// Destination square of [move], with castling normalised to the king's
  /// landing square (so badges anchor to the king after O-O / O-O-O).
  final Square? lastMoveSquare;

  Move? get uciMove => move;
}

String _moveLabel(List<_Ply> history, int cursor) {
  if (cursor == 0) return 'Start position';
  final fullMove = (cursor + 1) ~/ 2;
  final isWhite = cursor.isOdd;
  final san = history[cursor].san ?? '';
  final marker = isWhite ? '$fullMove.' : '$fullMove…';
  final progress = '$cursor / ${history.length - 1}';
  return '$marker $san   ·   $progress';
}

/// Pull a Lichess game id out of a parsed PGN's headers. Mirrors the
/// mobile extractor in `chess_board_screen_new.dart` — checks `Site`,
/// `LichessId`, `LichessGameId`, `LichessURL`, `SiteUrl`, `Source`, and
/// the dartchess gameId fallback. Lichess game ids are exactly 8
/// alphanumeric characters; broadcast URLs encode them as the last
/// segment.
String? _extractLichessGameId(Map<String, String> headers) {
  final candidates = <String?>[
    headers['Site'],
    headers['LichessId'],
    headers['LichessGameId'],
    headers['LichessURL'],
    headers['SiteUrl'],
    headers['Source'],
  ];
  final idRegex = RegExp(r'^[a-zA-Z0-9]{8}$');
  final urlRegex = RegExp(r'lichess\.org/([a-zA-Z0-9]{8})(?:[/?#]|$)');
  final broadcastRegex = RegExp(
    r'lichess\.org/broadcast/[^/]+/[^/]+/[a-zA-Z0-9]{8}/([a-zA-Z0-9]{8})',
  );
  for (final candidate in candidates) {
    if (candidate == null || candidate.isEmpty) continue;
    final trimmed = candidate.trim();
    final broadcastMatch = broadcastRegex.firstMatch(trimmed);
    if (broadcastMatch != null) return broadcastMatch.group(1);
    if (idRegex.hasMatch(trimmed)) return trimmed;
    final m = urlRegex.firstMatch(trimmed);
    if (m != null) return m.group(1);
  }
  return null;
}

String? _extractLichessSiteUrl(Map<String, String> headers) {
  for (final key in const ['Site', 'LichessURL', 'SiteUrl', 'Source']) {
    final v = headers[key];
    if (v != null && v.contains('lichess.org')) return v.trim();
  }
  return null;
}

/// Build the moves-signature the Lichess annotations service uses to
/// dedupe identical lines: `'<count>:<move1>|<move2>|...'` with check/
/// mate markers stripped. Must match mobile's `_buildSignature` exactly
/// or the Edge Function will return null.
String _buildMovesSignature(List<String> moveSans) {
  final normalized =
      moveSans.map((san) => san.replaceAll(RegExp(r'[+#]'), '')).toList();
  return '${normalized.length}:${normalized.join('|')}';
}

/// True when the user has SFX enabled in board settings. Mirrors the
/// `boardSettingsProviderNew.soundEnabled` toggle so the desktop board
/// honours whatever the user picked on mobile or in the desktop
/// preferences pane. Reads via `ref.read` because we only want a
/// snapshot — we don't want this to rebuild the whole pane every time
/// the user toggles SFX.
bool _shouldPlaySounds(WidgetRef ref, String? tabId) {
  final settings = ref.read(boardSettingsProviderNew).valueOrNull;
  // Default is the same as the model default (true) — if the settings
  // haven't loaded yet, keep sounds on so the first move plays.
  final globallyEnabled = settings?.soundEnabled ?? true;
  if (!globallyEnabled) return false;
  if (tabId == null || tabId.isEmpty) return true;
  return !ref.read(boardTabSoundMuteProvider).contains(tabId);
}

/// Castling in dartchess is encoded as king-captures-rook; remap to the
/// king's actual landing square so badge anchors and last-move feedback
/// land where the king ends up rather than on the rook.
Square? _normaliseLastMoveSquare(Move? move) {
  if (move == null) return null;
  if (move is NormalMove) {
    final from = move.from;
    final to = move.to;
    if (from == Square.e1 && to == Square.h1) return Square.g1;
    if (from == Square.e1 && to == Square.a1) return Square.c1;
    if (from == Square.e8 && to == Square.h8) return Square.g8;
    if (from == Square.e8 && to == Square.a8) return Square.c8;
    return to;
  }
  final squares = move.squares.toList();
  return squares.isEmpty ? null : squares.last;
}

/// Map the four primary quality NAGs to a Lichess annotation type so we
/// can render the same SVG badge whether the glyph came from PGN-baked
/// `$1`/`$2`/`$3`/`$4` or from a Lichess analysis classification.
LichessMoveAnnotationType? _mapNagToAnnotationType(int nag) {
  switch (nag) {
    case 1:
      return LichessMoveAnnotationType.goodMove;
    case 2:
      return LichessMoveAnnotationType.mistake;
    case 3:
      return LichessMoveAnnotationType.brilliant;
    case 4:
      return LichessMoveAnnotationType.blunder;
    default:
      return null;
  }
}

String _annotationIconAssetPath(LichessMoveAnnotationType type) {
  switch (type) {
    case LichessMoveAnnotationType.brilliant:
      return 'assets/svgs/brilliant.svg';
    case LichessMoveAnnotationType.missedWin:
      return 'assets/svgs/missed_win.svg';
    case LichessMoveAnnotationType.mistake:
      return 'assets/svgs/mistake.svg';
    case LichessMoveAnnotationType.blunder:
      return 'assets/svgs/blunder.svg';
    case LichessMoveAnnotationType.inaccuracy:
      return 'assets/svgs/inaccuracy.svg';
    case LichessMoveAnnotationType.goodMove:
      return 'assets/svgs/good_move.svg';
    case LichessMoveAnnotationType.bestMove:
      return 'assets/svgs/best_move.svg';
    case LichessMoveAnnotationType.bookMove:
      return 'assets/svgs/book_move.svg';
  }
}

Color _annotationColor(LichessMoveAnnotationType type) {
  switch (type) {
    case LichessMoveAnnotationType.brilliant:
      return const Color(0xFF177A68);
    case LichessMoveAnnotationType.missedWin:
      return const Color(0xFFF70400);
    case LichessMoveAnnotationType.goodMove:
      return const Color(0xFF177A68);
    case LichessMoveAnnotationType.bestMove:
      return const Color(0xFF28833A);
    case LichessMoveAnnotationType.bookMove:
      return const Color(0xFF4E5B4F);
    case LichessMoveAnnotationType.inaccuracy:
      return const Color(0xFFFABE46);
    case LichessMoveAnnotationType.mistake:
      return const Color(0xFFEB9518);
    case LichessMoveAnnotationType.blunder:
      return const Color(0xFFC9342E);
  }
}

/// Map a single-letter Lichess colour code (G/Y/B/R/O) to the colour used
/// for both `[%cal …]` arrows and `[%csl …]` square highlights. Mirrors
/// the mobile palette so PGN annotations look identical across shells.
Color _pgnAnnotationColor(String code) {
  switch (code.toUpperCase()) {
    case 'G':
      return const Color(0xFF15781B).withValues(alpha: 0.8);
    case 'Y':
      return const Color(0xFFE58F00).withValues(alpha: 0.8);
    case 'B':
      return const Color(0xFF003088).withValues(alpha: 0.8);
    case 'R':
      return const Color(0xFF882020).withValues(alpha: 0.8);
    case 'O':
      return const Color(0xFFE68F00).withValues(alpha: 0.8);
    default:
      return const Color(0xFF15781B).withValues(alpha: 0.8);
  }
}

/// Pull `[%cal Gg8g7,Re5e4]` arrows and `[%csl Re2,Gd5]` circles out of a
/// move's PGN comments. Authors use these to mark "interesting" squares
/// and tactical motifs; we surface them on chessground via [Shape]s so
/// they look identical to user-drawn shapes from the right-click overlay.
Iterable<cg.Shape> _shapesFromPgnComments(List<String> comments) {
  if (comments.isEmpty) return const [];
  final shapes = <cg.Shape>[];
  final calRegex = RegExp(r'\[%cal\s+([^\]]+)\]');
  final cslRegex = RegExp(r'\[%csl\s+([^\]]+)\]');
  for (final comment in comments) {
    for (final match in calRegex.allMatches(comment)) {
      final content = match.group(1);
      if (content == null) continue;
      for (final raw in content.split(',')) {
        final trimmed = raw.trim();
        if (trimmed.length != 5) continue;
        try {
          final orig = Square.fromName(trimmed.substring(1, 3));
          final dest = Square.fromName(trimmed.substring(3, 5));
          if (orig == dest) continue;
          shapes.add(
            cg.Arrow(
              color: _pgnAnnotationColor(trimmed[0]),
              orig: orig,
              dest: dest,
            ),
          );
        } catch (_) {}
      }
    }
    for (final match in cslRegex.allMatches(comment)) {
      final content = match.group(1);
      if (content == null) continue;
      for (final raw in content.split(',')) {
        final trimmed = raw.trim();
        if (trimmed.length != 3) continue;
        try {
          final sq = Square.fromName(trimmed.substring(1, 3));
          shapes.add(
            cg.Circle(color: _pgnAnnotationColor(trimmed[0]), orig: sq),
          );
        } catch (_) {}
      }
    }
  }
  return shapes;
}

/// Game-end visual data: per-square highlights (red for the loser's king,
/// mint green for both kings on a draw) plus the loser's king square so
/// the [_FallenKingOverlay] knows where to plant the falling-piece sprite.
class _GameEndingData {
  const _GameEndingData({
    required this.squareHighlights,
    required this.loserKingSquare,
    required this.isDraw,
  });

  final Map<Square, cg.SquareHighlight> squareHighlights;
  final Square? loserKingSquare;
  final bool isDraw;
}

/// Resolve a PGN `[Result]` header into a game-end descriptor. Returns
/// `null` when the result is missing, live (`*`), or the king squares
/// can't be located on the board (shouldn't happen in legal positions
/// but we degrade gracefully).
_GameEndingData? _gameEndingFor(String result, Position position) {
  // Normalise: strip whitespace, lower-case so `"1 - 0"`, `"1.0-0.0"`,
  // unicode `½` and a few other fragmentations all map to the canonical
  // form mobile already expects. Avoids the failure mode where an
  // unusual PGN header silently dropped end-game rendering.
  final normalised = result
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('½', '1/2');
  if (normalised.isEmpty || normalised == '*') return null;
  final board = position.board;
  final whiteKing = board.kingOf(Side.white);
  final blackKing = board.kingOf(Side.black);
  if (whiteKing == null || blackKing == null) return null;

  // Canonical drawn states + a few common variants.
  final isDraw =
      normalised == '1/2-1/2' ||
      normalised == '0.5-0.5' ||
      normalised == '1.0-1.0';
  final whiteWon =
      normalised == '1-0' || normalised == '1.0-0.0' || normalised == '1-0.0';
  final blackWon =
      normalised == '0-1' || normalised == '0.0-1.0' || normalised == '0.0-1';

  if (isDraw) {
    return _GameEndingData(
      squareHighlights: <Square, cg.SquareHighlight>{
        whiteKing: const cg.SquareHighlight(
          details: cg.HighlightDetails(solidColor: Color(0xCCADE1CD)),
        ),
        blackKing: const cg.SquareHighlight(
          details: cg.HighlightDetails(solidColor: Color(0xCCADE1CD)),
        ),
      },
      loserKingSquare: null,
      isDraw: true,
    );
  }
  if (whiteWon) {
    return _GameEndingData(
      squareHighlights: <Square, cg.SquareHighlight>{
        blackKing: const cg.SquareHighlight(
          details: cg.HighlightDetails(solidColor: Color(0xCCF53236)),
        ),
      },
      loserKingSquare: blackKing,
      isDraw: false,
    );
  }
  if (blackWon) {
    return _GameEndingData(
      squareHighlights: <Square, cg.SquareHighlight>{
        whiteKing: const cg.SquareHighlight(
          details: cg.HighlightDetails(solidColor: Color(0xCCF53236)),
        ),
      },
      loserKingSquare: whiteKing,
      isDraw: false,
    );
  }
  return null;
}

/// SVG / Unicode glyph badge anchored to a board square. Mirrors mobile's
/// `_buildBoardBadge`: positioned at the top-right of the destination
/// square, scales in with a short ease-out-back so a freshly landed move
/// "pops" its annotation.
class _BoardBadge extends StatelessWidget {
  const _BoardBadge({
    required this.boardSize,
    required this.square,
    required this.flipped,
    required this.color,
    required this.child,
    this.sizeFactor = 0.42,
  });

  final double boardSize;
  final Square square;
  final bool flipped;
  final Color color;
  final Widget child;
  final double sizeFactor;

  @override
  Widget build(BuildContext context) {
    final squareSize = boardSize / 8;
    final effectiveFile = flipped ? 7 - square.file : square.file;
    final effectiveRank = flipped ? square.rank : 7 - square.rank;
    final left = effectiveFile * squareSize;
    final top = effectiveRank * squareSize;
    final badgeSize = squareSize * sizeFactor;
    final badgeLeft = (left + squareSize - badgeSize / 2).clamp(
      0.0,
      boardSize - badgeSize,
    );
    final badgeTop = (top - badgeSize / 2 + squareSize * 0.04).clamp(
      0.0,
      boardSize - badgeSize,
    );

    return Positioned(
      left: badgeLeft,
      top: badgeTop,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.6, end: 1.0),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          builder:
              (context, scale, c) => Transform.scale(scale: scale, child: c),
          child: Container(
            width: badgeSize,
            height: badgeSize,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x73000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
              border: Border.all(color: const Color(0x2EFFFFFF), width: 0.5),
            ),
            padding: EdgeInsets.all(badgeSize * 0.16),
            child: RepaintBoundary(child: child),
          ),
        ),
      ),
    );
  }
}

/// Falling-king overlay rendered on top of the chessboard at the loser's
/// king square. Uses motor's bouncy spring to rotate the piece -45° on
/// mount, mirroring the mobile end-of-game effect. The opaque background
/// hides the chessground-rendered king underneath so we don't see two
/// overlapping sprites mid-animation.
class _FallenKingOverlay extends StatefulWidget {
  const _FallenKingOverlay({
    required this.left,
    required this.top,
    required this.squareSize,
    required this.pieceImage,
    required this.squareColor,
  });

  final double left;
  final double top;
  final double squareSize;
  final ImageProvider pieceImage;
  final Color squareColor;

  @override
  State<_FallenKingOverlay> createState() => _FallenKingOverlayState();
}

class _FallenKingOverlayState extends State<_FallenKingOverlay> {
  bool _animate = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _animate = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.left,
      top: widget.top,
      child: IgnorePointer(
        child: SizedBox(
          width: widget.squareSize,
          height: widget.squareSize,
          child: Stack(
            children: [
              ColoredBox(
                color: widget.squareColor,
                child: const SizedBox.expand(),
              ),
              Center(
                child: SingleMotionBuilder(
                  motion: const CupertinoMotion.bouncy(),
                  value: _animate ? -math.pi / 4 : 0.0,
                  builder:
                      (context, rotation, child) => Transform.rotate(
                        angle: rotation,
                        alignment: Alignment.center,
                        child: child,
                      ),
                  child: Image(image: widget.pieceImage, fit: BoxFit.contain),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny dove-icon badge that pops into the top-right of a king's square
/// when the game ends in a draw. Two copies are placed (one per king)
/// with a slight delay between them for a stagger effect.
class _AnimatedPeaceIcon extends StatefulWidget {
  const _AnimatedPeaceIcon({
    required this.square,
    required this.boardSize,
    required this.flipped,
    required this.delayMs,
  });

  final Square square;
  final double boardSize;
  final bool flipped;
  final int delayMs;

  @override
  State<_AnimatedPeaceIcon> createState() => _AnimatedPeaceIconState();
}

class _AnimatedPeaceIconState extends State<_AnimatedPeaceIcon> {
  bool _animate = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delayMs), () {
      if (mounted) setState(() => _animate = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final squareSize = widget.boardSize / 8;
    final effectiveFile =
        widget.flipped ? 7 - widget.square.file : widget.square.file;
    final effectiveRank =
        widget.flipped ? widget.square.rank : 7 - widget.square.rank;
    final containerSize = squareSize * 0.28;
    return Positioned(
      left: effectiveFile * squareSize + squareSize - containerSize - 1,
      top: effectiveRank * squareSize + 1,
      child: IgnorePointer(
        child: SingleMotionBuilder(
          motion: const CupertinoMotion.bouncy(),
          value: _animate ? 1.0 : 0.0,
          builder:
              (context, scale, child) => Transform.scale(
                scale: scale,
                alignment: Alignment.topRight,
                child: child,
              ),
          child: Container(
            width: containerSize,
            height: containerSize,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: Center(
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.black,
                  BlendMode.srcIn,
                ),
                child: Text(
                  '🕊️',
                  style: TextStyle(fontSize: containerSize * 0.6),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _fenPositionKey(String fen) {
  final parts = fen.trim().split(RegExp(r'\s+'));
  if (parts.length < 4) return fen.trim();
  return parts.take(4).join(' ');
}

String? _nullableFenPositionKey(String? fen) {
  final trimmed = fen?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return _fenPositionKey(trimmed);
}

({Position position, Move move})? _previewExplorerMove(
  Position position,
  String? uci,
) {
  final trimmed = uci?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  try {
    final move = Move.parse(trimmed);
    if (move == null || !position.isLegal(move)) return null;
    return (position: position.play(move), move: move);
  } catch (_) {
    return null;
  }
}

({Position position, Move move, String san})? _previewExplorerLine(
  Position position,
  List<String> ucis,
  int step,
) {
  if (ucis.isEmpty || step < 0) return null;
  final upTo = step.clamp(0, ucis.length - 1).toInt();
  var cursor = position;
  Move? lastMove;
  String? lastSan;
  for (var i = 0; i <= upTo; i++) {
    final move = Move.parse(ucis[i].trim());
    if (move == null || !cursor.isLegal(move)) return null;
    final made = cursor.makeSan(move);
    cursor = made.$1;
    lastMove = move;
    lastSan = made.$2;
  }
  if (lastMove == null || lastSan == null) return null;
  return (position: cursor, move: lastMove, san: lastSan);
}

String _boardRenderKey({
  required String? activeTabId,
  required String? activeGameId,
  required BoardTabGameArgs? boardArgs,
  required PgnImport? latestPgnImport,
  required String? lastAppliedGameId,
  required String? lastAppliedPgn,
}) {
  final scope = _boardRenderScope(
    activeTabId: activeTabId,
    activeGameId: activeGameId,
    boardArgs: boardArgs,
    latestPgnImport: latestPgnImport,
  );
  final hydrationState = _boardHydrationState(
    activeGameId: activeGameId,
    boardArgs: boardArgs,
    latestPgnImport: latestPgnImport,
    lastAppliedGameId: lastAppliedGameId,
    lastAppliedPgn: lastAppliedPgn,
  );
  return '$scope:$hydrationState';
}

String _boardRenderScope({
  required String? activeTabId,
  required String? activeGameId,
  required BoardTabGameArgs? boardArgs,
  required PgnImport? latestPgnImport,
}) {
  final tabId = _nonBlank(activeTabId) ?? 'board-default';
  final args = boardArgs;
  if (args != null) {
    final gameScope =
        _nonBlank(args.gameId) ??
        _nonBlank(args.gameListSelectedId) ??
        _nonBlank(args.sourceGame?.gameId) ??
        _nonBlank(args.label) ??
        'pgn:${args.pgn.trim().hashCode}';
    final initialFenScope =
        _nullableFenPositionKey(args.initialFen) ??
        (args.gameId == null ? _nullableFenPositionKey(args.fenSeed) : null) ??
        '';
    return 'tab:$tabId:$gameScope:$initialFenScope';
  }

  final import = latestPgnImport;
  if (import != null && import.pgn.trim().isNotEmpty) {
    final importScope =
        _nonBlank(import.gameId) ??
        _nonBlank(import.path) ??
        'pgn:${import.pgn.trim().hashCode}';
    return 'import:$tabId:$importScope';
  }

  return 'scratch:$tabId:${_nonBlank(activeGameId) ?? ''}';
}

String _boardHydrationState({
  required String? activeGameId,
  required BoardTabGameArgs? boardArgs,
  required PgnImport? latestPgnImport,
  required String? lastAppliedGameId,
  required String? lastAppliedPgn,
}) {
  final args = boardArgs;
  final argsGameId = _nonBlank(args?.gameId);
  if (argsGameId != null) {
    return lastAppliedGameId == argsGameId && _nonBlank(lastAppliedPgn) != null
        ? 'loaded'
        : _pendingHydrationKey(lastAppliedGameId, lastAppliedPgn);
  }

  final argsPgn = args?.pgn.trim();
  if (argsPgn != null && argsPgn.isNotEmpty) {
    return lastAppliedPgn?.trim() == argsPgn
        ? 'loaded'
        : _pendingHydrationKey(null, lastAppliedPgn);
  }

  final import = latestPgnImport;
  final importGameId = _nonBlank(import?.gameId);
  if (importGameId != null || _nonBlank(activeGameId) != null) {
    final gameId = importGameId ?? _nonBlank(activeGameId)!;
    return lastAppliedGameId == gameId && _nonBlank(lastAppliedPgn) != null
        ? 'loaded'
        : _pendingHydrationKey(lastAppliedGameId, lastAppliedPgn);
  }

  final importPgn = import?.pgn.trim();
  if (importPgn != null && importPgn.isNotEmpty) {
    return lastAppliedPgn?.trim() == importPgn
        ? 'loaded'
        : _pendingHydrationKey(null, lastAppliedPgn);
  }

  return 'static';
}

String _pendingHydrationKey(String? lastAppliedGameId, String? lastAppliedPgn) {
  final appliedGame = _nonBlank(lastAppliedGameId) ?? 'none';
  final appliedPgn = _nonBlank(lastAppliedPgn);
  return appliedPgn == null
      ? 'pending:$appliedGame:empty'
      : 'pending:$appliedGame:${appliedPgn.hashCode}';
}

String? _nonBlank(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

ChessMovePointer? _pointerForInitialFen(ChessGame game, String? initialFen) {
  final targetKey = _nullableFenPositionKey(initialFen);
  if (targetKey == null) return null;
  if (_fenPositionKey(game.startingFen) == targetKey) return const <int>[];

  for (var i = 0; i < game.mainline.length; i++) {
    if (_fenPositionKey(game.mainline[i].fen) == targetKey) return <int>[i];
  }
  return null;
}

/// Best-effort parse of the live clock string into seconds for inheriting
/// onto a "Play from here" session. Accepts `h:mm:ss`, `m:ss`, or seconds.
int? _baseSecondsFromClock(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final cleaned = raw.replaceAll(RegExp(r'[^0-9:]'), '');
  if (cleaned.isEmpty) return null;
  final parts = cleaned.split(':');
  try {
    if (parts.length == 1) return int.parse(parts.first);
    if (parts.length == 2) {
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    }
    if (parts.length == 3) {
      return int.parse(parts[0]) * 3600 +
          int.parse(parts[1]) * 60 +
          int.parse(parts[2]);
    }
  } catch (_) {
    return null;
  }
  return null;
}

/// Extract Fischer increment from the PGN `TimeControl` header (e.g.
/// `300+5` → 5, `40/7200:1800+30` → 30). Returns null if no `+` segment.
int? _incrementFromHeaders(Map<String, String> headers) {
  final tc = headers['TimeControl'];
  if (tc == null || tc.isEmpty) return null;
  final idx = tc.lastIndexOf('+');
  if (idx == -1 || idx == tc.length - 1) return null;
  final inc = int.tryParse(tc.substring(idx + 1));
  return inc;
}
