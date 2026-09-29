import 'package:chessever/desktop/services/local_pgn_source.dart';
import 'dart:async';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'dart:convert';
import 'dart:io' as io;

import 'package:chessground/chessground.dart' show PieceAssets;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:chessever/desktop/services/desktop_board_window_service.dart';
import 'package:chessever/desktop/services/local_chess_database_open_guard.dart';
import 'package:chessever/desktop/widgets/desktop_header_action_button.dart';
import 'package:chessever/desktop/widgets/desktop_toast.dart';
import 'package:chessever/desktop/services/gamebase_position_games_loader.dart';

import 'package:chessever/desktop/services/player_opening_tree_builder.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/desktop/widgets/adaptive_games_table.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_context_menu.dart';
import 'package:chessever/desktop/widgets/move_hover_preview.dart';
import 'package:chessever/desktop/widgets/table_display_value.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/chessboard/analysis/chess_game.dart';
import 'package:chessever/screens/gamebase/providers/explorer_games_cache.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_explorer_state.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/library/utils/gamebase_pgn_builder.dart';
import 'package:chessever/screens/player_profile/utils/twic_event_identity.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/figurine_notation.dart';
import 'package:chessever/widgets/federation_flag.dart';

typedef PreviewUciLineCallback =
    void Function(List<String> ucis, {bool autoplay, int? step});
typedef ContinuationStepTapCallback = void Function(int rowIndex, int step);

/// External control surface for [DesktopPositionGamesTable] when a host
/// widget owns navigation that touches the table's rows — for example the
/// combined moves+games explorer view that wants keyboard arrows to walk
/// down from the moves into the games and Enter to open the selection.
///
/// The controller mirrors a tiny slice of the table's state (row count,
/// selected row id) plus an `openSelected` action. Keep the surface
/// minimal so the table stays the owner of its rows + pagination.
class DesktopPositionGamesTableController extends ChangeNotifier {
  _DesktopPositionGamesTableState? _state;
  int _rowCount = 0;
  List<String> _rowIds = const <String>[];
  List<List<String>> _rowContinuations = const <List<String>>[];
  List<String?> _rowSourceLabels = const <String?>[];
  String? _selectedRowId;

  void _attach(_DesktopPositionGamesTableState state) {
    _state = state;
  }

  void _detach(_DesktopPositionGamesTableState state) {
    if (_state == state) _state = null;
  }

  void _setRows(
    List<String> ids,
    List<List<String>> continuations,
    List<String?> sourceLabels,
  ) {
    final selectionStillPresent =
        _selectedRowId == null || ids.contains(_selectedRowId);
    if (ids.length == _rowCount &&
        _listEq(ids, _rowIds) &&
        _nestedListEq(continuations, _rowContinuations) &&
        _optionalListEq(sourceLabels, _rowSourceLabels) &&
        selectionStillPresent) {
      return;
    }
    _rowIds = List<String>.unmodifiable(ids);
    _rowContinuations = List<List<String>>.unmodifiable(
      continuations.map((c) => List<String>.unmodifiable(c)),
    );
    _rowSourceLabels = List<String?>.unmodifiable(sourceLabels);
    _rowCount = ids.length;
    if (!selectionStillPresent) _selectedRowId = null;
    notifyListeners();
  }

