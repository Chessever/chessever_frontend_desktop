import 'dart:io';
import 'package:chessever/desktop/services/tournament_server/tournament_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_play_access.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

void main() {
  test('denied tournament start starts no local server', () async {
    final server = TournamentServer(canStart: () => false);
    addTearDown(server.dispose);
    expect(await server.start(), isFalse);
    expect(server.state.status, TournamentServerStatus.stopped);
  });

  const account = DesktopEntitlementSnapshot(
    accountId: 'account',
    generation: 1,
  );
  DesktopAccess decide(SubscriptionState sub) =>
      evaluateDesktopAccess(
        context: desktopPlayAccessContext,
        entitlement: account,
        subscription: sub,
      ).outcome;

  test('Play entry and starts require a verified Premium decision', () {
    expect(decide(SubscriptionState()), DesktopAccess.premiumRequired);
    expect(decide(SubscriptionState(isLoading: true)), DesktopAccess.checking);
    expect(
      decide(SubscriptionState(error: 'offline')),
      DesktopAccess.temporarilyUnavailable,
    );
    expect(
      decide(SubscriptionState(isSubscribed: true)),
      DesktopAccess.allowed,
    );
  });

  test(
    'new sessions recheck admission, not entitlement-watch live teardown',
    () {
      final source =
          File('lib/desktop/state/play_session.dart').readAsStringSync();
      expect(
        source,
        contains('readDesktopAccess(ref.read, desktopPlayAccessContext)'),
      );
      expect(source, contains('args == null || !admitted'));
      final pane = File('lib/desktop/panes/play_pane.dart').readAsStringSync();
      expect(pane, contains('!access.isAllowed && session == null && !retainedTournament'));
      expect(pane, contains('if (!admitDesktopPlay(ref)) return;'));
      final seed =
          File(
            'lib/desktop/services/play/play_from_here.dart',
          ).readAsStringSync();
      expect(
        seed,
        contains('container.read(desktopAccountIdentityProvider) != account'),
      );
      expect(
        seed,
        contains('container.read(desktopTabsProvider).activeId != owner'),
      );
    },
  );
}
