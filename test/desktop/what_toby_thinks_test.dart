import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart' show Side, Square;
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
import 'package:chessever/desktop/services/engine/game_analysis_report.dart'
    show GameMoveClassification;
import 'package:chessever/desktop/services/toby/toby_classes.dart';
import 'package:chessever/desktop/state/desktop_account_identity.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/move_classification_icon.dart';
import 'package:chessever/desktop/widgets/toby/what_toby_thinks.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';
import 'package:chessever/screens/chessboard/game_review/classification_style.dart';
import 'package:chessever/theme/app_theme.dart';

typedef _Call = ({Map<String, Object?> body, CancelToken cancel});

class _FakeGamebase extends GamebaseRepository {
  _FakeGamebase(this._answer) : super(Dio(), baseUrl: 'http://example.test');

  final FutureOr<GamebaseTobyReply> Function(_Call call, int index) _answer;
  final calls = <_Call>[];

  /// The opening tree's game count per move, for the Book class, and the
  /// positions it was asked for.
  Map<String, int>? bookCounts;
  final bookAsks = <({String fen, String line})>[];

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
      'prior': 0.22,
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

Map<String, dynamic> _move(String uci, String san, double p, {double? prior}) =>
    {
      'uci': uci,
      'san': san,
      'probability': p,
      'prior': prior ?? p,
      'wdl': {'white': 0.3, 'draw': 0.5, 'black': 0.2},
    };

const String _positionKey = 'position-after-e4-e5';

/// Italian Game, White to move: a real position, for the board facts the
/// report classes read.
const String _italian =
    'r1bq1rk1/ppp2ppp/2n2n2/2b1p3/2B1P3/2NP1N2/PPP2PPP/R1BQ1RK1 w - - 0 7';

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

class _StepIntent extends Intent {
  const _StepIntent();
}

/// Space on the board plays Stockfish's move.
class _PlayEngineMoveIntent extends Intent {
  const _PlayEngineMoveIntent();
}

class _Harness {
  _Harness(
    this.container,
    this.repo,
    this.subscription,
    this.controller,
    this.bookAccess,
  );

  final ProviderContainer container;
  final _FakeGamebase repo;
  final _Subscription subscription;
  final TobyPanelController controller;
  final DesktopAccessContext? bookAccess;
  int closes = 0;
  int searches = 0;
  int steps = 0;
  int engineMoves = 0;
  final played = <String>[];
}

/// The reader's account, as the board's window resolves it.
class _Reader extends DesktopAccountIdentityNotifier {
  _Reader(this.identity);

  final DesktopAccountIdentity identity;

