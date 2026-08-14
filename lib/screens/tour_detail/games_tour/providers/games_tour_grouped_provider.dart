import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/repository/supabase/game/games.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/lichess_pairings_fallback_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_stage_round_resolver.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_tournament_state_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
import 'package:chessever/screens/tour_detail/bracket/utils/knockout_stage_parser.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class GroupedGamesData {
  final List<GamesAppBarModel> filteredRounds;
  final Map<String, List<GamesTourModel>> gamesByRound;
  final MatchHeaderModel? matchFormatHeader;
  final bool isKnockoutTournament;
  final bool isMultiStageKnockout;
  final bool isLoading;
  final List<GamesAppBarModel> rounds;
  final List<GamesTourModel> allGames;
  final int providerGameCount;
  final Object? loadError;

  /// Upcoming rounds whose only content is future pairings (resolved player
  /// names, no moves yet). They render as collapsible cards pinned to the
  /// bottom of the Games tab, below every played round.
  final Set<String> upcomingPairingRoundIds;

  GroupedGamesData({
    required this.filteredRounds,
    required this.gamesByRound,
    this.matchFormatHeader,
    required this.isKnockoutTournament,
    required this.isMultiStageKnockout,
    required this.isLoading,
    required this.rounds,
    required this.allGames,
    required this.providerGameCount,
    this.loadError,
    this.upcomingPairingRoundIds = const {},
  });
}

/// Whether the screen-model snapshot is complete enough to replace the last
/// rendered Games-tab snapshot.
///
/// In [GameDisplayMode.all], a non-empty raw provider paired with an empty
/// screen model means the model is still catching up. Filtered modes are
/// different: zero models is a valid result (for example, a completed event
/// with no live games), so that empty snapshot must be rendered immediately.
bool isGamesModelReadyForDisplay({
  required GameDisplayMode displayMode,
  required bool isSearchMode,
  required int providerGameCount,
  required int modelGameCount,
}) {
  return isSearchMode ||
      displayMode != GameDisplayMode.all ||
      providerGameCount == 0 ||
      modelGameCount > 0;
}

/// Whether a game with [gameStatus] belongs in [displayMode].
///
/// Live mode is intentionally strict: an unknown/missing result is not proof
/// that a game is live. Only the explicit ongoing status is included.
bool isGameStatusVisible({
  required GameDisplayMode displayMode,
  required GameStatus gameStatus,
}) {
  switch (displayMode) {
    case GameDisplayMode.hideFinishedGames:
      return gameStatus.isOngoing;
    case GameDisplayMode.showfinishedGame:
      return gameStatus.isFinished;
    case GameDisplayMode.all:
      return true;
  }
}

