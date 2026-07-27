import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/tournament_detail_pane.dart'
    show tournamentDetailStandingsSearchByTabIdProvider;
import 'package:chessever/desktop/state/active_player.dart';
import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/cursor_mode.dart';
import 'package:chessever/desktop/widgets/desktop_search_field.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/spring_scroll_physics.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart'
    show openTournamentGameTab;
import 'package:chessever/screens/player_profile/player_profile_data_source.dart';
import 'package:chessever/services/fide_photo_service.dart';
import 'package:chessever/screens/standings/player_standing_model.dart';
import 'package:chessever/screens/standings/score_card_screen.dart'
    show
        scoreCardGamesContextProvider,
        scoreCardPlayerProfileDataSourceProvider;
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/location_service_provider.dart';
import 'package:chessever/widgets/federation_flag.dart';
import 'package:chessever/widgets/player_initials_avatar.dart';

typedef StandingsPhotoResolver = Future<String?> Function(String? fideId);
typedef StandingsGameOpener =
    void Function(GamesTourModel game, List<GamesTourModel> eventGames);

@visibleForTesting
List<GamesTourModel> scopeTournamentStandingsGames(
  PlayerTourStandingsSnapshot snapshot,
  Iterable<GamesTourModel> games,
) {
  final tourIds = {
    for (final tourId in snapshot.tourIds)
      if (tourId.trim().isNotEmpty) tourId.trim(),
  };
  if (tourIds.isEmpty) return const <GamesTourModel>[];
  return List<GamesTourModel>.unmodifiable(
    games.where((game) => tourIds.contains(game.tourId.trim())),
  );
}

@visibleForTesting
TournamentStandingsRoundTable buildTournamentStandingsRoundTable({
  required List<PlayerStandingModel> standings,
  required List<GamesTourModel> games,
}) {
  final standingIndex = _TournamentStandingIdentityIndex(standings);

  final uniqueGames = <String, GamesTourModel>{};
  for (final game in games) {
    final existing = uniqueGames[game.gameId];
    if (existing == null ||
        (!existing.gameStatus.isFinished && game.gameStatus.isFinished)) {
      uniqueGames[game.gameId] = game;
    }
  }

  final cellsByPlayerAndStage =
      <String, Map<String, List<TournamentStandingsRoundCell>>>{};
  final stages = <String, _TournamentStandingsStage>{};
  final orderedGames =
      uniqueGames.values.toList()..sort((a, b) => a.gameId.compareTo(b.gameId));
  for (final game in orderedGames) {
    final stage = _standingsStage(game);
    if (stage == null) continue;
    stages.putIfAbsent(stage.key, () => stage);

    void addForSide({required bool playedWhite}) {
      final playerCard = playedWhite ? game.whitePlayer : game.blackPlayer;
      final opponentCard = playedWhite ? game.blackPlayer : game.whitePlayer;
      final standing = standingIndex.find(playerCard);
      if (standing == null) return;
      final opponentStanding = standingIndex.find(opponentCard);
      final opponentRank = standingIndex.rankFor(opponentCard);
      final opponentRating =
          (opponentStanding?.score ?? 0) > 0
              ? opponentStanding!.score
              : (opponentCard.rating > 0 ? opponentCard.rating : null);
      final playerKey = _primaryStandingKey(standing.fideId, standing.name);
      final playerStages = cellsByPlayerAndStage.putIfAbsent(
        playerKey,
        () => {},
      );
      final candidate = TournamentStandingsRoundCell(
        game: game,
        round: stage.round,
        resultText: _resultForPlayer(game.gameStatus, playedWhite),
        playedWhite: playedWhite,
        opponentName: opponentStanding?.name ?? opponentCard.name,
        opponentRank: opponentRank,
        opponentRating: opponentRating,
        isOngoing:
            game.gameStatus == GameStatus.ongoing ||
            game.gameStatus == GameStatus.unknown,
      );
      playerStages.putIfAbsent(stage.key, () => []).add(candidate);
    }

    addForSide(playedWhite: true);
    addForSide(playedWhite: false);
  }

  final sortedStages = stages.values.toList()..sort();
  final columns = <TournamentStandingsColumn>[];
  final cells = <String, Map<String, TournamentStandingsRoundCell>>{};
  for (final stage in sortedStages) {
    var slotCount = 0;
    for (final playerStages in cellsByPlayerAndStage.values) {
      final stageCells = playerStages[stage.key];
      if (stageCells == null) continue;
      stageCells.sort((a, b) => a.game.gameId.compareTo(b.game.gameId));
      slotCount = math.max(slotCount, stageCells.length);
    }
    for (var slot = 0; slot < slotCount; slot += 1) {
      columns.add(
        TournamentStandingsColumn(
          id: slotCount == 1 ? stage.id : '${stage.id}-${slot + 1}',
          label: slotCount == 1 ? stage.label : '${stage.label} · ${slot + 1}',
          round: stage.round,
          stageKey: stage.key,
          slot: slot,
        ),
      );
    }
  }

  for (final playerEntry in cellsByPlayerAndStage.entries) {
    final playerCells = <String, TournamentStandingsRoundCell>{};
    for (final column in columns) {
      final stageCells = playerEntry.value[column.stageKey];
      if (stageCells != null && column.slot < stageCells.length) {
        playerCells[column.id] = stageCells[column.slot];
      }
    }
    cells[playerEntry.key] = playerCells;
  }

  return TournamentStandingsRoundTable(columns: columns, cellsByPlayer: cells);
}