  static bool _listEq(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _nestedListEq(List<List<String>> a, List<List<String>> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_listEq(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _optionalListEq(List<String?> a, List<String?> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int get rowCount => _rowCount;

  /// Stable row id at [index]. Returns null when the index is out of range
  /// (the host's keyboard cursor lazily expands as pagination loads more
  /// rows; mis-targets should no-op rather than crash).
  String? rowIdAt(int index) {
    if (index < 0 || index >= _rowIds.length) return null;
    return _rowIds[index];
  }

  String? get selectedRowId => _selectedRowId;

  List<String> continuationAt(int index) {
    if (index < 0 || index >= _rowContinuations.length) {
      return const <String>[];
    }
    return _rowContinuations[index];
  }

  String? sourceLabelAt(int index) {
    if (index < 0 || index >= _rowSourceLabels.length) return null;
    return _rowSourceLabels[index];
  }

  /// Highlight a specific row by id. Pass `null` to clear. Triggers a
  /// repaint of the table so the selection band shows. Keyboard callers keep
  /// [reveal] enabled so off-screen selections scroll into view; pointer hover
  /// disables it because hovering a scrollable table must not move the table.
  void select(
    String? id, {
    bool preview = false,
    bool autoplay = true,
    int? step,
    bool reveal = true,
    bool clearPreview = true,
  }) {
    final changed = _selectedRowId != id;
    _selectedRowId = id;
    if (id == null) {
      if (clearPreview) _state?._clearPreview();
    } else {
      if (reveal && changed) {
        _state?._ensureSelectedVisible(id);
      }
      if (preview) {
        _state?._previewRowById(id, autoplay: autoplay, step: step);
      }
    }
    if (changed) notifyListeners();
  }

  /// Preview/autoplay the selected row without changing row selection.
  void previewSelected({bool autoplay = true, int? step}) {
    final id = _selectedRowId;
    if (id == null) return;
    _state?._previewRowById(id, autoplay: autoplay, step: step);
  }

  /// Open the currently selected row in a board tab. When
  /// [continuationStep] is supplied, the new board tab seeks to the
  /// position after that inline continuation ply.
  ///
  /// No-op when nothing is selected or the table is detached.
  void openSelected({bool focus = true, int? continuationStep}) {
    final id = _selectedRowId;
    if (id == null) return;
    _state?._openRowById(id, focus: focus, continuationStep: continuationStep);
  }
}

/// Compact table of indexed games at the explorer's current FEN. Lives in
/// the right rail of the OpeningExplorerPane — directly below the filters —
/// so the moves table and the position-search endpoint results update
/// side-by-side as the user navigates the line on the board.
///
/// Wires:
///  - row tap → opens the full game in a Board tab via [openBoardGameTab]
class DesktopPositionGamesTable extends ConsumerStatefulWidget {
  const DesktopPositionGamesTable({
    super.key,
    required this.fen,
    this.moves = const <String>[],
    this.uci,
    this.exactFenSearch = false,
    this.useFixedRowAlignment = false,
    this.externalScrollController,
    this.controller,
    this.referenceLayout = false,
    this.onFocusRowIndex,
    this.onPreviewContinuation,
    this.onActivateContinuationStep,
    this.activeContinuationStep,
    this.activeContinuationAutoplay = false,
    this.active = true,
    this.waitForPlayerOpeningTree = false,
    this.playerOpeningTreePlayerId,
    this.localOpeningTreeIndex,
    this.localOpeningTreeTitle = '',
    this.positionAutoplaying = false,
  });

  /// Optional bridge for host-driven keyboard navigation. The host calls
  /// `select` / `openSelected` to drive selection + activation without
  /// reaching into table state.
  final DesktopPositionGamesTableController? controller;

  /// Mirrors pointer selection into the host-owned keyboard/focus cursor.
  final void Function(int index)? onFocusRowIndex;

  /// Called when a row becomes selected/focused so the board can preview
  /// that game's continuation from the current position.
  final PreviewUciLineCallback? onPreviewContinuation;

  /// Called when the user clicks an inline move inside the notation column.
  final ContinuationStepTapCallback? onActivateContinuationStep;

  /// Active ply inside the selected row's one-line continuation. Null means
  /// row selection is outside embedded continuation mode, so no token marker
  /// is shown.
  final int? activeContinuationStep;

  /// Whether the active continuation marker is being driven by autoplay.
  final bool activeContinuationAutoplay;

  /// The board is stepping through its line on a timer (auto-replay), so
  /// positions pass faster than anyone reads their games. The table then
  /// waits [kDesktopPositionGamesAutoplayDwell] before asking the server for
  /// a position it holds nothing for, so a replay sends no request per
  /// passing position. Held pages still paint at once, and when the replay
  /// stops the position it stopped on is asked for after the usual dwell.
  final bool positionAutoplaying;

  /// Whether this table is currently visible/interactive. Hidden right-rail
  /// pages keep their table mounted so keyboard selection state is preserved,
  /// but pagination and query refresh work should pause until the page is
  /// foregrounded again.
  final bool active;

  /// True only for player-profile Build Tree scopes. When set, the table waits
  /// for the backend tree snapshot before using the normal position-games API.
  final bool waitForPlayerOpeningTree;

  /// Player id for the Build Tree scope. Supplying this prevents the first
  /// frame from fetching unscoped games before global explorer filters apply.
  final String? playerOpeningTreePlayerId;

  /// Local PGN database tree for board tabs opened from an imported database.
  /// When present, pages and sorts are served directly from this index.
  final PlayerOpeningTreeIndex? localOpeningTreeIndex;
  final String localOpeningTreeTitle;

  /// reference-style compact position-reference density for the in-game
  /// Explorer split. The column schema stays shared with the standalone
  /// Games tab; this only tightens player cells and row metrics.
  final bool referenceLayout;

  /// When `true`, the games table renders without its own vertical scroll
  /// view — the host scroll view owns scrolling. Used by the combined
  /// moves+games explorer view so a single scrollbar covers both lists.
  final bool useFixedRowAlignment;

  /// Optional caller-owned scroll controller. When supplied, the table
  /// attaches its scroll-near-bottom pagination listener to it instead of
  /// the internal controller. Required (alongside `useFixedRowAlignment`)
  /// when the host owns vertical scrolling.
  final ScrollController? externalScrollController;

  final String fen;
  final List<String> moves;
  final bool exactFenSearch;

  /// When set, restrict the listing to games where this UCI move was the
  /// next move played from [fen]. Set by the explorer pane when the user
  /// clicks a per-move "Games" pill on the moves table; null lists all
  /// games at the position.
  final String? uci;

  @override
  ConsumerState<DesktopPositionGamesTable> createState() =>
      _DesktopPositionGamesTableState();
}

/// How long a new position must stay on the board before a games table that
/// holds nothing for it asks the server. Stepping through a line a few moves
/// a second never waits this long, so it sends no request per passing
/// position; stopping to read asks at once. A page the explorer already holds
/// (a warm-up, a revisit, a saved copy) paints the moment the position lands,
/// whatever this is, and a request already on the wire is attached to at once.
const Duration kDesktopPositionGamesNetworkDwell = Duration(milliseconds: 450);

/// [kDesktopPositionGamesNetworkDwell] while the board auto-replays its line
/// ([DesktopPositionGamesTable.positionAutoplaying]): longer than a replay
/// step, so no passing position is asked for.
const Duration kDesktopPositionGamesAutoplayDwell = Duration(seconds: 2);

class _DesktopPositionGamesTableState
    extends ConsumerState<DesktopPositionGamesTable> {
  static const double _scrollPrefetchExtent = 360;

  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  final Map<String, List<String>> _fullContinuationCache =
      <String, List<String>>{};
  final Set<String> _loadingFullContinuations = <String>{};
  Timer? _localTreeRefreshDebounce;
  Timer? _resetFetchDebounce;
  Timer? _errorRetryTimer;
  int _errorRetryAttempts = 0;
  String? _lastPreviewedRowId;
  bool _lastPreviewAutoplay = true;
  int? _lastPreviewStep;
  bool _isInitialLoading = true;

  /// The last fetch was refused by access. The table renders a locked
  /// surface instead of an empty result or an error.
  bool _queryLocked = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _nextPageNumber = 0;
  int _requestToken = 0;
  String? _lastTappedRowId;
  DateTime? _lastTapAt;
  int _insertRequestId = 0;
  int? _totalCount;
  BoardTabPositionGamesApi? _resolvedApi;
  GamebasePositionGamesQuery? _lastSuccessfulQuery;
  String? _lastSuccessfulSourceKey;
  String? _error;
  bool _errorRetryable = false;

  /// The last failure came from the global database (not a local file), so
  /// the error surface offers a Retry.
  bool _errorFromNetwork = false;

  /// Whether the rows on screen were listed in exact-position mode.
  bool _rowsExactFenSearch = false;
  String? _waitingForTreeMessage;
  bool _needsRefresh = false;

  /// Page 0 on screen is a saved copy (read back from disk, or held longer
  /// than [kExplorerGamesFreshFor]) being checked against the server: the
  /// moment it was asked for. Null while page 0 is a current answer. A saved
  /// copy is never final: paging waits for the check, and a failed check
  /// says so above the rows.
  DateTime? _savedAt;

  /// The check of the saved copy on screen failed.
  bool _refreshFailed = false;

  /// When the page 0 on screen was asked for. A later page asked for before
  /// it is asked for again rather than appended, so its offsets match.
  DateTime? _firstPageFetchedAt;

  /// The reader reached the end of the rows while paging waited for a saved
  /// copy's check; paging picks up as soon as page 0 is current.
  bool _pagingDeferred = false;

  /// Bumped whenever page 0 of the table's inputs settles from something
  /// newer than the disk: an answer (fetched or held, empty or not), a
  /// failure, a lock, a wait. A disk read started before then lands too late
  /// to be shown as the page being checked: nothing is checking it any more.
  int _firstPageSettles = 0;

  /// Page 0 of this query failed from the global database with nothing of it
  /// on screen. A saved copy the disk finds for it afterwards is shown as it
  /// would have been had the disk answered first: marked as not refreshed,
  /// with its Retry.
  GamebasePositionGamesQuery? _failedFirstPage;

  /// Time from a position landing to its rows painting, for the paint
  /// breadcrumb ([recordExplorerGamesPaint]).
  final Stopwatch _paintWatch = Stopwatch();
  bool _paintRecorded = true;

  /// Local sort override. Click on a sortable column header sets this and
  /// triggers a reset+refetch. Cleared (back to filter default) when the
  /// caller cycles past `asc`. Kept local to the table so sorting in one
  /// rail doesn't leak into other places reading the same explorer state.
  AdaptiveSortState? _sortOverride;

  ScrollController get _activeScrollController =>
      widget.externalScrollController ?? _scroll;

  @override
  void initState() {
    super.initState();
    _activeScrollController.addListener(_onScroll);
    widget.controller?._attach(this);
    if (widget.active) {
      _fetchPage(reset: true);
    } else {
      _needsRefresh = true;
      _isInitialLoading = false;
    }
  }

  @override
  void didUpdateWidget(covariant DesktopPositionGamesTable old) {
    super.didUpdateWidget(old);
    final fenChanged = _positionKey(old.fen) != _positionKey(widget.fen);
    final movesChanged = !listEquals(old.moves, widget.moves);
    final uciChanged = (old.uci ?? '').trim() != (widget.uci ?? '').trim();
    final modeChanged = old.exactFenSearch != widget.exactFenSearch;
    final localTreeChanged =
        old.localOpeningTreeIndex != widget.localOpeningTreeIndex ||
        old.localOpeningTreeTitle != widget.localOpeningTreeTitle;
    final activeChanged = old.active != widget.active;
    final scrollChanged =
        old.externalScrollController != widget.externalScrollController;
    if (scrollChanged) {
      old.externalScrollController?.removeListener(_onScroll);
      if (widget.externalScrollController != null) {
        _scroll.removeListener(_onScroll);
        widget.externalScrollController!.addListener(_onScroll);
      } else {
        _scroll.addListener(_onScroll);
      }
    }
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
      final rowIds = _rowIdsSnapshot();
      _pruneRowKeys(rowIds);
      widget.controller?._setRows(
        rowIds,
        _rowContinuationsSnapshot(),
        _rowSourceLabelsSnapshot(),
      );
    }
    if (fenChanged ||
        movesChanged ||
        uciChanged ||
        modeChanged ||
        localTreeChanged) {
      // A move filter picked on this position (the list icon), or a switch
      // between the move-line and exact-position search, is a deliberate
      // pick: asked at once. Navigation waits out the dwell below.
      final deliberate =
          !fenChanged &&
          !movesChanged &&
          !localTreeChanged &&
          !(_resetFetchDebounce?.isActive ?? false);
      _cancelPendingResetFetch(invalidate: true);
      if (!widget.active) {
        _needsRefresh = true;
        _isInitialLoading = false;
        _fullContinuationCache.clear();
        _loadingFullContinuations.clear();
        return;
      }
      if (localTreeChanged) {
        _clearRowsForPendingReset();
        _scheduleResetFetch(delay: Duration.zero);
        return;
      }
      _showPositionChange(deliberate: deliberate);
      return;
    }
    if (activeChanged && widget.active) {
      if (_needsRefresh || !_hasLoadedCurrentQuery()) {
        _needsRefresh = false;
        // Brought on screen: whatever is held paints now, anything else is
        // asked for at once.
        _showPositionChange(deliberate: true);
        return;
      }
    }
    if (old.positionAutoplaying &&
        !widget.positionAutoplaying &&
        (_resetFetchDebounce?.isActive ?? false)) {
      // The replay stopped on a position still waiting out the replay's
      // longer dwell: it is now read like any other.
      _scheduleResetFetch();
    }
  }

  @override
  void dispose() {
    _localTreeRefreshDebounce?.cancel();
    _resetFetchDebounce?.cancel();
    _errorRetryTimer?.cancel();
    widget.controller?._detach(this);
    widget.externalScrollController?.removeListener(_onScroll);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Same key the explorer cache uses — first 4 FEN fields (board,
  /// side-to-move, castling, en-passant). Drops the half-move + full-move
  /// counters so a position from move 30 matches the same position from
  /// move 31.
  String _positionKey(String fen) =>
      fen.trim().split(RegExp(r'\s+')).take(4).join(' ');

  void _onScroll() {
    if (!widget.active) return;
    if (_isLoadingMore || !_hasMore || _rows.isEmpty) return;
    final controller = _activeScrollController;
    if (!controller.hasClients) return;
    final pos = controller.position;
    if (pos.pixels < pos.maxScrollExtent - _scrollPrefetchExtent) return;
    // A later page is only ever stacked on a current page 0: never on the
    // previous position's rows, a page 0 still loading, or a saved copy
    // being checked (its offsets may have moved). Resumed by
    // [_resumeDeferredPaging] once page 0 is current.
    if ((_resetFetchDebounce?.isActive ?? false) ||
        _isInitialLoading ||
        _savedAt != null) {
      _pagingDeferred = true;
      return;
    }
    _fetchPage(reset: false);
  }

  /// Page 0 just became current. If the reader got to the end of the rows
  /// while it was loading or being checked, load the next page now rather
  /// than waiting for another scroll that may never come.
  void _resumeDeferredPaging() {
    if (!_pagingDeferred) return;
    _pagingDeferred = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onScroll();
    });
  }

  /// Whether the rows on screen came from the global database (the path the
  /// explorer games cache and its warm-ups cover) for the table's inputs.
  bool get _usesGlobalDatabase =>
      widget.active &&
      !widget.waitForPlayerOpeningTree &&
      _positionQueryAllowed &&
      desktopPositionGamesUseNetwork(
        ref,
        _buildQuery(pageNumber: 0),
        localOpeningTreeIndex: widget.localOpeningTreeIndex,
      );

  /// Whether the rows on screen answer [query] (page 0) from the current
  /// source, whether as a current answer or a saved copy being checked.
  bool _rowsAnswer(GamebasePositionGamesQuery query) {
    final last = _lastSuccessfulQuery;
    if (last == null || _rows.isEmpty) return false;
    return _lastSuccessfulSourceKey == _sourceKey &&
        _rowsExactFenSearch == widget.exactFenSearch &&
        last.withPage(0) == query;
  }

  void _startPaintWatch() {
    _paintWatch
      ..reset()
      ..start();
    _paintRecorded = false;
  }

  void _recordPaint(ExplorerGamesSource source) {
    if (_paintRecorded) return;
    _paintRecorded = true;
    _paintWatch.stop();
    recordExplorerGamesPaint(
      surface: 'desktop games table',
      source: source,
      elapsed: _paintWatch.elapsed,
    );
  }

  /// The table's inputs moved to a new position (or move filter). What the
  /// explorer already holds for it paints in this frame: a current answer as
  /// final, a saved copy marked as being checked. With nothing held the rows
  /// on screen are marked as not current (they answer the previous inputs)
  /// and the disk is read while the server is asked: at once when
  /// [deliberate] or when that request is already on the wire, otherwise
  /// once the reader stops for [kDesktopPositionGamesNetworkDwell].
  void _showPositionChange({required bool deliberate}) {
    _startPaintWatch();
    _pagingDeferred = false;
    final painted = _paintHeldFirstPage();
    if (painted == _HeldPaint.current) return;
    final global = _usesGlobalDatabase;
    final query = _buildQuery(pageNumber: 0);
    if (painted == _HeldPaint.none) {
      _markRowsNotCurrent();
      if (global) _readSavedFirstPage(query);
    }
    final attachNow =
        deliberate ||
        (global &&
            isDesktopPositionGamesFirstPageInFlight(
              ref,
              query,
              exactFenSearch: widget.exactFenSearch,
            ));
    _scheduleResetFetch(delay: attachNow ? Duration.zero : null);
  }

  /// Paints the first page the explorer holds for the table's inputs, if any.
  _HeldPaint _paintHeldFirstPage() {
    if (!mounted || !_usesGlobalDatabase) return _HeldPaint.none;
    final query = _buildQuery(pageNumber: 0);
    final held = peekDesktopPositionGamesFirstPage(
      ref,
      query,
      exactFenSearch: widget.exactFenSearch,
    );
    if (held == null) return _HeldPaint.none;
    // An empty saved copy would flash "No Games Found" before the answer.
    if (!held.current && held.response.data.isEmpty) return _HeldPaint.none;
    _installFirstPage(query, held);
    return held.current ? _HeldPaint.current : _HeldPaint.saved;
  }

  /// Reads the disk's saved page 0 for [query] and paints it, unless the
  /// table has moved on or page 0 has settled by then.
  ///
  /// The disk usually answers well before the server, but not always (a
  /// fast failure, a disk queue busy saving pages). A copy that lands after
  /// the server answered is dropped, even when that answer is empty, and one
  /// that lands after the server failed is shown as not refreshed with its
  /// Retry, never as a copy still being checked.
  void _readSavedFirstPage(GamebasePositionGamesQuery query) {
    final exactFenSearch = widget.exactFenSearch;
    final settles = _firstPageSettles;
    unawaited(
      readDesktopPositionGamesSavedFirstPage(
        ref,
        query,
        exactFenSearch: exactFenSearch,
      ).then((held) {
        if (held == null || !mounted || !widget.active) return;
        if (!held.current && held.response.data.isEmpty) return;
        if (widget.exactFenSearch != exactFenSearch) return;
        if (_buildQuery(pageNumber: 0) != query || _rowsAnswer(query)) return;
        if (_queryLocked || _waitingForTreeMessage != null) return;
        if (_firstPageSettles != settles) {
          if (_failedFirstPage == query && _error != null && _rows.isEmpty) {
            _installFirstPage(query, held, refreshFailed: !held.current);
          }
          return;
        }
        _installFirstPage(query, held);
      }, onError: (Object _) {}),
    );
  }

  /// Page 0 of the table's inputs settled (see [_firstPageSettles]).
  void _firstPageSettled({GamebasePositionGamesQuery? failed}) {
    _firstPageSettles += 1;
    _failedFirstPage = failed;
  }

  /// Rows on screen answer earlier inputs: shown under the progress line
  /// (or as a spinner when there are none) until the answer lands.
  void _markRowsNotCurrent() {
    if (_isInitialLoading && !_refreshFailed) return;
    setState(() {
      _isInitialLoading = true;
      _refreshFailed = false;
    });
  }

  /// Installs a held page 0 for [query] exactly as a fetched one would be.
  ///
  /// [refreshFailed]: the server already failed to answer [query], so the
  /// copy goes up marked as not refreshed and the failure (and its Retry)
  /// stays.
  void _installFirstPage(
    GamebasePositionGamesQuery query,
    DesktopHeldPositionGamesPage held, {
    bool refreshFailed = false,
  }) {
    if (held.current) {
      _firstPageSettled();
    } else {
      _failedFirstPage = null;
    }
    final rows = <Map<String, dynamic>>[];
    final ids = <String>{};
    for (final row in held.response.data) {
      final id = row['id']?.toString().trim() ?? '';
      if (id.isNotEmpty && !ids.add(id)) continue;
      rows.add(row);
    }
    if (!_rowsAnswer(query)) {
      _fullContinuationCache.clear();
      _loadingFullContinuations.clear();
    }
    setState(() {
      _rows
        ..clear()
        ..addAll(rows);
      _hasMore = held.response.metadata.hasMore && rows.isNotEmpty;
      _nextPageNumber = 1;
      _totalCount = held.response.metadata.totalCount;
      _resolvedApi = held.resolvedApi;
      _lastSuccessfulQuery = query;
      _lastSuccessfulSourceKey = _sourceKey;
      _rowsExactFenSearch = widget.exactFenSearch;
      _isInitialLoading = false;
      _isLoadingMore = false;
      if (!refreshFailed) {
        _error = null;
        _errorRetryable = false;
        _errorFromNetwork = false;
      }
      _waitingForTreeMessage = null;
      _queryLocked = false;
      _savedAt = held.current ? null : held.fetchedAt;
      _refreshFailed = refreshFailed && !held.current;
      _firstPageFetchedAt = held.fetchedAt;
    });
    _errorRetryAttempts = 0;
    final rowIds = _rowIdsSnapshot();
    _pruneRowKeys(rowIds);
    widget.controller?._setRows(
      rowIds,
      _rowContinuationsSnapshot(),
      _rowSourceLabelsSnapshot(),
    );
    _recordPaint(held.current ? ExplorerGamesSource.memory : held.source);
    if (held.current) _resumeDeferredPaging();
  }

  void _cancelPendingResetFetch({bool invalidate = false}) {
    _resetFetchDebounce?.cancel();
    _resetFetchDebounce = null;
    if (invalidate) _requestToken += 1;
  }

  void _clearRowsForPendingReset() {
    _firstPageSettled();
    _fullContinuationCache.clear();
    _loadingFullContinuations.clear();
    _lastSuccessfulSourceKey = null;
    _lastPreviewedRowId = null;
    setState(() {
      _rows.clear();
      _isInitialLoading = true;
      _isLoadingMore = false;
      _hasMore = true;
      _nextPageNumber = 0;
      _totalCount = null;
      _resolvedApi = null;
      _lastSuccessfulQuery = null;
      _error = null;
      _errorRetryable = false;
      _errorFromNetwork = false;
      _waitingForTreeMessage = null;
      _savedAt = null;
      _refreshFailed = false;
      _firstPageFetchedAt = null;
    });
    _pruneRowKeys(const <String>[]);
    widget.controller?._setRows(
      const <String>[],
      const <List<String>>[],
      const <String?>[],
    );
  }

  void _scheduleResetFetch({Duration? delay}) {
    _cancelPendingResetFetch();
    _resetFetchDebounce = Timer(delay ?? _resetFetchDebounceDuration, () {
      _resetFetchDebounce = null;
      if (!mounted || !widget.active) {
        _needsRefresh = true;
        return;
      }
      _fetchPage(reset: true);
    });
  }

  Duration get _resetFetchDebounceDuration {
    if (widget.localOpeningTreeIndex != null) {
      return const Duration(milliseconds: 120);
    }
    return widget.positionAutoplaying
        ? kDesktopPositionGamesAutoplayDwell
        : kDesktopPositionGamesNetworkDwell;
  }

  /// The request listing games at this position makes. A local file's tree
  /// is opening-tree exploration; the ChessEver database is explorer depth,
  /// player scope and exact-position search.
  DesktopAccessContext get _positionQueryContext {
    final localTree = widget.localOpeningTreeIndex;
    if (localTree != null && widget.playerOpeningTreePlayerId == null) {
      return const DesktopAccessContext(
        feature: DesktopFeature.openingTree,
        action: DesktopAction.previewNavigate,
        origin: DesktopDiscoveryOrigin.localFile,
      );
    }
    return DesktopAccessContext(
      feature: DesktopFeature.openingExplorer,
      action: widget.exactFenSearch
          ? DesktopAction.acquireSource
          : DesktopAction.previewNavigate,
      origin: DesktopDiscoveryOrigin.gamebase,
      playedPlies: widget.moves.length,
      playerScoped:
          widget.playerOpeningTreePlayerId != null ||
          ref.read(gamebaseExplorerProvider).filters.playerIds.isNotEmpty,
    );
  }

  bool get _positionQueryAllowed =>
      readDesktopAccess(ref.read, _positionQueryContext).isAllowed;

  /// Rows from a ChessEver database position carry gamebase provenance.
  DesktopAccessContext get _rowAccessContext =>
      widget.localOpeningTreeIndex != null &&
          widget.playerOpeningTreePlayerId == null
      ? const DesktopAccessContext(
          feature: DesktopFeature.localFiles,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.localFile,
        )
      : const DesktopAccessContext(
          feature: DesktopFeature.gamebase,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.gamebase,
        );

  Future<void> _fetchPage({
    required bool reset,
    bool preserveRows = false,
    bool fromAutoRetry = false,
  }) async {
    if (!fromAutoRetry) {
      // A user-driven or event-driven fetch replaces any recovery in flight.
      _cancelErrorAutoRetry();
    }
    if (!mounted) return;
    // Denied => no request, no rows from a previous (free) position.
    if (!_positionQueryAllowed) {
      _requestToken += 1;
      _cancelPendingResetFetch();
      _firstPageSettled();
      setState(() {
        _rows.clear();
        _isInitialLoading = false;
        _isLoadingMore = false;
        _hasMore = false;
        _totalCount = null;
        _error = null;
        _queryLocked = true;
        _savedAt = null;
        _refreshFailed = false;
      });
      return;
    }
    if (_queryLocked) setState(() => _queryLocked = false);
    if (!widget.active) {
      _needsRefresh = true;
      return;
    }
    _needsRefresh = false;
    if (reset) _cancelPendingResetFetch();
    final treeWaitMessage = _playerTreeWaitMessage();
    if (treeWaitMessage != null) {
      _requestToken += 1;
      _firstPageSettled();
      _fullContinuationCache.clear();
      _loadingFullContinuations.clear();
      setState(() {
        _rows.clear();
        _isInitialLoading = false;
        _isLoadingMore = false;
        _hasMore = false;
        _nextPageNumber = 0;
        _totalCount = null;
        _resolvedApi = null;
        _lastSuccessfulQuery = null;
        _error = null;
        _waitingForTreeMessage = treeWaitMessage;
        _savedAt = null;
        _refreshFailed = false;
        _firstPageFetchedAt = null;
      });
      _pruneRowKeys(const <String>[]);
      widget.controller?._setRows(
        const <String>[],
        const <List<String>>[],
        const <String?>[],
      );
      return;
    }
    final pageNumber = reset ? 0 : _nextPageNumber;
    final global = _usesGlobalDatabase;
    if (reset) {
      _requestToken += 1;
      _pagingDeferred = false;
      if (_paintRecorded) _startPaintWatch();
      // A page the explorer holds paints first: a current answer is final
      // (no request), a saved copy stays up, marked, while it is checked.
      final painted = preserveRows ? _HeldPaint.none : _paintHeldFirstPage();
      if (painted == _HeldPaint.current) return;
      if (painted == _HeldPaint.none) {
        _fullContinuationCache.clear();
        _loadingFullContinuations.clear();
      }
      final hadRows = _rows.isNotEmpty;
      final keepRows = preserveRows && hadRows;
      // The pagination fields keep describing the rows on screen until the
      // new page 0 replaces them.
      setState(() {
        _isInitialLoading = !keepRows;
        _isLoadingMore = false;
        _error = null;
        _errorFromNetwork = false;
        _refreshFailed = false;
        _waitingForTreeMessage = null;
      });
      if (!hadRows) {
        _pruneRowKeys(const <String>[]);
        widget.controller?._setRows(
          const <String>[],
          const <List<String>>[],
          const <String?>[],
        );
      }
      if (painted == _HeldPaint.none && global && !preserveRows) {
        // The disk usually answers well before the server.
        _readSavedFirstPage(_buildQuery(pageNumber: 0));
      }
    } else {
      setState(() => _isLoadingMore = true);
    }
    final requestToken = _requestToken;
    final stopwatch = Stopwatch()..start();

    try {
      final query = _buildQuery(pageNumber: pageNumber);
      if (kDebugMode) {
        debugPrint(
          '[DesktopPositionGamesTable] fetch start '
          'reset=$reset exactFen=${widget.exactFenSearch} '
          'moves=${query.moves.length} page=$pageNumber '
          'size=${query.pageSize} notationPlies=${query.notationPlies} '
          'sort=${query.sortBy.name}/${query.sortDirection.name}',
        );
      }
      final page = await fetchDesktopPositionGamesPage(
        ref,
        query,
        exactFenSearch: widget.exactFenSearch,
        resolvedApi: reset ? null : _resolvedApi,
        localOpeningTreeIndex: widget.localOpeningTreeIndex,
        notOlderThan: reset ? null : _firstPageFetchedAt,
      );
      final response = page.response;
      if (!mounted || requestToken != _requestToken) return;
      if (reset) _firstPageSettled();

      final merged =
          reset
              ? <Map<String, dynamic>>[]
              : List<Map<String, dynamic>>.from(_rows);
      final existingIds = <String>{
        for (final row in merged)
          if ((row['id']?.toString().trim() ?? '').isNotEmpty)
            row['id'].toString().trim(),
      };
      var added = 0;
      for (final row in response.data) {
        final id = row['id']?.toString().trim() ?? '';
        if (id.isNotEmpty && !existingIds.add(id)) continue;
        merged.add(row);
        added += 1;
      }
      if (reset && !_rowsAnswer(query.withPage(0))) {
        _fullContinuationCache.clear();
        _loadingFullContinuations.clear();
      }

      setState(() {
        _rows
          ..clear()
          ..addAll(merged);
        _hasMore = response.metadata.hasMore && added > 0;
        _nextPageNumber = pageNumber + 1;
        if (reset) {
          _totalCount = response.metadata.totalCount;
          _resolvedApi = page.resolvedApi;
          _rowsExactFenSearch = widget.exactFenSearch;
          _savedAt = null;
          _refreshFailed = false;
          _firstPageFetchedAt =
              global
                  ? ref.read(explorerGamesCacheProvider).fetchedAtOf(response)
                  : null;
        } else {
          _totalCount = response.metadata.totalCount ?? _totalCount;
          _resolvedApi = page.resolvedApi ?? _resolvedApi;
        }
        _lastSuccessfulQuery = query;
        _lastSuccessfulSourceKey = _sourceKey;
        _isInitialLoading = false;
        _isLoadingMore = false;
        _error = null;
        _errorRetryable = false;
        _errorFromNetwork = false;
      });
      _errorRetryAttempts = 0;
      if (kDebugMode) {
        debugPrint(
          '[DesktopPositionGamesTable] fetch done '
          '${stopwatch.elapsedMilliseconds}ms reset=$reset '
          'api=${page.resolvedApi?.name ?? 'default'} '
          'rows=${response.data.length} hasMore=${response.metadata.hasMore}',
        );
      }
      final rowIds = _rowIdsSnapshot();
      _pruneRowKeys(rowIds);
      widget.controller?._setRows(
        rowIds,
        _rowContinuationsSnapshot(),
        _rowSourceLabelsSnapshot(),
      );
      if (reset) {
        _recordPaint(ExplorerGamesSource.network);
        _resumeDeferredPaging();
      }
    } catch (e) {
      if (!mounted || requestToken != _requestToken) return;
      // A localized database open failure is transient by nature (a tree store
      // being published, another writer holding the file): show actionable
      // wording, keep the last good rows on screen, and retry on a bounded
      // backoff so the panel recovers in place instead of dead-ending and
      // making the user leave and re-enter the tab.
      final retryable = isRetryableLocalChessDatabaseFailure(e);
      final query0 = _buildQuery(pageNumber: 0);
      // A saved copy of this very page stays up, marked as not refreshed. Rows
      // listed for an earlier position never stand in for this one's answer.
      final showingSaved = reset && _savedAt != null && _rowsAnswer(query0);
      final staleRows =
          reset && global && _rows.isNotEmpty && !_rowsAnswer(query0);
      if (staleRows) {
        _fullContinuationCache.clear();
        _loadingFullContinuations.clear();
        _lastPreviewedRowId = null;
      }
      setState(() {
        _error = localChessDatabaseUserMessage(e);
        _errorRetryable = retryable;
        _errorFromNetwork = global;
        _isInitialLoading = false;
        _isLoadingMore = false;
        if (showingSaved) _refreshFailed = true;
        if (staleRows) {
          _rows.clear();
          _hasMore = false;
          _nextPageNumber = 0;
          _totalCount = null;
          _resolvedApi = null;
          _lastSuccessfulQuery = null;
          _lastSuccessfulSourceKey = null;
          _savedAt = null;
          _refreshFailed = false;
          _firstPageFetchedAt = null;
        }
      });
      if (staleRows) {
        _pruneRowKeys(const <String>[]);
        widget.controller?._setRows(
          const <String>[],
          const <List<String>>[],
          const <String?>[],
        );
      }
      if (reset) {
        _firstPageSettled(failed: global && _rows.isEmpty ? query0 : null);
      }
      if (retryable) _scheduleErrorAutoRetry();
      if (kDebugMode) {
        debugPrint(
          '[DesktopPositionGamesTable] fetch failed '
          '${stopwatch.elapsedMilliseconds}ms reset=$reset '
          'retryable=$retryable error=$_error cause=$e',
        );
      }
    }
  }

  /// Two bounded retries cover a tree-store publish that is still finishing;
  /// after that the panel keeps the last good rows (or the error surface) and
  /// waits for the user's Retry so a genuinely broken database cannot spin.
  static const int _maxErrorAutoRetries = 2;
  static const List<Duration> _errorAutoRetryDelays = <Duration>[
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];

  void _scheduleErrorAutoRetry() {
    if (!widget.active) return;
    if (_errorRetryAttempts >= _maxErrorAutoRetries) return;
    final delay = _errorAutoRetryDelays[_errorRetryAttempts];
    _errorRetryAttempts += 1;
    _errorRetryTimer?.cancel();
    _errorRetryTimer = Timer(delay, () {
      _errorRetryTimer = null;
      if (!mounted || !widget.active) {
        _needsRefresh = true;
        return;
      }
      _fetchPage(reset: true, fromAutoRetry: true);
    });
  }

  void _cancelErrorAutoRetry() {
    _errorRetryTimer?.cancel();
    _errorRetryTimer = null;
    _errorRetryAttempts = 0;
  }

  void _retryAfterError() {
    _cancelErrorAutoRetry();
    if (!mounted || !widget.active) {
      _needsRefresh = true;
      return;
    }
    _fetchPage(reset: true);
  }

  String? _playerTreeWaitMessage() {
    if (widget.localOpeningTreeIndex != null) return null;
    if (!widget.waitForPlayerOpeningTree) return null;
    final filters = ref.read(gamebaseExplorerProvider).filters;
    final scopedPlayerId = widget.playerOpeningTreePlayerId?.trim();
    final playerId =
        scopedPlayerId != null && scopedPlayerId.isNotEmpty
            ? scopedPlayerId
            : filters.requestPlayerId?.trim() ?? '';
    if (playerId.isEmpty) {
      _logPlayerTreeWait('no player id available for Build Tree wait gate');
      return null;
    }

    final treeState = ref.read(playerOpeningTreeProvider(playerId));
    _schedulePlayerTreeStart(playerId);
    if (filters.requestPlayerId?.trim() != playerId) {
      _logPlayerTreeWait(
        'waiting for scoped filters player=$playerId '
        'filterPlayerIds=${filters.playerIds}',
      );
      return 'Games will load after the player tree scope is ready.';
    }
    if (treeState.progress.status == PlayerOpeningTreeStatus.complete) {
      _logPlayerTreeWait(
        'tree ready, games may fetch player=$playerId '
        'treeId=${treeState.treeId} positions=${treeState.index.positionCount}',
      );
      return null;
    }
    if (treeState.progress.status == PlayerOpeningTreeStatus.error) {
      _logPlayerTreeWait(
        'tree error player=$playerId treeId=${treeState.treeId} '
        'error=${treeState.progress.error}',
      );
      return treeState.progress.error ?? 'Player tree build failed.';
    }
    _logPlayerTreeWait(
      'waiting for tree player=$playerId treeId=${treeState.treeId} '
      'status=${treeState.progress.status.name}',
    );
    return 'Games will load after the player tree is ready.';
  }

  void _schedulePlayerTreeStart(String playerId) {
    Future.microtask(() {
      if (!mounted) return;
      _logPlayerTreeWait('scheduled tree start player=$playerId');
      ref
          .read(gamebaseExplorerProvider.notifier)
          .enableLocalPlayerTree(playerId);
      ref.read(playerOpeningTreeProvider(playerId).notifier).start();
    });
  }

  void _scheduleLocalTreeRefresh() {
    _localTreeRefreshDebounce?.cancel();
    _localTreeRefreshDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || !widget.active) {
        _needsRefresh = true;
        return;
      }
      _fetchPage(reset: true, preserveRows: true);
    });
  }