// Optimization: Move heavy grouping, filtering, and sorting off the main UI build path.
// The UI can just watch this provider and paint.
final gamesTourGroupedProvider = Provider.autoDispose<GroupedGamesData>((ref) {
  final gamesAppBar = ref.watch(gamesAppBarProvider);
  if (gamesAppBar.hasError) {
    return GroupedGamesData(
      filteredRounds: const [],
      gamesByRound: const {},
      isKnockoutTournament: false,
      isMultiStageKnockout: false,
      isLoading: false,
      rounds: const [],
      allGames: const [],
      providerGameCount: 0,
      loadError: gamesAppBar.error,
    );
  }
  if (gamesAppBar.isLoading || !gamesAppBar.hasValue) {
    return GroupedGamesData(
      filteredRounds: [],
      gamesByRound: {},
      isKnockoutTournament: false,
      isMultiStageKnockout: false,
      isLoading: true,
      rounds: [],
      allGames: [],
      providerGameCount: 0,
    );
  }

  final rounds = gamesAppBar.value?.gamesAppBarModels ?? [];
  final tourId = ref.read(tourDetailScreenProvider).value?.aboutTourModel.id;
  final knockoutState = ref.watch(knockoutTournamentStateProvider(tourId));
  final isKnockoutTournament = knockoutState.isKnockout;

  final screenModelAsync = ref.watch(gamesTourScreenProvider);
  final allGamesScreenModel =
      screenModelAsync.valueOrNull?.gamesTourModels ?? [];
  final isSearchMode = screenModelAsync.valueOrNull?.isSearchMode ?? false;
  final displayMode =
      screenModelAsync.valueOrNull?.gameDisplayMode ?? GameDisplayMode.all;

  final gamesAsync = ref.watch(gamesTourProvider(tourId ?? ''));
  final providerGameCount = gamesAsync.valueOrNull?.length ?? 0;
  final modelGameCount = allGamesScreenModel.length;

  if (gamesAsync.hasError) {
    return GroupedGamesData(
      filteredRounds: const [],
      gamesByRound: const {},
      isKnockoutTournament: isKnockoutTournament,
      isMultiStageKnockout: false,
      isLoading: false,
      rounds: rounds,
      allGames: const [],
      providerGameCount: 0,
      loadError: gamesAsync.error,
    );
  }

  if (gamesAsync.isLoading && allGamesScreenModel.isEmpty) {
    return GroupedGamesData(
      filteredRounds: [],
      gamesByRound: {},
      isKnockoutTournament: isKnockoutTournament,
      isMultiStageKnockout: false,
      isLoading: true,
      rounds: rounds,
      allGames: allGamesScreenModel,
      providerGameCount: providerGameCount,
    );
  }

  if (!isGamesModelReadyForDisplay(
    displayMode: displayMode,
    isSearchMode: isSearchMode,
    providerGameCount: providerGameCount,
    modelGameCount: modelGameCount,
  )) {
    return GroupedGamesData(
      filteredRounds: [],
      gamesByRound: {},
      isKnockoutTournament: isKnockoutTournament,
      isMultiStageKnockout: false,
      isLoading: true,
      rounds: rounds,
      allGames: allGamesScreenModel,
      providerGameCount: providerGameCount,
    );
  }

  MatchHeaderModel? matchFormatHeader;
  if (!isKnockoutTournament) {
    final tourDetail = ref.read(tourDetailScreenProvider).valueOrNull;
    final allTours = tourDetail?.tours ?? [];
    final currentTour =
        allTours.where((t) => t.tour.id == tourId).firstOrNull?.tour;
    final formatString = currentTour?.info.format;

    if (KnockoutMatchDetector.isMatchFormat(
      formatString,
      allGamesScreenModel,
    )) {
      final matches = KnockoutMatchDetector.groupByMatchesAcrossAllRounds(
        allGamesScreenModel,
      );
      if (matches.isNotEmpty) {
        final entry = matches.entries.first;
        matchFormatHeader = KnockoutMatchDetector.createMatchHeader(
          entry.key,
          entry.value,
        );
      }
    }
  }

  final gamesByRound = <String, List<GamesTourModel>>{};
  final seenGameIdsPerRound = <String, Set<String>>{};
  final roundIds = rounds.map((round) => round.id).toSet();

  void ensureRoundEntry(String roundId) {
    gamesByRound.putIfAbsent(roundId, () => <GamesTourModel>[]);
    seenGameIdsPerRound.putIfAbsent(roundId, () => <String>{});
  }

  bool addGameToRound(String roundId, GamesTourModel game) {
    if (!isEventBoardGameVisible(game)) {
      return false;
    }
    ensureRoundEntry(roundId);
    if (seenGameIdsPerRound[roundId]!.add(game.gameId)) {
      gamesByRound[roundId]!.add(game);
      return true;
    }
    return false;
  }

  for (final round in rounds) {
    ensureRoundEntry(round.id);
  }

  final isMultiStageKnockout =
      isKnockoutTournament &&
      rounds.any((r) => r.id.startsWith('knockout-stage-'));
  final knownTourIds =
      ref
          .read(tourDetailScreenProvider)
          .valueOrNull
          ?.tours
          .map((tour) => tour.tour.id) ??
      const <String>[];
  final stageReferences = <String, KnockoutStageRoundReference>{
    if (tourId != null)
      for (final round in rounds)
        if (resolveKnockoutStageRoundReference(
              round: round,
              selectedTourId: tourId,
              knownTourIds: knownTourIds,
            )
            case final reference?)
          round.id: reference,
  };
  final hasSiblingStageTours = stageReferences.values.any(
    (reference) => reference.isSiblingTour,
  );
  var representedSiblingIsLoading = false;

  if (isMultiStageKnockout && hasSiblingStageTours) {
    final selectedTourId = tourId!;
    final selectedTourGames = allGamesScreenModel.where(
      (game) => game.tourId == selectedTourId,
    );
    if (!isSearchMode) {
      final stageTourGames = <String, List<GamesTourModel>>{};
      for (final stageTourId
          in stageReferences.values
              .map((reference) => reference.siblingTourId)
              .whereType<String>()
              .toSet()) {
        final stageAsync = ref.watch(gamesTourProvider(stageTourId));
        representedSiblingIsLoading =
            representedSiblingIsLoading || stageAsync.isLoading;
        final rawStageGames = stageAsync.valueOrNull ?? [];
        final stageModels = <GamesTourModel>[];
        for (final game in rawStageGames) {
          try {
            final model = GamesTourModel.fromGame(game);
            if (isEventBoardGameVisible(model)) stageModels.add(model);
          } catch (_) {
            // One malformed row must not hide every sibling stage game.
          }
        }
        stageTourGames[stageTourId] = stageModels;
      }

      gamesByRound.addAll(
        groupItemsForTournamentDisplayRounds(
          rounds: rounds,
          selectedTourId: selectedTourId,
          knownTourIds: knownTourIds,
          selectedTourItems: selectedTourGames,
          sourceRoundIdOf: (game) => game.roundId,
          siblingTourItems: (stageTourId) => stageTourGames[stageTourId] ?? [],
        ),
      );
    } else {
      final groupedSearchGames = groupItemsForTournamentDisplayRounds(
        rounds: rounds,
        selectedTourId: selectedTourId,
        knownTourIds: knownTourIds,
        selectedTourItems: selectedTourGames,
        sourceRoundIdOf: (game) => game.roundId,
        siblingTourItems:
            (stageTourId) =>
                allGamesScreenModel.where((game) => game.tourId == stageTourId),
      );
      for (final entry in groupedSearchGames.entries) {
        for (final game in entry.value) {
          addGameToRound(entry.key, game);
        }
      }
    }
  } else if (isMultiStageKnockout) {
    for (final game in allGamesScreenModel) {
      String? roundId;
      for (final stage in rounds) {
        if (stage.sourceRoundIds.contains(game.roundId)) {
          roundId = stage.id;
          break;
        }
      }
      // Compatibility fallback for cached/legacy synthetic models that do not
      // yet carry their source round ids.
      if (roundId == null && tourId != null) {
        roundId = roundSlugStageRoundId(tourId, game.roundSlug);
      }
      if (roundId != null && gamesByRound.containsKey(roundId)) {
        addGameToRound(roundId, game);
      }
    }
  } else {
    for (final game in allGamesScreenModel) {
      if (!isKnockoutTournament && !_shouldIncludeGame(displayMode, game)) {
        continue;
      }
      if (roundIds.contains(game.roundId)) {
        addGameToRound(game.roundId, game);
      } else {
        final defaultRound = rounds.firstOrNull;
        if (defaultRound != null) {
          addGameToRound(defaultRound.id, game);
        }
      }
    }
  }

  // Future rounds: Lichess publishes pairings for upcoming rounds ahead of
  // time. Those games never pass isEventBoardGameVisible (no played position),
  // so their rounds would be dropped entirely. Surface them as pairing-only
  // rounds instead — but only with resolved player names ("?" placeholder
  // pairings stay hidden) and never for multi-stage knockouts, whose rounds
  // are synthetic stage ids.
  final upcomingPairingRoundIds = <String>{};
  if (!isMultiStageKnockout) {
    for (final round in rounds) {
      if (gamesByRound[round.id]?.isNotEmpty ?? false) continue;
      // Rounds that are conclusively over (completed) are excluded; a round
      // that flips to ongoing at starts_at while its broadcast lags keeps
      // showing its pairings instead of vanishing until the first moves.
      if (round.roundStatus == RoundStatus.completed) continue;

      final pairings =
          allGamesScreenModel
              .where(
                (game) =>
                    game.roundId == round.id &&
                    (isKnockoutTournament ||
                        _shouldIncludeGame(displayMode, game)) &&
                    _hasResolvedPlayer(game.whitePlayer) &&
                    _hasResolvedPlayer(game.blackPlayer),
              )
              .toList()
            ..sort((a, b) {
              final aBoard = a.boardNr;
              final bBoard = b.boardNr;
              if (aBoard != null && bBoard != null) {
                return aBoard.compareTo(bBoard);
              }
              if (aBoard != null) return -1;
              if (bBoard != null) return 1;
              return a.gameId.compareTo(b.gameId);
            });
      if (pairings.isEmpty) continue;

      ensureRoundEntry(round.id);
      for (final game in pairings) {
        if (seenGameIdsPerRound[round.id]!.add(game.gameId)) {
          gamesByRound[round.id]!.add(game);
        }
      }
      upcomingPairingRoundIds.add(round.id);
    }
  }

  // FALLBACK: during a round break the DB may not have the next round's
  // pairings yet (backend pairing sync disabled or lagging) even though
  // Lichess has already published them. Fetch that single round straight
  // from the public Lichess API and surface it exactly like DB-backed
  // pairings; the fetch provider auto-refreshes every 90s and this branch
  // deactivates on its own once real rows exist in the DB.
  if (!isMultiStageKnockout && !isSearchMode && tourId != null) {
    final now = DateTime.now();
    GamesAppBarModel? fallbackRound;
    for (final round in rounds) {
      if (upcomingPairingRoundIds.contains(round.id)) continue;
      if (gamesByRound[round.id]?.isNotEmpty ?? false) continue;
      if (round.roundStatus == RoundStatus.completed) continue;
      final startsAt = round.startsAt;
      if (startsAt == null) continue;
      final untilStart = startsAt.difference(now);
      // Slightly wider than the 1h top-pin display gate, plus grace for
      // late-starting broadcasts (same window the data hub sync uses).
      if (untilStart > const Duration(minutes: 65) ||
          untilStart < const Duration(minutes: -30)) {
        continue;
      }
      if (fallbackRound == null ||
          (fallbackRound.startsAt != null &&
              startsAt.isBefore(fallbackRound.startsAt!))) {
        fallbackRound = round;
      }
    }

    if (fallbackRound != null) {
      final fetched =
          ref
              .watch(
                lichessPairingsFallbackProvider(
                  LichessPairingsRequest(
                    roundId: fallbackRound.id,
                    tourId: tourId,
                  ),
                ),
              )
              .valueOrNull ??
          const <Games>[];
      final fallbackModels = <GamesTourModel>[];
      for (final game in fetched) {
        try {
          final model = GamesTourModel.fromGame(game);
          if (_hasResolvedPlayer(model.whitePlayer) &&
              _hasResolvedPlayer(model.blackPlayer)) {
            fallbackModels.add(model);
          }
        } catch (_) {
          // Best-effort fallback: skip malformed boards.
        }
      }
      if (fallbackModels.isNotEmpty) {
        ensureRoundEntry(fallbackRound.id);
        for (final model in fallbackModels) {
          if (seenGameIdsPerRound[fallbackRound.id]!.add(model.gameId)) {
            gamesByRound[fallbackRound.id]!.add(model);
          }
        }
        upcomingPairingRoundIds.add(fallbackRound.id);
      }
    }
  }

  // The Games tab is a board list. Its final presentation order must come
  // from the broadcaster's authoritative board number—not arrival order,
  // rating, status, or a local pin. Run this after every DB/fallback path has
  // been reconciled so all cards obey one deterministic contract.
  for (final roundId in gamesByRound.keys.toList(growable: false)) {
    gamesByRound[roundId] = sortTournamentRoundGamesByBoard(
      gamesByRound[roundId]!,
    );
  }

  final playedRounds =
      rounds
          .where(
            (round) =>
                !upcomingPairingRoundIds.contains(round.id) &&
                (gamesByRound[round.id]?.isNotEmpty ?? false),
          )
          .toList();
  final upcomingPairingRounds =
      rounds
          .where((round) => upcomingPairingRoundIds.contains(round.id))
          .toList()
        ..sort((a, b) {
          final aStart = a.startsAt;
          final bStart = b.startsAt;
          if (aStart == null && bStart == null) return a.name.compareTo(b.name);
          if (aStart == null) return 1;
          if (bStart == null) return -1;
          final cmp = aStart.compareTo(bStart);
          return cmp != 0 ? cmp : a.name.compareTo(b.name);
        });

  // Match mobile: played rounds keep the app-bar order, while pairing-only
  // rounds are always appended after them, soonest first.
  final filteredRounds = [...playedRounds, ...upcomingPairingRounds];
  final hasGroupedGames = gamesByRound.values.any((games) => games.isNotEmpty);

  return GroupedGamesData(
    filteredRounds: filteredRounds,
    gamesByRound: gamesByRound,
    matchFormatHeader: matchFormatHeader,
    isKnockoutTournament: isKnockoutTournament,
    isMultiStageKnockout: isMultiStageKnockout,
    isLoading: shouldKeepGroupedGamesLoading(
      representedSiblingIsLoading: representedSiblingIsLoading,
      hasGroupedGames: hasGroupedGames,
    ),
    rounds: rounds,
    allGames: allGamesScreenModel,
    providerGameCount: providerGameCount,
    upcomingPairingRoundIds: upcomingPairingRoundIds,
  );
});