class TournamentStandingsRoundTable {
  const TournamentStandingsRoundTable({
    required this.columns,
    required Map<String, Map<String, TournamentStandingsRoundCell>>
    cellsByPlayer,
  }) : _cellsByPlayer = cellsByPlayer;

  final List<TournamentStandingsColumn> columns;
  final Map<String, Map<String, TournamentStandingsRoundCell>> _cellsByPlayer;

  List<int> get rounds => <int>{
    for (final column in columns)
      if (column.round case final round?) round,
  }.toList(growable: false);

  TournamentStandingsRoundCell? cellFor(PlayerStandingModel player, int round) {
    for (final column in columns) {
      if (column.round == round) return cellForColumn(player, column);
    }
    return null;
  }

  TournamentStandingsRoundCell? cellForColumn(
    PlayerStandingModel player,
    TournamentStandingsColumn column,
  ) {
    return _cellsByPlayer[_primaryStandingKey(
      player.fideId,
      player.name,
    )]?[column.id];
  }

  List<TournamentStandingsRoundCell> cellsFor(PlayerStandingModel player) {
    final playerCells =
        _cellsByPlayer[_primaryStandingKey(player.fideId, player.name)];
    if (playerCells == null) return const [];
    return [
      for (final column in columns)
        if (playerCells[column.id] case final cell?) cell,
    ];
  }
}

class TournamentStandingsColumn {
  const TournamentStandingsColumn({
    required this.id,
    required this.label,
    required this.round,
    required this.stageKey,
    required this.slot,
  });

  final String id;
  final String label;
  final int? round;
  final String stageKey;
  final int slot;

  double get width => math.min(120, math.max(46, label.length * 7 + 16));
}

class TournamentStandingsRoundCell {
  const TournamentStandingsRoundCell({
    required this.game,
    required this.round,
    required this.resultText,
    required this.playedWhite,
    required this.opponentName,
    required this.opponentRank,
    required this.opponentRating,
    required this.isOngoing,
  });

  final GamesTourModel game;
  final int? round;
  final String resultText;
  final bool playedWhite;
  final String opponentName;
  final int? opponentRank;
  final int? opponentRating;
  final bool isOngoing;

  String get tooltipMessage {
    final rank = opponentRank == null ? '' : '#$opponentRank ';
    final rating = opponentRating == null ? '' : ' · $opponentRating';
    return '$rank$opponentName$rating';
  }
}

