import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/board_explorer_scope.dart';
import 'package:chessever/desktop/state/board_tab_fen.dart';
import 'package:chessever/desktop/state/board_pane_session.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/state/tournament_games.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/gamebase/providers/gamebase_providers.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';

/// Args for a Board tab focused on a *specific game*. The plain Board tab
/// (the default scratch board the user can play freely on) carries no
/// args; per-game Board tabs each carry their own copy in
/// [boardTabGameArgsByTabIdProvider] so swapping tabs swaps the game.
enum BoardTabLibrarySaveOriginKind { cloudSavedAnalysis, localPgnFile }

@immutable
class BoardTabLibrarySaveOrigin {
  const BoardTabLibrarySaveOrigin.cloudSavedAnalysis({
    required this.analysisId,
    required this.title,
  }) : kind = BoardTabLibrarySaveOriginKind.cloudSavedAnalysis,
       sourcePath = null,
       sourceIndex = null,
       sourceFileGameCount = null;

  const BoardTabLibrarySaveOrigin.localPgnFile({
    required this.sourcePath,
    required this.sourceIndex,
    required this.sourceFileGameCount,
    required this.title,
  }) : kind = BoardTabLibrarySaveOriginKind.localPgnFile,
       analysisId = null;

  final BoardTabLibrarySaveOriginKind kind;
  final String? analysisId;
  final String? sourcePath;
  final int? sourceIndex;
  final int? sourceFileGameCount;
  final String title;
}

class BoardTabGameArgs {
  const BoardTabGameArgs({
    this.gameId,
    required this.pgn,
    required this.label,
    required this.whiteName,
    required this.blackName,
    this.whiteFederation = '',
    this.blackFederation = '',
    this.whiteTitle = '',
    this.blackTitle = '',
    this.whiteRating = 0,
    this.blackRating = 0,
    this.whiteFideId,
    this.blackFideId,
    this.initialBoardFlipped = false,
    this.fenSeed,
    this.initialFen,
    this.sourceGame,
    this.viewSource = ChessboardView.tour,
    this.tournamentTitle = '',
    this.eventGames = const <TournamentGameSummary>[],
    this.eventGamesLoading = false,
    this.routeTitle = '',
    this.routeGames = const <TournamentGameSummary>[],
    this.routeGamesContinuation,
    this.databaseTitle = '',
    this.databaseGames = const <TournamentGameSummary>[],
    this.databaseGamesPagination,
    this.databaseGamesContinuation,
    this.eventGamesContinuation,
    this.gameListSelectedId,
    this.librarySaveOrigin,
  });

  /// Supabase game id, when this tab is bound to a tournament game. Null
  /// for drag-dropped PGNs and saved-analysis opens — those have no live
  /// stream to subscribe to.
  final String? gameId;

  /// Initial PGN movetext seeded into the board pane on mount.
  final String pgn;

  /// Caller-supplied debug label / breadcrumb (e.g. "Chess Olympiad /
  /// Carlsen vs Nepo, R5"). Currently used as the tab tooltip.
  final String label;

  final String whiteName;
  final String blackName;
  final String whiteFederation;
  final String blackFederation;
  final String whiteTitle;
  final String blackTitle;
  final int whiteRating;
  final int blackRating;
  final int? whiteFideId;
  final int? blackFideId;

  /// Initial board orientation for callers that know the user's point of view.
  /// User/session state wins after the Board pane has mounted.
  final bool initialBoardFlipped;

  /// Last-known FEN at open time, used to drive the tab chip's mini
  /// eval bar before the live stream pushes its first update.
  final String? fenSeed;

  /// Optional position the Board tab should seek to once the PGN has been
  /// loaded. Used by Opening Explorer / position-game rows so opening a
  /// game lands on the explored position instead of the PGN root.
  final String? initialFen;

  /// Original tournament/live game row that opened this board tab.
  ///
  /// Kept so player-header taps can open a scorecard with the same event
  /// context mobile supplies from `ChessBoardScreenNew`. Detached PGNs and
  /// saved analyses intentionally leave this null.
  final GamesTourModel? sourceGame;

  /// Mobile board source this tab came from. Used when the desktop board
  /// needs to reproduce mobile's scorecard context rules.
  final ChessboardView viewSource;

  /// Event context for Board tabs opened from a tournament game list.
  ///
  /// Keeping this on the tab args makes the "other games in this event"
  /// table stable even after the tab navigates away from the Tournament
  /// Detail pane that originally supplied the list.
  final String tournamentTitle;
  final List<TournamentGameSummary> eventGames;
  final bool eventGamesLoading;