/// Keep the empty state suppressed while a represented sibling stage is still
/// resolving, but never cover a stage that has already produced games.
bool shouldKeepGroupedGamesLoading({
  required bool representedSiblingIsLoading,
  required bool hasGroupedGames,
}) => representedSiblingIsLoading && !hasGroupedGames;

/// Maps a game's round slug to the synthetic stage round id that
/// [gamesAppBarProvider] builds for legacy cached stage rows. Generic game and
/// tiebreak legs are deliberately not promoted into independent stages.
@visibleForTesting
String? roundSlugStageRoundId(String tourId, String? roundSlug) {
  final slug = roundSlug?.trim();
  if (slug == null || slug.isEmpty) return null;
  final stage = resolveLogicalKnockoutStage('', slug);
  return stage == null ? null : '$kKnockoutStagePrefix-$tourId-${stage.key}';
}

@visibleForTesting
List<GamesTourModel> sortTournamentRoundGamesByBoard(
  Iterable<GamesTourModel> games,
) {
  final sorted = games.toList(growable: false);
  sorted.sort((a, b) {
    final aBoard = a.boardNr;
    final bBoard = b.boardNr;
    if (aBoard != null && bBoard != null) {
      final boardOrder = aBoard.compareTo(bBoard);
      if (boardOrder != 0) return boardOrder;
    } else if (aBoard != null) {
      return -1;
    } else if (bBoard != null) {
      return 1;
    }

    // Duplicate/missing board numbers can occur in malformed or hydrating
    // feeds. A stable identity fallback stops equal cards from shuffling.
    return a.gameId.compareTo(b.gameId);
  });
  return sorted;
}