  void _logPlayerTreeWait(String message) {
    if (kDebugMode) debugPrint('[PlayerOpeningTree][GamesTable] $message');
  }

  GamebasePositionGamesQuery _buildQuery({required int pageNumber}) {
    // Built through the shared factory so every warm-up of this table
    // addresses the exact page (and saved copy) the table reads.
    return GamebasePositionGamesQuery.desktopTablePage(
      fen: widget.fen,
      moves: widget.moves,
      uci: widget.uci,
      filters: ref.read(gamebaseExplorerProvider).filters,
      sortBy: _sortOverride?.field,
      sortDirection: _sortOverride?.direction,
      pageNumber: pageNumber,
    );
  }

  /// The position, move line and move filter the rows on screen were listed
  /// for. They trail the widget while a newer position is on its way (or
  /// failed), and a row opened in that window must open against its own.
  String get _rowsFen => _lastSuccessfulQuery?.fen ?? widget.fen;
  List<String> get _rowsMoves => _lastSuccessfulQuery?.moves ?? widget.moves;
  String? get _rowsUci =>
      _lastSuccessfulQuery == null ? widget.uci : _lastSuccessfulQuery!.uci;

  bool _hasLoadedCurrentQuery() {
    if (_error != null || _savedAt != null) return false;
    return _rowsAnswer(_buildQuery(pageNumber: 0));
  }

