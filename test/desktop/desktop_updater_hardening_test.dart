import 'package:chessever/desktop/services/desktop_updater.dart';
import 'package:chessever/desktop/services/desktop_updater_startup.dart';
import 'package:chessever/desktop/widgets/mandatory_update_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _major = DesktopUpdateState.available(
  version: '22.0.0+428',
  releaseNotes: '',
  tier: DesktopUpdateTier.major,
);

Future<void> _pumpGate(WidgetTester tester, DesktopUpdateState state) async {
  DesktopUpdaterService.instance.state.value = state;
  addTearDown(
    () =>
        DesktopUpdaterService.instance.state.value =
            const DesktopUpdateState.idle(),
  );
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        home: MandatoryUpdateGate(child: Scaffold(body: Text('the app'))),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the required-update gate always has a way out', () {
    testWidgets('while the update keeps failing and is being retried', (
      tester,
    ) async {
      await _pumpGate(
        tester,
        _major.copyRetrying(
          message: 'HttpException: HTTP 403',
          retryAttempt: 2,
          maxRetryAttempts: 5,
          nextRetryAt: DateTime(2026, 10, 2, 12),
          manualDownloadUrl: 'https://chessever.com/#download',
        ),
      );

      expect(find.text('Retrying update…'), findsOneWidget);
      expect(find.text('Open download page'), findsOneWidget);
    });

    testWidgets('while the update is downloading, in case it stalls', (
      tester,
    ) async {
      await _pumpGate(
        tester,
        _major.copyDownloading(
          progress: 0.42,
          receivedBytes: 42.0,
          totalBytes: 100.0,
        ),
      );

      expect(find.text('Downloading 42%…'), findsOneWidget);
      expect(find.text('Open download page'), findsOneWidget);
    });

    testWidgets('a staged update offers only the restart', (tester) async {
      await _pumpGate(tester, _major.copyDownloaded());

      expect(find.text('Restart & Update'), findsOneWidget);
      expect(find.text('Open download page'), findsNothing);
    });

    testWidgets('a minor update never blocks the app', (tester) async {
      await _pumpGate(
        tester,
        const DesktopUpdateState.available(
          version: '22.0.1+429',
          releaseNotes: '',
          tier: DesktopUpdateTier.minor,
        ).copyRetrying(
          message: 'offline',
          retryAttempt: 1,
          maxRetryAttempts: 5,
          nextRetryAt: DateTime(2026, 10, 2, 12),
          manualDownloadUrl: 'https://chessever.com/#download',
        ),
      );

      expect(find.text('Open download page'), findsNothing);
      expect(find.text('the app'), findsOneWidget);
    });
  });

  group('starting the updater', () {
    testWidgets('an unfocused launch starts it on the next return', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      var starts = 0;
      final startup = DesktopUpdaterStartup(
        start: () async => starts++,
        firstDelay: const Duration(seconds: 4),
        resumeDelay: const Duration(milliseconds: 700),
      );
      addTearDown(startup.dispose);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );

      // Launched, then the user clicked into another app.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      startup.schedule();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(starts, 0, reason: 'the first attempt is dropped while unfocused');
      expect(startup.started, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(starts, 1);

      // Coming back again does not start it twice.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(starts, 1);
    });

    testWidgets('a focused launch starts it once, after the delay', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var starts = 0;
      final startup = DesktopUpdaterStartup(
        start: () async => starts++,
        firstDelay: const Duration(seconds: 4),
      );
      addTearDown(startup.dispose);

      startup.schedule();
      startup.schedule();
      await tester.pump(const Duration(seconds: 3));
      expect(starts, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(starts, 1);
    });
  });
}