class _TournamentStandingIdentityIndex {
  _TournamentStandingIdentityIndex(List<PlayerStandingModel> standings) {
    for (var index = 0; index < standings.length; index++) {
      final standing = standings[index];
      final rank = standing.overallRank ?? index + 1;
      final fideId = standing.fideId;
      if (fideId != null && fideId > 0) {
        _standingByFideId.putIfAbsent(fideId, () => standing);
        _rankByFideId.putIfAbsent(fideId, () => rank);
      }

      final name = _normalizeStandingName(standing.name);
      if (name.isEmpty || _ambiguousNames.contains(name)) continue;
      final existing = _standingByName[name];
      if (existing != null &&
          _primaryStandingKey(existing.fideId, existing.name) !=
              _primaryStandingKey(standing.fideId, standing.name)) {
        _ambiguousNames.add(name);
        _standingByName.remove(name);
        _rankByName.remove(name);
      } else {
        _standingByName.putIfAbsent(name, () => standing);
        _rankByName.putIfAbsent(name, () => rank);
      }
    }
  }

  final Map<int, PlayerStandingModel> _standingByFideId = {};
  final Map<int, int> _rankByFideId = {};
  final Map<String, PlayerStandingModel> _standingByName = {};
  final Map<String, int> _rankByName = {};
  final Set<String> _ambiguousNames = {};

  PlayerStandingModel? find(PlayerCard player) {
    final fideId = player.fideId;
    if (fideId != null && fideId > 0) {
      return _standingByFideId[fideId];
    }
    final name = _normalizeStandingName(player.name);
    if (name.isEmpty || _ambiguousNames.contains(name)) return null;
    return _standingByName[name];
  }

  int? rankFor(PlayerCard player) {
    final fideId = player.fideId;
    if (fideId != null && fideId > 0) return _rankByFideId[fideId];
    final name = _normalizeStandingName(player.name);
    if (name.isEmpty || _ambiguousNames.contains(name)) return null;
    return _rankByName[name];
  }
}

String _primaryStandingKey(int? fideId, String name) {
  return fideId != null && fideId > 0
      ? 'fide:$fideId'
      : 'name:${_normalizeStandingName(name)}';
}

String _normalizeStandingName(String name) {
  return name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}

int? _standingsRoundNumber(GamesTourModel game) {
  int? parse(String value, {required bool allowBareNumber}) {
    final roundMatch = RegExp(
      r'(?:round|r)[\s_-]*(\d+)',
      caseSensitive: false,
    ).firstMatch(value);
    if (roundMatch != null) return int.tryParse(roundMatch.group(1)!);
    if (!allowBareNumber) return null;
    final numberMatch = RegExp(r'(\d+)').firstMatch(value);
    return numberMatch == null ? null : int.tryParse(numberMatch.group(1)!);
  }

  final slug = game.roundSlug?.trim();
  if (slug != null && slug.isNotEmpty) {
    return parse(slug, allowBareNumber: true);
  }
  return parse(game.roundId.trim(), allowBareNumber: false);
}

_TournamentStandingsStage? _standingsStage(GamesTourModel game) {
  final round = _standingsRoundNumber(game);
  if (round != null) {
    return _TournamentStandingsStage(
      key: 'round:$round',
      id: '$round',
      label: '$round',
      round: round,
    );
  }

  final slug = game.roundSlug?.trim() ?? '';
  final rawLabel = slug.isNotEmpty ? slug : game.roundId.trim();
  final normalized = rawLabel
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return null;
  final label = switch (normalized) {
    'final' || 'finals' => 'Finals',
    'tie break' || 'tiebreak' || 'tie breaks' || 'tiebreaks' => 'Tiebreak',
    'armageddon' => 'Armageddon',
    _ => normalized
        .split(' ')
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' '),
  };
  return _TournamentStandingsStage(
    key: 'stage:$normalized',
    id: 'stage-${normalized.replaceAll(' ', '-')}',
    label: label,
    round: null,
  );
}

class _TournamentStandingsStage
    implements Comparable<_TournamentStandingsStage> {
  const _TournamentStandingsStage({
    required this.key,
    required this.id,
    required this.label,
    required this.round,
  });

  final String key;
  final String id;
  final String label;
  final int? round;

  int get _namedOrder => switch (label.toLowerCase()) {
    'finals' => 0,
    'tiebreak' => 1,
    'armageddon' => 2,
    _ => 3,
  };

  @override
  int compareTo(_TournamentStandingsStage other) {
    final leftRound = round;
    final rightRound = other.round;
    if (leftRound != null && rightRound != null) {
      return leftRound.compareTo(rightRound);
    }
    if (leftRound != null) return -1;
    if (rightRound != null) return 1;
    final order = _namedOrder.compareTo(other._namedOrder);
    return order != 0 ? order : label.compareTo(other.label);
  }
}

