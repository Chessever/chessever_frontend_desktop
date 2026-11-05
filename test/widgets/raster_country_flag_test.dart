import 'dart:async';

import 'package:chessever/widgets/raster_country_flag.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingBundle extends CachingAssetBundle {
  int loads = 0;

  @override
  Future<ByteData> load(String key) {
    loads++;
    return rootBundle.load(key);
  }
}

Future<ImageInfo> _resolve(
  ImageProvider provider,
  ImageConfiguration configuration,
) async {
  final result = Completer<ImageInfo>();
  final stream = provider.resolve(configuration);
  final listener = ImageStreamListener(
    (image, _) => result.complete(image),
    onError: result.completeError,
  );
  stream.addListener(listener);
  try {
    return await result.future;
  } finally {
    stream.removeListener(listener);
  }
}

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Future<ImageProvider> providerFor(
    WidgetTester tester, {
    String code = 'DE',
    double width = 18,
    double height = 12,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RasterCountryFlag(code, width: width, height: height),
        ),
      ),
    );
    return tester.widget<Image>(find.byType(Image)).image;
  }

  testWidgets('shares pending loads and cached pixels for equivalent flags', (
    tester,
  ) async {
    final upper = await providerFor(tester, code: 'US');
    final lower = await providerFor(tester, code: 'us');
    final bundle = _CountingBundle();
    final config = ImageConfiguration(bundle: bundle, devicePixelRatio: 2);
    final images = await tester.runAsync(
      () => Future.wait([_resolve(upper, config), _resolve(lower, config)]),
    );
    expect(bundle.loads, 1);
    expect(images![0].image.isCloneOf(images[1].image), isTrue);
    expect(images[0].image.width, 36);
    expect(images[0].image.height, 24);
    for (final image in images) {
      image.dispose();
    }
    final cached = await tester.runAsync(() => _resolve(lower, config));
    expect(bundle.loads, 1);
    cached!.dispose();
  });

  testWidgets('separates sizes, pixel densities and asset bundles', (
    tester,
  ) async {
    final small = await providerFor(tester);
    final large = await providerFor(tester, width: 36, height: 24);
    final bundle = _CountingBundle();
    final other = _CountingBundle();
    final one = ImageConfiguration(bundle: bundle, devicePixelRatio: 1);
    final two = ImageConfiguration(bundle: bundle, devicePixelRatio: 2);
    expect(await small.obtainKey(one), isNot(await small.obtainKey(two)));
    expect(await small.obtainKey(two), await large.obtainKey(one));
    expect(
      await small.obtainKey(one),
      isNot(await small.obtainKey(ImageConfiguration(bundle: other))),
    );
  });

  testWidgets('covers a square slot without transparent letterboxing', (
    tester,
  ) async {
    final provider = await providerFor(tester, width: 12, height: 12);
    final image = await tester.runAsync(
      () => _resolve(provider, const ImageConfiguration(devicePixelRatio: 2)),
    );
    expect(image!.image.width, 24);
    expect(image.image.height, 24);
    final bytes = await tester.runAsync(() => image.image.toByteData());
    final pixels = bytes!.buffer.asUint8List();
    List<int> pixel(int x, int y) =>
        pixels.sublist((y * 24 + x) * 4, (y * 24 + x) * 4 + 4);
    expect(pixel(1, 1), [0, 0, 0, 255]);
    expect(pixel(22, 12), [221, 0, 0, 255]);
    expect(pixel(1, 22), [255, 206, 0, 255]);
    image.dispose();
  });

  testWidgets('caps large artwork textures while preserving the slot', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = await providerFor(tester, width: 1800, height: 1200);
    final image = await tester.runAsync(
      () => _resolve(provider, const ImageConfiguration(devicePixelRatio: 3)),
    );
    expect(image!.image.width, 1024);
    expect(image.image.height, 683);
    expect(
      tester.getSize(find.byType(RasterCountryFlag)),
      const Size(1800, 1200),
    );
    image.dispose();
  });
}
