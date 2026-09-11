import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/widgets/desktop_access_gate.dart';
import 'package:chessever/desktop/widgets/desktop_board_access_gate.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/active_board_game.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

class _Membership extends SubscriptionNotifier {
  _Membership(super.initial) : super.stub();
  void publish(SubscriptionState next) => state = next;
}

void main() {
  final now = DateTime.utc(2026, 9, 10);
  test('legacy paid payload and personal recovery remain distinguishable', () {
    const legacy = BoardTabGameArgs(
      pgn: '',
      label: 'Database',
      whiteName: '',
      blackName: '',
      databaseGamesContinuation: BoardTabGamesContinuation.twicDatabase(),
    );
    final json = DesktopBoardWindowPayload.fromArgs(legacy).toJson();
    (json['args'] as Map).remove('requiresPremium');
    final restored = DesktopBoardWindowPayload.fromJson(json).args!;
    expect(restored.needsPremiumAdmission, isTrue);
    expect(
      restored
          .copyWith(
            librarySaveOrigin:
                const BoardTabLibrarySaveOrigin.cloudSavedAnalysis(
                  analysisId: 'saved',
                  title: 'Mine',
                ),
          )
          .needsPremiumAdmission,
      isFalse,
    );
  });
  test('unknown, refresh and error never authorize new Premium work', () {
    expect(
      desktopPremiumAccess(SubscriptionState(isLoading: true), now: now),
      DesktopAccess.checking,
    );
    expect(
      desktopPremiumAccess(
        SubscriptionState(isSubscribed: true, isLoading: true),
        now: now,
      ),
      DesktopAccess.checking,
    );
    expect(
      desktopPremiumAccess(
        SubscriptionState(isSubscribed: true, error: 'offline'),
        now: now,
      ),
      DesktopAccess.unavailable,
    );
  });
  test('expiry is exclusive; cancelled still active until expiry', () {
    expect(
      desktopPremiumAccess(
        SubscriptionState(isSubscribed: true, expirationDate: now),
        now: now,
      ),
      DesktopAccess.premiumRequired,
    );
    expect(
      desktopPremiumAccess(
        SubscriptionState(
          isSubscribed: true,
          willRenew: false,
          expirationDate: now.add(const Duration(seconds: 1)),
        ),
        now: now,
      ),
      DesktopAccess.allowed,
    );
    expect(
      desktopPremiumAccess(SubscriptionState(isSubscribed: true), now: now),
      DesktopAccess.allowed,
    );
  });
  test('phone explorer boundary is one-indexed ply, not ten full moves', () {
    expect(desktopExplorerPositionIsFree(0), isTrue);
    expect(desktopExplorerPositionIsFree(19), isTrue);
    expect(desktopExplorerPositionIsFree(20), isFalse);
    expect(desktopExplorerPositionIsFree(-1), isFalse);
    expect(
      desktopExplorerAccess(
        DesktopAccess.premiumRequired,
        playedPlies: 0,
        preparation: true,
      ),
      DesktopAccess.premiumRequired,
    );
    expect(
      desktopExplorerAccess(DesktopAccess.checking, playedPlies: 0),
      DesktopAccess.allowed,
    );
    expect(
      desktopExplorerAccess(DesktopAccess.unavailable, playedPlies: 21),
      DesktopAccess.unavailable,
    );
  });
  test('quota includes bulk operations but not updates, including overage', () {
    expect(desktopQuotaFits(2, 1, desktopFreeFavoritePlayers), isTrue);
    expect(desktopQuotaFits(3, 1, desktopFreeFavoritePlayers), isFalse);
    expect(desktopQuotaFits(8, 2, desktopFreeCloudGames), isTrue);
    expect(desktopQuotaFits(8, 3, desktopFreeCloudGames), isFalse);
    expect(desktopQuotaFits(25, 0, desktopFreeCloudGames), isTrue);
    expect(desktopQuotaFits(0, -1, desktopFreeCloudGames), isFalse);
  });
  test(
    'paid source identity survives copies and detached-window round trip',
    () {
      const paid = BoardTabGameArgs(
        pgn: '',
        label: 'Prepare',
        whiteName: '',
        blackName: '',
        requiresPremium: true,
      );
      final copied = paid.copyWith(label: 'Database game');
      expect(copied.requiresPremium, isTrue);
      final decoded = DesktopBoardWindowPayload.decode(
        DesktopBoardWindowPayload.fromArgs(copied).encode(),
      );
      expect(decoded.args!.requiresPremium, isTrue);
      expect(paid.copyWith(requiresPremium: false).requiresPremium, isFalse);
    },
  );
  testWidgets(
    'locked Prepare never mounts its data child; loading is not an upsell',
    (tester) async {
      final membership = _Membership(SubscriptionState(isLoading: true));
      var mounts = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [subscriptionProvider.overrideWith((_) => membership)],
          child: MaterialApp(
            home: DesktopAccessGate(
              feature: 'Prepare',
              builder: (_) {
                mounts++;
                return const Text('REAL PREPARATION DATA');
              },
            ),
          ),
        ),
      );
      expect(mounts, 0);
      expect(find.text('View Premium'), findsNothing);
      membership.publish(
        SubscriptionState(isSubscribed: true, isLoading: true),
      );
      await tester.pump();
      expect(
        mounts,
        0,
      ); // A NEW pane cannot inherit an in-flight refresh grant.
      membership.publish(SubscriptionState());
      await tester.pump();
      expect(mounts, 0);
      expect(find.text('Prepare · Premium'), findsOneWidget);
      membership.publish(SubscriptionState(isSubscribed: true));
      await tester.pump();
      expect(find.text('REAL PREPARATION DATA'), findsOneWidget);
      membership.publish(SubscriptionState());
      await tester.pump();
      expect(find.text('REAL PREPARATION DATA'), findsNothing);
    },
  );
  testWidgets(
    'admitted personal board stays mounted during refresh and expiry',
    (tester) async {
      final membership = _Membership(SubscriptionState(isSubscribed: true));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [subscriptionProvider.overrideWith((_) => membership)],
          child: MaterialApp(
            home: DesktopBoardAccessGate(
              builder: (_) => const Text('PRIVATE DRAFT'),
            ),
          ),
        ),
      );
      membership.publish(
        SubscriptionState(isSubscribed: true, isLoading: true),
      );
      await tester.pump();
      expect(find.text('PRIVATE DRAFT'), findsOneWidget);
      membership.publish(SubscriptionState());
      await tester.pump();
      expect(find.text('PRIVATE DRAFT'), findsOneWidget);
    },
  );
}