  /// Route/source context that produced the Board tab.
  ///
  /// For example, when a player-profile Games tab is filtered down to 129
  /// games and the user opens one of them, this list preserves those 129
  /// games even if the active game also belongs to a broader event.
  final String routeTitle;
  final List<TournamentGameSummary> routeGames;
  final BoardTabGamesContinuation? routeGamesContinuation;

  /// Database/library context for Board tabs opened from a game database.
  ///
  /// Mirrors [eventGames], but represents the source database, folder, import
  /// preview, or position-search result set rather than a live event.
  final String databaseTitle;
  final List<TournamentGameSummary> databaseGames;
  final BoardTabDatabaseGamesPagination? databaseGamesPagination;
  final BoardTabGamesContinuation? databaseGamesContinuation;

  /// Provider-backed continuation for event/favorites context.
  final BoardTabGamesContinuation? eventGamesContinuation;

  /// Selection key for [eventGames] / [databaseGames] rows when [gameId] is
  /// intentionally null (for example local saved analyses should not subscribe
  /// the Board pane to a Supabase live game stream).
  final String? gameListSelectedId;

  /// Original user-library record, when this board tab came from the user's own
  /// cloud library or local PGN database. Save can then update that record
  /// instead of treating the edited game as a detached import.
  final BoardTabLibrarySaveOrigin? librarySaveOrigin;

  BoardTabGameArgs copyWith({
    String? gameId,
    String? pgn,
    String? label,
    String? whiteName,
    String? blackName,
    String? whiteFederation,
    String? blackFederation,
    String? whiteTitle,
    String? blackTitle,
    int? whiteRating,
    int? blackRating,
    int? whiteFideId,
    int? blackFideId,
    bool? initialBoardFlipped,
    String? fenSeed,
    String? initialFen,
    GamesTourModel? sourceGame,
    ChessboardView? viewSource,
    String? tournamentTitle,
    List<TournamentGameSummary>? eventGames,
    bool? eventGamesLoading,
    String? routeTitle,
    List<TournamentGameSummary>? routeGames,
    BoardTabGamesContinuation? routeGamesContinuation,
    String? databaseTitle,
    List<TournamentGameSummary>? databaseGames,
    BoardTabDatabaseGamesPagination? databaseGamesPagination,
    BoardTabGamesContinuation? databaseGamesContinuation,
    BoardTabGamesContinuation? eventGamesContinuation,
    String? gameListSelectedId,
    BoardTabLibrarySaveOrigin? librarySaveOrigin,
  }) {
    return BoardTabGameArgs(
      gameId: gameId ?? this.gameId,
      pgn: pgn ?? this.pgn,
      label: label ?? this.label,
      whiteName: whiteName ?? this.whiteName,
      blackName: blackName ?? this.blackName,
      whiteFederation: whiteFederation ?? this.whiteFederation,
      blackFederation: blackFederation ?? this.blackFederation,
      whiteTitle: whiteTitle ?? this.whiteTitle,
      blackTitle: blackTitle ?? this.blackTitle,
      whiteRating: whiteRating ?? this.whiteRating,
      blackRating: blackRating ?? this.blackRating,
      whiteFideId: whiteFideId ?? this.whiteFideId,
      blackFideId: blackFideId ?? this.blackFideId,
      initialBoardFlipped: initialBoardFlipped ?? this.initialBoardFlipped,
      fenSeed: fenSeed ?? this.fenSeed,
      initialFen: initialFen ?? this.initialFen,
      sourceGame: sourceGame ?? this.sourceGame,
      viewSource: viewSource ?? this.viewSource,
      tournamentTitle: tournamentTitle ?? this.tournamentTitle,
      eventGames: eventGames ?? this.eventGames,
      eventGamesLoading: eventGamesLoading ?? this.eventGamesLoading,
      routeTitle: routeTitle ?? this.routeTitle,
      routeGames: routeGames ?? this.routeGames,
      routeGamesContinuation:
          routeGamesContinuation ?? this.routeGamesContinuation,
      databaseTitle: databaseTitle ?? this.databaseTitle,
      databaseGames: databaseGames ?? this.databaseGames,
      databaseGamesPagination:
          databaseGamesPagination ?? this.databaseGamesPagination,
      databaseGamesContinuation:
          databaseGamesContinuation ?? this.databaseGamesContinuation,
      eventGamesContinuation:
          eventGamesContinuation ?? this.eventGamesContinuation,
      gameListSelectedId: gameListSelectedId ?? this.gameListSelectedId,
      librarySaveOrigin: librarySaveOrigin ?? this.librarySaveOrigin,
    );
  }
}

