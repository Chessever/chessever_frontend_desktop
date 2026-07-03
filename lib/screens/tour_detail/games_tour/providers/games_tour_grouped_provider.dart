import 'package:chessever/screens/tour_detail/games_tour/models/games_app_bar_view_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_app_bar_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_stage_id.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/knockout_tournament_state_provider.dart';
import 'package:chessever/screens/tour_detail/games_tour/utils/knockout_match_detector.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
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

  /// Upcoming rounds whose only content is future pairings (resolved player
  /// names, no moves yet). At most one of them — the very next round, when it
  /// starts in less than an hour — is pinned to the TOP of [filteredRounds];
  /// the rest render below every played round.
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
    this.upcomingPairingRoundIds = const {},
  });
}

// Optimization: Move heavy grouping, filtering, and sorting off the main UI build path.
// The UI can just watch this provider and paint.
final gamesTourGroupedProvider = Provider.autoDispose<GroupedGamesData>((ref) {
  final gamesAppBar = ref.watch(gamesAppBarProvider);
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

  if (!isSearchMode && providerGameCount > 0 && modelGameCount == 0) {
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
  final isRoundSlugDerivedStages =
      isMultiStageKnockout &&
      tourId != null &&
      rounds.any((r) {
        if (!r.id.startsWith('knockout-stage-')) return false;
        final suffix = r.id.replaceFirst('knockout-stage-', '');
        return suffix.startsWith('$tourId-') &&
            suffix.length > tourId.length + 1;
      });

  if (isMultiStageKnockout && !isRoundSlugDerivedStages) {
    if (!isSearchMode) {
      final stageTourIds =
          rounds
              .where((r) => r.id.startsWith('knockout-stage-'))
              .map((r) => r.id.replaceFirst('knockout-stage-', ''))
              .toList();

      final stageTourGames = <String, List<GamesTourModel>>{};
      for (final stageTourId in stageTourIds) {
        final stageAsync = ref.read(gamesTourProvider(stageTourId));
        final rawStageGames = stageAsync.valueOrNull ?? [];
        stageTourGames[stageTourId] =
            rawStageGames
                .map((g) => GamesTourModel.fromGame(g))
                .where(isEventBoardGameVisible)
                .toList();
      }

      for (final round in rounds) {
        if (round.id.startsWith('knockout-stage-')) {
          final stageTourId = round.id.replaceFirst('knockout-stage-', '');
          final stageGames = stageTourGames[stageTourId] ?? [];
          gamesByRound[round.id] = stageGames;
        }
      }
    } else {
      for (final game in allGamesScreenModel) {
        final stageTourId = game.tourId;
        final roundId = 'knockout-stage-$stageTourId';
        if (gamesByRound.containsKey(roundId)) {
          addGameToRound(roundId, game);
        }
      }
    }
  } else if (isRoundSlugDerivedStages) {
    for (final game in allGamesScreenModel) {
      final roundId = roundSlugDerivedKnockoutStageId(
        tourId: tourId,
        roundSlug: game.roundSlug,
      );
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

  if (!isSearchMode) {
    final pinnedGameIds = screenModelAsync.valueOrNull?.pinnedGamedIs ?? [];
    if (pinnedGameIds.isNotEmpty) {
      final pinnedOrder = <String, int>{
        for (var i = 0; i < pinnedGameIds.length; i++) pinnedGameIds[i]: i,
      };
      for (final roundId in gamesByRound.keys) {
        final roundGames = gamesByRound[roundId]!;
        roundGames.sort((a, b) {
          final aPinnedIndex = pinnedOrder[a.gameId];
          final bPinnedIndex = pinnedOrder[b.gameId];
          final aPinned = aPinnedIndex != null;
          final bPinned = bPinnedIndex != null;
          if (aPinned && !bPinned) return -1;
          if (!aPinned && bPinned) return 1;
          if (aPinned && bPinned) {
            return aPinnedIndex.compareTo(bPinnedIndex);
          }
          return 0;
        });
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

  // At most ONE pairing round may render on TOP of the (newest-first) list,
  // and only when ALL of these hold:
  //   1. it is the one-and-only very next round of this tour,
  //   2. its boards/matchups are already published (it IS a pairing round),
  //   3. we are 100% sure it starts in less than an hour (known startsAt).
  // Every other future pairing round renders below all played rounds.
  GamesAppBarModel? topPairingRound;
  if (upcomingPairingRounds.isNotEmpty) {
    final next = upcomingPairingRounds.first;
    final startsAt = next.startsAt;
    if (startsAt != null &&
        startsAt.difference(DateTime.now()) < const Duration(hours: 1)) {
      topPairingRound = next;
    }
  }
  final filteredRounds = [
    if (topPairingRound != null) topPairingRound,
    ...playedRounds,
    ...upcomingPairingRounds.where((round) => round != topPairingRound),
  ];

  return GroupedGamesData(
    filteredRounds: filteredRounds,
    gamesByRound: gamesByRound,
    matchFormatHeader: matchFormatHeader,
    isKnockoutTournament: isKnockoutTournament,
    isMultiStageKnockout: isMultiStageKnockout,
    isLoading: false,
    rounds: rounds,
    allGames: allGamesScreenModel,
    providerGameCount: providerGameCount,
    upcomingPairingRoundIds: upcomingPairingRoundIds,
  );
});

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
  switch (mode) {
    case GameDisplayMode.hideFinishedGames:
      return !game.gameStatus.isFinished;
    case GameDisplayMode.showfinishedGame:
      return game.gameStatus.isFinished;
    case GameDisplayMode.all:
      return true;
  }
}
