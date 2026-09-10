import 'dart:convert';

import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/state/broadcast_video_streams_provider.dart';
import 'package:chessever/providers/live_stream_lifecycle_provider.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const BroadcastVideoScope _scope = BroadcastVideoScope(tourId: 't1');

ProviderContainer _container(void Function() onFetch) {
  final container = ProviderContainer(
    overrides: [
      broadcastVideoStreamsClientProvider.overrideWithValue(
        BroadcastVideoStreamsClient(
          httpClient: MockClient((_) async {
            onFetch();
            return http.Response(
              jsonEncode(<String, Object?>{'streams': <Object?>[]}),
              200,
            );
          }),
        ),
      ),
    ],
  );
  return container;
}

void main() {
  testWidgets('keeps polling after the provider is invalidated', (
    tester,
  ) async {
    var fetches = 0;
    final container = _container(() => fetches++);
    final subscription = container.listen(
      broadcastVideoStreamsProvider(_scope),
      (_, _) {},
    );
    await tester.pump();
    expect(fetches, 1);

    // Riverpod 2 keeps the notifier instance and runs onDispose before the
    // rebuild; polling must come back with the rebuild instead of dying.
    container.invalidate(broadcastVideoStreamsProvider(_scope));
    // The rebuild is scheduled on a zero-length timer, not a microtask.
    await tester.pump(const Duration(milliseconds: 1));
    expect(fetches, 2);

    await tester.pump(
      broadcastVideoStreamsRefreshInterval + const Duration(seconds: 1),
    );
    expect(fetches, 3);

    // Inside the body: the pending-timer check runs before tear-downs.
    subscription.close();
    // Auto-dispose and the container's own teardown schedule zero-length
    // timers; drain them before the pending-timer check.
    await tester.pump(const Duration(milliseconds: 1));
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('skips hidden windows and re-reads on return', (tester) async {
    var fetches = 0;
    final container = _container(() => fetches++);
    final subscription = container.listen(
      broadcastVideoStreamsProvider(_scope),
      (_, _) {},
    );
    await tester.pump();
    expect(fetches, 1);

    final lifecycle = container.read(
      liveGameStreamingLifecycleProvider.notifier,
    );
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(
      broadcastVideoStreamsRefreshInterval + const Duration(seconds: 1),
    );
    expect(fetches, 1, reason: 'a hidden window is not watching');

    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fetches, 2, reason: 'returning refreshes at once, like the web');

    subscription.close();
    // Auto-dispose and the container's own teardown schedule zero-length
    // timers; drain them before the pending-timer check.
    await tester.pump(const Duration(milliseconds: 1));
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });
}