String _resultForPlayer(GameStatus status, bool playedWhite) {
  return switch (status) {
    GameStatus.whiteWins => playedWhite ? '1' : '0',
    GameStatus.blackWins => playedWhite ? '0' : '1',
    GameStatus.draw => '½',
    GameStatus.ongoing || GameStatus.unknown => '•',
  };
}

/// Standings sub-view of the Tournament Detail.
///
/// Uses [playerTourScreenProvider] to surface the ranked desktop standings with
/// player, rating, and event score columns.
class TournamentStandingsView extends HookConsumerWidget {
  const TournamentStandingsView({
    super.key,
    required this.tabId,
    required this.tournamentId,
    this.tournamentTitle = '',
    this.photoResolver,
    this.gameOpener,
  });

  final String tabId;
  final String tournamentId;
  final String tournamentTitle;
  final StandingsPhotoResolver? photoResolver;
  final StandingsGameOpener? gameOpener;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standings = ref.watch(playerTourStandingsSnapshotProvider);
    final openGeneration = useRef(0);
    final standingsScope = standings.valueOrNull;
    final officialRosterByTourId =
        <String, AsyncValue<List<PlayerStandingModel>>>{
          for (final tourId in standingsScope?.tourIds ?? const <String>{})
            tourId: ref.watch(tournamentRosterStandingsProvider(tourId)),
        };
    // Source of truth lives in the provider so the search text restores
    // after the tab.kind flip to Board and back. The controller is local
    // because TextEditingController itself can't survive widget disposal,
    // but its initial text is seeded from the persisted query.
    final query = ref.watch(
      tournamentDetailStandingsSearchByTabIdProvider(tabId),
    );
    final searchController = useTextEditingController(text: query);
    final horizontalController = useScrollController();
    final games = ref.watch(mergedTournamentGamesProvider);
    // If the provider is mutated by another path (e.g. tests, clear-all),
    // reflect it in the controller without clobbering the user's caret on
    // ordinary keystrokes.
    if (searchController.text != query) {
      searchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          child: DesktopSearchField(
            controller: searchController,
            hintText: 'Filter standings (player, title, federation)',
            onChanged:
                (v) =>
                    ref
                        .read(
                          tournamentDetailStandingsSearchByTabIdProvider(
                            tabId,
                          ).notifier,
                        )
                        .state = v,
            onClear:
                () =>
                    ref
                        .read(
                          tournamentDetailStandingsSearchByTabIdProvider(
                            tabId,
                          ).notifier,
                        )
                        .state = '',
          ),
        ),
        Expanded(
          child: standings.when(
            skipLoadingOnRefresh: true,
            skipLoadingOnReload: true,
            data: (snapshot) {
              final hasCompleteOfficialRoster =
                  officialRosterByTourId.isNotEmpty &&
                  officialRosterByTourId.values.every(
                    (value) => value.hasValue,
                  );
              final players =
                  hasCompleteOfficialRoster
                      ? assignOverallRanks(
                        _mergeOfficialRosterRows(
                          officialRosterByTourId.values.expand(
                            (value) =>
                                value.valueOrNull ??
                                const <PlayerStandingModel>[],
                          ),
                        ),
                      )
                      : snapshot.standings;
              final scopedGames = scopeTournamentStandingsGames(
                snapshot,
                games,
              );
              final roundTable = buildTournamentStandingsRoundTable(
                standings: players,
                games: scopedGames,
              );
              final q = query.trim().toLowerCase();
              final filtered =
                  q.isEmpty
                      ? players
                      : players
                          .where((p) {
                            if (p.name.toLowerCase().contains(q)) return true;
                            if ((p.title ?? '').toLowerCase().contains(q)) {
                              return true;
                            }
                            if (p.countryCode.toLowerCase().contains(q)) {
                              return true;
                            }
                            return false;
                          })
                          .toList(growable: false);
              if (players.isEmpty) {
                return const _Empty();
              }
              if (filtered.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No standings match "$q"',
                      style: const TextStyle(
                        color: kWhiteColor70,
                        fontSize: 13,
                      ),
                    ),
                  ),
                );
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  final requiredWidth =
                      _StandingsLayout.tableWidth(roundTable.columns) +
                      _StandingsLayout.horizontalPadding;
                  final contentWidth = math.max(
                    constraints.maxWidth,
                    requiredWidth,
                  );
                  return Scrollbar(
                    controller: horizontalController,
                    scrollbarOrientation: ScrollbarOrientation.bottom,
                    child: SingleChildScrollView(
                      controller: horizontalController,
                      scrollDirection: Axis.horizontal,
                      physics: const DesktopScrollPhysics(),
                      child: SizedBox(
                        width: contentWidth,
                        height: constraints.maxHeight,
                        child: ListView.separated(
                          key: PageStorageKey<String>(
                            'tournament-detail-standings:$tabId',
                          ),
                          physics: const DesktopScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                          itemCount: filtered.length + 1,
                          separatorBuilder:
                              (_, i) => Divider(
                                color:
                                    i == 0 ? Colors.transparent : kDividerColor,
                                height: 1,
                              ),
                          itemBuilder: (context, i) {
                            if (i == 0) {
                              return _StandingsHeaderRow(
                                columns: roundTable.columns,
                              );
                            }

                            final p = filtered[i - 1];
                            return _StandingsPlayerRow(
                              player: p,
                              rank: p.overallRank ?? players.indexOf(p) + 1,
                              flagFederation: _flagFederation(
                                ref,
                                p.countryCode,
                              ),
                              rounds: roundTable,
                              photoResolver:
                                  photoResolver ??
                                  (fideId) =>
                                      FidePhotoService.getPhotoUrlOrNull(
                                        fideId,
                                      ),
                              onOpenScoreCard: () => _openScoreCard(ref, p),
                              onOpenGame:
                                  (game) => _openGame(
                                    ref,
                                    game,
                                    scopedGames,
                                    openGeneration,
                                  ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              );
            },
            loading:
                () => const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(kPrimaryColor),
                    ),
                  ),
                ),
            error:
                (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Could not load standings: $e',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: kRedColor, fontSize: 12),
                    ),
                  ),
                ),
          ),
        ),
      ],
    );
  }

  String _flagFederation(WidgetRef ref, String countryCode) {
    // Some broadcasts ship the federation under non-ISO codes (e.g. FIDE
    // 3-letter); fall back to the LocationService mapping so the flag still
    // renders. Empty country = blank slot, not a broken image.
    final rawFed = countryCode.trim();
    final mappedFed = ref
        .read(locationServiceProvider)
        .getValidCountryCode(rawFed);
    return rawFed.isNotEmpty ? rawFed : mappedFed;
  }

  void _openScoreCard(WidgetRef ref, PlayerStandingModel player) {
    ref.read(scoreCardGamesContextProvider.notifier).state = null;
    ref.read(scoreCardPlayerProfileDataSourceProvider.notifier).state =
        PlayerProfileDataSource.supabase;
    openPlayerScoreCard(ref, player, fromTournamentContext: true);
  }

  void _openGame(
    WidgetRef ref,
    GamesTourModel game,
    List<GamesTourModel> eventGames,
    ObjectRef<int> openGeneration,
  ) {
    final customOpener = gameOpener;
    if (customOpener != null) {
      customOpener(game, eventGames);
      return;
    }
    final generation = ++openGeneration.value;
    final capturedTournament = ref.read(tournamentByTabIdProvider)[tabId];
    final title =
        tournamentTitle.trim().isNotEmpty
            ? tournamentTitle.trim()
            : (game.tourName?.trim().isNotEmpty == true
                ? game.tourName!.trim()
                : (game.eventName?.trim().isNotEmpty == true
                    ? game.eventName!.trim()
                    : tournamentId));
    unawaited(
      openTournamentGameTab(
        ref,
        game,
        title,
        eventGames: eventGames,
        canCommitOpen: (container) {
          final tabs = container.read(desktopTabsProvider);
          final currentTournament =
              container.read(tournamentByTabIdProvider)[tabId];
          final segment = container.read(
            tournamentDetailSegmentByTabIdProvider(tabId),
          );
          return openGeneration.value == generation &&
              tabs.activeId == tabId &&
              tabs.active?.kind == TabKind.tournamentDetail &&
              currentTournament?.id == capturedTournament?.id &&
              segment == TournamentDetailSegment.standings;
        },
      ),
    );
  }
}