  String get _sourceKey {
    final local = widget.localOpeningTreeIndex;
    if (local == null) return 'global';
    final databaseId = local.playerId?.trim() ?? '';
    return 'local:${local.treeId}:$databaseId:${local.persistedPositionCount}:${local.persistedGameCount}';
  }

  List<String> _rowIdsSnapshot() {
    return [
      for (final r in _rows)
        if ((r['id']?.toString().trim() ?? '').isNotEmpty)
          r['id'].toString().trim()
        else
          '',
    ];
  }

  List<List<String>> _rowContinuationsSnapshot() {
    return [
      for (final r in _rows)
        _bestContinuationForRow(r, _readContinuation(r['continuation'])),
    ];
  }

  List<String?> _rowSourceLabelsSnapshot() {
    return [for (final r in _rows) _sourceLabelForRow(r)];
  }

  List<String> _bestContinuationForRow(
    Map<String, dynamic> row,
    List<String> fallback,
  ) {
    final id = (row['id']?.toString().trim() ?? '');
    final cached = id.isEmpty ? null : _fullContinuationCache[id];
    if (cached != null && cached.length > fallback.length) return cached;
    return fallback;
  }

  GlobalKey _rowKeyFor(String id) {
    return _rowKeys.putIfAbsent(
      id,
      () => GlobalKey(debugLabel: 'desktop-position-game-row-$id'),
    );
  }

  void _pruneRowKeys(List<String> ids) {
    final current = ids.where((id) => id.isNotEmpty).toSet();
    _rowKeys.removeWhere((id, _) => !current.contains(id));
  }

  void _openRowById(String id, {required bool focus, int? continuationStep}) {
    final row = _rows.firstWhere(
      (r) => (r['id']?.toString().trim() ?? '') == id,
      orElse: () => const <String, dynamic>{},
    );
    if (row.isEmpty) return;
    unawaited(_openGame(row, focus: focus, continuationStep: continuationStep));
  }

  void _clearPreview() {
    // The table owns row hover and row selection, but clearing the board-side
    // preview is owned by the page that combines this table with the board.
    widget.onPreviewContinuation?.call(const <String>[]);
  }

  void _previewRowById(String id, {bool autoplay = true, int? step}) {
    final row = _rows.firstWhere(
      (r) => (r['id']?.toString().trim() ?? '') == id,
      orElse: () => const <String, dynamic>{},
    );
    if (row.isEmpty) return;
    _previewRow(row, autoplay: autoplay, step: step);
  }

  void _previewRow(
    Map<String, dynamic> row, {
    bool autoplay = true,
    int? step,
  }) {
    final preview = widget.onPreviewContinuation;
    if (preview == null) return;
    // The host plays the line from its own board position. Rows still
    // listed for the previous position (the next one is on its way) would
    // play a continuation that does not start there.
    if (_positionKey(_rowsFen) != _positionKey(widget.fen)) return;
    final id = (row['id']?.toString().trim() ?? '');
    final fallback = _readContinuation(row['continuation']);
    final cached = id.isEmpty ? null : _fullContinuationCache[id];
    final line = cached ?? fallback;
    _lastPreviewedRowId = id.isEmpty ? null : id;
    _lastPreviewAutoplay = autoplay;
    _lastPreviewStep = step;
    preview(line, autoplay: autoplay, step: step);
    if (id.isNotEmpty) {
      _ensureFullContinuationLoaded(id, fallback);
    }
  }

  void _handleRowHover(Map<String, dynamic> row, int index) {
    // Hover is intentionally passive in the in-game right rail. Row focus and
    // previews are driven by click and keyboard selection.
  }

  void _selectRow(Map<String, dynamic> row, int index) {
    widget.onFocusRowIndex?.call(index);
    final id = (row['id']?.toString().trim() ?? '');
    if (id.isNotEmpty && widget.controller != null) {
      widget.controller!.select(id, preview: false, reveal: false);
    }
  }

  void _handleRowTap(Map<String, dynamic> row, {required bool inNewTab}) {
    final id = (row['id']?.toString().trim() ?? '');
    if (inNewTab) {
      unawaited(_openGame(row, focus: false));
      return;
    }
    final now = DateTime.now();
    final doubleClick =
        id.isNotEmpty &&
        id == _lastTappedRowId &&
        _lastTapAt != null &&
        now.difference(_lastTapAt!) <= const Duration(milliseconds: 500);
    _lastTappedRowId = id;
    _lastTapAt = now;
    if (doubleClick) {
      unawaited(_openGame(row, focus: true));
      return;
    }
    _selectRow(row, _rows.indexOf(row));
  }

