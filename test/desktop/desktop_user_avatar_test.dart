import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/play/play_profile_repository.dart';
import 'package:chessever/desktop/widgets/desktop_user_profile_button.dart';
import 'package:chessever/repository/authentication/auth_repository.dart';
import 'package:chessever/repository/authentication/model/app_user.dart';
import 'package:chessever/repository/authentication/model/auth_state.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

void main() {
  Future<(_Auth, _Subscription)> mountAvatar(WidgetTester tester) async {
    final auth = _Auth();
    final subscription = _Subscription();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStateProvider.overrideWith(() => auth),
          subscriptionProvider.overrideWith((ref) => subscription),
          playUserProfileProvider.overrideWith(
            (ref) async => PlayUserProfile.fallback('Berkay'),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: DesktopUserAvatar())),
      ),
    );
    await tester.pump();
    return (auth, subscription);
  }

  testWidgets('auth and entitlement refreshes keep the photo mounted', (
    tester,
  ) async {
    final (auth, subscription) = await mountAvatar(tester);
    final photo = tester.element(find.byType(CachedNetworkImage));

    subscription.setPremium(true);
    await tester.pump();
    expect(tester.element(find.byType(CachedNetworkImage)), same(photo));

    auth.publish(const AppAuthState.loading());
    await tester.pump();
    expect(tester.element(find.byType(CachedNetworkImage)), same(photo));
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .imageUrl,
      _user.avatarUrl,
    );

    auth.publish(AppAuthState.authenticated(_user));
    subscription.setPremium(false);
    await tester.pump();
    expect(tester.element(find.byType(CachedNetworkImage)), same(photo));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign-out clears the retained account photo', (tester) async {
    final (auth, _) = await mountAvatar(tester);
    expect(find.byType(CachedNetworkImage), findsOneWidget);

    auth.publish(const AppAuthState.unauthenticated());
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching accounts replaces the previous photo stream', (
    tester,
  ) async {
    final (auth, _) = await mountAvatar(tester);
    final previous = tester.element(find.byType(CachedNetworkImage));
    auth.publish(
      AppAuthState.authenticated(
        AppUser(
          id: 'another-account',
          displayName: 'Another player',
          avatarUrl: 'https://example.com/another-avatar.png',
          createdAt: DateTime(2026),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.element(find.byType(CachedNetworkImage)),
      isNot(same(previous)),
    );
    expect(
      tester
          .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
          .imageUrl,
      'https://example.com/another-avatar.png',
    );
    expect(tester.takeException(), isNull);
  });
}

final _user = AppUser(
  id: 'account',
  displayName: 'Berkay',
  avatarUrl: 'https://example.com/avatar.png',
  createdAt: DateTime(2026),
);

class _Auth extends AuthController {
  @override
  AppAuthState build() => AppAuthState.authenticated(_user);

  void publish(AppAuthState value) => state = AsyncData(value);
}

class _Subscription extends SubscriptionNotifier {
  _Subscription() : super.stub(SubscriptionState());

  void setPremium(bool value) => state = SubscriptionState(isSubscribed: value);
}
