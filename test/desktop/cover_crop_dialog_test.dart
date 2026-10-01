import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chessever/desktop/services/collection_cover.dart';
import 'package:chessever/desktop/widgets/library/cover_crop_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';

final _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<Uint8List> _photo(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..drawRect(
      Rect.fromLTWH(0, 0, width / 2, height.toDouble()),
      Paint()..color = const Color(0xFFFF0000),
    )
    ..drawRect(
      Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()),
      Paint()..color = const Color(0xFF0000FF),
    );
  final image = await recorder.endRecording().toImage(width, height);
  return (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
}

Future<Rect?> _open(
  WidgetTester tester,
  Size photo,
  Future<void> Function() act,
) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  Rect? framed = Rect.zero;
  await tester.pumpWidget(
    MaterialApp(
      home: FTheme(
        data: FThemes.zinc.dark,
        child: Builder(
          builder:
              (context) => TextButton(
                onPressed:
                    () async =>
                        framed = await showCoverCropDialog(
                          context,
                          bytes: _onePixelPng,
                          photoSize: photo,
                        ),
                child: const Text('open'),
              ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('Frame your cover'), findsOneWidget);
  await act();
  await tester.pumpAndSettle();
  return framed;
}

void main() {
  testWidgets(
    'starts centred and returns the framed window',
    semanticsEnabled: false,
    (tester) async {
      final framed = await _open(tester, const Size(1800, 1200), () async {
        await tester.tap(
          find.byKey(const ValueKey('cover_crop_use')),
          warnIfMissed: false,
        );
      });
      expect(framed!.top, closeTo(0, 1e-6));
      expect(framed.height, closeTo(1, 1e-6));
      expect(framed.width, closeTo(800 / 1800, 1e-6));
      expect(framed.left, closeTo((1 - 800 / 1800) / 2, 1e-6));
    },
  );

  testWidgets(
    'the slider zooms about the centre and never past 600 px',
    semanticsEnabled: false,
    (tester) async {
      // 2400×3600 photo: zoom 1 shows 2400 px wide, so the cap is 4×.
      final framed = await _open(tester, const Size(2400, 3600), () async {
        final slider = tester.widget<Slider>(
          find.byKey(const ValueKey('cover_crop_zoom')),
        );
        expect(slider.max, closeTo(4, 1e-6));
        slider.onChanged!(2);
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('cover_crop_use')),
          warnIfMissed: false,
        );
      });
      expect(framed!.width, closeTo(0.5, 1e-6));
      expect(framed.height, closeTo(0.5, 1e-6));
      expect(framed.center.dx, closeTo(0.5, 1e-6));
      expect(framed.center.dy, closeTo(0.5, 1e-6));
    },
  );

  testWidgets('Cancel returns nothing', semanticsEnabled: false, (
    tester,
  ) async {
    final framed = await _open(tester, const Size(1200, 1800), () async {
      await tester.tap(find.text('Cancel'), warnIfMissed: false);
    });
    expect(framed, isNull);
  });

  testWidgets('the cover is rendered from the framed window', (tester) async {
    await tester.runAsync(() async {
      final photo = await _photo(1800, 1200);
      final cover = await prepareCollectionCover(
        photo,
        crop: const Rect.fromLTWH(0.6, 0, 0.4444, 1),
      );
      final codec = await ui.instantiateImageCodec(cover);
      final image = (await codec.getNextFrame()).image;
      expect((image.width, image.height), (800, 1200));
      final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final i = (600 * 800 + 400) * 4;
      expect((raw.getUint8(i), raw.getUint8(i + 2)), (0, 255));
    });
    expect(collectionCoverFits(const Size(1600, 800)), isFalse);
  });
}