  Future<void> _showRowContextMenu(
    Map<String, dynamic> row,
    Offset position,
  ) async {
    _selectRow(row, _rows.indexOf(row));
    final action = await showDesktopContextMenu<_PositionGameRowAction>(
      context: context,
      position: position,
      entries: const [
        DesktopContextMenuItem<_PositionGameRowAction>(
          value: _PositionGameRowAction.openInNewTab,
          icon: Icons.open_in_new_rounded,
          label: 'Open game in new tab',
          shortcut: '⌘·Click',
        ),
        DesktopContextMenuItem<_PositionGameRowAction>(
          value: _PositionGameRowAction.openInNewWindow,
          icon: Icons.open_in_browser_rounded,
          label: 'Open game in new window',
        ),
        DesktopContextMenuItem<_PositionGameRowAction>(
          value: _PositionGameRowAction.insertGame,
          icon: Icons.call_merge_rounded,
          label: 'Insert game',
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _PositionGameRowAction.openInNewTab:
        unawaited(_openGame(row, focus: false));
      case _PositionGameRowAction.openInNewWindow:
        unawaited(_openGame(row, inNewWindow: true));
      case _PositionGameRowAction.insertGame:
        await _insertGame(row);
    }
  }

  Future<void> _insertGame(Map<String, dynamic> row) async {
    final id = (row['id']?.toString().trim() ?? '');
    if (id.isEmpty) return;
    // Inserting moves from a database game reaches back to its source.
    if (!admitDesktopAction(
      ProviderScope.containerOf(context, listen: false),
      _rowAccessContext.copyWith(action: DesktopAction.insertMove),
      surface: 'position_games_insert',
    )) {
      return;
    }
    try {
      final openedRow =
          widget.localOpeningTreeIndex == null
              ? row
              : (await compute(
                _hydrateLocalPgnRowsInBackground,
                <Map<String, dynamic>>[Map<String, dynamic>.from(row)],
              )).single;
      if (!mounted) return;
      var pgn = (openedRow['pgn']?.toString() ?? '').trim();
      if (!pgnHasMoves(pgn) && widget.localOpeningTreeIndex == null) {
        final gameWithPgn = await ref
            .read(gamebaseRepositoryProvider)
            .getGameWithPgn(id);
        pgn = gameWithPgn?.pgn?.trim() ?? '';
        if (!pgnHasMoves(pgn) && gameWithPgn?.data != null) {
          pgn = (buildPgnFromGamebaseData(gameWithPgn!.data) ?? '').trim();
        }
      }
      if (!mounted) return;
      if (!pgnHasMoves(pgn)) {
        _showErrorToast('Could not load PGN for insert.');
        return;
      }
      ref
          .read(boardGameInsertRequestProvider.notifier)
          .state = BoardGameInsertRequest(
        id: ++_insertRequestId,
        pgn: pgn,
        sourceLabel: _sourceLabelFromRow(row),
      );
    } catch (e) {
      if (!mounted) return;
      _showErrorToast('Could not insert game: $e');
    }
  }

  void _showErrorToast(String message) {
    showDesktopToast(context, message, error: true);
  }

  String _sourceLabelFromRow(Map<String, dynamic> row) {
    final result = _normalizeResult((row['result']?.toString() ?? '').trim());
    final white = _compactPlayerCitation(
      row['white']?.toString() ?? row['whiteName']?.toString() ?? '',
      _readInt(row['whiteElo']),
    );
    final black = _compactPlayerCitation(
      row['black']?.toString() ?? row['blackName']?.toString() ?? '',
      _readInt(row['blackElo']),
    );
    final event = _displayEventForRow(row);
    final year = _yearFromRow(row);
    return [
      if (result.isNotEmpty) result,
      if (white.isNotEmpty || black.isNotEmpty) '$white-$black',
      if (event.isNotEmpty) event,
      if (year.isNotEmpty) year,
    ].join(' ');
  }

  String _yearFromRow(Map<String, dynamic> row) {
    final raw = row['date']?.toString().trim() ?? '';
    if (raw.length >= 4) return raw.substring(0, 4);
    return '';
  }

  String _compactPlayerCitation(String rawName, int rating) {
    final clean = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return '';
    final parts =
        clean.split(RegExp(r'[ ,]+')).where((p) => p.isNotEmpty).toList();
    final last = parts.isEmpty ? clean : parts.first;
    final initial = parts.length >= 2 ? ',${parts[1].substring(0, 1)}' : '';
    final ratingText = rating > 0 ? ' ($rating)' : '';
    return '$last$initial$ratingText';
  }

  String _normalizeResult(String result) {
    final normalized = result.replaceAll('½', '1/2').trim();
    return switch (normalized) {
      '1/2-1/2' => '½-½',
      '1-0' || '0-1' || '*' => normalized,
      _ => result,
    };
  }

  void _handleNotationStepTap(Map<String, dynamic> row, int index, int step) {
    if (index >= 0) {
      widget.onActivateContinuationStep?.call(index, step);
    }
    final id = (row['id']?.toString().trim() ?? '');
    if (id.isNotEmpty && widget.controller != null) {
      widget.controller!.select(
        id,
        preview: true,
        autoplay: false,
        step: step,
        reveal: false,
      );
    } else {
      _previewRow(row, autoplay: false, step: step);
    }
  }

  void _ensureFullContinuationLoaded(String id, List<String> fallback) {
    if (widget.onPreviewContinuation == null ||
        _fullContinuationCache.containsKey(id) ||
        _loadingFullContinuations.contains(id)) {
      return;
    }
    _loadingFullContinuations.add(id);
    unawaited(_loadFullContinuation(id, fallback));
  }

  Future<void> _loadFullContinuation(String id, List<String> fallback) async {
    final fen = _rowsFen;
    // A hover/preview continuation is a PGN fetch: never started when denied.
    if (!readDesktopAccess(
      ref.read,
      _rowAccessContext.copyWith(action: DesktopAction.fetchPgn),
    ).isAllowed) {
      return;
    }
    try {
      final gameWithPgn = await ref
          .read(gamebaseRepositoryProvider)
          .getGameWithPgn(id);
      var pgn = gameWithPgn?.pgn;
      if (!pgnHasMoves(pgn) && gameWithPgn?.data != null) {
        pgn = buildPgnFromGamebaseData(gameWithPgn!.data);
      }
      final full =
          pgnHasMoves(pgn)
              ? _continuationFromPgnAfterFen(id, pgn!, fen)
              : const <String>[];
      // The same game can be listed at the next position too; a line read
      // after the previous position never stands in for this one's.
      if (!mounted || _rowsFen != fen) return;
      final best = full.length > fallback.length ? full : fallback;
      setState(() {
        _fullContinuationCache[id] = List<String>.unmodifiable(best);
      });
      widget.controller?._setRows(
        _rowIdsSnapshot(),
        _rowContinuationsSnapshot(),
        _rowSourceLabelsSnapshot(),
      );
      if (widget.controller?.selectedRowId == id && best.isNotEmpty) {
        widget.onPreviewContinuation?.call(
          best,
          autoplay: _lastPreviewedRowId == id ? _lastPreviewAutoplay : true,
          step: _lastPreviewedRowId == id ? _lastPreviewStep : null,
        );
      }
    } catch (_) {
      if (mounted) {
        _fullContinuationCache[id] = List<String>.unmodifiable(fallback);
      }
    } finally {
      _loadingFullContinuations.remove(id);
    }
  }

  void _ensureSelectedVisible(String? id) {
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _rowKeys[id]?.currentContext;
      if (context == null) return;
      final renderObject = context.findRenderObject();
      if (renderObject == null || !_activeScrollController.hasClients) return;
      final scrollObject =
          _activeScrollController.position.context.storageContext
              .findRenderObject();
      if (renderObject is! RenderBox || scrollObject is! RenderBox) return;
      final targetTop =
          renderObject.localToGlobal(Offset.zero, ancestor: scrollObject).dy;
      final viewport = _activeScrollController.position.viewportDimension;
      final target = (_activeScrollController.offset +
              targetTop -
              (viewport - renderObject.size.height) * 0.16)
          .clamp(
            _activeScrollController.position.minScrollExtent,
            _activeScrollController.position.maxScrollExtent,
          );
      _activeScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _openGame(
    Map<String, dynamic> row, {
    bool focus = true,
    bool inNewWindow = false,
    int? continuationStep,
  }) async {
    final id = (row['id']?.toString().trim() ?? '');
    if (id.isEmpty) return;
    // Denied => no local hydrate and no board. The central board admission
    // re-checks with the same provenance.
    if (!admitBoardSourceOpen(
      ProviderScope.containerOf(context, listen: false),
      _rowAccessContext,
      surface: 'position_games_open',
    )) {
      return;
    }
    final sourceRows = <Map<String, dynamic>>[
      for (final current in _rows) Map<String, dynamic>.from(current),
    ];
    final openedRows =
        widget.localOpeningTreeIndex == null
            ? sourceRows
            : await compute(_hydrateLocalPgnRowsInBackground, sourceRows);
    if (!mounted) return;
    final openedRow = openedRows.firstWhere(
      (candidate) => (candidate['id']?.toString().trim() ?? '') == id,
      orElse: () => Map<String, dynamic>.from(row),
    );
    final whiteName = (openedRow['white']?.toString() ?? '').trim();
    final blackName = (openedRow['black']?.toString() ?? '').trim();
    final initialFen = _initialFenForOpenedGame(
      openedRow,
      continuationStep: continuationStep,
    );
    final databaseGames = openedRows
        .map((r) => _summaryForOpenedRow(r, fallbackFen: initialFen))
        .where((g) => g.id.trim().isNotEmpty)
        .toList(growable: false);
    final query = _lastSuccessfulQuery ?? _buildQuery(pageNumber: 0);
    final databaseTitle = _databaseTitleForOpenedGame();
    final isLocalRow = widget.localOpeningTreeIndex != null;
    final pgn = (openedRow['pgn']?.toString() ?? '').trim();
    if (isLocalRow && !pgnHasMoves(pgn)) {
      _showErrorToast('Could not load local PGN for this game.');
      return;
    }
    final args = BoardTabGameArgs(
      gameId: isLocalRow ? null : id,
      pgn: pgn,
      label: '$whiteName vs $blackName',
      whiteName: whiteName,
      blackName: blackName,
      whiteFederation: (openedRow['whiteFed']?.toString() ?? '').trim(),
      blackFederation: (openedRow['blackFed']?.toString() ?? '').trim(),
      whiteTitle: (openedRow['whiteTitle']?.toString() ?? '').trim(),
      blackTitle: (openedRow['blackTitle']?.toString() ?? '').trim(),
      whiteRating: _readInt(openedRow['whiteElo']),
      blackRating: _readInt(openedRow['blackElo']),
      whiteFideId: _readNullableInt(openedRow['whiteFideId']),
      blackFideId: _readNullableInt(openedRow['blackFideId']),
      fenSeed: initialFen,
      initialFen: initialFen,
      databaseTitle: databaseTitle,
      databaseGames:
          databaseGames.isEmpty
              ? [_summaryForOpenedRow(openedRow, fallbackFen: initialFen)]
              : databaseGames,
      databaseGamesPagination: BoardTabDatabaseGamesPagination(
        query: gamebasePositionGamesQueryWithPage(query, 0),
        nextPageNumber: _nextPageNumber,
        hasMore: _hasMore,
        exactFenSearch:
            _lastSuccessfulQuery == null
                ? widget.exactFenSearch
                : _rowsExactFenSearch,
        resolvedApi: _resolvedApi,
        totalCount: _totalCount,
        firstPageAskedAt: _firstPageFetchedAt,
        firstPageIsSavedCopy: _savedAt != null,
      ),
      localOpeningTreeIndex: widget.localOpeningTreeIndex,
      localOpeningTreeTitle: widget.localOpeningTreeTitle,
      gameListSelectedId: id,
      librarySaveOrigin: _localLibrarySaveOriginForRow(openedRow),
      accessContext: _rowAccessContext,
    );
    if (inNewWindow) {
      unawaited(openBoardGameWindow(ref, args));
      return;
    }

    openBoardGameTab(
      ref,
      args,
      focus: focus,
      reuseExisting: false,
      replaceActive: false,
    );
  }

  TournamentGameSummary _summaryForOpenedRow(
    Map<String, dynamic> row, {
    required String fallbackFen,
  }) {
    if (widget.localOpeningTreeIndex == null) {
      return gamebasePositionGameSummaryFromRow(row, fallbackFen: fallbackFen);
    }

    // The opening-tree rail outlives this table. Preserve each visible local
    // row's PGN and source coordinates in its lightweight summary so selecting
    // a different row can replace the Board tab without trying to hydrate the
    // local id from Supabase/Gamebase.
    final pgn = (row['pgn']?.toString() ?? '').trim();
    return gamebasePositionGameSummaryFromRow(<String, dynamic>{
      ...row,
      if (pgn.isNotEmpty) 'pgn': pgn,
    }, fallbackFen: fallbackFen);
  }

  String _initialFenForOpenedGame(
    Map<String, dynamic> row, {
    int? continuationStep,
  }) {
    if (continuationStep != null && continuationStep >= 0) {
      final continuation = _bestContinuationForRow(
        row,
        _readContinuation(row['continuation']),
      );
      final initialFen = _fenAfterContinuationStep(
        _rowsFen,
        continuation,
        continuationStep,
      );
      if (initialFen != null) return initialFen;
    }

    final fen = _rowsFen;
    final uci = _rowsUci?.trim();
    if (uci == null || uci.isEmpty) return fen;

    try {
      final position = Chess.fromSetup(Setup.parseFen(fen));
      final move = Move.parse(uci);
      if (move == null || !position.isLegal(move)) return fen;
      return position.play(move).fen;
    } catch (_) {
      return fen;
    }
  }

  String? _fenAfterContinuationStep(
    String fen,
    List<String> continuation,
    int step,
  ) {
    if (continuation.isEmpty) return null;
    final target = step.clamp(0, continuation.length - 1).toInt();

    try {
      Position position = Chess.fromSetup(
        Setup.parseFen(fen),
        ignoreImpossibleCheck: true,
      );
      for (final uci in continuation.take(target + 1)) {
        final move = Move.parse(uci);
        if (move == null || !position.isLegal(move)) return null;
        position = position.playUnchecked(move);
      }
      return position.fen;
    } catch (_) {
      return null;
    }
  }

  BoardTabLibrarySaveOrigin? _localLibrarySaveOriginForRow(
    Map<String, dynamic> row,
  ) {
    if (widget.localOpeningTreeIndex == null) return null;
    final sourcePath = (row['sourcePath']?.toString() ?? '').trim();
    final sourceIndex =
        row['indexInFile'] == null ? null : _readInt(row['indexInFile']);
    final sourceFileGameCount = _readNullableInt(row['fileGameCount']);
    if (sourcePath.isEmpty ||
        sourceIndex == null ||
        sourceFileGameCount == null) {
      return null;
    }
    final white = (row['white']?.toString() ?? '').trim();
    final black = (row['black']?.toString() ?? '').trim();
    final title =
        white.isNotEmpty || black.isNotEmpty
            ? '${white.isEmpty ? 'White' : white} vs ${black.isEmpty ? 'Black' : black}'
            : (row['event']?.toString().trim() ?? 'Local PGN game');
    return BoardTabLibrarySaveOrigin.localPgnFile(
      sourcePath: sourcePath,
      sourceIndex: sourceIndex,
      sourceFileGameCount: sourceFileGameCount,
      sourcePgnFingerprint: (row['pgnHash']?.toString() ?? '').trim(),
      sourceRecordRevision:
          (row['pgn']?.toString().trim().isNotEmpty ?? false)
              ? localPgnRecordRevision(row['pgn'].toString())
              : '',
      title: title,
    );
  }

  String _databaseTitleForOpenedGame() {
    final localTitle = widget.localOpeningTreeTitle.trim();
    final fen = _rowsFen;
    final tokens = <String>[..._toSanTokens(Chess.initial.fen, _rowsMoves)];
    final pinnedUci = _rowsUci?.trim();
    if (pinnedUci != null && pinnedUci.isNotEmpty) {
      tokens.addAll(_toSanTokens(fen, [pinnedUci]));
    }

    if (tokens.isEmpty) {
      if (localTitle.isNotEmpty) return localTitle;
      if (_positionKey(fen) == _positionKey(Chess.initial.fen)) {
        return 'Start position games';
      }
      return 'Position games: ${_compactFen(fen)}';
    }

    if (localTitle.isNotEmpty) {
      return '$localTitle - continuation after ${_shortNotation(tokens)}';
    }
    return 'Continuation after ${_shortNotation(tokens)}';
  }

  @override
  Widget build(BuildContext context) {
    // A purchase, a restore or an offline-grace change can unlock the
    // position: re-run the query once membership moves.
    ref.listen(subscriptionProvider, (_, _) {
      if (_queryLocked && _positionQueryAllowed) {
        unawaited(_fetchPage(reset: true));
      }
    });
    // Re-run the query whenever the explorer's filter slice changes
    // (toggle a chip, set a rating range, pick a player, etc).
    ref.listen<GamebaseFilters>(
      gamebaseExplorerProvider.select((s) => s.filters),
      (previous, next) {
        if (previous == next) return;
        if (_sortOverride != null &&
            previous != null &&
            (previous.sortBy != next.sortBy ||
                previous.sortDirection != next.sortDirection)) {
          setState(() => _sortOverride = null);
        }
        _fetchPage(reset: true);
      },
    );
    final filters = ref.watch(
      gamebaseExplorerProvider.select((s) => s.filters),
    );
    final playerId = filters.requestPlayerId?.trim();
    if (widget.localOpeningTreeIndex == null &&
        playerId != null &&
        playerId.isNotEmpty) {
      ref.listen<PlayerOpeningTreeState>(playerOpeningTreeProvider(playerId), (
        previous,
        next,
      ) {
        if (previous?.index == next.index &&
            previous?.progress.status == next.progress.status) {
          return;
        }
        final previousGameCount = previous?.index.downloadedGameCount ?? 0;
        final nextGameCount = next.index.downloadedGameCount;
        final gamesChanged = previousGameCount != nextGameCount;
        final statusChanged = previous?.progress.status != next.progress.status;
        if (!gamesChanged && !statusChanged) return;
        _scheduleLocalTreeRefresh();
      });
    }
    final boardSettings = ref.watch(
      boardSettingsProviderNew.select(
        (s) => s.valueOrNull ?? const BoardSettingsNew(),
      ),
    );
    final body = _buildBody(boardSettings);
    // Host-driven scroll (combined moves+games explorer) supplies its own
    // outer scroll view; the table must size to its content so the outer
    // sliver knows how tall to render it. Otherwise the table fills the
    // available vertical space via Expanded.
    final bodyWrapper =
        widget.useFixedRowAlignment ? body : Expanded(child: body);
    return FTheme(
      data: FThemes.zinc.dark,
      child: ColoredBox(
        color: kBlack2Color,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize:
              widget.useFixedRowAlignment ? MainAxisSize.min : MainAxisSize.max,
          children: [bodyWrapper],
        ),
      ),
    );
  }

  Widget _buildBody(BoardSettingsNew boardSettings) {
    if (_waitingForTreeMessage != null && _rows.isEmpty) {
      return _Empty(
        icon: Icons.account_tree_outlined,
        title: 'Building player tree',
        message: _waitingForTreeMessage!,
      );
    }
    if (_isInitialLoading && _rows.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      );
    }
    if (_queryLocked && _rows.isEmpty) {
      final lockedContext = _positionQueryContext;
      return DesktopAccessLockedSurface(
        decision: readDesktopAccess(ref.read, lockedContext),
        accessContext: lockedContext,
        surface: 'position_games_locked',
      );
    }
    if (_error != null && _rows.isEmpty) {
      return _Empty(
        icon: Icons.cloud_off_outlined,
        title: "Couldn't load games",
        message: _error!,
        actionLabel: _errorRetryable || _errorFromNetwork ? 'Retry' : null,
        onAction:
            _errorRetryable || _errorFromNetwork ? _retryAfterError : null,
      );
    }
    if (_rows.isEmpty) {
      return const _Empty(
        icon: Icons.menu_book_outlined,
        title: 'No Games Found',
        message:
            'No master / online games are indexed for the position on the board.',
      );
    }

    final selectedRowId = widget.controller?.selectedRowId;
    final filters = ref.read(gamebaseExplorerProvider).filters;
    final sortState =
        _sortOverride ??
        AdaptiveSortState(
          field: filters.sortBy,
          direction: filters.sortDirection,
        );
    final useNotationSubline = !widget.referenceLayout;
    final table = AdaptiveGamesTable<Map<String, dynamic>>(
      columns: _buildColumns(boardSettings, selectedRowId),
      rows: _rows,
      enableColumnResizing: widget.referenceLayout,
      scrollController: _scroll,
      useFixedRowAlignment: widget.useFixedRowAlignment,
      rowMinHeight: widget.referenceLayout ? 30 : 32,
      headerHeight: 24,
      padding:
          widget.referenceLayout
              ? const EdgeInsets.symmetric(horizontal: 7)
              : const EdgeInsets.symmetric(horizontal: 5),
      // Without the inline notation column the meta-only columns fit the
      // rail without forced horizontal scroll — the subline absorbs the
      // wide notation oneliner.
      minTableWidth:
          useNotationSubline ? null : (widget.referenceLayout ? 1280 : 1680),
      rowSublineBuilder:
          useNotationSubline
              ? (context, row) {
                final rowId = (row['id']?.toString().trim() ?? '');
                final rowIndex = _rows.indexOf(row);
                final isSelected =
                    selectedRowId != null &&
                    selectedRowId.isNotEmpty &&
                    rowId == selectedRowId;
                final continuation = _bestContinuationForRow(
                  row,
                  _readContinuation(row['continuation']),
                );
                if (continuation.isEmpty) return null;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 1, 8, 5),
                  child: _NotationCell(
                    fen: _rowsFen,
                    rowId: rowId,
                    indicatorNamespace: 'games',
                    continuation: continuation,
                    activePlyIndex:
                        isSelected ? widget.activeContinuationStep : null,
                    activeAutoplay:
                        isSelected && widget.activeContinuationAutoplay,
                    useFigurine: boardSettings.useFigurine,
                    pieceAssets: boardSettings.pieceAssets,
                    onTapStep:
                        (step) => _handleNotationStepTap(row, rowIndex, step),
                  ),
                );
              }
              : null,
      sortState: sortState,
      onSortChanged: (next) {
        setState(() => _sortOverride = next);
        _fetchPage(reset: true);
      },
      rowDecorationBuilder:
          selectedRowId == null
              ? null
              : (row, hovered) {
                final rowId = (row['id']?.toString().trim() ?? '');
                if (rowId == selectedRowId) {
                  return BoxDecoration(
                    color: kPrimaryColor.withValues(alpha: 0.18),
                    border: const Border(
                      left: BorderSide(color: kPrimaryColor, width: 2),
                      bottom: BorderSide(color: kDividerColor, width: 0.5),
                    ),
                  );
                }
                if (hovered) {
                  return const BoxDecoration(
                    color: kBlack3Color,
                    border: Border(
                      bottom: BorderSide(color: kDividerColor, width: 0.5),
                    ),
                  );
                }
                return null;
              },
      rowKeyBuilder: (row) {
        final rowId = (row['id']?.toString().trim() ?? '');
        if (rowId.isEmpty) return null;
        return _rowKeyFor(rowId);
      },
      enableRowHover: false,
      onRowHover: _handleRowHover,
      onRowTap:
          (row, {required bool inNewTab, required bool shiftPressed}) =>
              _handleRowTap(row, inNewTab: inNewTab),
      onRowSecondaryTap:
          (row, position) => unawaited(_showRowContextMenu(row, position)),
      footer:
          _hasMore
              ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                    ),
                  ),
                ),
              )
              : null,
    );
    final savedAt = _savedAt;
    if (savedAt != null && _refreshFailed && !_isInitialLoading) {
      // A saved copy the server could not confirm stays readable, but never
      // passes for the current answer.
      final notice = _SavedCopyNotice(
        savedAt: savedAt,
        onRetry: _retryAfterError,
      );
      if (widget.useFixedRowAlignment) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [notice, table],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [notice, Expanded(child: table)],
      );
    }
    // The line marks rows that are not the current answer yet: a page 0 on
    // its way, the previous position's rows, or a saved copy being checked.
    if (!_isInitialLoading && savedAt == null) return table;
    return Stack(
      children: [
        table,
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: LinearProgressIndicator(
            minHeight: 1,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation(kPrimaryColor),
          ),
        ),
      ],
    );
  }

  /// Builds the full column spec for the position-games table. Cell widgets
  /// are content-only — alignment + padding are owned by AdaptiveGamesTable.
  List<AdaptiveColumn<Map<String, dynamic>>> _buildColumns(
    BoardSettingsNew boardSettings,
    String? selectedRowId,
  ) {
    final showPlayerChrome = !widget.referenceLayout;
    final playerMaxWidth = widget.referenceLayout ? 76.0 : 132.0;
    final notationMinWidth = widget.referenceLayout ? 520.0 : 720.0;
    final indicatorNamespace = widget.referenceLayout ? 'explorer' : 'games';
    // Two-line row layout: dedicated Games tabs (referenceLayout=false) drop
    // the inline NOTATION column and re-render the continuation as a full-
    // width subline beneath the metadata cells — the per-row notation gets
    // the rail width instead of competing with elo/year/opening columns.
    // The cramped Explorer split keeps the inline column.
    final useNotationSubline = !widget.referenceLayout;

    final columns = [
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'white',
        label: 'WHITE',
        sortField: GamebaseSortField.whiteName,
        cellBuilder:
            (_, row) => _CompactPlayerName(
              name: _rowText(row, const ['white', 'whiteName']),
              federation: _rowText(row, const ['whiteFed']),
              title: _rowText(row, const ['whiteTitle']),
              showFlag: showPlayerChrome,
              showTitle: showPlayerChrome,
              maxWidth: playerMaxWidth,
            ),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'black',
        label: 'BLACK',
        sortField: GamebaseSortField.blackName,
        cellBuilder:
            (_, row) => _CompactPlayerName(
              name: _rowText(row, const ['black', 'blackName']),
              federation: _rowText(row, const ['blackFed']),
              title: _rowText(row, const ['blackTitle']),
              showFlag: showPlayerChrome,
              showTitle: showPlayerChrome,
              maxWidth: playerMaxWidth,
            ),
      ),
      if (!useNotationSubline)
        AdaptiveColumn<Map<String, dynamic>>(
          id: 'notation',
          label: 'NOTATION',
          flex: widget.referenceLayout ? 4.6 : 5.0,
          minWidth: notationMinWidth,
          resizeMinWidth: 180,
          cellBuilder: (_, row) {
            final rowId = (row['id']?.toString().trim() ?? '');
            final rowIndex = _rows.indexOf(row);
            final isSelected =
                selectedRowId != null &&
                selectedRowId.isNotEmpty &&
                rowId == selectedRowId;
            return _NotationCell(
              fen: _rowsFen,
              rowId: rowId,
              indicatorNamespace: indicatorNamespace,
              continuation: _bestContinuationForRow(
                row,
                _readContinuation(row['continuation']),
              ),
              activePlyIndex: isSelected ? widget.activeContinuationStep : null,
              activeAutoplay: isSelected && widget.activeContinuationAutoplay,
              useFigurine: boardSettings.useFigurine,
              pieceAssets: boardSettings.pieceAssets,
              onTapStep: (step) => _handleNotationStepTap(row, rowIndex, step),
            );
          },
        ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'whiteElo',
        label: 'ELO W',
        sortField: GamebaseSortField.whiteElo,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, row) => _Numeric(value: _readInt(row['whiteElo'])),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'blackElo',
        label: 'ELO B',
        sortField: GamebaseSortField.blackElo,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, row) => _Numeric(value: _readInt(row['blackElo'])),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'result',
        label: 'RES',
        sortField: GamebaseSortField.result,
        headerAlignment: Alignment.center,
        cellAlignment: Alignment.center,
        cellBuilder:
            (_, row) =>
                _ResultCell(result: (row['result']?.toString() ?? '').trim()),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'year',
        label: 'YEAR',
        sortField: GamebaseSortField.date,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, row) {
          final raw = row['date']?.toString();
          final date = raw == null ? null : DateTime.tryParse(raw);
          return Text(
            date == null ? '' : _formatDate(date),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: kWhiteColor70,
              fontSize: 11,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          );
        },
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'eco',
        label: 'ECO',
        sortField: GamebaseSortField.eco,
        cellBuilder:
            (_, row) => _TextCell(
              value: _rowText(row, const ['eco']),
              maxWidth: 38,
              color: kWhiteColor70,
            ),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'opening',
        label: 'OPENING',
        sortField: GamebaseSortField.opening,
        cellBuilder:
            (_, row) => _TextCell(
              value: _rowText(row, const ['opening']),
              maxWidth: widget.referenceLayout ? 160 : 220,
              color: kWhiteColor,
            ),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'variation',
        label: 'VAR',
        sortField: GamebaseSortField.variation,
        cellBuilder:
            (_, row) => _TextCell(
              value: _rowText(row, const ['variation']),
              maxWidth: widget.referenceLayout ? 120 : 170,
              color: kWhiteColor70,
            ),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'event',
        label: 'EVENT',
        sortField: GamebaseSortField.event,
        cellBuilder:
            (_, row) => _TextCell(
              value: _displayEventForRow(row),
              maxWidth: widget.referenceLayout ? 150 : 210,
              color: kWhiteColor70,
            ),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'site',
        label: 'SITE',
        sortField: GamebaseSortField.site,
        cellBuilder:
            (_, row) => _TextCell(
              value: _rowText(row, const ['site']),
              maxWidth: widget.referenceLayout ? 130 : 180,
              color: kWhiteColor70,
            ),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'timeControl',
        label: 'TC',
        sortField: GamebaseSortField.timeControl,
        headerAlignment: Alignment.center,
        cellAlignment: Alignment.center,
        tooltip: 'Time control',
        cellBuilder:
            (_, row) =>
                _TimeControlCell(value: _rowText(row, const ['timeControl'])),
      ),
      AdaptiveColumn<Map<String, dynamic>>(
        id: 'mode',
        label: 'MODE',
        headerAlignment: Alignment.center,
        cellAlignment: Alignment.center,
        tooltip: 'Online / over-the-board',
        cellBuilder: (_, row) => _ModeCell(value: _readBool(row['isOnline'])),
      ),
    ];
    final byId = <String, AdaptiveColumn<Map<String, dynamic>>>{
      for (final column in columns) column.id: column,
    };
    if (!widget.referenceLayout) {
      return [
        for (final id in const <String>[
          'white',
          'whiteElo',
          'black',
          'blackElo',
          'result',
          'year',
          'event',
          'notation',
          'opening',
          'variation',
          'eco',
          'site',
          'timeControl',
          'mode',
        ])
          if (byId[id] != null) byId[id]!,
      ];
    }

    return [
      for (final id in const <String>[
        'white',
        'whiteElo',
        'black',
        'blackElo',
        'result',
        'year',
        'event',
        'notation',
        'eco',
        'site',
        'opening',
        'variation',
        'timeControl',
        'mode',
      ])
        if (byId[id] != null) byId[id]!,
    ];
  }
}

