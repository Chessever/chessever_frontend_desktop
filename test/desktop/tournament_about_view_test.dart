import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/widgets/tournament_about_view.dart';
import 'package:chessever/repository/supabase/tour/tour.dart';
import 'package:chessever/screens/group_event/model/about_tour_model.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';

void main() {
  testWidgets('renders mobile-shared event about details without port note', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeTournamentProvider.overrideWithValue(_event()),
          desktopTournamentAboutModelProvider.overrideWithValue(
            AsyncValue<AboutTourModel?>.data(AboutTourModel.fromTour(_tour())),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 640,
              child: TournamentAboutView(tournamentId: 'event-1'),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Players'), findsOneWidget);
    expect(
      find.text('GM Carlsen, Magnus, GM Nakamura, Hikaru, GM Ju, Wenjun'),
      findsOneWidget,
    );
    expect(find.text('Time Control'), findsOneWidget);
    expect(find.text('120 min + 30 sec / move'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.textContaining('May 26'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(find.text('Stavanger, Norway'), findsOneWidget);
    expect(find.text('Lichess'), findsOneWidget);
    expect(find.text('norwaychess.no'), findsOneWidget);
    expect(find.text('Official Standings'), findsOneWidget);
    expect(find.textContaining('AboutTourModel'), findsNothing);
    expect(find.textContaining('port'), findsNothing);
  });
}

GroupEventCardModel _event() {
  return GroupEventCardModel(
    id: 'event-1',
    title: 'Norway Chess 2026',
    dates: 'May 26 - Jun 6, 2026',
    maxAvgElo: 2800,
    timeUntilStart: 'Starts soon',
    tourEventCategory: TourEventCategory.upcoming,
    timeControl: 'Standard',
    endDate: DateTime.utc(2026, 6, 6),
    startDate: DateTime.utc(2026, 5, 26),
  );
}

Tour _tour() {
  return Tour(
    id: 'tour-1',
    name: 'Norway Chess 2026',
    slug: 'norway-chess-2026',
    info: const TourInfo(
      tc: '120 min + 30 sec / move',
      website: 'https://www.norwaychess.no/',
      location: 'Stavanger, Norway',
      standings: 'https://www.norwaychess.no/standings',
    ),
    createdAt: DateTime.utc(2026, 1, 1),
    url: 'https://lichess.org/broadcast/norway-chess-2026/open',
    tier: 1,
    dates: [DateTime.utc(2026, 5, 26), DateTime.utc(2026, 6, 6)],
    players: [
      TournamentPlayer(
        federation: 'NOR',
        name: 'Carlsen, Magnus',
        title: 'GM',
        played: 0,
        rating: 2830,
      ),
      TournamentPlayer(
        federation: 'USA',
        name: 'Nakamura, Hikaru',
        title: 'GM',
        played: 0,
        rating: 2804,
      ),
      TournamentPlayer(
        federation: 'CHN',
        name: 'Ju, Wenjun',
        title: 'GM',
        played: 0,
        rating: 2559,
      ),
      TournamentPlayer(federation: 'NOR', name: 'Unrated Local', played: 0),
    ],
    groupBroadcastId: 'event-1',
    avgElo: 2730,
  );
}