List<PlayerStandingModel> _mergeOfficialRosterRows(
  Iterable<PlayerStandingModel> rows,
) {
  final byIdentity = <String, PlayerStandingModel>{};
  for (final row in rows) {
    byIdentity[_primaryStandingKey(row.fideId, row.name)] = row;
  }
  return byIdentity.values.toList(growable: false);
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No standings published yet.',
          style: TextStyle(color: kLightGreyColor, fontSize: 12),
        ),
      ),
    );
  }
}

abstract final class _StandingsLayout {
  static const horizontalPadding = 48.0;
  static const rankWidth = 32.0;
  static const avatarSlotWidth = 50.0;
  static const playerWidth = 300.0;
  static const ratingWidth = 72.0;
  static const pointsWidth = 62.0;

  static double tableWidth(List<TournamentStandingsColumn> columns) {
    return rankWidth +
        avatarSlotWidth +
        playerWidth +
        ratingWidth +
        pointsWidth +
        columns.fold<double>(0, (width, column) => width + column.width);
  }
}

class _StandingsHeaderRow extends StatelessWidget {
  const _StandingsHeaderRow({required this.columns});

  final List<TournamentStandingsColumn> columns;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: kLightGreyColor,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Row(
        children: [
          const SizedBox(
            width: _StandingsLayout.rankWidth,
            child: Text('#', style: style),
          ),
          const SizedBox(width: _StandingsLayout.avatarSlotWidth),
          const SizedBox(
            width: _StandingsLayout.playerWidth,
            child: Text('Player', style: style),
          ),
          const _HeaderCell(
            label: 'Rating',
            width: _StandingsLayout.ratingWidth,
          ),
          const _HeaderCell(label: 'Pts.', width: _StandingsLayout.pointsWidth),
          for (final column in columns)
            SizedBox(
              key: Key('standings-round-header-${column.id}'),
              width: column.width,
              child: Text(
                column.label,
                textAlign: TextAlign.center,
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.width});

  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: kLightGreyColor,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _StandingsPlayerRow extends StatelessWidget {
  const _StandingsPlayerRow({
    required this.player,
    required this.rank,
    required this.flagFederation,
    required this.rounds,
    required this.photoResolver,
    required this.onOpenScoreCard,
    required this.onOpenGame,
  });

  final PlayerStandingModel player;
  final int rank;
  final String flagFederation;
  final TournamentStandingsRoundTable rounds;
  final StandingsPhotoResolver photoResolver;
  final VoidCallback onOpenScoreCard;
  final ValueChanged<GamesTourModel> onOpenGame;

  @override
  Widget build(BuildContext context) {
    final points = _standingsPoints(player.matchScore);
    final rating = player.score > 0 ? player.score.toString() : '';
    final playerKey = _standingWidgetKey(player);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: _StandingsLayout.rankWidth,
            child: Text(
              '$rank',
              style: const TextStyle(
                color: kLightGreyColor,
                fontSize: 13,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: _StandingsLayout.avatarSlotWidth,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _StandingsPlayerAvatar(
                key: Key('standings-player-avatar-$playerKey'),
                player: player,
                photoResolver: photoResolver,
              ),
            ),
          ),
          SizedBox(
            width: _StandingsLayout.playerWidth,
            child: Row(
              children: [
                SizedBox(
                  key: Key('standings-flag-$playerKey'),
                  width: 26,
                  height: 17,
                  child:
                      flagFederation.isEmpty
                          ? const SizedBox.shrink()
                          : FederationFlag(
                            federation: flagFederation,
                            width: 26,
                            height: 17,
                            borderRadius: BorderRadius.circular(2),
                          ),
                ),
                const SizedBox(width: 8),
                if ((player.title ?? '').isNotEmpty) ...[
                  Text(
                    player.title!,
                    key: Key('standings-title-$playerKey'),
                    style: const TextStyle(
                      color: kPrimaryColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: _PlayerNameLink(
                    playerName: player.name,
                    onTap: onOpenScoreCard,
                  ),
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
          SizedBox(
            width: _StandingsLayout.ratingWidth,
            child: Text(
              rating,
              key: Key('standings-rating-$playerKey'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor70,
                fontSize: 13,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: _StandingsLayout.pointsWidth,
            child: Text(
              points,
              key: Key('standings-points-$playerKey'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: kWhiteColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          for (final column in rounds.columns)
            SizedBox(
              key: Key('standings-round-$playerKey-${column.id}'),
              width: column.width,
              child: Center(
                child: Builder(
                  builder: (context) {
                    final cell = rounds.cellForColumn(player, column);
                    return cell == null
                        ? const SizedBox(width: 26, height: 26)
                        : _StandingsRoundResult(
                          cell: cell,
                          onOpen: () => onOpenGame(cell.game),
                        );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StandingsPlayerAvatar extends StatelessWidget {
  const _StandingsPlayerAvatar({
    super.key,
    required this.player,
    required this.photoResolver,
  });

  static const size = 40.0;

  final PlayerStandingModel player;
  final StandingsPhotoResolver photoResolver;

  @override
  Widget build(BuildContext context) {
    final initials = getPlayerInitials(player.name);
    final fideId = player.fideId?.toString();
    return FutureBuilder<String?>(
      future: photoResolver(fideId),
      builder: (context, snapshot) {
        final photoUrl = snapshot.data;
        return ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child:
              photoUrl != null && photoUrl.isNotEmpty
                  ? CachedNetworkImage(
                    key: Key(
                      'standings-player-photo-${_standingWidgetKey(player)}',
                    ),
                    imageUrl: photoUrl,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    placeholder:
                        (_, __) => _StandingsAvatarFallback(initials: initials),
                    errorWidget:
                        (_, __, ___) =>
                            _StandingsAvatarFallback(initials: initials),
                  )
                  : _StandingsAvatarFallback(initials: initials),
        );
      },
    );
  }
}

class _StandingsAvatarFallback extends StatelessWidget {
  const _StandingsAvatarFallback({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _StandingsPlayerAvatar.size,
      height: _StandingsPlayerAvatar.size,
      decoration: BoxDecoration(
        color: kBlack3Color,
        border: Border.all(color: kDividerColor),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(
          color: kWhiteColor70,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _StandingsRoundResult extends StatelessWidget {
  const _StandingsRoundResult({required this.cell, required this.onOpen});

  final TournamentStandingsRoundCell cell;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final background =
        cell.isOngoing
            ? Colors.transparent
            : (cell.playedWhite ? const Color(0xFFE8E8E8) : kBlack3Color);
    final foreground =
        cell.isOngoing
            ? kWhiteColor70
            : (cell.playedWhite ? kBlack2Color : kWhiteColor);
    return DesktopTooltip(
      message: cell.tooltipMessage,
      child: Semantics(
        button: true,
        label: 'Open round ${cell.round} game against ${cell.opponentName}',
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space) {
              onOpen();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ClickCursor(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpen,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: background,
                  border: Border.all(
                    color:
                        cell.playedWhite && !cell.isOngoing
                            ? const Color(0xFFCECECE)
                            : kWhiteColor.withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  cell.resultText,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _standingsPoints(String? matchScore) {
  final raw = matchScore?.split('/').first.trim() ?? '';
  if (raw.isEmpty) return '';
  final value = double.tryParse(raw);
  if (value == null) return raw;
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
}

String _standingWidgetKey(PlayerStandingModel player) {
  return player.fideId?.toString() ?? _normalizeStandingName(player.name);
}

class _PlayerNameLink extends StatefulWidget {
  const _PlayerNameLink({required this.playerName, required this.onTap});

  final String playerName;
  final VoidCallback onTap;

  @override
  State<_PlayerNameLink> createState() => _PlayerNameLinkState();
}

class _PlayerNameLinkState extends State<_PlayerNameLink> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused || _pressed;
    final color =
        _pressed ? kPrimaryColor.withValues(alpha: 0.82) : kWhiteColor;

    return Semantics(
      button: true,
      label: 'Open ${widget.playerName} score card',
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
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
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: Text(
                widget.playerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  decoration:
                      active ? TextDecoration.underline : TextDecoration.none,
                  decorationColor: kPrimaryColor,
                  decorationThickness: 1.2,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