enum BoardTabGamesContinuationKind {
  favorites,
  countrymen,
  playerProfile,
  twicDatabase,
}

@immutable
class BoardTabGamesContinuation {
  const BoardTabGamesContinuation({required this.kind, this.argument});

  const BoardTabGamesContinuation.favorites()
    : kind = BoardTabGamesContinuationKind.favorites,
      argument = null;

  const BoardTabGamesContinuation.countrymen()
    : kind = BoardTabGamesContinuationKind.countrymen,
      argument = null;

  const BoardTabGamesContinuation.playerProfile(Object playerKey)
    : kind = BoardTabGamesContinuationKind.playerProfile,
      argument = playerKey;

  const BoardTabGamesContinuation.twicDatabase()
    : kind = BoardTabGamesContinuationKind.twicDatabase,
      argument = null;

  final BoardTabGamesContinuationKind kind;

  /// Provider-family argument for keyed sources. Kept intentionally loose so
  /// this desktop state object does not depend on every source pane's provider
  /// type; the rail casts it at the load boundary.
  final Object? argument;

  String get signature => switch (kind) {
    BoardTabGamesContinuationKind.favorites => 'favorites',
    BoardTabGamesContinuationKind.countrymen => 'countrymen',
    BoardTabGamesContinuationKind.playerProfile => 'playerProfile:$argument',
    BoardTabGamesContinuationKind.twicDatabase => 'twicDatabase',
  };
}

enum BoardTabPositionGamesApi { indexedPosition, exactFen }

@immutable
class BoardTabDatabaseGamesPagination {
  const BoardTabDatabaseGamesPagination({
    required this.query,
    required this.nextPageNumber,
    required this.hasMore,
    required this.exactFenSearch,
    this.resolvedApi,
    this.totalCount,
  });

  final GamebasePositionGamesQuery query;
  final int nextPageNumber;
  final bool hasMore;
  final bool exactFenSearch;
  final BoardTabPositionGamesApi? resolvedApi;
  final int? totalCount;

  BoardTabDatabaseGamesPagination copyWith({
    GamebasePositionGamesQuery? query,
    int? nextPageNumber,
    bool? hasMore,
    bool? exactFenSearch,
    BoardTabPositionGamesApi? resolvedApi,
    int? totalCount,
  }) {
    return BoardTabDatabaseGamesPagination(
      query: query ?? this.query,
      nextPageNumber: nextPageNumber ?? this.nextPageNumber,
      hasMore: hasMore ?? this.hasMore,
      exactFenSearch: exactFenSearch ?? this.exactFenSearch,
      resolvedApi: resolvedApi ?? this.resolvedApi,
      totalCount: totalCount ?? this.totalCount,
    );
  }
}

/// Per-tab Board-game args, keyed by [DesktopTab.id]. The plain Board tab
/// has no entry here — its absence is what marks the tab as "scratch".
final boardTabGameArgsByTabIdProvider =
    StateProvider<Map<String, BoardTabGameArgs>>(
      (_) => const <String, BoardTabGameArgs>{},
    );

/// Board player-name taps can show event score cards only when the tab still
/// carries a tournament/live source game with a usable tour id.
GamesTourModel? boardPlayerTapEventContextGame(GamesTourModel? sourceGame) {
  if (sourceGame == null || sourceGame.tourId.trim().isEmpty) {
    return null;
  }
  return sourceGame;
}

@immutable
class BoardGameInsertRequest {
  const BoardGameInsertRequest({
    required this.id,
    required this.pgn,
    required this.sourceLabel,
  });

  final int id;
  final String pgn;
  final String sourceLabel;
}

final boardGameInsertRequestProvider = StateProvider<BoardGameInsertRequest?>(
  (ref) => null,
);

