import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/standings/team_standing_model.dart';
import 'package:chessever/screens/standings/team_standings_builder.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/providers/games_tour_provider.dart';
import 'package:chessever/screens/tour_detail/player_tour/player_tour_screen_provider.dart';
import 'package:chessever/screens/tour_detail/provider/tour_detail_screen_provider.dart';
import 'package:chessever/utils/team_scoring_rules.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Team rows currently expanded to reveal their players. Multiple may be open.
final expandedTeamsProvider = StateProvider.autoDispose<Set<String>>(
  (ref) => <String>{},
);

/// The team whose score card is currently open (set on card tap, read by the
/// team score card screen). Mirrors `selectedPlayerProvider`.
final selectedTeamProvider = StateProvider<TeamStandingModel?>((ref) => null);

/// Replaces an early scorecard placeholder with the fully computed standing
/// as soon as standings finish loading. Games-tab navigation intentionally
/// opens immediately, so the selected value can initially have no players.
TeamStandingModel? resolveSelectedTeamStanding({
  required TeamStandingModel? selected,
  required List<TeamStandingModel>? standings,
}) {
  if (selected == null) return null;
  final selectedKey = selected.teamName.trim().toLowerCase();
  if (selectedKey.isEmpty || standings == null) return selected;
  for (final team in standings) {
    if (team.teamName.trim().toLowerCase() == selectedKey) return team;
  }
  return selected;
}

final selectedTeamStandingProvider = Provider<TeamStandingModel?>((ref) {
  return resolveSelectedTeamStanding(
    selected: ref.watch(selectedTeamProvider),
    standings: ref.watch(teamStandingsProvider).valueOrNull,
  );
});

/// Reads a tour's live games as [GamesTourModel]s, subscribing only to
/// result-affecting changes.
List<GamesTourModel> _watchTeamGamesForTour(Ref ref, String tourId) {
  final games = <GamesTourModel>[];
  if (tourId.isEmpty) return games;
  ref.watch(gamesTourProvider(tourId).select(standingsGamesSignature));
  final raw = ref.watch(gamesTourProvider(tourId)).valueOrNull ?? const [];
  for (final g in raw) {
    try {
      games.add(GamesTourModel.fromGame(g));
    } catch (_) {}
  }
  return games;
}

/// Reads the current tour's live games as [GamesTourModel]s, subscribing only
/// to result-affecting changes.
List<GamesTourModel> _watchTeamGames(Ref ref) {
  final tourId =
      ref.watch(tourDetailScreenProvider).valueOrNull?.aboutTourModel.id ?? '';
  return _watchTeamGamesForTour(ref, tourId);
}

TourInfo? _tourInfoForTourId(Ref ref, String tourId) {
  final vm = ref.watch(tourDetailScreenProvider).valueOrNull;
  if (vm == null || tourId.isEmpty) return null;
  for (final t in vm.tours) {
    if (t.tour.id == tourId) return t.tour.info;
  }
  return null;
}

/// Round-by-round matches for a given team (by name). Powers both the
/// expandable team standings row and the team score card.
TourInfo? _selectedTourInfo(Ref ref) {
  final tourId =
      ref.watch(tourDetailScreenProvider).valueOrNull?.aboutTourModel.id ?? '';
  return _tourInfoForTourId(ref, tourId);
}

final teamMatchesFamilyProvider =
    AutoDisposeProvider.family<List<TeamMatch>, String>((ref, teamName) {
      final games = _watchTeamGames(ref);
      return buildTeamMatches(
        games: games,
        teamName: teamName,
        scoring: TeamScoringRules.fromTourInfo(_selectedTourInfo(ref)),
      );
    });

/// Round-by-round matches for the currently selected team (team score card).
final teamMatchesProvider = AutoDisposeProvider<List<TeamMatch>>((ref) {
  final team = ref.watch(selectedTeamStandingProvider);
  if (team == null) return const [];
  return ref.watch(teamMatchesFamilyProvider(team.teamName));
});

/// Team standings for the team-event "Standings" tab. Reuses the already-ranked
/// individual standings ([playerTourScreenProvider]) for the per-team player
/// rows and the same games source for the match/board score computation.
///
/// Recomputes only when the individual standings re-emit or a game result
/// changes (via [standingsGamesSignature]) — not on clock/move ticks.
final teamStandingsProvider =
    AutoDisposeProvider<AsyncValue<List<TeamStandingModel>>>((ref) {
      final playersAsync = ref.watch(playerTourScreenProvider);
      return playersAsync.whenData((players) {
        final games = _watchTeamGames(ref);
        return buildTeamStandings(
          games: games,
          playerStandings: players,
          scoring: TeamScoringRules.fromTourInfo(_selectedTourInfo(ref)),
        );
      });
    });

/// Tour-scoped team standings for the in-game event rail.
///
/// The rail's [tourDetailScreenProvider] may still be pointed at a different
/// event, so this reads the official roster and games for [tourId] directly
/// instead of the currently selected hall tour.
final teamStandingsForTourProvider =
    AutoDisposeProvider.family<AsyncValue<List<TeamStandingModel>>, String>((
      ref,
      rawTourId,
    ) {
      final tourId = rawTourId.trim();
      if (tourId.isEmpty) {
        return const AsyncValue.data(<TeamStandingModel>[]);
      }

      final playersAsync = ref.watch(tournamentRosterStandingsProvider(tourId));
      final games = _watchTeamGamesForTour(ref, tourId);
      final scoring = TeamScoringRules.fromTourInfo(
        _tourInfoForTourId(ref, tourId),
      );

      if (playersAsync.hasValue) {
        return AsyncValue.data(
          buildTeamStandings(
            games: games,
            playerStandings: playersAsync.requireValue,
            scoring: scoring,
          ),
        );
      }
      if (games.isNotEmpty) {
        return AsyncValue.data(
          buildTeamStandings(
            games: games,
            playerStandings: const [],
            scoring: scoring,
          ),
        );
      }
      if (playersAsync.hasError) {
        return AsyncValue.error(playersAsync.error!, playersAsync.stackTrace!);
      }
      return const AsyncValue.loading();
    });
