import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/auth/desktop_paywall_copy.dart';
import 'package:chessever/desktop/widgets/desktop_date_gate_prompt.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 4, 12);
  DesktopAccessDecision decide(
    DesktopAccessContext request, {
    bool webapp = true,
    SubscriptionState? subscription,
  }) => evaluateDesktopAccess(
    context: request,
    subscription: subscription ?? SubscriptionState(),
    entitlement: DesktopEntitlementSnapshot.guest,
    now: now,
    isWebApp: webapp,
  );

  for (final origin in [
    DesktopDiscoveryOrigin.miniatures,
    DesktopDiscoveryOrigin.favorites,
  ]) {
    DesktopAccessContext request(DesktopAction action, {DateTime? date}) =>
        DesktopAccessContext(
          feature:
              origin == DesktopDiscoveryOrigin.miniatures
                  ? DesktopFeature.miniatures
                  : DesktopFeature.broadcast,
          action: action,
          origin: origin,
          contentDate: date,
        );
    group('webapp ${origin.name}', () {
      for (final action in [
        DesktopAction.view,
        DesktopAction.sort,
        DesktopAction.filter,
      ]) {
        test(
          '${action.name} list remains free even during membership failure',
          () {
            expect(
              decide(
                request(action),
                subscription: SubscriptionState(error: 'offline'),
              ).isAllowed,
              isTrue,
            );
          },
        );
      }
      for (final date in [
        null,
        DateTime.utc(2026, 11, 4),
        DateTime.utc(2026, 11, 3),
      ]) {
        test('opening date $date requires Premium', () {
          final context = request(DesktopAction.openContent, date: date);
          expect(decide(context).outcome, DesktopAccess.premiumRequired);
          expect(decide(context).reason, DesktopAccessReason.premiumPaidSource);
          final copy = desktopPaywallCopyFor(decide(context), context: context);
          expect(
            copy.title,
            contains(
              origin == DesktopDiscoveryOrigin.miniatures
                  ? 'Miniatures'
                  : 'Favorites',
            ),
          );
        });
      }
      for (final action in [
        DesktopAction.previewNavigate,
        DesktopAction.fetchPgn,
        DesktopAction.insertMove,
        DesktopAction.copy,
        DesktopAction.save,
        DesktopAction.export,
      ]) {
        test('${action.name} cannot bypass the content gate', () {
          expect(
            decide(request(action, date: now)).outcome,
            DesktopAccess.premiumRequired,
          );
        });
      }
      test('Premium opens content; loading/error are not sales prompts', () {
        final context = request(DesktopAction.openContent, date: now);
        expect(
          decide(
            context,
            subscription: SubscriptionState(isSubscribed: true),
          ).isAllowed,
          isTrue,
        );
        expect(
          decide(
            context,
            subscription: SubscriptionState(isLoading: true),
          ).outcome,
          DesktopAccess.checking,
        );
        expect(
          decide(
            context,
            subscription: SubscriptionState(error: 'offline'),
          ).outcome,
          DesktopAccess.temporarilyUnavailable,
        );
      });
      test('native retains its current free path', () {
        expect(
          decide(
            request(DesktopAction.openContent, date: now),
            webapp: false,
          ).isAllowed,
          isTrue,
        );
      });
      test(
        'source provenance survives serialization and board retargeting',
        () {
          final original = request(DesktopAction.openContent, date: now);
          final restored = DesktopAccessContext.fromJson(original.toJson());
          expect(decide(restored).outcome, DesktopAccess.premiumRequired);
          expect(
            decide(
              restored.copyWith(
                feature: DesktopFeature.broadcast,
                action: DesktopAction.fetchPgn,
              ),
            ).outcome,
            DesktopAccess.premiumRequired,
          );
        },
      );
    });
  }

  test('favorite-event/player management is not a paid game open', () {
    expect(
      decide(
        const DesktopAccessContext(
          feature: DesktopFeature.favorites,
          action: DesktopAction.create,
          origin: DesktopDiscoveryOrigin.favorites,
          quota: DesktopQuota.none,
        ),
      ).isAllowed,
      isTrue,
    );
  });
  test('ordinary broadcast and retained library copies stay free', () {
    expect(
      decide(
        const DesktopAccessContext(
          feature: DesktopFeature.broadcast,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.broadcast,
        ),
      ).isAllowed,
      isTrue,
    );
    expect(
      decide(
        const DesktopAccessContext(
          feature: DesktopFeature.ownedDocument,
          action: DesktopAction.openContent,
          origin: DesktopDiscoveryOrigin.favorites,
          ownedDocument: true,
          retainedSaveId: 'saved-copy',
        ),
      ).isAllowed,
      isTrue,
    );
  });

  const locked = DesktopAccessDecision(
    DesktopAccess.premiumRequired,
    DesktopAccessReason.premiumPaidSource,
  );
  for (final afterAllowed in [false, true]) {
    testWidgets(
      'webapp opens paywall directly and rechecks access ($afterAllowed)',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        );
        var evaluations = 0;
        var presentations = 0;
        final admitted = await resolveDesktopDateGate(
          context,
          isWebApp: true,
          title: 'Intermediate prompt',
          body: 'Not shown on webapp',
          evaluate: () {
            evaluations++;
            return evaluations > 1 && afterAllowed
                ? const DesktopAccessDecision(
                  DesktopAccess.allowed,
                  DesktopAccessReason.allowedPremium,
                )
                : locked;
          },
          presentPaywall: (_, decision, accessContext) async {
            presentations++;
            expect(decision, locked);
            return true;
          },
        );
        expect(presentations, 1);
        expect(evaluations, 2);
        expect(admitted, afterAllowed);
        expect(find.byType(DesktopDateGateDialog), findsNothing);
      },
    );
  }

  testWidgets('native desktop keeps the explanation and dismiss path', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final pending = resolveDesktopDateGate(
      context,
      isWebApp: false,
      title: 'Native gate',
      body: 'Native rule',
      evaluate: () => locked,
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopDateGateDialog), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(await pending, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
