import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/panes/tournaments_pane.dart';
import 'package:chessever/desktop/state/event_artwork_provider.dart';
import 'package:chessever/desktop/widgets/desktop_game_card.dart';
import 'package:chessever/desktop/widgets/tournament_games_view.dart';
import 'package:chessever/providers/board_settings_provider_new.dart';
import 'package:chessever/providers/engine_settings_provider.dart';
import 'package:chessever/providers/for_you_games_logic.dart';
import 'package:chessever/providers/for_you_games_provider.dart';
import 'package:chessever/repository/lichess/cloud_eval/cloud_eval.dart';
import 'package:chessever/repository/supabase/game/game_stream_repository.dart';
import 'package:chessever/screens/chessboard/provider/current_eval_provider.dart';
import 'package:chessever/screens/group_event/model/tour_event_card_model.dart';
import 'package:chessever/screens/tour_detail/games_tour/models/games_tour_model.dart';
import 'package:chessever/utils/responsive_helper.dart';
import 'package:chessever/widgets/event_card/event_image_provider.dart';

/// Frame-cost contract for the Events > For You feed, the app's home page.
///
/// These run the real feed (rows, live game cards, mini boards, eval rails)
/// over fixed data and count the work each frame does. Wall-clock numbers are
/// printed for comparison between runs; the assertions are on counts, which
/// do not depend on the machine.
void main() {
  const tabId = 'tournaments-default';
  const eventCount = 40;
  const gamesPerEvent = 5;

  final events = List<GroupEventCardModel>.generate(
    eventCount,
    _event,
    growable: false,
  );
  final snapshots = <String, ForYouEventGamesSnapshot>{
    for (var e = 0; e < eventCount; e++)
      events[e].id: ForYouEventGamesSnapshot(
        eventId: events[e].id,
        tourId: 'tour-$e',
        visibleGames: List<GamesTourModel>.generate(
          gamesPerEvent,
          (g) => _game(e, g),
          growable: false,
        ),
        pinnedIds: const <String>[],
      ),
  };

  Widget harness() {
    return ProviderScope(
      overrides: [
        forYouEventsProvider.overrideWith(
          (_) => _StaticForYou(ForYouState(events: events, hasMore: false)),
        ),
        forYouEventGamesWithAutoRefreshProvider.overrideWith(
          (ref, eventId) => AsyncValue.data(snapshots[eventId]!),
        ),
        forYouEventSnapshotProvider.overrideWith(
          (ref, eventId) => AsyncValue.data(snapshots[eventId]!),
        ),
        gameStreamRepositoryProvider.overrideWithValue(
          _SilentGameStreamRepository(),
        ),
        boardSettingsProviderNew.overrideWith(_BoardSettings.new),
        engineSettingsProviderNew.overrideWith(_EngineSettings.new),
        gameCardEvalWithStockfishFallbackProvider.overrideWith(
          (ref, fen) async => _eval(fen),
        ),
        gameCardEvalCacheOnlyProvider.overrideWith(
          (ref, fen) async => _eval(fen),
        ),
        eventArtworkProvider.overrideWith(
          (ref, eventId) async => const EventImageData(),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            ResponsiveHelper.init(context);
            return Scaffold(
              body: buildDesktopForYouFeedForTesting(tabId: tabId),
            );
          },
        ),
      ),
    );
  }

  Future<void> mountFeed(WidgetTester tester) async {
    // The window in the bug report: a 1440p-class pane next to the sidebar.
    tester.view.physicalSize = const Size(1740, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness());
    // Settle async eval values, post-frame visibility reports and entrance
    // motion before measuring.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(LiveDesktopGameCard), findsWidgets);
  }

  testWidgets('steady scrolling does no card rebuild work between row mounts', (
    tester,
  ) async {
    await mountFeed(tester);
    final probe = _FrameProbe()..attach();
    addTearDown(probe.detach);

    // A trackpad-style scroll: small pixel deltas every frame, which take
    // the direct (non-animated) wheel path.
    final center = tester.getCenter(find.byType(ListView).first);
    for (var frame = 0; frame < 240; frame++) {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 12)),
      );
      await probe.frame(tester, const Duration(microseconds: 8333));
    }
    probe
      ..detach()
      ..report('trackpad scroll, 240 frames x 12 px');

    // Every card that was already mounted keeps its build output: the only
    // card builds are the ones for rows entering the cache window.
    final rowsEntered = (240 * 12 / 320).ceil() + 2;
    expect(
      probe.buildsOf<DesktopGameCard>(),
      lessThanOrEqualTo(rowsEntered * gamesPerEvent),
      reason: 'mounted cards must not rebuild while the feed scrolls',
    );
  });

  testWidgets('a wheel flick does not rebuild the mounted cards', (
    tester,
  ) async {
    await mountFeed(tester);
    final probe = _FrameProbe()..attach();
    addTearDown(probe.detach);

    final center = tester.getCenter(find.byType(ListView).first);
    // One wheel notch (animated 120 ms), then rest long enough for the
    // scroll-idle timer to fire. Repeated: this is how a mouse wheel is used.
    for (var notch = 0; notch < 6; notch++) {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(position: center, scrollDelta: const Offset(0, 40)),
      );
      for (var frame = 0; frame < 48; frame++) {
        await probe.frame(tester, const Duration(microseconds: 8333));
      }
    }
    probe
      ..detach()
      ..report('6 wheel notches of 40 px with 400 ms rests');

    // 240 px of travel mounts at most one new row.
    expect(
      probe.buildsOf<DesktopGameCard>(),
      lessThanOrEqualTo(2 * gamesPerEvent),
      reason: 'starting and stopping a scroll must not rebuild every card',
    );
  });
}

