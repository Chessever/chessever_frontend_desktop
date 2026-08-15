import 'package:chessever/desktop/state/active_tournament.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tournament detail segments', () {
    test('adds Bracket only for a proven individual knockout', () {
      expect(
        tournamentDetailSegmentsFor(isKnockout: true, isTeamEvent: false),
        [
          TournamentDetailSegment.about,
          TournamentDetailSegment.games,
          TournamentDetailSegment.bracket,
          TournamentDetailSegment.standings,
        ],
      );
    });

    test('keeps ordinary and team events on the existing three segments', () {
      const existing = [
        TournamentDetailSegment.about,
        TournamentDetailSegment.games,
        TournamentDetailSegment.standings,
      ];

      expect(
        tournamentDetailSegmentsFor(isKnockout: false, isTeamEvent: false),
        existing,
      );
      expect(
        tournamentDetailSegmentsFor(isKnockout: false, isTeamEvent: true),
        existing,
      );
      expect(
        tournamentDetailSegmentsFor(isKnockout: true, isTeamEvent: true),
        existing,
      );
    });
  });

  group('TournamentDetailLayoutTracker', () {
    test('retains a proven knockout layout across pending reloads', () {
      final tracker = TournamentDetailLayoutTracker();

      expect(
        tracker.resolve(
          tourId: 'playoffs',
          isKnockout: true,
          isDetectionPending: false,
        ),
        TournamentDetailLayout.individualKnockout,
      );
      expect(
        tracker.resolve(tourId: 'playoffs', isDetectionPending: true),
        TournamentDetailLayout.individualKnockout,
      );
    });

    test('does not leak the previous category layout to a new tour', () {
      final tracker =
          TournamentDetailLayoutTracker()
            ..resolve(tourId: 'playoffs', isKnockout: true);

      expect(
        tracker.resolve(tourId: 'swiss', isDetectionPending: true),
        TournamentDetailLayout.regular,
      );
    });

    test('team evidence overrides a remembered individual bracket', () {
      final tracker =
          TournamentDetailLayoutTracker()
            ..resolve(tourId: 'event', isKnockout: true);

      expect(
        tracker.resolve(
          tourId: 'event',
          isTeam: true,
          isDetectionPending: false,
        ),
        TournamentDetailLayout.team,
      );
    });

    test('preserves a provisionally requested Bracket while pending', () {
      final tracker = TournamentDetailLayoutTracker();

      expect(
        tracker.resolve(
          tourId: 'playoffs',
          isDetectionPending: true,
          unresolvedLayout: provisionalTournamentDetailLayoutForSegment(
            TournamentDetailSegment.bracket,
          ),
        ),
        TournamentDetailLayout.individualKnockout,
      );
    });
  });

  group('bracket open ownership', () {
    const originTabId = 'event-a-tab';

    bool canCommit({
      String activeTabId = originTabId,
      TournamentDetailSegment segment = TournamentDetailSegment.bracket,
      int currentEpoch = 7,
    }) => canCommitTournamentBracketOpen(
      tabs: DesktopTabsState(
        tabs: const [
          DesktopTab(
            id: originTabId,
            kind: TabKind.tournamentDetail,
            title: 'Event A',
          ),
          DesktopTab(id: 'other-tab', kind: TabKind.board, title: 'Board'),
        ],
        activeId: activeTabId,
      ),
      originTabId: originTabId,
      originEventId: 'event-a',
      expectedEventId: 'event-a',
      expectedTourId: 'playoffs-a',
      selectedBroadcastId: 'event-a',
      resolvedTourId: 'playoffs-a',
      currentSegment: segment,
      expectedEpoch: 7,
      currentEpoch: currentEpoch,
    );

    test('accepts the unchanged active Bracket command', () {
      expect(canCommit(), isTrue);
    });

    test('rejects completion after another tab becomes active', () {
      expect(canCommit(activeTabId: 'other-tab'), isFalse);
    });

    test('rejects completion after leaving Bracket', () {
      expect(canCommit(segment: TournamentDetailSegment.games), isFalse);
    });

    test('rejects an older click after a newer command starts', () {
      expect(canCommit(currentEpoch: 8), isFalse);
    });
  });
}
