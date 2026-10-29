import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chessever/chat/ai_sharing_consent.dart';
import 'package:chessever/desktop/widgets/botvinnik/botvinnik_ai_consent_dialog.dart';
import 'package:chessever/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    final font = FontLoader(FThemes.zinc.dark.typography.defaultFontFamily);
    font.addFont(
      rootBundle.load('packages/forui/assets/fonts/inter/Inter-Regular.ttf'),
    );
    await font.load();
  });

  test(
    'permission defaults to denied, is per account and can be withdrawn',
    () async {
      const consent = AiSharingConsent();
      expect(await consent.isGranted('account-a'), isFalse);
      await consent.setGranted('account-a', true);
      expect(await consent.isGranted('account-a'), isTrue);
      expect(await consent.isGranted('account-b'), isFalse);
      await consent.setGranted('account-a', false);
      expect(await consent.isGranted('account-a'), isFalse);
    },
  );

  test('no account cannot receive consent', () async {
    await expectLater(
      AiSharingConsent.instance.setGranted('', true),
      throwsStateError,
    );
  });

  for (final allow in [false, true]) {
    testWidgets(
      allow
          ? 'allows sharing only after an explicit click'
          : 'declining never grants sharing',
      (tester) async {
        final choices = <bool>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              backgroundColor: kBackgroundColor,
              body: Center(
                child: SizedBox(
                  width: 500,
                  child: FTheme(
                    data: FThemes.zinc.dark,
                    child: BotvinnikAiConsentDialog(
                      accountId: 'account-a',
                      saveChoice: (choice) async => choices.add(choice),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(choices, isEmpty);
        expect(find.textContaining('Cloudflare Workers AI'), findsOneWidget);
        expect(find.textContaining('TinyFish'), findsOneWidget);
        await tester.tap(
          find.text(allow ? 'Allow AI sharing' : 'Do not allow'),
        );
        await tester.pumpAndSettle();
        expect(choices, [allow]);
      },
    );
  }

  testWidgets('consent is readable and scrollable at a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: kBackgroundColor,
          body: RepaintBoundary(
            key: key,
            child: SingleChildScrollView(
              child: FTheme(
                data: FThemes.zinc.dark,
                child: BotvinnikAiConsentDialog(
                  accountId: 'account-a',
                  saveChoice: (_) async {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final pixels = await boundary.toImage();
      final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '/tmp/chessever-ai-consent.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      pixels.dispose();
    });
    await tester.ensureVisible(find.text('Allow AI sharing'));
    expect(find.text('Allow AI sharing').hitTestable(), findsOneWidget);
  });
}
