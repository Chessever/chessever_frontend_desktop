import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dartchess/dartchess.dart' show Outcome, Side;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chessever/desktop/auth/desktop_access_providers.dart';
import 'package:chessever/desktop/auth/desktop_entitlement_snapshot.dart';
import 'package:chessever/desktop/panes/board_pane.dart';
import 'package:chessever/desktop/services/toby/toby_label.dart';
import 'package:chessever/desktop/services/toby/toby_prediction.dart';
import 'package:chessever/desktop/state/toby_panel.dart';
import 'package:chessever/desktop/widgets/desktop_tooltip.dart';
import 'package:chessever/desktop/widgets/toby/toby_bar.dart';
import 'package:chessever/desktop/widgets/toby/what_toby_thinks.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/repository/gamebase/gamebase_repository.dart';
import 'package:chessever/repository/sqlite/app_database.dart';
import 'package:chessever/revenue_cat_service/subscribe_state.dart';

/// The Toby bar beside the board: its geometry, what it shows for each
/// reading, its one shared request loop with the Toby Predicts view, and
/// its setting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(tobyReadingCache.clear);

  group('geometry', () {
    const wdl = TobyWdl(white: 0.124, draw: 0.761, black: 0.115);

    test('White sits at White\'s end: the bottom, the top when flipped', () {
      final upright = tobyBarSlices(
        wdl: wdl,
        flipped: false,
        height: 400,
        labelExtent: 11,
      );
      expect(upright.map((s) => s.side), [
        TobyBarSide.black,
        TobyBarSide.draw,
        TobyBarSide.white,
      ]);
      expect(upright.first.top, 0);
      expect(upright.last.top + upright.last.extent, moreOrLessEquals(400));
      expect(upright[0].extent, moreOrLessEquals(46));
      expect(upright[1].extent, moreOrLessEquals(304.4));
      expect(upright[2].extent, moreOrLessEquals(49.6));

      final flipped = tobyBarSlices(
        wdl: wdl,
        flipped: true,
        height: 400,
        labelExtent: 11,
      );
      expect(flipped.map((s) => s.side), [
        TobyBarSide.white,
        TobyBarSide.draw,
        TobyBarSide.black,
      ]);
      expect(flipped.first.extent, moreOrLessEquals(49.6));
    });

    test('figures are whole percentages adding to 100', () {
      final slices = tobyBarSlices(
        wdl: wdl,
        flipped: false,
        height: 400,
        labelExtent: 11,
      );
      expect(slices.fold<int>(0, (sum, s) => sum + s.percent), 100);
      expect(
        {for (final s in slices) s.side: s.percent},
        {TobyBarSide.white: 12, TobyBarSide.draw: 76, TobyBarSide.black: 12},
      );
    });

    test('a figure shows only where its segment holds it whole, with its '
        'padding above and below', () {
      const need = 11 + 2 * kTobyBarLabelPadding;
      // A 100 px board: 12.4 and 11.5 px are too short for 18 px.
      final small = tobyBarSlices(
        wdl: wdl,
        flipped: false,
        height: 100,
        labelExtent: 11,
      );
      expect(
        {for (final s in small) s.side: s.label},
        {
          TobyBarSide.black: false,
          TobyBarSide.draw: true,
          TobyBarSide.white: false,
        },
      );
      // The web's 18 px floor (TOBY_BAR_LABEL_MIN_PX) holds for small
      // text: 17 px fits the figure and its padding but carries none.
      expect(need, lessThan(kTobyBarLabelMinExtent));
      final atNeed = tobyBarSlices(
        wdl: const TobyWdl(white: 0.17, draw: 0.66, black: 0.17),
        flipped: false,
        height: need / 0.17,
        labelExtent: 11,
      );
      expect(atNeed.where((s) => s.label).map((s) => s.side), [
        TobyBarSide.draw,
      ]);
      // Exactly 18 px is enough; a hair less is not.
      final exact = tobyBarSlices(
        wdl: const TobyWdl(white: 0.17, draw: 0.66, black: 0.17),
        flipped: false,
        height: kTobyBarLabelMinExtent / 0.17,
        labelExtent: 11,
      );
      expect(exact.every((s) => s.label), isTrue);
      final short = tobyBarSlices(
        wdl: const TobyWdl(white: 0.17, draw: 0.66, black: 0.17),
        flipped: false,
        height: kTobyBarLabelMinExtent / 0.17 - 0.5,
        labelExtent: 11,
      );
      expect(short.where((s) => s.label).map((s) => s.side), [
        TobyBarSide.draw,
      ]);
      // A larger text scale raises the floor to the line and its padding.
      final large = tobyBarSlices(
        wdl: const TobyWdl(white: 0.17, draw: 0.66, black: 0.17),
        flipped: false,
        height: 20 / 0.17,
        labelExtent: 16,
      );
      expect(large.where((s) => s.label).map((s) => s.side), [
        TobyBarSide.draw,
      ]);
      // A segment with no share never carries a figure.
      final none = tobyBarSlices(
        wdl: const TobyWdl(white: 1, draw: 0, black: 0),
        flipped: false,
        height: 400,
        labelExtent: 11,
      );
      expect(none.where((s) => s.label).map((s) => s.side), [
        TobyBarSide.white,
      ]);
    });

    test('no reading, or no height, is the empty track', () {
      expect(
        tobyBarSlices(wdl: null, flipped: false, height: 400, labelExtent: 11),
        isEmpty,
      );
      expect(
        tobyBarSlices(wdl: wdl, flipped: false, height: 0, labelExtent: 11),
        isEmpty,
      );
    });

    test('a game over shows its result: all White, all Black, all draw', () {
      const white = TobyWdl(white: 1, draw: 0, black: 0);
      const black = TobyWdl(white: 0, draw: 0, black: 1);
      const draw = TobyWdl(white: 0, draw: 1, black: 0);
      expect(tobyResultWdl(outcome: const Outcome(winner: Side.white)), white);
      expect(tobyResultWdl(outcome: const Outcome(winner: Side.black)), black);
      expect(tobyResultWdl(outcome: Outcome.draw), draw);
      expect(tobyResultWdl(pgnResult: '1-0'), white);
      expect(tobyResultWdl(pgnResult: '0-1'), black);
      expect(tobyResultWdl(pgnResult: '1/2-1/2'), draw);
      expect(tobyResultWdl(pgnResult: '½-½'), draw);
      expect(tobyResultWdl(pgnResult: ' 1 - 0 '), white);
      expect(tobyResultWdl(pgnResult: '*'), isNull);
      expect(tobyResultWdl(pgnResult: ''), isNull);
      expect(tobyResultWdl(), isNull);
      // The web's set: a bare 1/2 and the decimal forms too.
      expect(tobyResultWdl(pgnResult: '1/2'), draw);
      expect(tobyResultWdl(pgnResult: '0.5-0.5'), draw);
      expect(tobyResultWdl(pgnResult: '1.0-0.0'), white);
      expect(tobyResultWdl(pgnResult: '0.0-1.0'), black);
      // The web's order: the game's result (passed only at its last move)
      // first, then the board's own outcome.
      expect(tobyResultWdl(outcome: Outcome.draw, pgnResult: '1-0'), white);
      expect(tobyResultWdl(outcome: Outcome.draw, pgnResult: '*'), draw);
    });

    test('a reading shows at once; the next position keeps the last values; '
        'an error or refusal empties the track', () {
      const previous = TobyWdl(white: 0.3, draw: 0.5, black: 0.2);
      final network = _reading(final_: false);
      expect(
        tobyBarWdlFor(const TobyReadingState(TobyStatus.thinking), previous),
        previous,
      );
      expect(
        tobyBarWdlFor(const TobyReadingState(TobyStatus.thinking), null),
        isNull,
      );
      expect(
        tobyBarWdlFor(
          TobyReadingState(TobyStatus.network, reading: network),
          previous,
        ),
        network.positionWdl,
      );
      expect(
        tobyBarWdlFor(TobyReadingState.ready(_reading(final_: true)), null),
        _finalWdl,
      );
      expect(
        tobyBarWdlFor(
          TobyReadingState(TobyStatus.busy, reading: network),
          previous,
        ),
        network.positionWdl,
      );
      for (final status in [
        TobyStatus.busy,
        TobyStatus.unavailable,
        TobyStatus.premiumUnconfirmed,
        TobyStatus.premiumRequired,
        TobyStatus.signInRequired,
        TobyStatus.notApplicable,
      ]) {
        expect(
          tobyBarWdlFor(TobyReadingState(status), previous),
          isNull,
          reason: status.name,
        );
      }
      expect(
        tobyBarWdlFor(
          TobyReadingState.ready(_reading(final_: true, wdl: false)),
          previous,
        ),
        isNull,
      );
    });

    test('its name and tooltip say what it is, with the inputs and the '
        'attribution', () {
      expect(
        tobyBarSemanticsLabel(
          const TobyWdl(white: 0.124, draw: 0.761, black: 0.114),
        ),
        'Toby: White 13%, draw 76%, Black 11%',
      );
      expect(tobyBarSemanticsLabel(null), 'Toby: no reading');
      final tip = tobyBarTooltip(inputs: '2650 v 2610 · Classical');
      expect(tip, contains('these players at this time control'));
      expect(tip, contains('2650 v 2610 · Classical'));
      expect(tip, contains(kTobyAttribution));
      expect(kTobyAttribution, 'Toby © Yosha Iglesias, toby.tribychess.org');
      expect(tobyBarTooltip(result: true), contains(kTobyAttribution));
    });
  });

  group('setting', () {
    test('on by default, also for caches written before it existed', () {
      expect(const EngineSettings().showTobyBar, isTrue);
      expect(engineSettingsFromCache(<String, dynamic>{}).showTobyBar, isTrue);
      expect(
        engineSettingsFromCache(<String, dynamic>{
          'showEngineGauge': false,
          'maxArrowsOnBoard': 2,
        }).showTobyBar,
        isTrue,
      );
      expect(
        engineSettingsFromCache(<String, dynamic>{
          'showTobyBar': false,
        }).showTobyBar,
        isFalse,
      );
      expect(
        const EngineSettings().copyWith(showTobyBar: false).showTobyBar,
        isFalse,
      );
    });

    test('independent of the engine, and only for games Toby reads', () {
      const off = EngineSettings(showEngineAnalysis: false);
      expect(shouldShowDesktopBoardTobyBar(off, null), isTrue);
      expect(shouldShowDesktopBoardTobyBar(off, 'Standard'), isTrue);
      expect(shouldShowDesktopBoardTobyBar(off, 'Chess960'), isFalse);
      expect(
        shouldShowDesktopBoardTobyBar(
          const EngineSettings(showTobyBar: false),
          null,
        ),
        isFalse,
      );
      // Hiding Stockfish lines does not hide its independent board bar.
      expect(shouldShowDesktopBoardEvalBar(off), isTrue);
    });

    test(
      'the board column reserves the bar\'s width beside the eval bar\'s',
      () {
        double fit({double toby = 0}) => desktopBoardColumnFitWidth(
          vLimit: 600,
          sizePreference: 500,
          focusMode: false,
          evalBarReservation: 36,
          tobyBarReservation: toby,
          outerPadding: 10,
        );
        expect(fit(), 500 + 36 + 20);
        expect(fit(toby: 36), 500 + 36 + 36 + 20);
      },
    );

    group('persistence', () {
      late Directory databaseDirectory;
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );

      setUpAll(() async {
        databaseDirectory = await Directory.systemTemp.createTemp(
          'chessever-toby-bar-',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              pathProviderChannel,
              (_) async => databaseDirectory.path,
            );
        sqfliteFfiInit();
        sqflite.databaseFactory = databaseFactoryFfiNoIsolate;
        await AppDatabase.instance.database;
      });

      tearDownAll(() async {
        await AppDatabase.instance.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        if (await databaseDirectory.exists()) {
          await databaseDirectory.delete(recursive: true);
        }
      });

      test('hiding it is kept on this device, like the gauge', () async {
        final first = ProviderContainer();
        expect(
          (await first.read(engineSettingsProviderNew.future)).showTobyBar,
          isTrue,
        );
        await first
            .read(engineSettingsProviderNew.notifier)
            .toggleTobyBar(false);
        expect(
          first.read(engineSettingsProviderNew).valueOrNull?.showTobyBar,
          isFalse,
        );
        first.dispose();

        final second = ProviderContainer();
        addTearDown(second.dispose);
        final restored = await second.read(engineSettingsProviderNew.future);
        expect(restored.showTobyBar, isFalse);
        // Nothing else moved.
        expect(
          restored.showEngineGauge,
          const EngineSettings().showEngineGauge,
        );

        await second
            .read(engineSettingsProviderNew.notifier)
            .toggleTobyBar(true);
        final third = ProviderContainer();
        addTearDown(third.dispose);
        expect(
          (await third.read(engineSettingsProviderNew.future)).showTobyBar,
          isTrue,
        );
      });
    });
  });

  group('the bar', () {
    const wdl = TobyWdl(white: 0.3, draw: 0.5, black: 0.2);

    testWidgets('three flat segments, figures centred in their own, White at '
        'the bottom', (tester) async {
      await _pumpBar(
        tester,
        const TobyBar(
          wdl: wdl,
          flipped: false,
          width: 24,
          height: 400,
          inputs: '2650 v 2610 · Classical',
        ),
      );
      final bar = tester.getRect(find.byType(TobyBar));
      final white = tester.getRect(find.text('30'));
      final draw = tester.getRect(find.text('50'));
      final black = tester.getRect(find.text('20'));
      expect(black.center.dy, lessThan(draw.center.dy));
      expect(draw.center.dy, lessThan(white.center.dy));
      // Each figure dead centre in its segment, across and down.
      expect(black.center.dy, moreOrLessEquals(bar.top + 40, epsilon: 0.5));
      expect(draw.center.dy, moreOrLessEquals(bar.top + 180, epsilon: 0.5));
      expect(white.center.dy, moreOrLessEquals(bar.top + 340, epsilon: 0.5));
      for (final figure in [white, draw, black]) {
        expect(figure.center.dx, moreOrLessEquals(bar.center.dx, epsilon: .5));
        expect(figure.width, lessThanOrEqualTo(24));
      }
      expect(_fills(tester), [kTobyBarBlack, kTobyBarDraw, kTobyBarWhite]);
      expect(
        find.bySemanticsLabel('Toby: White 30%, draw 50%, Black 20%'),
        findsOneWidget,
      );
    });

    testWidgets('a flipped board flips the bar', (tester) async {
      await _pumpBar(
        tester,
        const TobyBar(wdl: wdl, flipped: true, width: 24, height: 400),
      );
      expect(
        tester.getCenter(find.text('30')).dy,
        lessThan(tester.getCenter(find.text('20')).dy),
      );
      expect(_fills(tester), [kTobyBarWhite, kTobyBarDraw, kTobyBarBlack]);
    });

    testWidgets('a segment too short for its figure carries none', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        const TobyBar(
          wdl: TobyWdl(white: 0.02, draw: 0.95, black: 0.03),
          flipped: false,
          width: 24,
          height: 300,
        ),
      );
      expect(find.text('95'), findsOneWidget);
      expect(find.text('2'), findsNothing);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('no reading: an empty track of the same size, no figures', (
      tester,
    ) async {
      await _pumpBar(
        tester,
        const TobyBar(wdl: null, flipped: false, width: 24, height: 400),
      );
      expect(tester.getSize(find.byType(TobyBar)), const Size(24, 400));
      expect(find.byType(Text), findsNothing);
      expect(_fills(tester), isEmpty);
      expect(find.bySemanticsLabel('Toby: no reading'), findsOneWidget);
    });

    testWidgets('the boundaries ease to a new reading in 300 ms, and jump '
        'with reduced motion', (tester) async {
      Future<void> show(TobyWdl wdl, {bool reduce = false}) => _pumpBar(
        tester,
        TobyBar(wdl: wdl, flipped: false, width: 24, height: 400),
        reduceMotion: reduce,
      );
      double blackHeight() => _segments(tester).first.height;

      await show(wdl);
      expect(blackHeight(), moreOrLessEquals(80));
      await show(const TobyWdl(white: 0.3, draw: 0.3, black: 0.4));
      await tester.pump(const Duration(milliseconds: 100));
      expect(blackHeight(), greaterThan(80));
      expect(blackHeight(), lessThan(160));
      await tester.pump(const Duration(milliseconds: 250));
      expect(blackHeight(), moreOrLessEquals(160));

      await show(wdl, reduce: true);
      await tester.pump();
      expect(blackHeight(), moreOrLessEquals(80));
    });
  });

  group('reading', () {
    testWidgets('a signed-out reader sees the network stage at once, then '
        'the final one', (tester) async {
      final finalStage = Completer<GamebaseTobyReply>();
      final harness = await _pumpSurface(
        tester,
        guest: true,
        answer:
            (call, index) =>
                index == 0
                    ? _reply(202, _payload(stage: 'network'))
                    : finalStage.future,
      );
      expect(find.byType(Text), findsNothing);
      await tester.pump(tobySettleDelay);
      await tester.pump();
      // 12.4%, 76.1% and 11.5%: whole figures adding to 100.
      expect(find.text('12'), findsNWidgets(2));
      expect(find.text('76'), findsOneWidget);
      finalStage.complete(_reply(200, _payload()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('28'), findsOneWidget);
      expect(find.text('57'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
      expect(harness.repo.calls, hasLength(2));
      expect(
        find.bySemanticsLabel('Toby: White 28%, draw 57%, Black 15%'),
        findsOneWidget,
      );
    });

    testWidgets('a refusal or an error leaves the empty track', (tester) async {
      await _pumpSurface(tester, answer: (_, _) => _reply(403, null));
      await tester.pump(tobySettleDelay);
      await tester.pump();
      await tester.pump();
      expect(find.byType(Text), findsNothing);
      expect(_fills(tester), isEmpty);
    });

    testWidgets('the next position keeps the last values until it is read', (
      tester,
    ) async {
      final second = Completer<GamebaseTobyReply>();
      final harness = await _pumpSurface(
        tester,
        answer:
            (call, index) =>
                index == 0 ? _reply(200, _payload()) : second.future,
      );
      await tester.pump(tobySettleDelay);
      await tester.pump();
      expect(find.text('57'), findsOneWidget);

      harness.target.value = _target(plies: 3);
      await tester.pump();
      await tester.pump(tobySettleDelay);
      await tester.pump();
      expect(harness.repo.calls, hasLength(2));
      expect(find.text('57'), findsOneWidget);

      second.complete(
        _reply(
          200,
          _payload(wdl: const {'white': 0.5, 'draw': 0.4, 'black': 0.1}),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('57'), findsNothing);
      expect(find.text('40'), findsOneWidget);

      // A previewed line or a background board asks nothing and keeps them.
      harness.target.value = const TobyTarget.idle(TobyIdleReason.preview);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('40'), findsOneWidget);
      expect(harness.repo.calls, hasLength(2));
    });

    testWidgets('a background board whose game moves on drops the old '
        'chances instead of showing them for a new position', (tester) async {
      final harness = await _pumpSurface(tester);
      await tester.pump(tobySettleDelay);
      await tester.pump();
      expect(find.text('57'), findsOneWidget);

      // The board steps into the background of a split: the values stay
      // while it still shows the position they were read for.
      harness.target.value = const TobyTarget.idle(TobyIdleReason.background);
      await tester.pump();
      expect(find.text('57'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Toby: White')), findsOneWidget);

      // A live move arrives on that board: the bar empties, asks nothing.
      harness.board.value = 'position-3';
      await tester.pump();
      expect(find.text('57'), findsNothing);
      expect(find.bySemanticsLabel('Toby: no reading'), findsOneWidget);
      expect(harness.repo.calls, hasLength(1));
    });

    testWidgets('keyboard focus opens the tooltip with the attribution', (
      tester,
    ) async {
      await _pumpSurface(tester);
      await tester.pump(tobySettleDelay);
      await tester.pump();
      expect(find.textContaining(kTobyAttribution), findsNothing);
      final node = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byType(TobyBar),
                matching: find.byType(DesktopTooltip),
              )
              .first,
        ),
      );
      node.requestFocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining(kTobyAttribution), findsOneWidget);

      node.unfocus();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining(kTobyAttribution), findsNothing);
    });

    testWidgets('a game over shows its result and asks nothing', (
      tester,
    ) async {
      final harness = await _pumpSurface(
        tester,
        result: tobyResultWdl(pgnResult: '0-1'),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(harness.repo.calls, isEmpty);
      // All Black: Black's segment fills the bar.
      expect(
        tester.getSize(find.byKey(const ValueKey(TobyBarSide.black))).height,
        300,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey(TobyBarSide.white))).height,
        0,
      );
      expect(
        find.bySemanticsLabel('Toby: game over, White 0%, draw 0%, Black 100%'),
        findsOneWidget,
      );
    });

    testWidgets('the bar and the Toby Predicts view share one request loop', (
      tester,
    ) async {
      final harness = await _pumpSurface(tester, withPanel: true);
      await tester.pump(tobySettleDelay);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(WhatTobyThinks), findsOneWidget);
      expect(find.text('Nf3'), findsWidgets);
      expect(find.text('57'), findsOneWidget);
      expect(harness.repo.calls, hasLength(1));

      // A what-if is read once too, by both.
      harness.controller.setWhatIf((rating: 2400, cadence: null));
      await tester.pump();
      await tester.pump(tobySettleDelay);
      await tester.pump();
      expect(harness.repo.calls, hasLength(2));
      final overrides = harness.repo.calls.last.body['overrides'] as Map;
      expect(overrides['rating'], 2400);
    });
  });

  testWidgets('a shared image leaves out the Toby bar\'s room', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Center(
        child: RepaintBoundary(
          key: key,
          child: const SizedBox(
            width: 100,
            height: 50,
            child: ColoredBox(color: Color(0xFF123456)),
          ),
        ),
      ),
    );
    final bytes = await tester.runAsync(
      () => captureDesktopBoardShareImage(key, pixelRatio: 2, trimRight: 36),
    );
    final codec = await tester.runAsync(() => ui.instantiateImageCodec(bytes!));
    final frame = await tester.runAsync(() => codec!.getNextFrame());
    expect(frame!.image.width, (100 - 36) * 2);
    expect(frame.image.height, 100);
    frame.image.dispose();
  });
}

