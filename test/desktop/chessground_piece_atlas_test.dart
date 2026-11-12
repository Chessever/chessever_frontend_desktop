import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:chessground/chessground.dart' as cg;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('warm scrolling boards schedule no deferred-loading frame loop', (
    tester,
  ) async {
    final images = cg.ChessgroundImages.instance;
    await tester.runAsync(() => images.loadAll(cg.PieceSet.cburnett.assets));
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
          physics: _AlwaysDeferredPhysics(),
          child: cg.StaticChessboard(
            size: 200,
            fen: kInitialFEN,
            orientation: Side.white,
          ),
        ),
      ),
    );
    final scheduled = tester.binding.transientCallbackCount;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    images.clear();
    expect(
      scheduled,
      0,
      reason: 'Decoded pieces do not need to poll scroll velocity every frame.',
    );
  });

  testWidgets('custom non-square assets keep the original image path', (
    tester,
  ) async {
    final images = cg.ChessgroundImages.instance;
    final assets = cg.PieceSet.cburnett.assets;
    await tester.runAsync(() async {
      for (final asset in assets.values) {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 24, 16),
          Paint()..color = const Color(0xffc56b42),
        );
        final picture = recorder.endRecording();
        images.add(asset, await picture.toImage(24, 16));
        picture.dispose();
      }
      await images.loadAll(assets);
    });
    expect(images.atlasFor(assets), isNull);
    images.clear();
  });

  testWidgets('replacing an asset invalidates the packed sheet', (
    tester,
  ) async {
    final images = cg.ChessgroundImages.instance;
    final assets = cg.PieceSet.cburnett.assets;
    await tester.runAsync(() => images.loadAll(assets, devicePixelRatio: 2));
    final before = images.atlasFor(assets)!;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 16, 16),
        Paint()..color = const Color(0xffc56b42),
      );
      final picture = recorder.endRecording();
      images.add(assets.values.first, await picture.toImage(16, 16));
      picture.dispose();
      expect(images.atlasFor(assets), isNull);
      await images.loadAll(assets);
    });
    expect(images.atlasFor(assets), isNot(same(before)));
    images.clear();
  });

  testWidgets('a full board batches its 32 pieces into one atlas draw', (
    tester,
  ) async {
    final assets = cg.PieceSet.cburnett.assets;
    final images = cg.ChessgroundImages.instance;
    await tester.runAsync(() async {
      for (final asset in assets.values) {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 16, 16),
          Paint()..color = const Color(0xffc56b42),
        );
        final picture = recorder.endRecording();
        images.add(asset, await picture.toImage(16, 16));
        picture.dispose();
      }
      await images.loadAll(assets);
    });
    await tester.pumpWidget(
      const cg.StaticChessboard(
        size: 200,
        fen: kInitialFEN,
        orientation: Side.white,
      ),
    );
    final painter =
        find
            .byType(CustomPaint)
            .evaluate()
            .map((element) => (element.widget as CustomPaint).painter)
            .whereType<cg.PiecesPainter>()
            .single;
    final canvas = TestRecordingCanvas();
    painter.paint(canvas, const Size.square(200));
    final calls = canvas.invocations.map((call) => call.invocation.memberName);
    final draws = (
      images: calls.where((name) => name == #drawImageRect).length,
      atlases: calls.where((name) => name == #drawAtlas).length,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    images.clear();
    expect(draws, (images: 0, atlases: 1));
  });

  testWidgets('atlas matches original pieces at small and retina board sizes', (
    tester,
  ) async {
    final images = cg.ChessgroundImages.instance;
    final assets = cg.PieceSet.cburnett.assets;
    await tester.runAsync(() => images.loadAll(assets, devicePixelRatio: 2));
    for (final side in Side.values) {
      for (final size in [64.0, 208.0, 520.0]) {
        await tester.pumpWidget(
          cg.StaticChessboard(
            size: size,
            orientation: side,
            fen: kInitialFEN,
            pieceRotations: const {Square.e8: -math.pi / 4},
          ),
        );
        final painter =
            find
                .byType(CustomPaint)
                .evaluate()
                .map((element) => (element.widget as CustomPaint).painter)
                .whereType<cg.PiecesPainter>()
                .single;
        final pair = await tester.runAsync(
          () async => (
            await _pixels(painter, size, reference: false),
            await _pixels(painter, size, reference: true),
          ),
        );
        final (actual, expected) = pair!;
        var difference = 0;
        var visiblyDifferentPixels = 0;
        // drawAtlas and drawImageRect use different edge sampling kernels.
        // Allow one physical pixel at an anti-aliased edge, not a different
        // piece, position, orientation or missing sprite.
        final width = (size * 2).round();
        for (var i = 0; i < actual.length; i += 4) {
          final x = (i ~/ 4) % width;
          final y = (i ~/ 4) ~/ width;
          var smallest = 1021;
          var largestAtBest = 255;
          for (var dy = -1; dy <= 1; dy++) {
            for (var dx = -1; dx <= 1; dx++) {
              if (x + dx < 0 ||
                  x + dx >= width ||
                  y + dy < 0 ||
                  y + dy >= width) {
                continue;
              }
              final other = ((y + dy) * width + x + dx) * 4;
              var sum = 0;
              var largest = 0;
              for (var c = 0; c < 4; c++) {
                final delta = (actual[i + c] - expected[other + c]).abs();
                sum += delta;
                largest = math.max(largest, delta);
              }
              if (sum < smallest) {
                smallest = sum;
                largestAtBest = largest;
              }
            }
          }
          difference += smallest;
          if (largestAtBest > 16) visiblyDifferentPixels++;
        }
        expect(
          difference / actual.length,
          lessThan(1.0),
          reason: '$side $size: average channel error',
        );
        expect(
          visiblyDifferentPixels / (actual.length / 4),
          lessThan(0.02),
          reason: '$side $size: visible changes to piece edges',
        );
        // A missing/faded sprite cannot be excused as edge sampling. Compare
        // coverage per square as well as the full image's local pixel error.
        final cell = width ~/ 8;
        for (var row = 0; row < 8; row++) {
          for (var col = 0; col < 8; col++) {
            var actualAlpha = 0;
            var expectedAlpha = 0;
            for (var y = row * cell; y < (row + 1) * cell; y++) {
              for (var x = col * cell; x < (col + 1) * cell; x++) {
                final alpha = (y * width + x) * 4 + 3;
                actualAlpha += actual[alpha];
                expectedAlpha += expected[alpha];
              }
            }
            expect(
              (actualAlpha - expectedAlpha).abs(),
              lessThanOrEqualTo(math.max(1, expectedAlpha * 0.05)),
              reason: '$side $size: sprite coverage on $row,$col',
            );
          }
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    images.clear();
  });
}

class _AlwaysDeferredPhysics extends ScrollPhysics {
  const _AlwaysDeferredPhysics({super.parent});

  @override
  _AlwaysDeferredPhysics applyTo(ScrollPhysics? ancestor) =>
      _AlwaysDeferredPhysics(parent: buildParent(ancestor));

  @override
  bool recommendDeferredLoading(
    double velocity,
    ScrollMetrics metrics,
    BuildContext context,
  ) => true;
}

Future<Uint8List> _pixels(
  cg.PiecesPainter painter,
  double size, {
  required bool reference,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(2);
  if (reference) {
    // The original per-piece path, independent of atlas packing/transforms.
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final squareSize = size / 8;
    for (final entry in painter.pieces.entries) {
      final image =
          cg.ChessgroundImages.instance.get(
            painter.pieceAssets[entry.value.kind]!,
          )!;
      final x =
          painter.orientation == Side.white
              ? entry.key.file
              : 7 - entry.key.file;
      final y =
          painter.orientation == Side.white
              ? 7 - entry.key.rank
              : entry.key.rank;
      final dest = Rect.fromLTWH(
        x * squareSize,
        y * squareSize,
        squareSize,
        squareSize,
      );
      final angle = painter.pieceRotations[entry.key] ?? 0.0;
      canvas.save();
      canvas.translate(dest.center.dx, dest.center.dy);
      canvas.rotate(angle);
      canvas.translate(-dest.center.dx, -dest.center.dy);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        dest,
        paint,
      );
      canvas.restore();
    }
  } else {
    painter.paint(canvas, Size.square(size));
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage((size * 2).round(), (size * 2).round());
  picture.dispose();
  final data = await image.toByteData();
  image.dispose();
  return data!.buffer.asUint8List();
}
