import 'dart:convert';
import 'dart:io';

import 'package:chessever/desktop/auth/web_auth_return_destination.dart';
import 'package:chessever/desktop/auth/web_sign_in_public_data.dart';
import 'package:chessever/desktop/auth/web_sign_in_events_data.dart';
import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/state/signed_out_events_presentation.dart';
import 'package:chessever/desktop/panes/desktop_likes_pane.dart';
import 'package:chessever/desktop/services/likes/community_likes_models.dart';
import 'package:chessever/desktop/shell/desktop_tab_bar.dart';
import 'package:chessever/desktop/auth/web_sign_in_preview_data.dart';
import 'package:chessever/desktop/auth/web_sign_in_preview_gate.dart';
import 'package:chessever/desktop/services/desktop_web_location.dart';
import 'package:chessever/desktop/shell/desktop_sidebar.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _SearchIntent extends Intent {
  const _SearchIntent();
}

void main() {
  test('public Likes preview keeps one real tab without a Home work tab', () {
    final tabs = publicSignInPreviewTabsState(
      WebSignInPreviewLocation.fromUri(Uri.parse('/app/likes/week')),
    );
    expect(tabs.tabs, hasLength(1));
    expect(tabs.tabs.single.kind, TabKind.likes);
    expect(tabs.active?.kind, TabKind.likes);
    expect(tabs.isHomeVisible, isFalse);
  });
  test('public Home preview never manufactures a work tab', () {
    final tabs = publicSignInPreviewTabsState(
      WebSignInPreviewLocation.fromUri(Uri.parse('/')),
    );
    expect(tabs.tabs, isEmpty);
    expect(tabs.isHomeVisible, isTrue);
  });
  testWidgets(
    'Events gate mounts real For You without a sample-game fallback',
    (tester) async {
      var legacySampleLoads = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebSignInPreviewGate(
              location: Uri.parse('/broadcast'),
              loadPreview: () async {
                legacySampleLoads++;
                throw StateError(
                  'Events must never load the unrelated game sample',
                );
              },
              loadEvents:
                  () async => PublicEventsPreview(
                    presentation: SignedOutEventsPresentationData(
                      capturedAt: DateTime.utc(2026, 11, 8),
                      forYouEvents: const AsyncValue.data([]),
                    ),
                  ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(TournamentsPane), findsOneWidget);
      expect(
        tester
            .widget<TournamentsPane>(find.byType(TournamentsPane))
            .readOnlyPresentation,
        isTrue,
      );
      expect(find.byType(DesktopTabBar), findsOneWidget);
      expect(legacySampleLoads, 0);
      expect(find.byKey(const ValueKey('web-sign-in-barrier')), findsOneWidget);
    },
  );

  testWidgets(
    'Likes gate mounts the actual production pane, not sample cards',
    (tester) async {
      var legacySampleLoads = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: WebSignInPreviewGate(
              location: Uri.parse('/app/likes/week'),
              loadPreview: () async {
                legacySampleLoads++;
                throw StateError('The legacy sample must not be requested');
              },
              loadLikes:
                  (_) async => PublicLikesPreview(
                    generatedAt: DateTime.utc(2026, 11, 8),
                    result: const CommunityLikesResult.ranked([]),
                  ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(DesktopLikesPane), findsOneWidget);
      expect(
        tester
            .widget<DesktopLikesPane>(find.byType(DesktopLikesPane))
            .readOnlyPresentation,
        isTrue,
      );
      expect(find.byType(DesktopTabBar), findsOneWidget);
      expect(legacySampleLoads, 0);
      expect(find.byKey(const ValueKey('web-sign-in-barrier')), findsOneWidget);
      expect(find.text('Sign in to explore ChessEver'), findsOneWidget);
    },
  );

  test('Home and disabled legacy destinations use the Home preview', () {
    for (final kind in [
      TabKind.tournaments,
      TabKind.calendar,
      TabKind.howToUse,
    ]) {
      final location = WebSignInPreviewLocation.fromKind(kind);
      expect(location.title, 'Home', reason: kind.name);
      expect(location.kind, 'events', reason: kind.name);
    }
    for (final path in [
      '/',
      '/broadcast',
      '/calendar',
      '/calendar/2026-11/example',
      '/how-to-use',
    ]) {
      final location = WebSignInPreviewLocation.fromUri(Uri.parse(path));
      expect(location.title, 'Home', reason: path);
      expect(location.kind, 'events', reason: path);
    }
  });

  test(
    'every shell kind and canonical entry route has a preview presentation',
    () {
      for (final kind in TabKind.values) {
        expect(
          WebSignInPreviewLocation.fromKind(kind).title,
          isNotEmpty,
          reason: kind.name,
        );
        expect(
          WebSignInPreviewLocation.fromUri(
            Uri.parse(desktopWebBasePath(kind)),
          ).title,
          isNotEmpty,
          reason: kind.name,
        );
      }
      expect(
        WebSignInPreviewLocation.fromUri(Uri.parse('/app/likes/week')).kind,
        'likes',
      );
      expect(
        WebSignInPreviewLocation.fromUri(
          Uri.parse('/games/XLoP8967?ply=1'),
        ).kind,
        'board',
      );
      expect(
        WebSignInPreviewLocation.fromUri(
          Uri.parse('/games/search?collection=gm'),
        ).kind,
        'games',
      );
      expect(
        WebSignInPreviewLocation.fromUri(
          Uri.parse('/databases/private-id'),
        ).kind,
        'library',
      );
      expect(
        WebSignInPreviewLocation.fromUri(
          Uri.parse('/broadcast/settings'),
        ).title,
        'Settings',
      );
      expect(
        WebSignInPreviewLocation.fromUri(Uri.parse('/analysis?editor=1')).title,
        'Board Editor',
      );
    },
  );

  test(
    'return destination preserves app state without storing OAuth credentials',
    () {
      expect(
        safeWebAuthReturnDestination(
          Uri.parse(
            'https://app.chessever.com/games/XLoP8967?ply=1&flip=1&code=secret&access_token=secret#refresh_token=secret',
          ),
        ),
        '/games/XLoP8967?ply=1&flip=1',
      );
      expect(
        safeWebAuthReturnDestination(Uri.parse('/app/likes/week')),
        '/app/likes/week',
      );
      expect(
        safeWebAuthReturnDestination(Uri.parse('//another-host/path')),
        isNull,
      );
      expect(
        safeWebAuthReturnDestination(Uri.parse('javascript:alert(1)')),
        isNull,
      );
      expect(safeWebAuthReturnDestination(Uri.parse('relative/path')), isNull);
    },
  );

  test('bundled preview contains only bounded genuine public-card fields', () {
    final raw =
        jsonDecode(
              File('assets/web_preview/public_preview.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final data = WebSignInPreviewData.fromJson(raw);
    expect(data.capturedAt, isNotNull);
    const fields = {
      'gameId',
      'rank',
      'likes',
      'fen',
      'whiteName',
      'blackName',
      'whiteTitle',
      'blackTitle',
      'whiteFederation',
      'blackFederation',
      'whiteRating',
      'blackRating',
      'result',
      'event',
      'date',
    };
    for (final period in const ['today', 'week', 'month', 'year']) {
      final rows = (raw['likes'] as Map)[period] as List;
      expect(rows.length, inInclusiveRange(1, 12));
      expect(data.games(period).length, rows.length);
      for (final row in rows.cast<Map>()) {
        expect(row.keys.toSet().difference(fields), isEmpty);
        expect(
          row['likes'],
          isNull,
          reason: 'This sample must never fabricate ranking counts.',
        );
        expect(row['rank'], isNull);
      }
      for (final game in data.games(period)) {
        expect(game.card.canResolveRemoteFen, isFalse);
      }
    }
  });

  testWidgets(
    'required overlay blocks dismissal, backdrop input and inherited app shortcuts',
    (tester) async {
      var searches = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Shortcuts(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.keyF, control: true):
                    _SearchIntent(),
              },
              child: Actions(
                actions: {
                  _SearchIntent: CallbackAction<_SearchIntent>(
                    onInvoke: (_) {
                      searches++;
                      return null;
                    },
                  ),
                },
                child: WebSignInPreviewGate(
                  location: Uri.parse('/app/likes/week'),
                  loadPreview:
                      () async => WebSignInPreviewData.fromJson(const {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Sign in to explore ChessEver'), findsOneWidget);
      final barrier = tester.widget<ModalBarrier>(
        find.byKey(const ValueKey('web-sign-in-barrier')),
      );
      expect(barrier.dismissible, isFalse);
      expect(find.byType(ExcludeSemantics), findsWidgets);
      expect(find.byType(ExcludeFocus), findsWidgets);
      expect(
        tester
            .widget<DesktopSidebar>(find.byType(DesktopSidebar))
            .readOnlyPreview,
        isTrue,
      );
      await tester.tapAt(const Offset(30, 120));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(searches, 0);
      expect(find.text('Sign in to explore ChessEver'), findsOneWidget);
      expect(find.text('Continue as guest'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
