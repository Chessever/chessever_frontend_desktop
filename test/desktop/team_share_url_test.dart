import 'package:chessever/desktop/services/team_share_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds the canonical team link with an encoded team name', () {
    expect(
      buildDesktopTeamEventShareUrl(
        teamName: 'Åland & Co',
        canonicalEventId: '4TdB92Cj',
        eventName: 'Olympiad 2026',
        tourId: '4TdB92Cj',
        tourSlug: 'olympiad-2026',
      ),
      'https://chessever.com/broadcast/olympiad-2026/4TdB92Cj/team/'
      '%C3%85land%20%26%20Co',
    );
  });

  test('returns null for archive and display-only identities', () {
    expect(
      buildDesktopTeamEventShareUrl(
        teamName: 'Team Norway',
        canonicalEventId: 'gamebase',
        tourId: 'gamebase',
        tourSlug: 'Norway Chess 2026',
      ),
      isNull,
    );
    expect(
      buildDesktopTeamEventShareUrl(
        teamName: 'Team Norway',
        canonicalEventId: 'Norway Chess 2026',
      ),
      isNull,
    );
    expect(
      buildDesktopTeamEventShareUrl(
        teamName: '  ',
        canonicalEventId: '4TdB92Cj',
      ),
      isNull,
    );
  });
}