/// Open a Board tab focused on a specific game. Without [replaceActive],
/// [reuseExisting] controls whether another tab with the same `gameId` can
/// be activated instead of creating a duplicate.
/// Set [replaceActive] for browser-style plain-link navigation: the active
/// tab is converted into a Board tab and receives its own copy of [args],
/// even if another tab is already showing the same game.
/// The label is used as the tab title (the rich chip pulls fields out
/// of the args to render flags + names + ELO).
///
/// [reuseExisting] (default true) honours the "click an already-open
/// game → activate that tab" semantics. Pass false to always spawn a
/// fresh tab — used by Cmd/Ctrl+T's duplicate path.
///
/// [focus] (default true) controls whether the freshly opened tab
/// becomes the active one. Setting it to false appends the tab in the
/// background — the user stays on whatever they were looking at. Has
/// no effect when an existing tab is reused.
String openBoardGameTab(
  WidgetRef ref,
  BoardTabGameArgs args, {
  bool reuseExisting = true,
  bool focus = true,
  bool replaceActive = false,
}) {
  return openBoardGameTabFromContainer(
    ProviderScope.containerOf(ref as BuildContext, listen: false),
    args,
    reuseExisting: reuseExisting,
    focus: focus,
    replaceActive: replaceActive,
  );
}

/// Container-flavored variant of [openBoardGameTab] for callers that need
/// to survive widget disposal — e.g. async tap handlers whose source
/// `WidgetRef` (a live-game card) can be unmounted mid-await. The
/// [ProviderContainer] is owned by the surrounding `ProviderScope`, so
/// reads remain valid even after the originating widget is gone.
String openBoardGameTabFromContainer(
  ProviderContainer container,
  BoardTabGameArgs args, {
  bool reuseExisting = true,
  bool focus = true,
  bool replaceActive = false,
}) {
  final tabsNotifier = container.read(desktopTabsProvider.notifier);
  final byTab = container.read(boardTabGameArgsByTabIdProvider);

  if (replaceActive && focus) {
    final activeId =
        tabsNotifier.navigateActive(TabKind.board, title: args.label) ??
        tabsNotifier.open(
          TabKind.board,
          title: args.label,
          reuseExisting: false,
        );
    tabsNotifier.rename(activeId, title: args.label);
    _putBoardGameArgs(container, activeId, args, previous: byTab[activeId]);
    return activeId;
  }

  if (reuseExisting && args.gameId != null) {
    for (final entry in byTab.entries) {
      if (entry.value.gameId == args.gameId) {
        if (focus) tabsNotifier.activate(entry.key);
        // Refresh args so changing PGN (live update arrived since first
        // open) sticks. Keeps the tab chip + board synced.
        _putBoardGameArgs(container, entry.key, args, previous: entry.value);
        return entry.key;
      }
    }
  }

  final tabId = tabsNotifier.open(
    TabKind.board,
    title: args.label,
    reuseExisting: false,
    focus: focus,
  );
  _putBoardGameArgs(container, tabId, args);
  return tabId;
}

void _putBoardGameArgs(
  ProviderContainer container,
  String tabId,
  BoardTabGameArgs args, {
  BoardTabGameArgs? previous,
}) {
  final previousGameId = previous?.gameId;
  final hasExistingFen = container.read(boardTabFenProvider).containsKey(tabId);
  final hasExistingSession = container
      .read(boardPaneSessionByTabIdProvider)
      .containsKey(tabId);
  if ((previous != null && previousGameId != args.gameId) ||
      (previous == null && (hasExistingFen || hasExistingSession))) {
    container.read(boardTabFenProvider.notifier).clear(tabId);
    container.read(boardPaneSessionByTabIdProvider.notifier).clear(tabId);
  }
  container.read(boardExplorerScopeByTabIdProvider.notifier).update((m) {
    if (!m.containsKey(tabId)) return m;
    final next = Map<String, BoardExplorerScope>.of(m)..remove(tabId);
    return next;
  });
  container
      .read(boardTabGameArgsByTabIdProvider.notifier)
      .update((m) => <String, BoardTabGameArgs>{...m, tabId: args});
}

/// Opens a detached PGN (file picker, file drop, import preview) in its own
/// Board tab. Detached PGNs deliberately carry no `gameId`, so the Board pane
/// never subscribes them to a live broadcast row and repeated opens create
/// independent analysis tabs.
String openDetachedPgnTab(
  WidgetRef ref, {
  required String label,
  required String pgn,
  bool focus = true,
}) {
  final title = label.trim().isEmpty ? 'PGN' : label.trim();
  return openBoardGameTab(
    ref,
    BoardTabGameArgs(pgn: pgn, label: title, whiteName: '', blackName: ''),
    reuseExisting: false,
    focus: focus,
  );
}
