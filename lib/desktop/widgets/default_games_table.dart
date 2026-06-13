import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/desktop/utils/library_multi_select.dart';
import 'package:chessever/desktop/widgets/adaptive_games_table.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show openTournamentGameTab;
import 'package:chessever/repository/gamebase/search/gamebase_search_models.dart';
import 'package:chessever/screens/chessboard/provider/chess_board_screen_provider_new.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/country_utils.dart';
import 'package:chessever/widgets/federation_flag.dart';

/// Shared desktop database-style games table.
///
/// This is the default games table for every desktop surface that renders a
/// table view of games. Hosts provide the already-filtered row set; this widget
/// owns the common columns, compact dark density, hover/selection decoration,
/// and sortable header behavior used by the player-profile Games tab.
class DefaultGamesTable extends ConsumerStatefulWidget {
  const DefaultGamesTable({
    super.key,
    required this.games,
    required this.controller,
    this.active = true,
    this.routeTitle,
    this.routeGamesContinuation,
    this.routeGames,
    this.selectedIds = const <String>{},
    this.selectionMode = false,
    this.onToggleSelection,
    this.onReplaceSelection,
    this.onOpenGame,
    this.onContext,
    this.footer,
    this.rowKeyPrefix = 'default-game-table',
    this.profilePlayerName,
    this.profilePlayerFideId,
    this.profileFederationFallback,
  });

  final bool active;
  final List<GamesTourModel> games;
  final ScrollController controller;
  final String? routeTitle;
  final BoardTabGamesContinuation? routeGamesContinuation;
  final List<GamesTourModel>? routeGames;
  final bool selectionMode;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelection;
  final ValueChanged<Set<String>>? onReplaceSelection;
  final void Function(GamesTourModel game, {required bool inNewTab})?
  onOpenGame;
  final Future<void> Function({
    required Offset globalPos,
    required GamesTourModel game,
  })?
  onContext;
  final Widget? footer;
  final String rowKeyPrefix;
  final String? profilePlayerName;
  final int? profilePlayerFideId;
  final String? profileFederationFallback;

  @override
  ConsumerState<DefaultGamesTable> createState() => _DefaultGamesTableState();
}

class _DefaultGamesTableState extends ConsumerState<DefaultGamesTable> {
  static const double _rowHeight = 34;
  static const double _headerHeight = 26;

