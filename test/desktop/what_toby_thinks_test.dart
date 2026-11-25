import 'dart:async';

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart' show Square;
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/desktop/auth/desktop_access_admission.dart';
import 'package:chessever/desktop/auth/desktop_access_context.dart';
import 'package:chessever/desktop/auth/desktop_access_decision.dart';
import 'package:chessever/desktop/auth/desktop_access_policy.dart';
import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/services/desktop_global_search_intent.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/toby/what_toby_thinks.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/theme/app_theme.dart';

typedef _Call = ({Map<String, Object?> body, CancelToken cancel});

class _FakeGamebase extends GamebaseRepository {
  _FakeGamebase(this._answer) : super(Dio(), baseUrl: 'http://example.test');

  final FutureOr<GamebaseTobyReply> Function(_Call call, int index) _answer;
  final calls = <_Call>[];

  @override
  Future<GamebaseTobyReply> getTobyReading(
    Map<String, Object?> body,
    CancelToken cancelToken, {
    bool recheckAccess = false,
  }) async {
    final call = (body: body, cancel: cancelToken);
    calls.add(call);
    return _answer(call, calls.length - 1);
  }
}

class _Subscription extends SubscriptionNotifier {
  _Subscription(super.state) : super.stub();

  void become(SubscriptionState next) => state = next;
}

SubscriptionState _member() => SubscriptionState(
  isSubscribed: true,
  expirationDate: DateTime.now().add(const Duration(days: 30)),
);

GamebaseTobyReply _reply(int status, [Map<String, dynamic>? data]) => (
  statusCode: status,
  data: data,
  retryAfter: null,
);

Map<String, dynamic> _payload({String stage = 'final'}) => {
  'stage': stage,
  'sideToMove': 'white',
  'moves': [
    {
      'uci': 'g1f3',
      'san': 'Nf3',
      'probability': 0.71,
      'prior': 0.64,
      'wdl':
          stage == 'final'
              ? {'white': 0.30, 'draw': 0.55, 'black': 0.15}
              : null,
    },
    {
      'uci': 'd2d4',
      'san': 'd4',
      'probability': 0.2,
      'prior': 0.25,
      'wdl':
          stage == 'final'
              ? {'white': 0.32, 'draw': 0.50, 'black': 0.18}
              : null,
    },
  ],
  'positionWdl': {'white': 0.28, 'draw': 0.57, 'black': 0.15},
  'otherProbability': 0.09,
  'otherMoveCount': 18,
  'inputs': {
    'whiteRating': 2650,
    'blackRating': 2610,
    'ratingsKnown': true,
    'timeControl': 'classical',
    'ratingSource': 'FIDE',
    'baseTimeSeconds': 5400,
    'incrementSeconds': 30,
  },
};

const String _positionKey = 'position-after-e4-e5';

TobyTarget _target({String positionKey = _positionKey, int plies = 2}) =>
    TobyTarget.read(
      TobyRequest(
        moves: const ['e2e4', 'e7e5', 'g1f3', 'b8c6'].take(plies).toList(),
        whiteRating: 2650,
        blackRating: 2610,
        timeControl: '40/5400+30:1800+30',
        category: 'Classical',
      ),
      positionKey: positionKey,
    );

class _CloseTabIntent extends Intent {
  const _CloseTabIntent();
}

class _Harness {
  _Harness(this.container, this.repo, this.subscription, this.controller);

  final ProviderContainer container;
  final _FakeGamebase repo;
  final _Subscription subscription;
  final TobyPanelController controller;
  int closes = 0;
  int searches = 0;
  final played = <String>[];
}

/// Wide enough, in the test font (every glyph as wide as its size), for the
/// verdict beside the name and the move count beside the inputs.
const double _wide = 600;