/// Counts the build and paint work of each pumped frame.
class _FrameProbe {
  final Map<Type, int> _builds = <Type, int>{};
  final List<double> _frameMs = <double>[];
  final List<int> _frameBuilds = <int>[];
  final List<int> _framePaints = <int>[];
  int _buildsThisFrame = 0;
  int _paintsThisFrame = 0;
  RebuildDirtyWidgetCallback? _previousRebuild;
  ProfilePaintCallback? _previousPaint;

  void attach() {
    _previousRebuild = debugOnRebuildDirtyWidget;
    _previousPaint = debugOnProfilePaint;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      _buildsThisFrame++;
      final type = element.widget.runtimeType;
      _builds[type] = (_builds[type] ?? 0) + 1;
    };
    debugOnProfilePaint = (renderObject) => _paintsThisFrame++;
  }

  void detach() {
    debugOnRebuildDirtyWidget = _previousRebuild;
    debugOnProfilePaint = _previousPaint;
  }

  Future<void> frame(WidgetTester tester, Duration duration) async {
    _buildsThisFrame = 0;
    _paintsThisFrame = 0;
    final watch = Stopwatch()..start();
    await tester.pump(duration);
    watch.stop();
    _frameMs.add(watch.elapsedMicroseconds / 1000);
    _frameBuilds.add(_buildsThisFrame);
    _framePaints.add(_paintsThisFrame);
  }

  int buildsOf<T>() => _builds[T] ?? 0;

  void report(String label) {
    final sorted = [..._frameMs]..sort();
    double at(double q) =>
        sorted[math.min(sorted.length - 1, (sorted.length * q).floor())];
    final totalBuilds = _frameBuilds.fold<int>(0, (a, b) => a + b);
    final totalPaints = _framePaints.fold<int>(0, (a, b) => a + b);
    final top =
        _builds.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    debugPrint(
      '[for-you perf] $label\n'
      '  frames ${_frameMs.length}  '
      'frame ms p50 ${at(0.5).toStringAsFixed(2)} '
      'p95 ${at(0.95).toStringAsFixed(2)} '
      'max ${sorted.last.toStringAsFixed(2)} '
      'total ${sorted.fold<double>(0, (a, b) => a + b).toStringAsFixed(0)}\n'
      '  widget builds total $totalBuilds '
      'max/frame ${_frameBuilds.reduce(math.max)}  '
      'render paints total $totalPaints '
      'max/frame ${_framePaints.reduce(math.max)}\n'
      '  top builders: '
      '${top.take(12).map((e) => '${e.key} ${e.value}').join(', ')}',
    );
  }
}