  late final FocusNode _focusNode;
  AdaptiveSortState? _sortState;
  String? _highlightedGameId;
  int? _selectionAnchorIndex;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'default-games-table');
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  List<GamesTourModel> get _rows {
    final rows = List<GamesTourModel>.of(widget.games, growable: false);
    final sort = _sortState;
    if (sort == null) return rows;
    rows.sort((a, b) {
      final cmp = _compareGamesForSort(a, b, sort.field);
      return sort.direction == GamebaseSortDirection.asc ? cmp : -cmp;
    });
    return rows;
  }

  int _compareGamesForSort(
    GamesTourModel a,
    GamesTourModel b,
    GamebaseSortField field,
  ) {
    switch (field) {
      case GamebaseSortField.id:
        return _compareText(a.gameId, b.gameId);
      case GamebaseSortField.date:
        return _compareDate(_gameDate(a), _gameDate(b));
      case GamebaseSortField.eco:
        return _compareText(a.eco, b.eco);
      case GamebaseSortField.opening:
      case GamebaseSortField.variation:
        return _compareText(a.openingName, b.openingName);
      case GamebaseSortField.event:
        return _compareText(defaultGameEventLabel(a), defaultGameEventLabel(b));
      case GamebaseSortField.site:
        return _compareText(defaultGameSite(a), defaultGameSite(b));
      case GamebaseSortField.whiteName:
        return _compareText(a.whitePlayer.name, b.whitePlayer.name);
      case GamebaseSortField.blackName:
        return _compareText(a.blackPlayer.name, b.blackPlayer.name);
      case GamebaseSortField.whiteTitle:
        return _compareText(a.whitePlayer.title, b.whitePlayer.title);
      case GamebaseSortField.blackTitle:
        return _compareText(a.blackPlayer.title, b.blackPlayer.title);
      case GamebaseSortField.whiteFideId:
        return _compareInt(a.whitePlayer.fideId, b.whitePlayer.fideId);
      case GamebaseSortField.blackFideId:
        return _compareInt(a.blackPlayer.fideId, b.blackPlayer.fideId);
      case GamebaseSortField.whiteElo:
        return _compareInt(a.whitePlayer.rating, b.whitePlayer.rating);
      case GamebaseSortField.blackElo:
        return _compareInt(a.blackPlayer.rating, b.blackPlayer.rating);
      case GamebaseSortField.whiteFed:
        return _compareText(
          defaultGamePlayerFederation(
            a.whitePlayer,
            profilePlayerName: widget.profilePlayerName,
            profilePlayerFideId: widget.profilePlayerFideId,
            profileFederationFallback: widget.profileFederationFallback,
          ),
          defaultGamePlayerFederation(
            b.whitePlayer,
            profilePlayerName: widget.profilePlayerName,
            profilePlayerFideId: widget.profilePlayerFideId,
            profileFederationFallback: widget.profileFederationFallback,
          ),
        );
      case GamebaseSortField.blackFed:
        return _compareText(
          defaultGamePlayerFederation(
            a.blackPlayer,
            profilePlayerName: widget.profilePlayerName,
            profilePlayerFideId: widget.profilePlayerFideId,
            profileFederationFallback: widget.profileFederationFallback,
          ),
          defaultGamePlayerFederation(
            b.blackPlayer,
            profilePlayerName: widget.profilePlayerName,
            profilePlayerFideId: widget.profilePlayerFideId,
            profileFederationFallback: widget.profileFederationFallback,
          ),
        );
      case GamebaseSortField.whitePlayerId:
        return _compareText(
          a.whitePlayer.gamebasePlayerId,
          b.whitePlayer.gamebasePlayerId,
        );
      case GamebaseSortField.blackPlayerId:
        return _compareText(
          a.blackPlayer.gamebasePlayerId,
          b.blackPlayer.gamebasePlayerId,
        );
      case GamebaseSortField.timeControl:
        return _compareText(a.timeControl, b.timeControl);
      case GamebaseSortField.result:
        return _compareText(
          defaultGameResultText(a.gameStatus),
          defaultGameResultText(b.gameStatus),
        );
      case GamebaseSortField.avgElo:
        return _compareInt(a.avgElo, b.avgElo);
    }
  }

  void _highlight(GamesTourModel game) {
    if (widget.active && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
    if (_highlightedGameId == game.gameId) return;
    setState(() => _highlightedGameId = game.gameId);
  }

  void _replaceSelectionRange(
    List<GamesTourModel> rows, {
    required int from,
    required int to,
  }) {
    final replaceSelection = widget.onReplaceSelection;
    if (!widget.selectionMode || replaceSelection == null || rows.isEmpty) {
      return;
    }
    replaceSelection(
      LibraryMultiSelect.range(
        rowIds: [for (final row in rows) row.gameId],
        from: from,
        to: to,
      ),
    );
  }

  KeyEventResult _handleKey(
    FocusNode node,
    KeyEvent event,
    List<GamesTourModel> rows,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (rows.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final currentIndex = _currentHighlightedIndex(rows);
    int? nextIndex;
    if (key == LogicalKeyboardKey.arrowDown) {
      nextIndex = (currentIndex < 0 ? 0 : currentIndex + 1).clamp(
        0,
        rows.length - 1,
      );
    } else if (key == LogicalKeyboardKey.arrowUp) {
      nextIndex = (currentIndex < 0 ? 0 : currentIndex - 1).clamp(
        0,
        rows.length - 1,
      );
    } else if (key == LogicalKeyboardKey.pageDown) {
      nextIndex = (currentIndex < 0 ? 0 : currentIndex + _pageJump).clamp(
        0,
        rows.length - 1,
      );
    } else if (key == LogicalKeyboardKey.pageUp) {
      nextIndex = (currentIndex < 0 ? 0 : currentIndex - _pageJump).clamp(
        0,
        rows.length - 1,
      );
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final index = currentIndex < 0 ? 0 : currentIndex;
      _highlight(rows[index]);
      _openGame(rows[index], inNewTab: false);
      return KeyEventResult.handled;
    } else {
      return KeyEventResult.ignored;
    }

    final index = nextIndex.toInt();
    if (HardwareKeyboard.instance.isShiftPressed && widget.selectionMode) {
      final anchor = (_selectionAnchorIndex ?? currentIndex).clamp(
        0,
        rows.length - 1,
      );
      _selectionAnchorIndex = anchor.toInt();
      _replaceSelectionRange(rows, from: _selectionAnchorIndex!, to: index);
    } else {
      _selectionAnchorIndex = index;
    }
    _highlight(rows[index]);
    _scrollIndexIntoView(index);
    return KeyEventResult.handled;
  }

  int _currentHighlightedIndex(List<GamesTourModel> rows) {
    final id = _highlightedGameId;
    if (id == null) return -1;
    return rows.indexWhere((game) => game.gameId == id);
  }

  int get _pageJump {
    if (!widget.controller.hasClients) return 10;
    final viewport = widget.controller.position.viewportDimension;
    if (!viewport.isFinite || viewport <= 0) return 10;
    return (viewport / _rowHeight).floor().clamp(8, 30);
  }

  void _scrollIndexIntoView(int index) {
    if (!widget.controller.hasClients) return;
    final position = widget.controller.position;
    final rowTop = _headerHeight + (index * _rowHeight);
    final rowBottom = rowTop + _rowHeight;
    var target = position.pixels;
    if (rowTop < position.pixels) {
      target = rowTop;
    } else if (rowBottom > position.pixels + position.viewportDimension) {
      target = rowBottom - position.viewportDimension;
    } else {
      return;
    }
    widget.controller.animateTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOutCubic,
    );
  }

  void _selectRowInSelectionMode(
    GamesTourModel game,
    List<GamesTourModel> rows,
  ) {
    final index = rows.indexWhere((row) => row.gameId == game.gameId);
    if (index < 0) return;
    _highlight(game);
    if (HardwareKeyboard.instance.isShiftPressed &&
        widget.onReplaceSelection != null) {
      final anchor = (_selectionAnchorIndex ?? _currentHighlightedIndex(rows));
      final safeAnchor = (anchor < 0 ? index : anchor).clamp(
        0,
        rows.length - 1,
      );
      _selectionAnchorIndex = safeAnchor.toInt();
      _replaceSelectionRange(rows, from: _selectionAnchorIndex!, to: index);
      return;
    }
    _selectionAnchorIndex = index;
    widget.onToggleSelection?.call(game.gameId);
  }

  void _openGame(GamesTourModel game, {required bool inNewTab}) {
    final customOpen = widget.onOpenGame;
    if (customOpen != null) {
      customOpen(game, inNewTab: inNewTab);
      return;
    }
    unawaited(
      openTournamentGameTab(
        ref,
        game,
        defaultGameEventLabel(game),
        routeTitle: widget.routeTitle ?? defaultGameEventLabel(game),
        routeGames: widget.routeGames ?? widget.games,
        routeGamesContinuation: widget.routeGamesContinuation,
        focus: widget.active,
        reuseExisting: !inNewTab,
        replaceActive: !inNewTab,
        viewSource: ChessboardView.playerProfile,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Focus(
      focusNode: _focusNode,
      autofocus: widget.active,
      canRequestFocus: widget.active,
      onKeyEvent: (node, event) => _handleKey(node, event, rows),
      child: AdaptiveGamesTable<GamesTourModel>(
        columns: _buildColumns(rows),
        rows: rows,
        scrollController: widget.controller,
        rowMinHeight: _rowHeight,
        headerHeight: _headerHeight,
        minTableWidth: 1280,
        padding: const EdgeInsets.only(right: 6),
        sortState: _sortState,
        onSortChanged: (next) => setState(() => _sortState = next),
        rowDecorationBuilder: (game, hovered) {
          if (widget.selectedIds.contains(game.gameId) ||
              _highlightedGameId == game.gameId) {
            return BoxDecoration(
              color: kPrimaryColor.withValues(alpha: 0.16),
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
        rowKeyBuilder: (game) =>
            ValueKey('${widget.rowKeyPrefix}-${game.gameId}'),
        onRowTap: (game, {required bool inNewTab}) {
          if (widget.selectionMode) {
            _selectRowInSelectionMode(game, rows);
            return;
          }
          // Table view: a single click only selects/highlights the row.
          // Opening a game belongs to double-click (Cmd/Ctrl held opens a new
          // tab) so accidental single clicks no longer swap the active board.
          _highlight(game);
        },
        onRowDoubleTap: (game, {required bool inNewTab}) {
          if (widget.selectionMode) {
            _selectRowInSelectionMode(game, rows);
            return;
          }
          _highlight(game);
          _openGame(game, inNewTab: inNewTab);
        },
        onRowSecondaryTap: widget.onContext == null
            ? null
            : (game, position) =>
                  unawaited(widget.onContext!(globalPos: position, game: game)),
        footer: widget.footer,
      ),
    );
  }

  List<AdaptiveColumn<GamesTourModel>> _buildColumns(
    List<GamesTourModel> rows,
  ) {
    return [
      AdaptiveColumn<GamesTourModel>(
        id: 'number',
        label: '#',
        minWidth: 20,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, game) => _DefaultGamesNumberCell(
          value: rows.indexWhere((row) => row.gameId == game.gameId) + 1,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'white',
        label: 'WHITE',
        sortField: GamebaseSortField.whiteName,
        cellBuilder: (_, game) => _DefaultGamesPlayerCell(
          player: game.whitePlayer,
          profilePlayerName: widget.profilePlayerName,
          profilePlayerFideId: widget.profilePlayerFideId,
          profileFederationFallback: widget.profileFederationFallback,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'whiteElo',
        label: 'ELO W',
        sortField: GamebaseSortField.whiteElo,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, game) => _DefaultGamesNumberCell(
          value: game.whitePlayer.rating > 0 ? game.whitePlayer.rating : null,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'black',
        label: 'BLACK',
        sortField: GamebaseSortField.blackName,
        cellBuilder: (_, game) => _DefaultGamesPlayerCell(
          player: game.blackPlayer,
          profilePlayerName: widget.profilePlayerName,
          profilePlayerFideId: widget.profilePlayerFideId,
          profileFederationFallback: widget.profileFederationFallback,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'blackElo',
        label: 'ELO B',
        sortField: GamebaseSortField.blackElo,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, game) => _DefaultGamesNumberCell(
          value: game.blackPlayer.rating > 0 ? game.blackPlayer.rating : null,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'result',
        label: 'RES',
        sortField: GamebaseSortField.result,
        headerAlignment: Alignment.center,
        cellAlignment: Alignment.center,
        cellBuilder: (_, game) => _DefaultGamesResultCell(
          result: defaultGameResultText(game.gameStatus),
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'date',
        label: 'DATE',
        sortField: GamebaseSortField.date,
        headerAlignment: Alignment.centerRight,
        cellAlignment: Alignment.centerRight,
        cellBuilder: (_, game) => _DefaultGamesTextCell(
          value: defaultGameDateLabel(game),
          color: kWhiteColor70,
          maxWidth: 88,
          align: TextAlign.right,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'event',
        label: 'EVENT',
        sortField: GamebaseSortField.event,
        cellBuilder: (_, game) => _DefaultGamesTextCell(
          value: defaultGameEventLabel(game),
          color: kWhiteColor,
          maxWidth: 240,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'round',
        label: 'ROUND',
        cellBuilder: (_, game) => _DefaultGamesTextCell(
          value: defaultGameRoundLabel(game),
          color: kWhiteColor70,
          maxWidth: 96,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'eco',
        label: 'ECO',
        sortField: GamebaseSortField.eco,
        cellBuilder: (_, game) => _DefaultGamesTextCell(
          value: game.eco ?? '—',
          color: kWhiteColor70,
          maxWidth: 44,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'opening',
        label: 'OPENING',
        sortField: GamebaseSortField.opening,
        cellBuilder: (_, game) => _DefaultGamesTextCell(
          value: game.openingName ?? '—',
          color: kWhiteColor70,
          maxWidth: 260,
        ),
      ),
      AdaptiveColumn<GamesTourModel>(
        id: 'site',
        label: 'SITE',
        sortField: GamebaseSortField.site,
        cellBuilder: (_, game) => _DefaultGamesTextCell(
          value: defaultGameSite(game),
          color: kWhiteColor70,
          maxWidth: 160,
        ),
      ),
    ];
  }
}

class _DefaultGamesTextCell extends StatelessWidget {
  const _DefaultGamesTextCell({
    required this.value,
    required this.color,
    required this.maxWidth,
    this.align = TextAlign.left,
  });

  final String value;
  final Color color;
  final double maxWidth;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Text(
        value.trim().isEmpty ? '—' : value.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: TextStyle(color: color, fontSize: 11.5, height: 1.1),
      ),
    );
  }
}

class _DefaultGamesNumberCell extends StatelessWidget {
  const _DefaultGamesNumberCell({required this.value});

  final int? value;

  @override
  Widget build(BuildContext context) {
    return Text(
      (value == null || value! <= 0) ? '—' : value.toString(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: const TextStyle(
        color: kWhiteColor70,
        fontSize: 11.5,
        height: 1.1,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _DefaultGamesResultCell extends StatelessWidget {
  const _DefaultGamesResultCell({required this.result});

  final String result;

  @override
  Widget build(BuildContext context) {
    final text = result.trim().isEmpty ? '*' : result.trim();
    return Container(
      constraints: const BoxConstraints(minWidth: 34),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: kBlack3Color,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: kDividerColor),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: kWhiteColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _DefaultGamesPlayerCell extends StatelessWidget {
  const _DefaultGamesPlayerCell({
    required this.player,
    this.profilePlayerName,
    this.profilePlayerFideId,
    this.profileFederationFallback,
  });

  final PlayerCard player;
  final String? profilePlayerName;
  final int? profilePlayerFideId;
  final String? profileFederationFallback;

  @override
  Widget build(BuildContext context) {
    final federation = defaultGamePlayerFederation(
      player,
      profilePlayerName: profilePlayerName,
      profilePlayerFideId: profilePlayerFideId,
      profileFederationFallback: profileFederationFallback,
    );
    final iso2 = federation.isEmpty ? '' : CountryUtils.toIso2Code(federation);
    final title = player.title.trim();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 170),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iso2.isNotEmpty) ...[
            FederationFlag(
              federation: iso2,
              height: 14,
              width: 20,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(width: 6),
          ],
          if (title.isNotEmpty) ...[
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kPrimaryColor,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                height: 1.1,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              defaultGamePlayerName(player.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

DateTime? _gameDate(GamesTourModel game) => game.bucketDate;

String defaultGameEventLabel(GamesTourModel game) {
  return _resolveDefaultGameEventName(
        metadataEvent: null,
        tourSlug: game.tourSlug,
        tourId: game.tourId,
      ) ??
      'Event';
}

String defaultGameSite(GamesTourModel game) {
  if (game.isOnline) return 'Online';
  final slug = game.tourSlug?.trim() ?? '';
  if (slug.isEmpty) return '—';
  return _humanizeDefaultGameSlug(slug);
}

String defaultGamePlayerName(String rawName) {
  var name = rawName.trim();
  if (name.isEmpty) return name;
  name = name.replaceFirst(
    RegExp(r'^(GM|IM|FM|CM|WGM|WIM|WFM|WCM)\s+', caseSensitive: false),
    '',
  );

  final commaIndex = name.indexOf(',');
  if (commaIndex >= 0) {
    final last = name.substring(0, commaIndex).trim();
    final first = name.substring(commaIndex + 1).trim();
    if (last.isEmpty || first.isEmpty) return name;
    final initial = _firstNameInitial(first);
    return initial == null ? last : '$last, $initial.';
  }

  final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return name;
  final initial = _firstNameInitial(parts.first);
  if (initial == null) return name;
  return '${parts.sublist(1).join(' ')}, $initial.';
}

String defaultGameRoundLabel(GamesTourModel game) {
  final candidates = <String?>[game.roundSlug, game.roundId];
  for (final candidate in candidates) {
    final value = candidate?.trim() ?? '';
    if (value.isEmpty || _looksLikeEcoCode(value)) continue;
    return value;
  }
  return '—';
}

String? _firstNameInitial(String firstName) {
  final match = RegExp(r'[A-Za-zÀ-ÖØ-öø-ÿ]').firstMatch(firstName.trim());
  return match?.group(0)?.toUpperCase();
}

bool _looksLikeEcoCode(String value) {
  return RegExp(
    r'^[A-E][0-9]{2}$',
    caseSensitive: false,
  ).hasMatch(value.trim());
}

String? _resolveDefaultGameEventName({
  required String? metadataEvent,
  required String? tourSlug,
  required String? tourId,
}) {
  final fromMetadata = metadataEvent?.trim() ?? '';
  if (_isReadableDefaultGameEventName(fromMetadata)) return fromMetadata;

  final fromSlug = tourSlug?.trim() ?? '';
  if (_isReadableDefaultGameEventName(fromSlug)) {
    return _humanizeDefaultGameSlug(fromSlug);
  }

  final fromId = tourId?.trim() ?? '';
  if (_isReadableDefaultGameEventName(fromId)) return fromId;
  return null;
}

bool _isReadableDefaultGameEventName(String value) {
  if (value.isEmpty) return false;
  final lower = value.toLowerCase();
  if (lower == 'library' ||
      lower == 'gamebase' ||
      lower == 'opening_explorer' ||
      lower == 'import_preview') {
    return false;
  }
  return !_looksLikeOpaqueDefaultGameEventId(value);
}

bool _looksLikeOpaqueDefaultGameEventId(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return false;
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  if (uuid.hasMatch(text)) return true;
  if (RegExp(r'^[0-9a-f]{24}$', caseSensitive: false).hasMatch(text)) {
    return true;
  }
  return RegExp(r'^[0-9a-f]{12,64}$', caseSensitive: false).hasMatch(text);
}

String _humanizeDefaultGameSlug(String value) {
  if (!value.contains('-') && !value.contains('_')) return value;
  final words = value
      .split(RegExp(r'[-_]+'))
      .where((s) => s.isNotEmpty)
      .toList();
  if (words.isEmpty) return value;
  return words
      .map((word) {
        final lower = word.toLowerCase();
        return '${lower[0].toUpperCase()}${lower.substring(1)}';
      })
      .join(' ');
}

String defaultGameDateLabel(GamesTourModel game) {
  final date = _gameDate(game);
  if (date == null) return '—';
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

String defaultGameResultText(GameStatus status) {
  switch (status) {
    case GameStatus.whiteWins:
      return '1-0';
    case GameStatus.blackWins:
      return '0-1';
    case GameStatus.draw:
      return '½-½';
    case GameStatus.ongoing:
      return '*';
    case GameStatus.unknown:
      return '';
  }
}

String defaultGamePlayerFederation(
  PlayerCard player, {
  String? profilePlayerName,
  int? profilePlayerFideId,
  String? profileFederationFallback,
}) {
  final fed = _playerFederation(player);
  final fallback = profileFederationFallback?.trim() ?? '';
  if (fallback.isEmpty || fallback.toUpperCase() == 'FID') return fed;
  if (fed.isNotEmpty && fed.toUpperCase() != 'FID') return fed;
  if (!_isProfilePlayer(
    player,
    profilePlayerName: profilePlayerName,
    profilePlayerFideId: profilePlayerFideId,
  )) {
    return fed;
  }
  return fallback;
}

String _playerFederation(PlayerCard player) {
  final fed = player.federation.trim();
  if (fed.isNotEmpty) return fed;
  return player.countryCode.trim();
}

bool _isProfilePlayer(
  PlayerCard player, {
  String? profilePlayerName,
  int? profilePlayerFideId,
}) {
  final fideId = profilePlayerFideId;
  if (fideId != null && fideId > 0 && player.fideId == fideId) return true;

  final profileName = _normalizePlayerNameForMatch(profilePlayerName ?? '');
  if (profileName.isEmpty) return false;
  return _normalizePlayerNameForMatch(player.name) == profileName;
}

String _normalizePlayerNameForMatch(String value) {
  var normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) return '';
  normalized = normalized.replaceFirst(
    RegExp(r'^(gm|im|fm|cm|wgm|wim|wfm|wcm)\s+', caseSensitive: false),
    '',
  );
  final commaIndex = normalized.indexOf(',');
  if (commaIndex >= 0) {
    final last = normalized.substring(0, commaIndex).trim();
    final first = normalized.substring(commaIndex + 1).trim();
    normalized = '$first $last';
  }
  return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

int _compareText(String? a, String? b) =>
    (a ?? '').toLowerCase().compareTo((b ?? '').toLowerCase());

int _compareInt(int? a, int? b) => (a ?? -1).compareTo(b ?? -1);

int _compareDate(DateTime? a, DateTime? b) {
  final av = a?.millisecondsSinceEpoch ?? -1;
  final bv = b?.millisecondsSinceEpoch ?? -1;
  return av.compareTo(bv);
}