Future<_Harness> _pump(
  WidgetTester tester, {
  required bool premium,
  bool open = false,
  double width = _wide,
  int? slots,
  double top = 0,
  FutureOr<GamebaseTobyReply> Function(_Call call, int index)? answer,
}) async {
  SharedPreferences.setMockInitialValues({
    if (open) tobyPanelOpenStorageKey: true,
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final repo = _FakeGamebase(answer ?? (_, _) => _reply(200, _payload()));
  final subscription = _Subscription(premium ? _member() : SubscriptionState());
  final container = ProviderContainer(
    overrides: [
      gamebaseRepositoryProvider.overrideWithValue(repo),
      subscriptionProvider.overrideWith((ref) => subscription),
      desktopEntitlementProvider.overrideWithValue(
        const DesktopEntitlementSnapshot(accountId: 'reader', generation: 1),
      ),
    ],
  );
  addTearDown(container.dispose);
  final harness = _Harness(
    container,
    repo,
    subscription,
    TobyPanelController(session: 'panel-test-0001'),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.escape): _CloseTabIntent(),
              SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true):
                  DesktopGlobalSearchIntent(),
              SingleActivator(
                    LogicalKeyboardKey.keyF,
                    control: true,
                    shift: true,
                  ):
                  DesktopGlobalSearchIntent(),
            },
            child: Actions(
              actions: {
                _CloseTabIntent: CallbackAction<_CloseTabIntent>(
                  onInvoke: (_) => harness.closes++,
                ),
                DesktopGlobalSearchIntent:
                    CallbackAction<DesktopGlobalSearchIntent>(
                      onInvoke: (_) => harness.searches++,
                    ),
              },
              child: Focus(
                autofocus: true,
                child: Container(
                  alignment: Alignment.topLeft,
                  padding: EdgeInsets.only(top: top),
                  child: SizedBox(
                    width: width,
                    child:
                        slots == null
                            ? _Panel(harness: harness)
                            : TobyPanelSlots(
                              slots: slots,
                              child: _Panel(harness: harness),
                            ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // The preference restores asynchronously.
  await tester.pump();
  await tester.pump();
  return harness;
}

/// Lets a test swap the panel's target, as the board does on a move.
final _targetNotifier = ValueNotifier<TobyTarget>(_target());

class _Panel extends StatelessWidget {
  const _Panel({required this.harness});

  final _Harness harness;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TobyTarget>(
      valueListenable: _targetNotifier,
      builder:
          (context, target, _) => WhatTobyThinks(
            target: target,
            controller: harness.controller,
            onPlayUci: harness.played.add,
          ),
    );
  }
}

double _panelHeight(WidgetTester tester) =>
    tester.getSize(find.byType(WhatTobyThinks)).height;

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(tobySettleDelay + const Duration(milliseconds: 20));
  await tester.pump();
  await tester.pump();
}

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: Offset.zero);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  return gesture;
}

/// The boxes painted by the panel's private [painter] type.
List<RenderBox> _painted(WidgetTester tester, String painter) => [
  for (final element
      in find
          .byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == painter,
          )
          .evaluate())
    element.renderObject! as RenderBox,
];

/// The busy notice reads the same in the slot area and the inputs row, as
/// on chessever.com: no full stop, and "Try again" a control of its own.
void _expectOneBusyWording() {
  expect(find.textContaining('Toby is busy right now.'), findsNothing);
  expect(find.textContaining('Toby is busy.'), findsNothing);
  expect(find.textContaining('busy right now Try again'), findsNothing);
}

/// The tooltip box showing [message].
Rect _tipRect(WidgetTester tester, String message) => tester.getRect(
  find
      .ancestor(of: find.text(message), matching: find.byType(DecoratedBox))
      .first,
);