  @override
  DesktopAccountIdentity build() => identity;
}

/// The engine pane's `playedContext` for an opening position: the explorer
/// request the Book class asks under.
const _bookAccess = DesktopAccessContext(
  feature: DesktopFeature.openingExplorer,
  action: DesktopAction.previewNavigate,
  origin: DesktopDiscoveryOrigin.gamebase,
  playedPlies: 12,
);

/// Wide enough, in the test font (every glyph as wide as its size), for the
/// verdict beside the inputs and the outcome bars beside the moves.
const double _wide = 600;

/// The header's tabs over the list area, as the engine pane composes them:
/// the Toby view mounts only while its tab is chosen.
Future<_Harness> _pump(
  WidgetTester tester, {
  required bool premium,
  bool toby = false,
  bool guest = false,
  double width = _wide,
  double height = 560,
  FutureOr<GamebaseTobyReply> Function(_Call call, int index)? answer,
  Map<String, int>? bookCounts,
  DesktopAccountIdentity identity = const DesktopAccountIdentity(
    userId: 'reader',
  ),
  DesktopAccessContext? bookAccess = _bookAccess,
}) async {
  SharedPreferences.setMockInitialValues({if (toby) tobyTabStorageKey: true});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final repo = _FakeGamebase(answer ?? (_, _) => _reply(200, _payload()))
    ..bookCounts = bookCounts;
  final subscription = _Subscription(premium ? _member() : SubscriptionState());
  final container = ProviderContainer(
    overrides: [
      gamebaseRepositoryProvider.overrideWithValue(repo),
      tobyBookCountsProvider.overrideWith((ref, position) {
        repo.bookAsks.add(position);
        return repo.bookCounts;
      }),
      desktopAccountIdentityProvider.overrideWith(() => _Reader(identity)),
      subscriptionProvider.overrideWith((ref) => subscription),
      desktopEntitlementProvider.overrideWithValue(
        guest
            ? DesktopEntitlementSnapshot.guest
            : const DesktopEntitlementSnapshot(
              accountId: 'reader',
              generation: 1,
            ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final harness = _Harness(
    container,
    repo,
    subscription,
    TobyPanelController(session: 'panel-test-0001'),
    bookAccess,
  );
  addTearDown(harness.controller.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.escape): _CloseTabIntent(),
              SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(),
              SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(),
              SingleActivator(LogicalKeyboardKey.space):
                  _PlayEngineMoveIntent(),
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
                _StepIntent: CallbackAction<_StepIntent>(
                  onInvoke: (_) => harness.steps++,
                ),
                _PlayEngineMoveIntent: CallbackAction<_PlayEngineMoveIntent>(
                  onInvoke: (_) => harness.engineMoves++,
                ),
                DesktopGlobalSearchIntent:
                    CallbackAction<DesktopGlobalSearchIntent>(
                      onInvoke: (_) => harness.searches++,
                    ),
              },
              child: Focus(
                autofocus: true,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: _Pane(harness: harness),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // The chosen tab restores asynchronously.
  await tester.pump();
  await tester.pump();
  return harness;
}

/// Lets a test swap the view's target, as the board does on a move.
final _targetNotifier = ValueNotifier<TobyTarget>(_target());

class _Pane extends ConsumerWidget {
  const _Pane({required this.harness});

  final _Harness harness;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toby = ref.watch(tobyTabSelectedProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The test font is wide: a narrow pane shrinks the tabs, as the
        // engine pane's header does.
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: TobyViewTabs(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child:
              toby
                  ? ValueListenableBuilder<TobyTarget>(
                    valueListenable: _targetNotifier,
                    builder:
                        (context, target, _) => WhatTobyThinks(
                          target: target,
                          controller: harness.controller,
                          onPlayUci: harness.played.add,
                          bookAccess: harness.bookAccess,
                        ),
                  )
                  : const Text('Stockfish lines'),
        ),
      ],
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(tobySettleDelay + const Duration(milliseconds: 20));
  await tester.pump();
  await tester.pump();
}

Future<TestGesture> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(location: const Offset(890, 690));
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  return gesture;
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TobyViewTabs), matching: find.text(label));

/// Taps a tab, and lets its pressed state settle.
Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(_tab(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

/// The boxes painted by the view's private [painter] type.
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

Finder _paintedBy(String painter) => find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint && widget.painter.runtimeType.toString() == painter,
);

/// The list area, whose bottom edge fades the item it cuts.
final Finder _fadeArea = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_CutItemFade',
);

/// The fades the list area paints over cut items, in its coordinates.
List<Rect> _fades(WidgetTester tester) {
  final fades = <Rect>[];
  expect(
    tester.renderObject(_fadeArea),
    paints..everything((method, arguments) {
      if (method == #drawRect && (arguments[1] as Paint).shader != null) {
        fades.add(arguments[0] as Rect);
      }
      return true;
    }),
  );
  return fades;
}

/// Whether [text] was cut short (ellipsised) on screen.
bool _cut(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

void main() {
  setUp(() {
    tobyReadingCache.clear();
    _targetNotifier.value = _target();
  });

  group('the tabs', () {
    testWidgets('Stockfish is the default tab: Toby is not mounted and asks '
        'nothing', (tester) async {
      final h = await _pump(tester, premium: true);
      await tester.pump(const Duration(seconds: 2));

      expect(_tab('Stockfish'), findsOneWidget);
      expect(_tab(kTobyFeatureLabel), findsOneWidget);
      expect(find.byType(WhatTobyThinks), findsNothing);
      expect(find.text('Stockfish lines'), findsOneWidget);
      expect(h.repo.calls, isEmpty);
    });

    testWidgets('the chosen tab is white at full weight, the other 70% white '
        'until the pointer reaches it; nothing moves', (tester) async {
      await _pump(tester, premium: true);
      Text label(String text) => tester.widget<Text>(_tab(text));
      final before = (
        tester.getRect(_tab('Stockfish')),
        tester.getRect(_tab(kTobyFeatureLabel)),
      );
      expect(label('Stockfish').style!.color, kWhiteColor);
      expect(label('Stockfish').style!.fontWeight, FontWeight.w600);
      expect(label(kTobyFeatureLabel).style!.color, kWhiteColor70);
      expect(label(kTobyFeatureLabel).style!.fontWeight, FontWeight.w500);

      await _hover(tester, _tab(kTobyFeatureLabel));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(label(kTobyFeatureLabel).style!.color, isSameColorAs(kWhiteColor));
      expect(tester.getRect(_tab('Stockfish')), before.$1);
      expect(tester.getRect(_tab(kTobyFeatureLabel)), before.$2);

      await _tapTab(tester, kTobyFeatureLabel);
      await _settle(tester);
      expect(label(kTobyFeatureLabel).style!.color, kWhiteColor);
      expect(label('Stockfish').style!.color, kWhiteColor70);
      // The labels keep their full-weight width: switching moves nothing.
      expect(tester.getRect(_tab('Stockfish')).left, before.$1.left);
      expect(tester.getRect(_tab(kTobyFeatureLabel)).left, before.$2.left);
      // No pill, no dot, no lock: only the static rule under the chosen tab.
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
      expect(_paintedBy('_TabRulePainter'), findsOneWidget);
    });

    testWidgets('a free reader chooses the Toby tab like anyone: no lock, no '
        'prompt, and Toby is asked', (tester) async {
      final h = await _pump(tester, premium: false);
      // Both tabs at rest, nothing locked.
      expect(_tab(kTobyFeatureLabel), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      final shown = <DesktopAccessDecision>[];
      addTearDown(
        registerDesktopPaywallPresenter(h.container, (
          decision, {
          DesktopAccessContext? context,
          DesktopAccessResume? resume,
          required String surface,
        }) async {
          shown.add(decision);
          return false;
        }),
      );

      await _tapTab(tester, kTobyFeatureLabel);
      await _settle(tester);

      expect(shown, isEmpty);
      expect(find.byType(WhatTobyThinks), findsOneWidget);
      expect(find.text('Nf3'), findsOneWidget);
      expect(h.repo.calls, hasLength(1));
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool(tobyTabStorageKey), isTrue);
    });

    testWidgets('a stored Toby tab is restored for a free reader too', (
      tester,
    ) async {
      final h = await _pump(tester, premium: false, toby: true);
      await _settle(tester);

      expect(find.byType(WhatTobyThinks), findsOneWidget);
      expect(h.repo.calls, hasLength(1));
    });

    testWidgets('when Gamebase wants Premium, one quiet line offers the '
        'upgrade, and a purchase asks again', (tester) async {
      final h = await _pump(
        tester,
        premium: false,
        toby: true,
        answer:
            (_, index) =>
                index == 0
                    ? _reply(403, {'error': 'premium_required'})
                    : _reply(200, _payload()),
      );
      await _settle(tester);

      expect(
        find.text('$kTobyFeatureLabel is Premium right now'),
        findsOneWidget,
      );
      expect(find.text('Upgrade'), findsOneWidget);
      expect(find.byType(FPopover), findsNothing);
      expect(h.repo.calls, hasLength(1));

      final shown = <(DesktopAccessDecision, DesktopAccessContext?, String)>[];
      addTearDown(
        registerDesktopPaywallPresenter(h.container, (
          decision, {
          DesktopAccessContext? context,
          DesktopAccessResume? resume,
          required String surface,
        }) async {
          shown.add((decision, context, surface));
          h.subscription.become(_member());
          await resume?.run();
          return true;
        }),
      );
      await tester.tap(find.text('Upgrade'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final (decision, context, surface) = shown.single;
      expect(decision.outcome, DesktopAccess.premiumRequired);
      expect(decision.reason, DesktopAccessReason.premiumTobyPrediction);
      expect(context, isNull);
      expect(surface, 'engine_toby_tab');
      expect(h.repo.calls, hasLength(2));
      expect(find.text('Nf3'), findsOneWidget);
    });

    testWidgets('when Gamebase wants an account, one quiet line offers a '
        'guest sign-in, its action the brightest text on the line', (
      tester,
    ) async {
      final h = await _pump(
        tester,
        premium: false,
        toby: true,
        guest: true,
        answer: (_, _) => _reply(401, {'error': 'unauthorized'}),
      );
      await _settle(tester);

      final message = find.text('An account is needed right now');
      expect(message, findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      // Said once: the line does not repeat its action.
      expect(find.textContaining('Sign in to'), findsNothing);
      final messageStyle = tester.widget<Text>(message).style!;
      final action = tester.widget<Text>(find.text('Sign in')).style!;
      expect(action.color, kWhiteColor);
      expect(action.fontWeight, FontWeight.w600);
      expect(messageStyle.color, kWhiteColor70);
      expect(h.repo.calls, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(h.repo.calls, hasLength(1));
    });

    testWidgets('a signed-in reader Gamebase does not accept is offered Try '
        'again, not a sign-in it already has', (tester) async {
      final h = await _pump(
        tester,
        premium: false,
        toby: true,
        answer:
            (_, index) =>
                index == 0
                    ? _reply(401, {'error': 'unauthorized'})
                    : _reply(200, _payload()),
      );
      await _settle(tester);

      expect(find.text("Couldn't confirm your account"), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
      expect(h.repo.calls, hasLength(1));
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(h.repo.calls, hasLength(2));
      expect(find.text('Nf3'), findsOneWidget);
    });

    testWidgets('the chosen tab is kept on the device and restored', (
      tester,
    ) async {
      await _pump(tester, premium: true);
      await _tapTab(tester, kTobyFeatureLabel);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool(tobyTabStorageKey), isTrue);

      await _tapTab(tester, 'Stockfish');
      expect(preferences.getBool(tobyTabStorageKey), isFalse);
      expect(find.byType(WhatTobyThinks), findsNothing);

      // A new window (or a reload) reads the stored choice.
      await tester.pumpWidget(const SizedBox.shrink());
      tobyReadingCache.clear();
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      expect(find.byType(WhatTobyThinks), findsOneWidget);
      expect(h.repo.calls, hasLength(1));
    });

    testWidgets('tabs take focus with Tab and switch with Enter or Space; '
        'arrows, Esc and Cmd/Ctrl+Shift+F pass on', (tester) async {
      final h = await _pump(
        tester,
        premium: true,
        answer: (_, _) => Completer<GamebaseTobyReply>().future,
      );
      bool onTab(String label) =>
          Focus.of(tester.element(_tab(label))).hasPrimaryFocus;

      for (var i = 0; i < 4 && !onTab(kTobyFeatureLabel); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(onTab(kTobyFeatureLabel), isTrue);

      // ←/→ still step the game; Esc still closes the board tab.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(h.steps, 2);
      expect(h.closes, 1);
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
      expect(find.byType(WhatTobyThinks), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byType(WhatTobyThinks), findsOneWidget);
      expect(h.repo.calls, hasLength(1));

      // Back to Stockfish with Space.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(onTab('Stockfish'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(find.byType(WhatTobyThinks), findsNothing);
      // The tab took the Space, not the board.
      expect(h.engineMoves, 0);
    });
  });

  group('the Toby view', () {
    testWidgets('choosing the tab asks at once; a new position waits out the '
        'settle', (tester) async {
      final h = await _pump(
        tester,
        premium: true,
        answer: (_, _) => Completer<GamebaseTobyReply>().future,
      );
      await _tapTab(tester, kTobyFeatureLabel);
      expect(h.repo.calls, hasLength(1));

      _targetNotifier.value = _target(positionKey: 'next-position', plies: 3);
      await tester.pump();
      await tester.pump(tobySettleDelay - const Duration(milliseconds: 20));
      expect(h.repo.calls, hasLength(1));
      await tester.pump(const Duration(milliseconds: 40));
      expect(h.repo.calls, hasLength(2));
    });

    testWidgets('thinking, then the network stage muted, then the final '
        'reading in place', (tester) async {
      final network = Completer<GamebaseTobyReply>();
      final last = Completer<GamebaseTobyReply>();
      final h = await _pump(
        tester,
        premium: true,
        answer: (_, index) => index == 0 ? network.future : last.future,
      );
      await _tapTab(tester, kTobyFeatureLabel);
      // One centred line in the list area, under the inputs to be read.
      final thinking = find.text('Toby is thinking…');
      expect(thinking, findsOneWidget);
      final area = tester.getRect(find.byType(WhatTobyThinks));
      expect(tester.getCenter(thinking).dx, moreOrLessEquals(area.center.dx));
      expect(find.text('2650 v 2610 · Classical'), findsOneWidget);
      expect(h.repo.calls, hasLength(1));

      network.complete(_reply(202, _payload(stage: 'network')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Nf3'), findsOneWidget);
      expect(
        (tester.widget<Text>(find.text('Nf3')).style!.color),
        kWhiteColor70,
      );
      // The position's verdict does not wait for the final reading.
      expect(find.text('W 28 · D 57 · B 15'), findsOneWidget);
      // Every outcome bar is an empty track until then, with no tooltip.
      expect(
        _painted(tester, '_WdlPainter').map((box) => box.size.width),
        everyElement(40),
      );
      expect(h.repo.calls, hasLength(2));
      expect(h.repo.calls.last.body['have'], 'network');
      // No outcome yet: the rows and the board's arrows are Toby's teal.
      expect(
        tester.widget<Text>(find.text('71.0%')).style!.color,
        kTobyAccent.withValues(alpha: 0.6),
      );
      await tester.pump();
      expect(
        h.controller.boardArrows.value!.arrows.map(
          (arrow) => arrow.color.withValues(alpha: 1),
        ),
        everyElement(kTobyArrowNeutral),
      );
      final nf3 = tester.getTopLeft(find.text('Nf3'));

      last.complete(_reply(200, _payload()));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Text>(find.text('Nf3')).style!.color, kWhiteColor);
      expect(tester.getTopLeft(find.text('Nf3')), nf3);
      expect(find.text('W 28 · D 57 · B 15'), findsOneWidget);
      expect(find.text('2650 v 2610 · Classical'), findsOneWidget);
      expect(find.text('18 other moves · 9.0%'), findsOneWidget);
      expect(find.text(kTobyAttribution, findRichText: true), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Nf3, 71 percent, first instinct 64 percent. After it: White 30, '
          'draw 55, Black 15',
        ),
        findsOneWidget,
      );
    });

    testWidgets('rows read like Stockfish rows: the chance in the score '
        'column, teal and bold, the move after it, each row filled to its '
        'chance', (tester) async {
      await _pump(tester, premium: true, toby: true);
      await _settle(tester);

      final chance = tester.widget<Text>(find.text('71.0%'));
      // Nf3 is the best line by half a point: no class, Toby's teal.
      expect(chance.style!.color, kTobyAccent);
      expect(tobyRowTone(null), kTobyAccent);
      expect(chance.style!.fontWeight, FontWeight.w700);
      final view = tester.getRect(find.byType(WhatTobyThinks));
      // The 16 px list inset, then the row's 1 px border and 8 px padding.
      expect(tester.getTopLeft(find.text('71.0%')).dx, view.left + 25);
      // The move starts where a Stockfish line does: after the 56 px score
      // column and its 8 px gap.
      expect(tester.getTopLeft(find.text('Nf3')).dx, view.left + 25 + 64);
      final san = tester.widget<Text>(find.text('Nf3'));
      expect(san.style!.color, kWhiteColor);
      expect(san.style!.fontWeight, FontWeight.w600);

      final rows = _painted(tester, '_TobyRowPainter');
      expect(rows, hasLength(2));
      for (final (row, chance) in [(rows[0], 0.71), (rows[1], 0.2)]) {
        expect(row.size.height, 33);
        expect(row.size.width, view.width - 32);
        expect(
          row,
          paints..rect(
            rect: Rect.fromLTWH(
              0,
              0,
              (row.size.width * chance).roundToDouble(),
              33,
            ),
          ),
        );
      }
      // Stockfish's 6 px between rows.
      expect(
        rows[1].localToGlobal(Offset.zero).dy -
            rows[0].localToGlobal(Offset.zero).dy,
        33 + 6,
      );
    });

    testWidgets('a short pane keeps the attribution on screen: the row the '
        'list\'s edge cuts fades when most of it shows, and the list ends on '
        'a whole row when it would barely show', (tester) async {
      await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      final rows = [
        for (final row in _painted(tester, '_TobyRowPainter'))
          row.localToGlobal(Offset.zero) & row.size,
      ];
      expect(rows, hasLength(2));
      // Everything fits.
      expect(_fades(tester), isEmpty);
      final credit = find.text(kTobyAttribution, findRichText: true);

      /// Shortens the pane (its header and the view, from the top of the
      /// window) until the rows' room ends at [y].
      Future<void> roomEndsAt(double y, double paneBottomOverRoom) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(
          tester,
          premium: true,
          toby: true,
          height: y + paneBottomOverRoom,
        );
        await _settle(tester);
      }

      // Most of the second row on screen: it dissolves from its top to the
      // edge, and the first row is untouched. The attribution sits under
      // the edge, whole.
      final through = rows[1].top + rows[1].height * 0.85;
      // How far the pane's bottom sits under the rows' room while they
      // scroll: 6 px over the attribution's line, the list's 12 px under it.
      final below = 6 + tester.getRect(credit).height + 12;
      await roomEndsAt(through, below);
      final cut = tester.getRect(_fadeArea);
      expect(cut.bottom, moreOrLessEquals(through));
      expect(_fades(tester), [
        Rect.fromLTRB(
          rows[1].left - cut.left,
          rows[1].top - cut.top,
          rows[1].right - cut.left,
          cut.height,
        ),
      ]);
      expect(tester.getRect(credit).top, greaterThan(cut.bottom));
      expect(
        tester.getRect(credit).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(WhatTobyThinks)).bottom),
      );

      // Half of it or less: the list ends on the first row instead, with
      // nothing faded, and the attribution follows it.
      for (final y in [rows[1].center.dy, rows[0].bottom + 3]) {
        await roomEndsAt(y, below);
        final area = tester.getRect(_fadeArea);
        expect(area.bottom, moreOrLessEquals(rows[0].bottom), reason: '$y');
        expect(_fades(tester), isEmpty, reason: '$y');
        expect(tester.getRect(credit).top, greaterThan(area.bottom));
      }
    });

    testWidgets('a shorter pane gives way in steps: the reading line goes '
        'first, then the attribution closes up under one whole row', (
      tester,
    ) async {
      final credit = find.text(kTobyAttribution, findRichText: true);
      final inputs = find.text('2650 v 2610 · Classical');
      Rect firstRow() =>
          _painted(tester, '_TobyRowPainter').first.localToGlobal(Offset.zero) &
          _painted(tester, '_TobyRowPainter').first.size;
      Future<Rect> pumpHeight(double height) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _pump(tester, premium: true, toby: true, height: height);
        await _settle(tester);
        return tester.getRect(find.byType(WhatTobyThinks));
      }

      // Room for everything.
      var view = await pumpHeight(560);
      expect(inputs, findsOneWidget);
      final row = firstRow().height;
      final line = tester.getRect(credit).height;

      // Too short for the reading line too: it steps aside, and one whole
      // row and the attribution stay.
      view = await pumpHeight(52 + row + 6 + line + 12 + 10);
      expect(inputs, findsNothing);
      expect(firstRow().top, moreOrLessEquals(view.top));
      expect(tester.getRect(credit).top, greaterThan(firstRow().bottom));
      expect(tester.getRect(credit).bottom, lessThanOrEqualTo(view.bottom));

      // Shorter still: the attribution closes up under the row, 2 px away,
      // with 4 px under it.
      view = await pumpHeight(52 + row + 2 + line + 4);
      expect(inputs, findsNothing);
      expect(firstRow().top, moreOrLessEquals(view.top));
      expect(
        tester.getRect(credit).top - firstRow().bottom,
        moreOrLessEquals(2),
      );
      expect(view.bottom - tester.getRect(credit).bottom, moreOrLessEquals(4));
    });

    testWidgets('first instinct shows only when it differs by five points or '
        'more', (tester) async {
      final payload =
          _payload()
            ..['moves'] = [
              _move('g1f3', 'Nf3', 0.41, prior: 0.38),
              _move('f1c4', 'Bc4', 0.227, prior: 0.30),
              _move('d2d4', 'd4', 0.15, prior: 0.10),
            ];
      await _pump(
        tester,
        premium: true,
        toby: true,
        answer: (_, _) => _reply(200, payload),
      );
      await _settle(tester);

      expect(find.text('first instinct 38%'), findsNothing);
      expect(find.text('first instinct 30%'), findsOneWidget);
      expect(find.text('first instinct 10%'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('first instinct 30%')).style!.color,
        kSecondaryTextColor,
      );
    });

    testWidgets('up to six moves of at least 0.5% each, never fewer than '
        'three; the rest join the other-moves line', (tester) async {
      final payload =
          _payload()
            ..['moves'] = [
              _move('g1f3', 'Nf3', 0.40),
              _move('d2d4', 'd4', 0.20),
              _move('c2c4', 'c4', 0.15),
              _move('b1c3', 'Nc3', 0.10),
              _move('g2g3', 'g3', 0.06),
              _move('e2e3', 'e3', 0.04),
              _move('b2b3', 'b3', 0.01),
            ]
            ..['otherProbability'] = 0.04
            ..['otherMoveCount'] = 12;
      await _pump(
        tester,
        premium: true,
        toby: true,
        answer: (_, _) => _reply(200, payload),
      );
      await _settle(tester);

      for (final san in ['Nf3', 'd4', 'c4', 'Nc3', 'g3', 'e3']) {
        expect(find.text(san), findsOneWidget, reason: san);
      }
      expect(find.text('b3'), findsNothing);
      // 12 others plus b3, 4% plus its 1%.
      expect(find.text('13 other moves · 5.0%'), findsOneWidget);

      TobyReading reading(List<double> chances) => TobyReading(
        isFinal: true,
        sideToMove: Side.white,
        candidates: [
          for (final (i, p) in chances.indexed)
            TobyCandidate(uci: 'a2a${i + 3}', san: 'm$i', probability: p),
        ],
        otherProbability: 0,
        otherMoveCount: 0,
      );
      // Slivers after the top three are left out, never the top three.
      expect(
        tobyListedCandidates(reading([.9, .004, .003, .002])),
        hasLength(3),
      );
      expect(tobyListedCandidates(reading([.6, .3, .05, .004])), hasLength(3));
      expect(
        tobyListedCandidates(reading([.5, .3, .1, .05, .03, .01, .01])),
        hasLength(6),
      );
      expect(
        tobyOtherMovesLabel(reading([.6, .3, .05, .004]), 3),
        '1 other move · 0.4%',
      );
      expect(tobyOtherMovesLabel(reading([.7, .3]), 2), isNull);
    });

    testWidgets('the outcome bar after each move: 40 x 6, its figures in a '
        'tooltip; gone below 320 px', (tester) async {
      await _pump(tester, premium: true, toby: true);
      await _settle(tester);

      final bars = _painted(tester, '_WdlPainter');
      expect(bars, hasLength(2));
      expect(bars.map((box) => box.size.width), everyElement(40));
      // Its right edge is the row's text edge.
      final rows = _painted(tester, '_TobyRowPainter');
      expect(
        bars.first.localToGlobal(Offset(bars.first.size.width, 0)).dx,
        rows.first.localToGlobal(Offset(rows.first.size.width - 9, 0)).dx,
      );
      expect(
        bars.first,
        paints..rect(rect: const Rect.fromLTWH(0, 6, 40 * 0.30, 6)),
      );

      await _hover(tester, _paintedBy('_WdlPainter').first);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('White 30 · draw 55 · Black 15'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, premium: true, toby: true, width: 319);
      await _settle(tester);
      expect(find.text('Nf3'), findsOneWidget);
      expect(_paintedBy('_WdlPainter'), findsNothing);
    });

    testWidgets('the verdict reads W · D · B in whole percentages that add up '
        'to 100', (tester) async {
      expect(
        tobyVerdictLabel(const TobyWdl(white: 0.305, draw: 0.39, black: 0.305)),
        'W 31 · D 39 · B 30',
      );
      expect(
        tobyVerdictLabel(const TobyWdl(white: 0.32, draw: 0.48, black: 0.20)),
        'W 32 · D 48 · B 20',
      );
    });

    testWidgets('the inputs are never cut: the verdict gives way', (
      tester,
    ) async {
      await _pump(tester, premium: true, toby: true, width: 420);
      await _settle(tester);

      expect(find.text('W 28 · D 57 · B 15'), findsNothing);
      expect(_cut(tester, find.text('2650 v 2610 · Classical')), isFalse);
    });

    testWidgets('hovering a row shows only its arrow; a click pins it', (
      tester,
    ) async {
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      expect(find.text('Nf3'), findsOneWidget);

      final gesture = await _hover(tester, find.text('d4'));
      final hovered = h.controller.boardArrows.value!;
      expect(hovered.exclusive, isTrue);
      expect(hovered.positionKey, _positionKey);
      final arrow = hovered.arrows.single;
      expect(
        (orig: arrow.orig, dest: arrow.dest),
        (orig: Square.d2, dest: Square.d4),
      );
      // d4 gives away half a point against Nf3: no class, Toby's teal at
      // full weight, and no mark on the board.
      expect(arrow.color, kTobyArrowNeutral.withValues(alpha: kTobyArrowAlpha));
      expect(hovered.mark, isNull);
      expect(arrow.scale, kTobyArrowScale);

      // The gap under a row belongs to it: no flicker back to the engine.
      final nf3Row = _painted(tester, '_TobyRowPainter').first;
      await gesture.moveTo(
        nf3Row.localToGlobal(Offset(100, nf3Row.size.height + 3)),
      );
      await tester.pump();
      expect(h.controller.hoveredUci(_positionKey), 'g1f3');

      await tester.tap(find.text('Nf3'));
      await tester.pump();
      expect(h.controller.pinnedUci(_positionKey), 'g1f3');

      // Off the rows, the pin stands in for the engine arrows only.
      await gesture.moveTo(const Offset(890, 690));
      await tester.pump();
      final pinned = h.controller.boardArrows.value!;
      expect(pinned.exclusive, isFalse);
      // The pin stands in for the top three.
      expect(pinned.arrows.single.orig, Square.g1);

      // Unpinned, the board shows the top candidates again.
      await tester.tap(find.text('Nf3'));
      await tester.pump();
      await gesture.moveTo(const Offset(890, 690));
      await tester.pump();
      final top = h.controller.boardArrows.value!;
      expect(top.exclusive, isFalse);
      expect(top.arrows.map((a) => a.orig), [Square.d2, Square.g1]);
    });

    testWidgets('a pin resets when the position changes', (tester) async {
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      await tester.tap(find.text('Nf3'));
      await tester.pump();
      expect(h.controller.pinnedUci(_positionKey), 'g1f3');

      _targetNotifier.value = _target(positionKey: 'next-position', plies: 3);
      await tester.pump();
      await tester.pump();
      expect(h.controller.pinnedUci(_positionKey), isNull);
      // Nothing read for the old position stays on the board.
      expect(h.controller.boardArrows.value?.positionKey, isNot(_positionKey));
    });

    testWidgets('leaving the tab clears the pin, gives the board back the '
        'engine arrows and stops asking', (tester) async {
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      expect(h.controller.holdsBoard.value, isTrue);
      await tester.tap(find.text('Nf3'));
      await tester.pump();
      expect(h.controller.boardArrows.value, isNotNull);

      await _tapTab(tester, 'Stockfish');
      await tester.pump();
      expect(find.byType(WhatTobyThinks), findsNothing);
      expect(h.controller.boardArrows.value, isNull);
      expect(h.controller.holdsBoard.value, isFalse);
      final asked = h.repo.calls.length;

      _targetNotifier.value = _target(positionKey: 'next-position', plies: 3);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(h.repo.calls, hasLength(asked));
    });

    testWidgets('a membership that lapses changes nothing: Gamebase decides '
        'who reads', (tester) async {
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      await tester.tap(find.text('Nf3'));
      await tester.pump();

      h.subscription.become(SubscriptionState());
      await tester.pump();
      await tester.pump();
      expect(find.byType(WhatTobyThinks), findsOneWidget);
      expect(find.text('Nf3'), findsOneWidget);
      expect(h.controller.pinnedUci(_positionKey), 'g1f3');
    });

    testWidgets('Esc clears a pin while Toby has focus and does not close the '
        'tab; without a pin it still does', (tester) async {
      final h = await _pump(tester, premium: true, toby: true);
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
        'the rows, and ←/→ still step the game', (tester) async {
      final h = await _pump(tester, premium: true, toby: true);
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
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(h.steps, 1);
      // The pin is untouched by the chords.
      expect(h.controller.pinnedUci(_positionKey), 'g1f3');
    });

    testWidgets('Up and Down walk the rows and Enter pins the focused one', (
      tester,
    ) async {
      final h = await _pump(tester, premium: true, toby: true);
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
      expect(h.controller.boardArrows.value!.exclusive, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(h.controller.pinnedUci(_positionKey), 'd2d4');
      expect(h.closes, 0);
    });

    testWidgets('Tab onto the rows shows the focused one on the board', (
      tester,
    ) async {
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      // Before focus arrives, the board shows the top candidates.
      expect(h.controller.boardArrows.value!.exclusive, isFalse);
      expect(h.controller.boardArrows.value!.arrows, hasLength(2));

      for (var i = 0; i < 8; i++) {
        if (FocusManager.instance.primaryFocus?.debugLabel ==
            'Toby candidates') {
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Toby candidates');
      expect(h.controller.hoveredUci(_positionKey), 'g1f3');
      expect(h.controller.boardArrows.value!.exclusive, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(h.controller.hoveredUci(_positionKey), 'd2d4');
      // The what-if tooltip Tab passed through.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a right-click offers Play <move>, through the board', (
      tester,
    ) async {
      final h = await _pump(tester, premium: true, toby: true);
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
      final h = await _pump(tester, premium: true, toby: true);
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

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('Esc closes a what-if menu opened with the mouse, not the '
        'tab', (tester) async {
      final h = await _pump(tester, premium: true, toby: true);
      await _settle(tester);

      final inputs = find.text('2650 v 2610 · Classical');
      final gesture = await _hover(tester, inputs);
      await gesture.down(tester.getCenter(inputs));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Both players rated'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Both players rated'), findsNothing);
      expect(h.closes, 0);
    });

    testWidgets('each row takes its move\'s report class: the report\'s '
        'mark beside the move, the class colour on the chance and the fill, '
        'its name in the label; the board draws the top three in the same '
        'colours, and a hovered move\'s mark on its square', (tester) async {
      Map<String, dynamic> row(String uci, String san, double p, double win) {
        // White's win% is white + draw / 2; a 30% draw throughout.
        final white = win / 100 - 0.15;
        return {
          'uci': uci,
          'san': san,
          'probability': p,
          'prior': p,
          'wdl': {'white': white, 'draw': 0.30, 'black': 0.70 - white},
        };
      }

      final judged =
          _payload()
            ..['positionWdl'] = {'white': 0.35, 'draw': 0.30, 'black': 0.35}
            ..['moves'] = [
              // From 50%: Bg5 the only good move, a3 theory, h3 a blunder.
              row('c1g5', 'Bg5', 0.5, 55),
              row('a2a3', 'a3', 0.4, 47),
              row('h2h3', 'h3', 0.1, 33),
            ];
      _targetNotifier.value = TobyTarget.read(
        TobyRequest(moves: [...List.filled(11, 'a2a3'), 'd7d6']),
        positionKey: _italian,
      );
      final h = await _pump(
        tester,
        premium: true,
        toby: true,
        height: 640,
        answer: (_, _) => _reply(200, judged),
        bookCounts: {'a2a3': 120, 'h2h3': 500},
      );
      await _settle(tester);
      // The engine pane's "played" request for the same position and line.
      expect(h.repo.bookAsks.toSet(), {
        (fen: _italian, line: [...List.filled(11, 'a2a3'), 'd7d6'].join(' ')),
      });

      const top = GameMoveClassification.bestMove;
      const book = GameMoveClassification.bookMove;
      const blunder = GameMoveClassification.blunder;

      Color chance(String text) =>
          tester.widget<Text>(find.text(text)).style!.color!;
      expect(chance('50.0%'), kTobyClassRowTones[top]);
      expect(chance('40.0%'), kTobyClassRowTones[book]);
      expect(chance('10.0%'), kTobyClassRowTones[blunder]);
      final fills = [
        for (final element in _paintedBy('_TobyRowPainter').evaluate())
          ((element.widget as CustomPaint).painter as dynamic).fill as Color,
      ];
      expect(fills.map((fill) => fill.withValues(alpha: 1)), [
        classificationColor(top),
        classificationColor(book),
        classificationColor(blunder),
      ]);

      // The report's own mark, at the move list's size, 4 px after the
      // move and centred on its line.
      for (final (san, classification) in [
        ('Bg5', top),
        ('a3', book),
        ('h3', blunder),
      ]) {
        final mark = find.byWidgetPredicate(
          (widget) =>
              widget is MoveClassificationIcon &&
              widget.classification == classification,
        );
        expect(mark, findsOneWidget, reason: san);
        final markRect = tester.getRect(mark);
        final sanRect = tester.getRect(find.text(san));
        expect(markRect.size, const Size.square(17));
        expect(markRect.left - sanRect.right, moreOrLessEquals(4));
        expect(markRect.center.dy, moreOrLessEquals(sanRect.center.dy));
        expect(
          find.descendant(of: mark, matching: find.byType(SvgPicture)),
          findsOneWidget,
        );
        expect(
          tester
              .widget<SvgPicture>(
                find.descendant(of: mark, matching: find.byType(SvgPicture)),
              )
              .bytesLoader,
          isA<SvgAssetLoader>().having(
            (loader) => loader.assetName,
            'asset',
            classificationIconAsset(classification),
          ),
        );
      }
      // Every move starts at the same x, mark or not.
      expect({
        for (final san in ['Bg5', 'a3', 'h3'])
          tester.getTopLeft(find.text(san)).dx,
      }, hasLength(1));

      expect(
        find.bySemanticsLabel(
          'Bg5, 50 percent, Top move. After it: White 40, draw 30, Black 30',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'a3, 40 percent, Book. After it: White 32, draw 30, Black 38',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'h3, 10 percent, Blunder. After it: White 18, draw 30, Black 52',
        ),
        findsOneWidget,
      );

      final arrows = h.controller.boardArrows.value!;
      expect(arrows.positionKey, _italian);
      expect(arrows.exclusive, isFalse);
      expect(arrows.mark, isNull);
      expect(
        [for (final a in arrows.arrows) (a.orig, a.dest)],
        [
          (Square.h2, Square.h3),
          (Square.a2, Square.a3),
          (Square.c1, Square.g5),
        ],
      );
      expect(arrows.arrows.map((a) => a.color.withValues(alpha: 1)), [
        classificationColor(blunder),
        classificationColor(book),
        classificationColor(top),
      ]);
      expect(arrows.arrows.last.scale, kTobyArrowScale);
      expect(arrows.arrows.last.color.a, moreOrLessEquals(kTobyArrowAlpha));
      expect(arrows.arrows[1].scale, moreOrLessEquals(0.8 * 0.8));
      expect(arrows.arrows.first.scale, kTobyArrowMinScale);

      // A hovered blunder is the only arrow, at full weight in its colour,
      // with the report's mark on its square.
      await _hover(tester, find.text('h3'));
      final hovered = h.controller.boardArrows.value!;
      expect(hovered.exclusive, isTrue);
      expect(
        hovered.arrows.single.color,
        classificationColor(blunder).withValues(alpha: kTobyArrowAlpha),
      );
      expect(hovered.arrows.single.scale, kTobyArrowScale);
      expect(hovered.mark, (square: Square.h3, classification: blunder));
    });

    // The engine pane's "played" rule, and the web's `explorerCanBrowse`:
    // a reader who may not browse the opening tree gets no Book, and the
    // tree is never asked.
    for (final (name, identity, access) in <(
      String,
      DesktopAccountIdentity,
      DesktopAccessContext?,
    )>[
      (
        'an anonymous guest',
        const DesktopAccountIdentity(userId: 'guest', isAnonymous: true),
        _bookAccess,
      ),
      ('a signed-out reader', const DesktopAccountIdentity(), _bookAccess),
      (
        'a stale session',
        const DesktopAccountIdentity(userId: 'reader', staleSession: true),
        _bookAccess,
      ),
      (
        'a board with no explorer request',
        const DesktopAccountIdentity(userId: 'reader'),
        null,
      ),
    ]) {
      testWidgets('no Book for $name: the opening tree is not asked', (
        tester,
      ) async {
        final judged =
            _payload()
              ..['positionWdl'] = {'white': 0.35, 'draw': 0.30, 'black': 0.35}
              ..['moves'] = [
                {
                  'uci': 'c1g5',
                  'san': 'Bg5',
                  'probability': 0.6,
                  'prior': 0.6,
                  'wdl': {'white': 0.40, 'draw': 0.30, 'black': 0.30},
                },
                {
                  'uci': 'a2a3',
                  'san': 'a3',
                  'probability': 0.4,
                  'prior': 0.4,
                  'wdl': {'white': 0.32, 'draw': 0.30, 'black': 0.38},
                },
              ];
        _targetNotifier.value = TobyTarget.read(
          TobyRequest(moves: [...List.filled(11, 'a2a3'), 'd7d6']),
          positionKey: _italian,
        );
        final h = await _pump(
          tester,
          premium: true,
          toby: true,
          answer: (_, _) => _reply(200, judged),
          bookCounts: {'a2a3': 120},
          identity: identity,
          bookAccess: access,
        );
        await _settle(tester);
        expect(h.repo.bookAsks, isEmpty);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is MoveClassificationIcon &&
                widget.classification == GameMoveClassification.bookMove,
          ),
          findsNothing,
        );
        expect(find.text('a3'), findsOneWidget);
      });
    }

    testWidgets('every class draws the report\'s own badge at the move '
        'list\'s 17 px, and says the report\'s name for it', (tester) async {
      for (final classification in GameMoveClassification.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: MoveClassificationIcon(classification: classification),
            ),
          ),
        );
        final icon = find.byType(MoveClassificationIcon);
        expect(tester.getSize(icon), const Size.square(17));
        final svg = tester.widget<SvgPicture>(
          find.descendant(of: icon, matching: find.byType(SvgPicture)),
        );
        expect(
          (svg.bytesLoader as SvgAssetLoader).assetName,
          classificationIconAsset(classification),
        );
        expect(
          tobyCandidateSemanticsLabel(
            const TobyCandidate(uci: 'g1f3', san: 'Nf3', probability: 0.5),
            classification: classification,
          ),
          'Nf3, 50 percent, ${classification.label}',
        );
      }
      expect(
        tobyCandidateSemanticsLabel(
          const TobyCandidate(uci: 'g1f3', san: 'Nf3', probability: 0.5),
        ),
        'Nf3, 50 percent',
      );
    });

    testWidgets('a row without a class draws no mark, and its row is no '
        'taller than the mark', (tester) async {
      await _pump(tester, premium: true, toby: true);
      await _settle(tester);
      expect(find.byType(MoveClassificationIcon), findsNothing);
      final row = _painted(tester, '_TobyRowPainter').first;
      // 7 px padding above and below the line, which is as tall as its
      // text or the 18 px outcome bar box: the 17 px mark adds nothing, so
      // marked and plain rows match.
      final line = math.max(tester.getSize(find.text('Nf3')).height, 18);
      expect(row.size.height, 2 * 7 + line);
    });

    testWidgets('a certainty reads 100% in the chance column', (tester) async {
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
        toby: true,
        answer: (_, _) => _reply(200, only),
      );
      await _settle(tester);

      expect(find.text('100%'), findsOneWidget);
      expect(find.text('100.0%'), findsNothing);
      expect(find.textContaining('other move'), findsNothing);
    });

    testWidgets('a request Gamebase would refuse says why and asks nothing', (
      tester,
    ) async {
      _targetNotifier.value = TobyTarget.read(
        TobyRequest(moves: List<String>.filled(tobyMaxMoves + 1, 'e2e4')),
        positionKey: 'a-very-long-game',
      );
      final h = await _pump(tester, premium: true, toby: true);
      await tester.pump(const Duration(seconds: 2));

      expect(find.text("Toby can't read this position"), findsOneWidget);
      expect(find.byType(FPopover), findsNothing);
      expect(h.repo.calls, isEmpty);
    });

    testWidgets('a position Toby cannot read is one centred line and asks '
        'nothing', (tester) async {
      _targetNotifier.value = const TobyTarget.idle(TobyIdleReason.gameOver);
      final h = await _pump(tester, premium: true, toby: true);
      await tester.pump(const Duration(seconds: 2));

      final message = find.text('Game over');
      expect(message, findsOneWidget);
      final area = tester.getRect(find.byType(WhatTobyThinks));
      final centre = tester.getCenter(message);
      expect(centre.dx, moreOrLessEquals(area.center.dx));
      // Centred in the list area above the list's 12 px bottom padding.
      expect(centre.dy, moreOrLessEquals(area.top + (area.height - 12) / 2));
      expect(h.repo.calls, isEmpty);
    });

    testWidgets('a busy service offers Try again, which asks again', (
      tester,
    ) async {
      final h = await _pump(
        tester,
        premium: true,
        toby: true,
        answer: (_, _) => _reply(503),
      );
      await tester.pump(tobyPositionBudget + const Duration(seconds: 1));
      await tester.pump();

      expect(find.text('Toby is busy right now'), findsOneWidget);
      expect(find.textContaining('busy right now.'), findsNothing);
      final asked = h.repo.calls.length;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(h.repo.calls.length, greaterThan(asked));
    });

    testWidgets('a busy notice over a kept network stage keeps its whole '
        'sentence beside Try again', (tester) async {
      await _pump(
        tester,
        premium: true,
        toby: true,
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
      expect(_cut(tester, find.text('Toby is busy right now')), isFalse);
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
        toby: true,
        width: 330,
        answer: (_, _) => _reply(200, payload),
      );
      await _settle(tester);

      expect(_cut(tester, find.text('exd8=Q+')), isFalse);
    });

    testWidgets('an unconfirmed membership offers no what-if menu', (
      tester,
    ) async {
      await _pump(
        tester,
        premium: true,
        toby: true,
        answer: (_, _) => _reply(403, {'error': 'premium_required'}),
      );
      await _settle(tester);

      expect(find.text("Premium couldn't be confirmed"), findsOneWidget);
      expect(find.byType(FPopover), findsNothing);
    });
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