/// Player-name cell kept database-tight: "Surname,I" by default, with
/// optional flag/title chrome in the wider standalone Games tab.
class _CompactPlayerName extends StatelessWidget {
  const _CompactPlayerName({
    required this.name,
    required this.federation,
    required this.title,
    required this.showFlag,
    required this.showTitle,
    required this.maxWidth,
  });

  final String name;
  final String federation;
  final String title;
  final bool showFlag;
  final bool showTitle;
  final double maxWidth;

  static String _compact(String raw) {
    final trimmed = desktopTablePlayerValue(raw);
    if (trimmed.isEmpty) return '';
    if (trimmed.contains(',')) {
      final parts = trimmed.split(',');
      final surname = parts.first.trim();
      final given = parts.length > 1 ? parts[1].trim() : '';
      if (surname.isEmpty) return trimmed;
      if (given.isEmpty) return surname;
      return '$surname,${given.substring(0, 1)}';
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 2) return trimmed;
    final given = parts.first;
    final surname = parts.last;
    return '$surname,${given.substring(0, 1)}';
  }

  @override
  Widget build(BuildContext context) {
    final compactName = _compact(name);
    if (compactName.isEmpty) return const SizedBox.shrink();
    final label = Text(
      compactName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: kWhiteColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showFlag && federation.isNotEmpty) ...[
            FederationFlag(
              federation: federation,
              width: 13,
              height: 9,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(width: 5),
          ],
          if (showTitle && title.isNotEmpty) ...[
            Text(
              title,
              style: const TextStyle(
                color: kLightYellowColor,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Flexible(child: label),
        ],
      ),
    );
  }
}

class _TextCell extends StatelessWidget {
  const _TextCell({
    required this.value,
    required this.maxWidth,
    this.color = kWhiteColor70,
  });