const TobyWdl _finalWdl = TobyWdl(white: 0.28, draw: 0.57, black: 0.15);

TobyReading _reading({required bool final_, bool wdl = true}) => TobyReading(
  isFinal: final_,
  sideToMove: Side.white,
  candidates: const [TobyCandidate(uci: 'g1f3', san: 'Nf3', probability: 0.6)],
  positionWdl:
      !wdl
          ? null
          : final_
          ? _finalWdl
          : const TobyWdl(white: 0.124, draw: 0.761, black: 0.115),
  otherProbability: 0.4,
  otherMoveCount: 12,
);

Future<void> _pumpBar(
  WidgetTester tester,
  TobyBar bar, {
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(alignment: Alignment.topLeft, child: bar),
      ),
    ),
  );
}

/// The segments' boxes, top to bottom.
List<Rect> _segments(WidgetTester tester) {
  final rects = [
    for (final side in TobyBarSide.values)
      if (find.byKey(ValueKey<TobyBarSide>(side)).evaluate().isNotEmpty)
        tester.getRect(find.byKey(ValueKey<TobyBarSide>(side))),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return rects;
}

/// The segments' fills, top to bottom (none on the empty track).
List<Color> _fills(WidgetTester tester) {
  final boxes = [
    for (final side in TobyBarSide.values)
      for (final element in find
          .descendant(
            of: find.byKey(ValueKey<TobyBarSide>(side)),
            matching: find.byType(ColoredBox),
          )
          .evaluate()
          .take(1))
        (
          color: (element.widget as ColoredBox).color,
          top: tester.getRect(find.byElementPredicate((e) => e == element)).top,
        ),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final box in boxes) box.color];
}

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