/// Whether a game row is renderable as an event board: placeholder rows
/// (unresolved "?" players or an unstarted position) must never surface as
/// boards. Keep in sync with the mobile app's predicate of the same name in
/// chessever-frontend.
bool isEventBoardGameVisible(GamesTourModel game) {
  if (!_hasResolvedPlayer(game.whitePlayer) ||
      !_hasResolvedPlayer(game.blackPlayer)) {
    return false;
  }

  if (_hasPlayedPosition(game)) {
    return true;
  }

  // Do not turn unstarted pairings/placeholders into playable event boards.
  // Pairing-only rounds are surfaced separately via upcomingPairingRoundIds.
  return false;
}

bool _hasResolvedPlayer(PlayerCard player) {
  final normalized = player.name.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  return normalized != '?' &&
      normalized != '??' &&
      normalized != 'tbd' &&
      normalized != 'tba' &&
      normalized != 'unknown';
}

bool _hasPlayedPosition(GamesTourModel game) {
  if (game.lastMove?.trim().isNotEmpty == true) return true;
  if (_pgnContainsMoves(game.pgn)) return true;
  final fen = game.fen?.trim();
  if (fen == null || fen.isEmpty) return false;
  return !_isInitialFen(fen);
}

bool _pgnContainsMoves(String? pgn) {
  final text = pgn?.trim();
  if (text == null || text.isEmpty) return false;
  final withoutHeaders =
      text
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('['))
          .join(' ')
          .trim();
  return RegExp(r'\b\d+\s*\.').hasMatch(withoutHeaders) ||
      RegExp(
        r'\b[a-h][1-8][a-h][1-8][qrbn]?\b',
        caseSensitive: false,
      ).hasMatch(withoutHeaders);
}

bool _isInitialFen(String fen) {
  final board = fen.split(RegExp(r'\s+')).first;
  return board == 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
}

bool _shouldIncludeGame(GameDisplayMode mode, GamesTourModel game) {
  return isGameStatusVisible(displayMode: mode, gameStatus: game.gameStatus);
}