  final String value;
  final double maxWidth;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final displayValue = desktopTableDisplayValue(value);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(
        displayValue,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: displayValue.isEmpty ? kLightGreyColor : color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _TimeControlCell extends StatelessWidget {
  const _TimeControlCell({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final normalized = desktopTableDisplayValue(value).toUpperCase();
    final label = switch (normalized) {
      'CLASSICAL' => 'CLS',
      'RAPID' => 'RPD',
      'BLITZ' => 'BLZ',
      '' => '',
      final other => other.length <= 3 ? other : other.substring(0, 3),
    };
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: TextStyle(
        color: label.isEmpty ? kLightGreyColor : kWhiteColor70,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _ModeCell extends StatelessWidget {
  const _ModeCell({required this.value});

  final bool? value;

  @override
  Widget build(BuildContext context) {
    final label = switch (value) {
      true => 'ONL',
      false => 'OTB',
      null => '',
    };
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: TextStyle(
        color: value == null ? kLightGreyColor : kWhiteColor70,
        fontSize: 10,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _Numeric extends StatelessWidget {
  const _Numeric({required this.value});

  final int value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value > 0 ? '$value' : '',
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 11,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _NotationCell extends StatelessWidget {
  const _NotationCell({
    required this.fen,
    required this.rowId,
    required this.indicatorNamespace,
    required this.continuation,
    required this.activePlyIndex,
    required this.activeAutoplay,
    required this.useFigurine,
    required this.pieceAssets,
    required this.onTapStep,
  });

  final String fen;
  final String rowId;
  final String indicatorNamespace;
  final List<String> continuation;
  final int? activePlyIndex;
  final bool activeAutoplay;
  final bool useFigurine;
  final PieceAssets pieceAssets;
  final ValueChanged<int> onTapStep;

  @override
  Widget build(BuildContext context) {
    // Cap at 20 full moves (40 plies) — the oneliner is a preview, not the
    // whole game. Anything beyond that just gets clipped/faded anyway, so
    // skip the work of rendering it.
    const maxPlies = 40;
    final cappedContinuation =
        continuation.length > maxPlies
            ? continuation.sublist(0, maxPlies)
            : continuation;
    final sanTokens = _toSanTokens(fen, cappedContinuation);
    const style = TextStyle(
      color: kWhiteColor,
      fontSize: 11.5,
      height: 1.1,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    if (sanTokens.isEmpty) {
      return const SizedBox.shrink();
    }
    final activeIndex = activePlyIndex?.clamp(0, sanTokens.length - 1).toInt();
    return SizedBox(
      height: 22,
      child: ShaderMask(
        // Soft right-edge fade telegraphs that the row continues past the
        // visible width without the visual jolt of a hard mid-letter clip.
        shaderCallback:
            (rect) => const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [0.0, 0.92, 1.0],
              colors: [Colors.black, Colors.black, Colors.transparent],
            ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 22,
            maxHeight: 22,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < sanTokens.length; i++) ...[
                    _NotationHoverToken(
                      tokenKey: ValueKey<String>(
                        'position-game-notation-token-$indicatorNamespace-$rowId-$i',
                      ),
                      startingFen: fen,
                      movesUpToHover: cappedContinuation
                          .take(i + 1)
                          .toList(growable: false),
                      token: sanTokens[i],
                      useFigurine: useFigurine,
                      pieceAssets: pieceAssets,
                      style: style,
                      active: activeIndex == i,
                      autoplaying: activeIndex == i && activeAutoplay,
                      activeKey:
                          activeIndex == i
                              ? ValueKey<String>(
                                'position-game-notation-active-$indicatorNamespace-$rowId-$i',
                              )
                              : null,
                      onTap: () => onTapStep(i),
                    ),
                    // Larger whitespace between full moves (after a black
                    // ply, i.e. odd index) than between the two plies of
                    // the same move — keeps the rhythm "12.e4 e5 13.Nf3
                    // Nc6" easy to scan.
                    if (i < sanTokens.length - 1)
                      SizedBox(width: i.isOdd ? 4 : 1),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotationHoverToken extends StatefulWidget {
  const _NotationHoverToken({
    required this.tokenKey,
    required this.startingFen,
    required this.movesUpToHover,
    required this.token,
    required this.useFigurine,
    required this.pieceAssets,
    required this.style,
    required this.active,
    required this.autoplaying,
    required this.activeKey,
    required this.onTap,
  });

  final Key tokenKey;
  final String startingFen;
  final List<String> movesUpToHover;
  final String token;
  final bool useFigurine;
  final PieceAssets pieceAssets;
  final TextStyle style;
  final bool active;
  final bool autoplaying;
  final Key? activeKey;
  final VoidCallback onTap;

  @override
  State<_NotationHoverToken> createState() => _NotationHoverTokenState();
}

class _NotationHoverTokenState extends State<_NotationHoverToken> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokenStyle =
        widget.active
            ? widget.style.copyWith(
              color: kWhiteColor,
              fontWeight: FontWeight.w800,
            )
            : widget.style.copyWith(
              color: _hovered ? kWhiteColor : widget.style.color ?? kWhiteColor,
            );
    final tokenChild =
        widget.useFigurine
            ? RichText(
              maxLines: 1,
              overflow: TextOverflow.clip,
              text: TextSpan(
                children: buildFigurineSpans(
                  text: widget.token,
                  pieceAssets: widget.pieceAssets,
                  style: tokenStyle,
                  pieceSize: 12,
                ),
              ),
            )
            : Text(
              widget.token,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: tokenStyle,
            );
    final child = AnimatedContainer(
      key: widget.activeKey,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color:
            widget.active
                ? kPrimaryColor.withValues(alpha: 0.24)
                : (_hovered
                    ? kWhiteColor.withValues(alpha: 0.06)
                    : Colors.transparent),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color:
              widget.active
                  ? kPrimaryColor.withValues(alpha: 0.84)
                  : (_hovered
                      ? kWhiteColor.withValues(alpha: 0.20)
                      : Colors.transparent),
          width: 0.8,
        ),
        boxShadow:
            widget.active
                ? [
                  BoxShadow(
                    color: kPrimaryColor.withValues(alpha: 0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
                : null,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          tokenChild,
          if (widget.active)
            Positioned(
              left: 1,
              right: 1,
              bottom: -3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color:
                      widget.autoplaying
                          ? kWhiteColor.withValues(alpha: 0.90)
                          : kPrimaryColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const SizedBox(height: 2),
              ),
            ),
        ],
      ),
    );
    return KeyedSubtree(
      key: widget.tokenKey,
      child: MoveHoverPreview(
        startingFen: widget.startingFen,
        movesUpToHover: widget.movesUpToHover,
        size: 180,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: child,
          ),
        ),
      ),
    );
  }
}

enum _PositionGameRowAction { openInNewTab, openInNewWindow, insertGame }

/// Walk the UCI continuation through dartchess, emitting SAN with the
/// move-number labels a chess reader expects:
///   white-to-move + first ply  → "8.dxc3"
///   black-to-move + first ply  → "8…Bc5"
///   white-to-move on a later ply → "9.Qe2+"
///   black-to-move on a later ply → just "Qe7"
List<String> _toSanTokens(String fen, List<String> ucis) {
  if (ucis.isEmpty) return const <String>[];
  final parts = fen.trim().split(RegExp(r'\s+'));
  final initialFullMove = parts.length >= 6 ? int.tryParse(parts[5]) ?? 1 : 1;
  final whiteFirst = parts.length >= 2 ? parts[1] == 'w' : true;

  Position position;
  try {
    position = Chess.fromSetup(
      Setup.parseFen(fen),
      ignoreImpossibleCheck: true,
    );
  } catch (_) {
    return const <String>[];
  }

  final tokens = <String>[];
  var fullMove = initialFullMove;
  var whiteToMove = whiteFirst;
  for (final uci in ucis) {
    final move = Move.parse(uci);
    if (move == null) break;
    late final (Position, String) made;
    try {
      made = position.makeSan(move);
    } catch (_) {
      break;
    }
    final (next, san) = made;
    if (whiteToMove) {
      tokens.add('$fullMove.$san');
    } else if (tokens.isEmpty) {
      tokens.add('$fullMove…$san');
    } else {
      tokens.add(san);
    }
    position = next;
    if (!whiteToMove) fullMove += 1;
    whiteToMove = !whiteToMove;
  }
  return tokens;
}

String _shortNotation(List<String> tokens) {
  const maxTokens = 8;
  if (tokens.length <= maxTokens) return tokens.join(' ');
  final tail = tokens.sublist(tokens.length - maxTokens).join(' ');
  return '… $tail';
}

List<String> _continuationFromPgnAfterFen(
  String gameId,
  String pgn,
  String fen,
) {
  try {
    final game = ChessGame.fromPgn(gameId, pgn);
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

String _fenPositionKey(String fen) =>
    fen.trim().split(RegExp(r'\s+')).take(4).join(' ');

String _compactFen(String fen) {
  final key = fen.trim().split(RegExp(r'\s+')).take(4).join(' ');
  if (key.length <= 44) return key;
  return '${key.substring(0, 43)}…';
}

/// Bare-text result. Winner side is full-weight white; loser is dimmed;
/// draw is rendered as a single muted `½-½`. No chrome — readability at
/// row-density beats the old two-color pill that fought the surrounding
/// table.
class _ResultCell extends StatelessWidget {
  const _ResultCell({required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    final normalized = result.replaceAll('½', '1/2').trim();
    final (whiteLabel, blackLabel, outcome) = switch (normalized) {
      '1-0' || 'W' || 'w' || 'WHITE_WINS' => ('1', '0', _ResultOutcome.white),
      '0-1' || 'B' || 'b' || 'BLACK_WINS' => ('0', '1', _ResultOutcome.black),
      '1/2-1/2' || 'D' || 'd' || 'DRAW' => ('½', '½', _ResultOutcome.draw),
      _ => ('', '', _ResultOutcome.none),
    };
    if (outcome == _ResultOutcome.none) {
      return const SizedBox.shrink();
    }
    const base = TextStyle(
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
      height: 1.0,
    );
    final strong = base.copyWith(
      color: kWhiteColor,
      fontWeight: FontWeight.w700,
    );
    final weak = base.copyWith(
      color: kWhiteColor.withValues(alpha: 0.32),
      fontWeight: FontWeight.w500,
    );
    final neutral = base.copyWith(
      color: kWhiteColor.withValues(alpha: 0.62),
      fontWeight: FontWeight.w600,
    );
    final sep = base.copyWith(color: kWhiteColor.withValues(alpha: 0.28));
    final whiteStyle = switch (outcome) {
      _ResultOutcome.white => strong,
      _ResultOutcome.black => weak,
      _ResultOutcome.draw => neutral,
      _ResultOutcome.none => base,
    };
    final blackStyle = switch (outcome) {
      _ResultOutcome.white => weak,
      _ResultOutcome.black => strong,
      _ResultOutcome.draw => neutral,
      _ResultOutcome.none => base,
    };
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: whiteLabel, style: whiteStyle),
          TextSpan(text: '–', style: sep),
          TextSpan(text: blackLabel, style: blackStyle),
        ],
      ),
      maxLines: 1,
    );
  }
}

enum _ResultOutcome { white, black, draw, none }

enum _HeldPaint { none, saved, current }

/// One quiet line above a saved copy whose check failed: how old the rows
/// are, and a way to ask again.
class _SavedCopyNotice extends StatelessWidget {
  const _SavedCopyNotice({required this.savedAt, required this.onRetry});

  final DateTime savedAt;
  final VoidCallback onRetry;

  static String _age(DateTime savedAt) {
    final elapsed = DateTime.now().difference(savedAt);
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) {
      return '${elapsed.inMinutes} min ago';
    }
    if (elapsed.inDays < 1) {
      final hours = elapsed.inHours;
      return hours == 1 ? '1 hour ago' : '$hours hours ago';
    }
    final days = elapsed.inDays;
    return days == 1 ? 'yesterday' : '$days days ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBlack2Color,
      padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Saved ${_age(savedAt)}. Couldn’t refresh.',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
          ),
          const SizedBox(width: 8),
          _NoticeAction(label: 'Retry', onTap: onRetry),
        ],
      ),
    );
  }
}

class _NoticeAction extends StatefulWidget {
  const _NoticeAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_NoticeAction> createState() => _NoticeActionState();
}

class _NoticeActionState extends State<_NoticeAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return ClickCursor(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              widget.label,
              style: TextStyle(
                color: _hovered ? kWhiteColor : kWhiteColor70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;

  /// Optional recovery action. A failure the user can retry (`Retry`) must
  /// never be a dead end.
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final label = actionLabel?.trim() ?? '';
    final action = onAction;
    final hasAction = label.isNotEmpty && action != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: kLightGreyColor),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: kLightGreyColor, fontSize: 11),
            ),
            if (hasAction) ...[
              const SizedBox(height: 12),
              DesktopHeaderActionButton(
                label: label,
                icon: Icons.refresh_rounded,
                onPress: action,
                accented: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Hydrates local PGN rows away from Flutter's UI isolate.
/// Cached byte spans can belong to an older source revision. Resolve physical
/// ordinals and validate identity against one immutable snapshot per source in
/// this batch, including rows that predate cached byte spans.
List<Map<String, dynamic>> _hydrateLocalPgnRowsInBackground(
  List<Map<String, dynamic>> rows,
) {
  final sources = <String, ({String text, List<PgnGameRange> ranges})>{};
  final unavailableSources = <String>{};
  final hydratedRows = <Map<String, dynamic>>[];
  for (final row in rows) {
    final hydrated = Map<String, dynamic>.from(row);
    final inline = (hydrated['pgn']?.toString() ?? '').trim();
    if (pgnHasMoves(inline)) {
      hydratedRows.add(hydrated);
      continue;
    }

    final sourcePath = (hydrated['sourcePath']?.toString() ?? '').trim();
    final indexInFile = _readOptionalInt(hydrated['indexInFile']);
    if (sourcePath.isNotEmpty && indexInFile != null && indexInFile >= 0) {
      try {
        if (unavailableSources.contains(sourcePath)) {
          throw StateError('The source PGN is unavailable.');
        }
        final source = sources.putIfAbsent(sourcePath, () {
          try {
            final text = io.File(sourcePath).readAsStringSync();
            return (text: text, ranges: pgnGameRanges(text));
          } on Object {
            // Do not repeatedly read a failed source once per neighbor.
            unavailableSources.add(sourcePath);
            rethrow;
          }
        });
        hydrated['pgn'] = localPgnRecordFromSnapshot(
          text: source.text,
          recordRanges: source.ranges,
          indexInFile: indexInFile,
          expectedFileGameCount: _readOptionalInt(hydrated['fileGameCount']),
          expectedPgnFingerprint: hydrated['pgnHash']?.toString(),
        );
      } on Object {
        // Never let a rejected slice reach open/insert or acquire a revision.
        hydrated.remove('pgn');
      }
    }
    hydratedRows.add(hydrated);
  }
  return hydratedRows;
}

int _readInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _readNullableInt(dynamic value) {
  final parsed = _readInt(value);
  return parsed > 0 ? parsed : null;
}

int? _readOptionalInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

String _rowText(Map<String, dynamic> row, List<String> keys) {
  return _rowTextOrNull(row, keys) ?? '';
}

String? _rowTextOrNull(Map<String, dynamic> row, List<String> keys) {
  for (final key in keys) {
    final value = (row[key]?.toString() ?? '').trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

bool? _readBool(dynamic value) {
  if (value is bool) return value;
  final normalized = value?.toString().trim().toLowerCase();
  if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
    return true;
  }
  if (normalized == 'false' || normalized == '0' || normalized == 'no') {
    return false;
  }
  return null;
}

final _dateFormat = DateFormat('yyyy');
String _formatDate(DateTime d) => _dateFormat.format(d);
final _sourceDateFormat = DateFormat('yyyy-MM-dd');

String? _sourceLabelForRow(Map<String, dynamic> row) {
  // Structured pipe-delimited key=value payload so the notation renderer can
  // lay out a real game header (result · players + Elo · event · site · year)
  // instead of a flat comma-joined string that collapses commas inside names.
  final fields = <String, String>{};
  void put(String key, String? value) {
    if (value == null) return;
    final clean = value.replaceAll('|', ' ').replaceAll('=', ' ').trim();
    if (clean.isEmpty) return;
    fields[key] = clean;
  }

  put('result', _trimmedString(row['result']));
  put('white', _trimmedString(row['white']));
  put('whiteElo', _intString(row['whiteElo']));
  put('whiteTitle', _trimmedString(row['whiteTitle']));
  put('whiteFed', _trimmedString(row['whiteFed']));
  put('black', _trimmedString(row['black']));
  put('blackElo', _intString(row['blackElo']));
  put('blackTitle', _trimmedString(row['blackTitle']));
  put('blackFed', _trimmedString(row['blackFed']));
  put('event', _displayEventForRow(row));
  put('site', _trimmedString(row['site']));
  put('round', _trimmedString(row['round']));
  put('year', _dateLabelForRow(row));

  if (fields.isEmpty) return null;
  return fields.entries.map((e) => '${e.key}=${e.value}').join('|');
}

String _displayEventForRow(Map<String, dynamic> row) {
  const broadcastKeys = <String>[
    'BroadcastName',
    'Broadcast Name',
    'broadcastName',
    'broadcast_name',
    'GroupBroadcastName',
    'Group Broadcast Name',
    'groupBroadcastName',
    'group_broadcast_name',
  ];
  const eventKeys = <String>['Event', 'event'];
  return _rowTextOrNull(row, broadcastKeys) ??
      _nestedHeaderText(row, broadcastKeys) ??
      _pgnHeaderText(row, broadcastKeys) ??
      _derivedBroadcastTitleForRoundEvent(row, eventKeys) ??
      _rowTextOrNull(row, eventKeys) ??
      _nestedHeaderText(row, eventKeys) ??
      _pgnHeaderText(row, eventKeys) ??
      '';
}

String? _derivedBroadcastTitleForRoundEvent(
  Map<String, dynamic> row,
  List<String> eventKeys,
) {
  final event =
      _rowTextOrNull(row, eventKeys) ??
      _nestedHeaderText(row, eventKeys) ??
      _pgnHeaderText(row, eventKeys);
  if (event == null || !isTwicRoundPairingEventTitle(event)) return null;

  for (final key in const <String>[
    'BroadcastURL',
    'broadcastUrl',
    'broadcast_url',
    'GameURL',
    'gameUrl',
    'game_url',
    'Site',
    'site',
  ]) {
    final url =
        _rowTextOrNull(row, [key]) ??
        _nestedHeaderText(row, [key]) ??
        _pgnHeaderText(row, [key]);
    if (url == null || url.trim().isEmpty) continue;
    final title = preferredTwicEventTitle(event: event, site: url);
    if (title.trim().isNotEmpty && title.trim() != event.trim()) {
      return title.trim();
    }
  }

  return null;
}

String? _nestedHeaderText(Map<String, dynamic> row, List<String> keys) {
  for (final containerKey in const <String>[
    'md',
    'metadata',
    'headers',
    'data',
  ]) {
    final nested = _mapFromHeaderContainer(row[containerKey]);
    if (nested == null) continue;
    final direct = _rowTextOrNull(nested, keys);
    if (direct != null) return direct;
    if (containerKey == 'data') {
      final fromData = _nestedHeaderText(nested, keys);
      if (fromData != null) return fromData;
    }
  }
  return null;
}

Map<String, dynamic>? _mapFromHeaderContainer(Object? raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }
  return null;
}

String? _pgnHeaderText(Map<String, dynamic> row, List<String> keys) {
  final pgn = row['pgn']?.toString();
  if (pgn == null || pgn.trim().isEmpty) return null;
  for (final key in keys) {
    final match = RegExp(
      '^\\[${RegExp.escape(key)}\\s+"([^"]*)"\\]',
      multiLine: true,
    ).firstMatch(pgn);
    final value = match?.group(1)?.trim();
    if (value != null && value.isNotEmpty && value != '?') return value;
  }
  return null;
}

String? _dateLabelForRow(Map<String, dynamic> row) {
  final raw = _trimmedString(row['date']);
  if (raw == null) return null;
  final date = DateTime.tryParse(raw);
  if (date != null) return _sourceDateFormat.format(date).substring(0, 4);
  final year = RegExp(r'^\d{4}').firstMatch(raw)?.group(0);
  if (year == null || year.trim().isEmpty) return null;
  return year;
}

String? _intString(Object? value) {
  if (value == null) return null;
  if (value is int) return value > 0 ? '$value' : null;
  if (value is num) {
    final i = value.toInt();
    return i > 0 ? '$i' : null;
  }
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  final n = int.tryParse(s);
  if (n == null) return null;
  return n > 0 ? '$n' : null;
}

String? _trimmedString(Object? value) {
  final text = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text == null || text.isEmpty ? null : text;
}

/// Read the `continuation` field returned by /api/game-position/games when
/// `notationPlies` was passed. The repo decodes JSON arrays as
/// `List<dynamic>`, so we filter to the strings that look like UCI moves —
/// the rest are server-side bugs we don't want to crash the table over.
List<String> _readContinuation(dynamic raw) {
  if (raw is! List) return const <String>[];
  return [
    for (final entry in raw)
      if (entry is String && entry.isNotEmpty) entry,
  ];
}