GamebaseTobyReply _reply(int status, Map<String, dynamic>? data) => (
  statusCode: status,
  data: data,
  retryAfter: null,
);

Map<String, dynamic> _payload({
  String stage = 'final',
  Map<String, double>? wdl,
}) => {
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
  ],
  'positionWdl':
      wdl ??
      (stage == 'final'
          ? {'white': 0.28, 'draw': 0.57, 'black': 0.15}
          : {'white': 0.124, 'draw': 0.761, 'black': 0.115}),
  'otherProbability': 0.29,
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

TobyTarget _target({int plies = 2}) => TobyTarget.read(
  TobyRequest(
    moves: const ['e2e4', 'e7e5', 'g1f3', 'b8c6'].take(plies).toList(),
    whiteRating: 2650,
    blackRating: 2610,
    timeControl: '40/5400+30:1800+30',
    category: 'Classical',
  ),
  positionKey: 'position-$plies',
);

class _SurfaceHarness {
  _SurfaceHarness(this.repo, this.controller, this.target, this.board);

  final _FakeGamebase repo;
  final TobyPanelController controller;
  final ValueNotifier<TobyTarget> target;

  /// The board's own position. It follows a read target; set it by hand
  /// for an idle one (a background board whose game moves on).
  final ValueNotifier<String> board;
}