class _StaticForYou extends StateNotifier<ForYouState>
    implements ForYouNotifier {
  _StaticForYou(super.state);

  @override
  Future<void> loadMore() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshIfStale({
    Duration maxAge = const Duration(minutes: 5),
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SilentGameStreamRepository extends GameStreamRepository {
  @override
  Stream<LiveGameUpdate?> subscribeToLiveGameUpdate(String gameId) =>
      const Stream<LiveGameUpdate?>.empty();

  @override
  Stream<Map<String, dynamic>?> subscribeToGameUpdates(String gameId) =>
      const Stream<Map<String, dynamic>?>.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesBatch(
    List<String> gameIds,
  ) {
    late final StreamController<Map<String, LiveGameUpdate>> controller;
    controller = StreamController<Map<String, LiveGameUpdate>>(
      onCancel: () => scheduleMicrotask(controller.close),
    );
    return controller.stream;
  }

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForRound(
    String roundId,
  ) => const Stream<Map<String, LiveGameUpdate>>.empty();

  @override
  Stream<Map<String, LiveGameUpdate>> subscribeToLiveGameUpdatesForTour(
    String tourId,
  ) => const Stream<Map<String, LiveGameUpdate>>.empty();
}

class _BoardSettings extends BoardSettingsNotifierNew {
  @override
  Future<BoardSettingsNew> build() async {
    const settings = BoardSettingsNew();
    state = const AsyncValue.data(settings);
    return settings;
  }
}

class _EngineSettings extends EngineSettingsNotifierNew {
  @override
  Future<EngineSettings> build() async {
    const settings = EngineSettings();
    state = const AsyncValue.data(settings);
    return settings;
  }
}

CloudEval _eval(String fen) => CloudEval(
  fen: fen,
  knodes: 1000,
  depth: 20,
  pvs: [Pv(moves: 'e2e4', cp: (fen.hashCode % 300) - 150)],
);

GroupEventCardModel _event(int index) {
  return GroupEventCardModel(
    id: 'event-$index',
    title: 'Stress Open ${2026 + index} Section ${index + 1}',
    dates: 'Nov 10 - 15, 2026',
    maxAvgElo: 2500 + index,
    timeUntilStart: '',
    tourEventCategory: TourEventCategory.live,
    timeControl: 'standard',
    startDate: DateTime.utc(2026, 11, 10),
    endDate: DateTime.utc(2026, 11, 15),
    // Community events draw their fallback artwork without a network image.
    eventSource: EventSource.communityEvent,
  );
}

// Real middlegame positions, so each mini board paints a full piece set.
const List<String> _fens = <String>[
  'r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P1B2/2P1PN2/PP1NBPPP/R2QK2R w KQ - 0 8',
  'r2q1rk1/1b2bppp/p1np1n2/1p2p3/4P3/1BP2N1P/PP1P1PP1/RNBQR1K1 w - - 0 11',
  '2rq1rk1/pp1bppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/2KR1B1R w - - 0 11',
  'r1bqr1k1/pp1n1pbp/2pp1np1/4p3/2PPP3/2N2N1P/PP2BPP1/R1BQ1RK1 w - - 0 10',
  'r3k2r/pp1nbppp/2p1pn2/q4b2/2BP4/2N1PN2/PP1B1PPP/R2Q1RK1 w kq - 0 10',
  '4rrk1/1pp2ppp/p1np1q2/4p3/2B1P1b1/2PP1N2/PP3PPP/R2Q1RK1 w - - 0 13',
  'r4rk1/1pq1bppp/p1nppn2/8/3NPP2/2N1B3/PPPQ2PP/2KR1B1R w - - 0 12',
];

GamesTourModel _game(int event, int index) {
  final fen = _fens[(event * 3 + index) % _fens.length];
  return GamesTourModel(
    gameId: 'game-$event-$index',
    whitePlayer: _player('White ${event}_$index'),
    blackPlayer: _player('Black ${event}_$index'),
    whiteTimeDisplay: '45:12',
    blackTimeDisplay: '38:40',
    whiteClockCentiseconds: 271200,
    blackClockCentiseconds: 232000,
    gameStatus: GameStatus.ongoing,
    fen: fen,
    lastMove: 'e2e4',
    roundId: 'round-$event',
    tourId: 'tour-$event',
    tourSlug: 'stress-$event',
  );
}

PlayerCard _player(String name) {
  return PlayerCard(
    name: name,
    federation: 'USA',
    title: 'GM',
    rating: 2700,
    countryCode: 'USA',
    team: null,
  );
}