/// Whether [text] was cut short (ellipsised) on screen.
bool _cut(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

void main() {
  setUp(() {
    tobyReadingCache.clear();
    _targetNotifier.value = _target();
  });

  testWidgets('collapsed, the panel is one 32 px row and asks nothing', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true);
    await tester.pump(const Duration(seconds: 2));

    expect(find.text(kTobyFeatureLabel), findsOneWidget);
    expect(_panelHeight(tester), kTobyPanelCollapsedHeight);
    expect(h.repo.calls, isEmpty);
  });

  testWidgets('a free reader who taps it gets the paywall and no request', (
    tester,
  ) async {
    final h = await _pump(tester, premium: false);
    final shown = <(DesktopAccessDecision, DesktopAccessContext?, String)>[];
    addTearDown(
      registerDesktopPaywallPresenter(h.container, (
        decision, {
        DesktopAccessContext? context,
        DesktopAccessResume? resume,
        required String surface,
      }) async {
        shown.add((decision, context, surface));
        return false;
      }),
    );

    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    final (decision, _, surface) = shown.single;
    expect(decision.outcome, DesktopAccess.premiumRequired);
    expect(decision.reason, DesktopAccessReason.premiumTobyPrediction);
    expect(surface, 'toby_panel_expand');
    expect(_panelHeight(tester), kTobyPanelCollapsedHeight);
    expect(h.repo.calls, isEmpty);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(tobyPanelOpenStorageKey), isNull);
  });

  testWidgets('a purchase in the paywall opens the panel it was asked for', (
    tester,
  ) async {
    final h = await _pump(tester, premium: false);
    addTearDown(
      registerDesktopPaywallPresenter(h.container, (
        decision, {
        DesktopAccessContext? context,
        DesktopAccessResume? resume,
        required String surface,
      }) async {
        h.subscription.become(_member());
        await resume?.run();
        return true;
      }),
    );

    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    await _settle(tester);

    expect(_panelHeight(tester), kTobyPanelExpandedHeight);
    expect(h.repo.calls, hasLength(1));
  });

  testWidgets('a stored open panel stays collapsed for a reader without '
      'Premium', (tester) async {
    final h = await _pump(tester, premium: false, open: true);
    await tester.pump(const Duration(seconds: 2));

    expect(_panelHeight(tester), kTobyPanelCollapsedHeight);
    expect(h.repo.calls, isEmpty);
  });

  testWidgets('expanded, the height holds through every stage', (tester) async {
    final network = Completer<GamebaseTobyReply>();
    final last = Completer<GamebaseTobyReply>();
    final h = await _pump(
      tester,
      premium: true,
      answer: (_, index) => index == 0 ? network.future : last.future,
    );
    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    expect(_panelHeight(tester), kTobyPanelExpandedHeight);
    expect(find.text('Toby is thinking…'), findsOneWidget);

    await _settle(tester);
    expect(h.repo.calls, hasLength(1));
    expect(_panelHeight(tester), kTobyPanelExpandedHeight);

    network.complete(_reply(202, _payload(stage: 'network')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Nf3'), findsOneWidget);
    // The position's verdict does not wait for the final reading.
    expect(find.text('W 28 · D 57 · B 15'), findsOneWidget);
    expect(h.repo.calls, hasLength(2));
    expect(h.repo.calls.last.body['have'], 'network');
    expect(_panelHeight(tester), kTobyPanelExpandedHeight);

    last.complete(_reply(200, _payload()));
    await tester.pump();
    await tester.pump();
    expect(find.text('W 28 · D 57 · B 15'), findsOneWidget);
    expect(find.text('2650 v 2610 · Classical'), findsOneWidget);
    expect(find.text('+18 moves · 9.0%'), findsOneWidget);
    expect(find.text(kTobyAttribution, findRichText: true), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Nf3, 71 percent. After it: White 30, draw 55, Black 15',
      ),
      findsOneWidget,
    );
    expect(_panelHeight(tester), kTobyPanelExpandedHeight);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(tobyPanelOpenStorageKey), isTrue);
  });

  testWidgets('hovering a candidate shows only its arrow; a click pins it', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    expect(find.text('Nf3'), findsOneWidget);

    final gesture = await _hover(tester, find.text('d4'));
    final hovered = h.controller.boardArrow.value!;
    expect(hovered.exclusive, isTrue);
    expect(hovered.positionKey, _positionKey);
    expect(
      (orig: hovered.arrow.orig, dest: hovered.arrow.dest),
      (orig: Square.d2, dest: Square.d4),
    );
    expect(hovered.arrow.scale, 0.8);
    // A deeper value of the panel's teal, so it reads on light squares too.
    expect(hovered.arrow.color, kTobyArrowColor);
    expect(kTobyArrowColor.a, closeTo(0.9, 1e-6));
    expect(kTobyArrowColor.withValues(alpha: 1), const Color(0xFF1E7F79));

    await gesture.moveTo(tester.getCenter(find.text('Nf3')));
    await tester.pump();
    expect(h.controller.boardArrow.value!.arrow.orig, Square.g1);

    await tester.tap(find.text('Nf3'));
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), 'g1f3');

    // Off the rows, the pin stands in for the engine arrows only.
    await gesture.moveTo(const Offset(800, 650));
    await tester.pump();
    final pinned = h.controller.boardArrow.value!;
    expect(pinned.exclusive, isFalse);
    expect(pinned.arrow, isA<cg.Arrow>());
    expect(pinned.arrow.orig, Square.g1);
  });

  testWidgets('a pin resets when the position changes', (tester) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), 'g1f3');

    _targetNotifier.value = _target(positionKey: 'next-position', plies: 3);
    await tester.pump();
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), isNull);
    expect(h.controller.boardArrow.value, isNull);

    _targetNotifier.value = _target();
    await tester.pump();
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), isNull);
  });

  testWidgets('collapsing clears the pin and stops asking', (tester) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump();
    expect(h.controller.boardArrow.value, isNotNull);

    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    expect(_panelHeight(tester), kTobyPanelCollapsedHeight);
    expect(h.controller.boardArrow.value, isNull);
    final asked = h.repo.calls.length;

    _targetNotifier.value = _target(positionKey: 'next-position', plies: 3);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(h.repo.calls, hasLength(asked));
  });

  testWidgets('Esc clears a pin while Toby has focus and does not close the '
      'tab; without a pin it still does', (tester) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), 'g1f3');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), isNull);
    expect(h.closes, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(h.closes, 1);
  });

  testWidgets('Cmd+Shift+F and Ctrl+Shift+F still reach global search from '
      'Toby', (tester) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump();

    for (final modifier in [
      LogicalKeyboardKey.metaLeft,
      LogicalKeyboardKey.controlLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
    }
    expect(h.searches, 2);
    // The pin is untouched by the chords.
    expect(h.controller.pinnedUci(_positionKey), 'g1f3');
  });

  testWidgets('Up and Down walk the rows and Enter pins the focused one', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(h.controller.hoveredUci(_positionKey), 'g1f3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(h.controller.hoveredUci(_positionKey), 'd2d4');
    expect(h.controller.boardArrow.value!.exclusive, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(h.controller.pinnedUci(_positionKey), 'd2d4');
    expect(h.closes, 0);
  });

  testWidgets('a row menu plays the candidate through the board', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);

    await tester.tap(find.text('d4'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play d4'));
    await tester.pumpAndSettle();

    expect(h.played, ['d2d4']);
  });

  testWidgets('what-if choices change what is asked, not the position', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    expect(h.repo.calls, hasLength(1));
    expect(h.repo.calls.single.body.containsKey('overrides'), isFalse);

    await tester.tap(find.text('2650 v 2610 · Classical'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2400'));
    await tester.pump();
    await tester.tap(find.text('Blitz'));
    await tester.pump();
    await _settle(tester);

    final body = h.repo.calls.last.body;
    expect(body['overrides'], {'rating': 2400, 'timeControl': 'blitz'});
    expect(body['moves'], ['e2e4', 'e7e5']);
    expect(h.controller.whatIf, (rating: 2400, cadence: TobyCadence.blitz));

    // Close the menu before the test ends.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('a membership that lapses collapses the panel and takes its '
      'arrows off the board', (tester) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump();
    final gesture = await _hover(tester, find.text('d4'));
    expect(h.controller.boardArrow.value!.exclusive, isTrue);
    expect(h.controller.pinnedUci(_positionKey), 'g1f3');

    // The rows unmount under the pointer: no exit event reaches them.
    h.subscription.become(SubscriptionState());
    await tester.pump();
    await tester.pump();
    expect(_panelHeight(tester), kTobyPanelCollapsedHeight);
    expect(h.controller.hoveredUci(_positionKey), isNull);
    expect(h.controller.pinnedUci(_positionKey), isNull);
    expect(h.controller.boardArrow.value, isNull);
    await gesture.removePointer();
  });

  testWidgets('Esc closes a what-if menu opened with the mouse, not the tab', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);

    final gesture = await _hover(tester, find.text('2650 v 2610 · Classical'));
    await gesture.down(tester.getCenter(find.text('2650 v 2610 · Classical')));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Both players rated'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Both players rated'), findsNothing);
    expect(h.closes, 0);
  });

  testWidgets('Tab onto the candidates shows the focused one on the board', (
    tester,
  ) async {
    final h = await _pump(tester, premium: true, open: true);
    await _settle(tester);
    expect(h.controller.boardArrow.value, isNull);

    for (var i = 0; i < 6; i++) {
      if (FocusManager.instance.primaryFocus?.debugLabel == 'Toby candidates') {
        break;
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Toby candidates');
    expect(h.controller.hoveredUci(_positionKey), 'g1f3');
    expect(h.controller.boardArrow.value!.exclusive, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(h.controller.hoveredUci(_positionKey), 'd2d4');
  });

  testWidgets('the candidates start at the same inset as every other line', (
    tester,
  ) async {
    await _pump(tester, premium: true, open: true);
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump(const Duration(milliseconds: 400));

    // A pinned row's outline takes no room.
    final inset = tester.getTopLeft(find.text(kTobyFeatureLabel)).dx;
    expect(tester.getTopLeft(find.text('Nf3')).dx, inset);
    expect(tester.getTopLeft(find.text('d4')).dx, inset);
    expect(tester.getTopLeft(find.text('+18 moves · 9.0%')).dx, inset);
  });

  testWidgets('a certainty reads 100% in the percentage column', (
    tester,
  ) async {
    final only =
        _payload()
          ..['moves'] = [
            {
              'uci': 'e1d1',
              'san': 'Kd1',
              'probability': 1.0,
              'prior': 1.0,
              'wdl': {'white': 0.1, 'draw': 0.8, 'black': 0.1},
            },
          ]
          ..['otherProbability'] = 0
          ..['otherMoveCount'] = 0;
    await _pump(
      tester,
      premium: true,
      open: true,
      answer: (_, _) => _reply(200, only),
    );
    await _settle(tester);

    // "100.0%" is wider than the 40 px column in the app's font and lost
    // its "%"; a certainty drops the decimal instead.
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('100.0%'), findsNothing);
    expect(
      find.bySemanticsLabel(
        'Kd1, 100 percent. After it: White 10, draw 80, Black 10',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a request Gamebase would refuse says why and asks nothing', (
    tester,
  ) async {
    _targetNotifier.value = TobyTarget.read(
      TobyRequest(moves: List<String>.filled(tobyMaxMoves + 1, 'e2e4')),
      positionKey: 'a-very-long-game',
    );
    final h = await _pump(tester, premium: true, open: true);
    await tester.pump(const Duration(seconds: 2));

    expect(find.text("Toby can't read this position"), findsOneWidget);
    expect(h.repo.calls, isEmpty);
  });

  testWidgets('a position Toby cannot read asks nothing', (tester) async {
    _targetNotifier.value = const TobyTarget.idle(TobyIdleReason.gameOver);
    final h = await _pump(tester, premium: true, open: true);
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Game over'), findsOneWidget);
    expect(_panelHeight(tester), kTobyPanelExpandedHeight);
    expect(h.repo.calls, isEmpty);
  });

  testWidgets('a busy service offers Try again inside the fixed height', (
    tester,
  ) async {
    await _pump(
      tester,
      premium: true,
      open: true,
      answer: (_, _) => _reply(503),
    );
    await tester.pump(tobyPositionBudget + const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Toby is busy right now'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    _expectOneBusyWording();
    expect(_panelHeight(tester), kTobyPanelExpandedHeight);
  });

  testWidgets('every bar is drawn, with its first-instinct marker and both '
      'tooltips', (tester) async {
    final payload =
        _payload()
          ..['moves'] = [
            for (final (uci, san, probability, prior) in [
              ('g1f3', 'Nf3', 0.71, 0.64),
              ('d2d4', 'd4', 0.12, 0.12),
              ('c2c4', 'c4', 0.08, null),
            ])
              {
                'uci': uci,
                'san': san,
                'probability': probability,
                'prior': prior,
                'wdl': {'white': 0.30, 'draw': 0.55, 'black': 0.15},
              },
          ];
    await _pump(
      tester,
      premium: true,
      open: true,
      answer: (_, _) => _reply(200, payload),
    );
    await _settle(tester);

    // Inside a tooltip the bars sit in a loose stack; they used to collapse
    // to nothing there, which hid every marked bar and every outcome bar.
    final bars = _painted(tester, '_ProbabilityPainter');
    expect(bars, hasLength(3));
    expect(bars.map((box) => box.size.width).toSet(), hasLength(1));
    expect(bars.first.size.width, greaterThan(100));
    final outcomes = _painted(tester, '_WdlPainter');
    expect(outcomes.map((box) => box.size), everyElement(const Size(40, 26)));
    // An empty track still reads against the panel.
    expect(bars.last, paints..rrect(color: kDividerColor));

    final gesture = await _hover(
      tester,
      find
          .byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_ProbabilityPainter',
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.text('First instinct 64% · after checking 71%'),
      findsOneWidget,
    );

    await gesture.moveTo(
      tester.getCenter(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.painter.runtimeType.toString() == '_WdlPainter',
            )
            .first,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('White 30 · draw 55 · Black 15'), findsOneWidget);
  });

  testWidgets('the bar tooltips lie exactly over the next row, never over the '
      'header or the row they explain', (tester) async {
    // Room above, so a tooltip opening upwards would fit there.
    await _pump(tester, premium: true, open: true, top: 200);
    await _settle(tester);

    final header = tester.getRect(find.text(kTobyFeatureLabel));
    final panel = tester.getRect(find.byType(WhatTobyThinks));
    final bar = tester.getRect(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_ProbabilityPainter',
          )
          .first,
    );
    final gesture = await _hover(
      tester,
      find
          .byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_ProbabilityPainter',
          )
          .first,
    );
    await tester.pump(const Duration(milliseconds: 600));
    // Let the entrance scale finish.
    await tester.pump(const Duration(milliseconds: 400));
    const prior = 'First instinct 64% · after checking 71%';
    expect(find.text(prior), findsOneWidget);
    // The second row's box: the rows' 16 px inset, one row tall.
    final nextRow = Rect.fromLTRB(
      panel.left + 16,
      bar.bottom,
      panel.right - 16,
      bar.bottom + 26,
    );
    var tip = _tipRect(tester, prior);
    expect(tip, rectMoreOrLessEquals(nextRow, epsilon: 0.01));
    expect(tip.overlaps(header), isFalse);
    // Its text starts where the SANs do.
    expect(
      tester.getTopLeft(find.text(prior)).dx,
      tester.getTopLeft(find.text('Nf3')).dx,
    );

    await gesture.moveTo(
      tester.getCenter(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is CustomPaint &&
                  widget.painter.runtimeType.toString() == '_WdlPainter',
            )
            .first,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    // Let the entrance scale finish.
    await tester.pump(const Duration(milliseconds: 400));
    const outcome = 'White 30 · draw 55 · Black 15';
    expect(find.text(outcome), findsOneWidget);
    tip = _tipRect(tester, outcome);
    expect(tip, rectMoreOrLessEquals(nextRow, epsilon: 0.01));
    expect(tip.overlaps(header), isFalse);
    // Its text ends where the outcome bars do.
    expect(
      tester.getTopRight(find.text(outcome)).dx,
      moreOrLessEquals(
        tester
            .getTopRight(
              find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is CustomPaint &&
                        widget.painter.runtimeType.toString() == '_WdlPainter',
                  )
                  .first,
            )
            .dx,
        epsilon: 0.01,
      ),
    );
  });

  testWidgets('under the last slot a bar tooltip lies over the inputs row', (
    tester,
  ) async {
    await _pump(tester, premium: true, open: true, slots: 2, top: 200);
    await _settle(tester);

    final panel = tester.getRect(find.byType(WhatTobyThinks));
    final outcomes = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_WdlPainter',
    );
    final last = tester.getRect(outcomes.last);
    await _hover(tester, outcomes.last);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));

    const outcome = 'White 32 · draw 50 · Black 18';
    final inputsRow = Rect.fromLTRB(
      panel.left + 16,
      last.bottom,
      panel.right - 16,
      last.bottom + 22,
    );
    expect(
      _tipRect(tester, outcome),
      rectMoreOrLessEquals(inputsRow, epsilon: 0.01),
    );
    // The rows' 8 px corner, also on this shorter tip.
    final tip =
        tester
                .widget<DecoratedBox>(
                  find
                      .ancestor(
                        of: find.text(outcome),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    final corners = tip.borderRadius!
        .resolve(TextDirection.ltr)
        .toRRect(inputsRow);
    expect(corners.tlRadius, const Radius.circular(8));
    expect(corners.brRadius, const Radius.circular(8));
    // The attribution under it stays clear.
    expect(
      tester.getRect(find.text(kTobyAttribution, findRichText: true)).top,
      greaterThanOrEqualTo(inputsRow.bottom),
    );
  });

  testWidgets('in the network stage the outcome column shows an empty track '
      'and the verdict shows', (tester) async {
    final last = Completer<GamebaseTobyReply>();
    await _pump(
      tester,
      premium: true,
      open: true,
      answer:
          (_, index) =>
              index == 0
                  ? _reply(202, _payload(stage: 'network'))
                  : last.future,
    );
    await _settle(tester);
    expect(find.text('Nf3'), findsOneWidget);

    // One track per row, where the outcome bars will be: the bars' track
    // colour and nothing filled.
    final tracks = _painted(tester, '_WdlPainter');
    expect(tracks, hasLength(2));
    expect(tracks.map((box) => box.size), everyElement(const Size(40, 26)));
    final bars = _painted(tester, '_ProbabilityPainter');
    for (final (track, bar) in [(tracks[0], bars[0]), (tracks[1], bars[1])]) {
      expect(track, paints..rrect(color: kDividerColor));
      expect(track, paintsExactlyCountTimes(#drawRRect, 1));
      expect(track, paintsExactlyCountTimes(#drawRect, 0));
      expect(
        track.localToGlobal(Offset.zero).dy,
        bar.localToGlobal(Offset.zero).dy,
      );
    }
    expect(find.text('W 28 · D 57 · B 15'), findsOneWidget);
    // An unknown outcome offers no tooltip.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(
      tracks.first.localToGlobal(tracks.first.size.center(Offset.zero)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('White '), findsNothing);
  });

  testWidgets('the name and the inputs are never cut: the verdict and the '
      'move count give way', (tester) async {
    await _pump(tester, premium: true, open: true, width: 480);
    await _settle(tester);

    expect(find.text('W 28 · D 57 · B 15'), findsNothing);
    expect(_cut(tester, kTobyFeatureLabel), isFalse);
    expect(find.text('+18 moves · 9.0%'), findsNothing);
    expect(_cut(tester, '2650 v 2610 · Classical'), isFalse);
  });

  testWidgets('a busy notice keeps its whole sentence beside Try again', (
    tester,
  ) async {
    await _pump(
      tester,
      premium: true,
      open: true,
      width: 480,
      answer:
          (_, index) =>
              index == 0
                  ? _reply(202, _payload(stage: 'network'))
                  : _reply(503),
    );
    await tester.pump(tobyPositionBudget + const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Nf3'), findsOneWidget);
    expect(_cut(tester, 'Toby is busy right now'), isFalse);
    expect(find.text('Try again'), findsOneWidget);
    _expectOneBusyWording();
    // Two separate pieces, the action after the notice.
    expect(
      tester.getTopLeft(find.text('Try again')).dx,
      greaterThan(tester.getTopRight(find.text('Toby is busy right now')).dx),
    );
    // The inputs give way to the notice rather than squeezing it.
    expect(find.text('2650 v 2610 · Classical'), findsNothing);
  });

  testWidgets('a long promotion shrinks into the move column whole', (
    tester,
  ) async {
    final payload =
        _payload()
          ..['moves'] = [
            {
              'uci': 'e7d8',
              'san': 'exd8=Q+',
              'probability': 0.999,
              'prior': 0.8,
              'wdl': null,
            },
          ];
    await _pump(
      tester,
      premium: true,
      open: true,
      answer: (_, _) => _reply(200, payload),
    );
    await _settle(tester);

    expect(_cut(tester, 'exd8=Q+'), isFalse);
    final san = tester.getRect(find.text('exd8=Q+'));
    expect(san.width, lessThanOrEqualTo(56));
    expect(san.left, tester.getTopLeft(find.text(kTobyFeatureLabel)).dx);
  });

  testWidgets('messages sit centred in the slot area', (tester) async {
    final h = await _pump(
      tester,
      premium: true,
      answer: (_, _) => Completer<GamebaseTobyReply>().future,
    );
    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    expect(h.repo.calls, hasLength(1));

    final top = tester.getTopLeft(find.byType(WhatTobyThinks)).dy;
    final slotsCentre = top + kTobyPanelCollapsedHeight + 5 * 26 / 2;
    expect(
      tester.getCenter(find.text('Toby is thinking…')).dy,
      moreOrLessEquals(slotsCentre, epsilon: 1),
    );

    // A busy notice and its retry share the centre line.
    await tester.pump(tobyPositionBudget);
    await tester.pump();
    expect(
      tester.getCenter(find.text('Toby is busy right now')).dy,
      moreOrLessEquals(slotsCentre, epsilon: 1),
    );
    expect(
      tester.getCenter(find.text('Try again')).dy,
      moreOrLessEquals(slotsCentre, epsilon: 1),
    );
  });

  testWidgets('before a reading the inputs show what will be read; the '
      'what-if menu leaves when it can change nothing', (tester) async {
    await _pump(
      tester,
      premium: true,
      open: true,
      answer: (_, _) => Completer<GamebaseTobyReply>().future,
    );
    await tester.pump();
    expect(find.text('Toby is thinking…'), findsOneWidget);
    expect(find.text('2650 v 2610 · Classical'), findsOneWidget);
    expect(find.text('What if…'), findsNothing);
    expect(find.byType(FPopover), findsOneWidget);

    _targetNotifier.value = const TobyTarget.idle(TobyIdleReason.variant);
    await tester.pump();
    expect(find.text('Toby reads standard chess positions'), findsOneWidget);
    expect(find.byType(FPopover), findsNothing);
  });

  testWidgets('an unconfirmed membership offers no what-if menu', (
    tester,
  ) async {
    await _pump(
      tester,
      premium: true,
      open: true,
      answer: (_, _) => _reply(403, {'error': 'premium_required'}),
    );
    await _settle(tester);

    expect(find.text("Premium couldn't be confirmed"), findsOneWidget);
    expect(find.byType(FPopover), findsNothing);
  });

  testWidgets('opening the panel asks at once; a new position waits out the '
      'settle', (tester) async {
    final h = await _pump(
      tester,
      premium: true,
      answer: (_, _) => Completer<GamebaseTobyReply>().future,
    );
    await tester.tap(find.text(kTobyFeatureLabel));
    await tester.pump();
    expect(h.repo.calls, hasLength(1));

    _targetNotifier.value = _target(positionKey: 'next-position', plies: 3);
    await tester.pump();
    await tester.pump(tobySettleDelay - const Duration(milliseconds: 20));
    expect(h.repo.calls, hasLength(1));
    await tester.pump(const Duration(milliseconds: 40));
    expect(h.repo.calls, hasLength(2));
  });

  testWidgets('a short engine pane gets three slots; the rest join the '
      'move count', (tester) async {
    final payload =
        _payload()
          ..['moves'] = [
            for (final (uci, san, probability) in [
              ('g1f3', 'Nf3', 0.40),
              ('d2d4', 'd4', 0.20),
              ('c2c4', 'c4', 0.15),
              ('b1c3', 'Nc3', 0.10),
              ('g2g3', 'g3', 0.06),
            ])
              {
                'uci': uci,
                'san': san,
                'probability': probability,
                'prior': probability,
                'wdl': null,
              },
          ];
    await _pump(
      tester,
      premium: true,
      open: true,
      slots: 3,
      answer: (_, _) => _reply(200, payload),
    );
    await _settle(tester);

    expect(_panelHeight(tester), tobyPanelHeight(expanded: true, slots: 3));
    expect(_panelHeight(tester), kTobyPanelExpandedHeight - 2 * 26);
    expect(find.text('c4'), findsOneWidget);
    expect(find.text('Nc3'), findsNothing);
    expect(find.text('g3'), findsNothing);
    // 18 others plus the two left out, 9% plus their 16%.
    expect(find.text('+20 moves · 25.0%'), findsOneWidget);
  });

  testWidgets('one corner radius, and the chevron brightens with the label', (
    tester,
  ) async {
    await _pump(tester, premium: true);
    final chevron = find.byIcon(Icons.chevron_right_rounded);
    expect(tester.widget<Icon>(chevron).color, kWhiteColor70);
    await _hover(tester, find.text(kTobyFeatureLabel));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(tester.widget<Icon>(chevron).color, isSameColorAs(kWhiteColor));
    final label = tester.widget<Text>(find.text(kTobyFeatureLabel));
    expect(label.style!.color, isSameColorAs(kWhiteColor));

    await tester.tap(find.text(kTobyFeatureLabel));
    await _settle(tester);
    await tester.tap(find.text('Nf3'));
    await tester.pump(const Duration(milliseconds: 400));
    final radii = <BorderRadiusGeometry?>{
      for (final box in tester.widgetList<Container>(
        find.descendant(
          of: find.byType(WhatTobyThinks),
          matching: find.byType(Container),
        ),
      ))
        for (final decoration in [box.decoration, box.foregroundDecoration])
          if (decoration is BoxDecoration && decoration.borderRadius != null)
            decoration.borderRadius,
    };
    expect(radii, {BorderRadius.circular(8)});
  });

  test('resolveTobyTarget reads only a standard, settled, foreground '
      'position', () {
    TobyRequest request() => TobyRequest(moves: const ['e2e4']);
    TobyTarget resolve({
      bool foreground = true,
      bool previewing = false,
      bool gameOver = false,
      String? variant,
    }) => resolveTobyTarget(
      foreground: foreground,
      previewing: previewing,
      gameOver: gameOver,
      variant: variant,
      positionKey: 'fen',
      request: request,
    );

    expect(resolve().request, isNotNull);
    expect(resolve().positionKey, 'fen');
    expect(resolve(variant: 'Standard').request, isNotNull);
    expect(resolve(variant: 'Chess960').idle, TobyIdleReason.variant);
    expect(resolve(variant: 'Atomic').idle, TobyIdleReason.variant);
    expect(resolve(previewing: true).idle, TobyIdleReason.preview);
    expect(resolve(gameOver: true).idle, TobyIdleReason.gameOver);
    expect(resolve(foreground: false).idle, TobyIdleReason.background);
  });
}