/// A board's Toby bar, 300 px tall, and with [withPanel] the Toby
/// Predicts view beside it on the same target and controller, as the board
/// pane composes them.
Future<_SurfaceHarness> _pumpSurface(
  WidgetTester tester, {
  bool guest = false,
  bool withPanel = false,
  TobyWdl? result,
  FutureOr<GamebaseTobyReply> Function(_Call call, int index)? answer,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final repo = _FakeGamebase(answer ?? (_, _) => _reply(200, _payload()));
  final controller = TobyPanelController(session: 'toby-bar-test-01');
  addTearDown(controller.dispose);
  final target = ValueNotifier<TobyTarget>(_target());
  addTearDown(target.dispose);
  final board = ValueNotifier<String>(target.value.positionKey!);
  addTearDown(board.dispose);
  target.addListener(() {
    final key = target.value.positionKey;
    if (key != null) board.value = key;
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        gamebaseRepositoryProvider.overrideWithValue(repo),
        // No opening tree: the view's Book class is not under test here.
        tobyBookCountsProvider.overrideWith((ref, _) => null),
        subscriptionProvider.overrideWith(
          (ref) => SubscriptionNotifier.stub(SubscriptionState()),
        ),
        desktopEntitlementProvider.overrideWithValue(
          guest
              ? DesktopEntitlementSnapshot.guest
              : const DesktopEntitlementSnapshot(
                accountId: 'reader',
                generation: 1,
              ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([target, board]),
            builder:
                (context, _) => Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 300,
                      child: TobyBarSurface(
                        target: target.value,
                        controller: controller,
                        result: result,
                        positionKey: board.value,
                        flipped: false,
                        width: 24,
                        height: 300,
                      ),
                    ),
                    if (withPanel)
                      SizedBox(
                        width: 600,
                        height: 500,
                        child: WhatTobyThinks(
                          target: target.value,
                          controller: controller,
                        ),
                      ),
                  ],
                ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _SurfaceHarness(repo, controller, target, board);
}
