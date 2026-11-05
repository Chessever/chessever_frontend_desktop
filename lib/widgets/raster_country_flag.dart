import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:country_flags/country_flags.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:jovial_svg/jovial_svg.dart';

/// The existing flag artwork, cached at its displayed pixel size.
///
/// A scrolling grid can contain hundreds of flags. Replaying their vector paths
/// on each frame costs far more than drawing the small images. ImageCache shares
/// both pending loads and finished images, bounds retained memory, and owns image
/// disposal. Changing the display scale or slot size gets a new cache entry.
class RasterCountryFlag extends StatelessWidget {
  const RasterCountryFlag(
    this.countryCode, {
    super.key,
    this.width = 60,
    this.height = 40,
  });

  final String countryCode;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final flagCode = FlagCode.fromCountryCode(countryCode);
    if (flagCode == null) {
      return CountryFlag.fromCountryCode(
        countryCode,
        theme: ImageTheme(width: width, height: height),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.constrain(Size(width, height));
          if (size.isEmpty) return const SizedBox.shrink();
          return Image(
            image: _FlagImage(flagCode, size),
            width: size.width,
            height: size.height,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.low,
            excludeFromSemantics: true,
          );
        },
      ),
    );
  }
}

class _FlagImage extends ImageProvider<_FlagImageKey> {
  const _FlagImage(this.flagCode, this.size);

  final String flagCode;
  final Size size;

  @override
  Future<_FlagImageKey> obtainKey(ImageConfiguration configuration) {
    // Keep even very large event artwork bounded, without changing its aspect.
    final scale = math.min(
      configuration.devicePixelRatio ?? 1,
      1024 / math.max(size.width, size.height),
    );
    return SynchronousFuture(
      _FlagImageKey(
        flagCode,
        configuration.bundle ?? rootBundle,
        math.max(1, (size.width * scale).ceil()),
        math.max(1, (size.height * scale).ceil()),
      ),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    _FlagImageKey key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_rasterize(key));
  }

  Future<ImageInfo> _rasterize(_FlagImageKey key) async {
    final scalable = await ScalableImage.fromSIAsset(
      key.bundle,
      'packages/country_flags/res/si/${key.flagCode}.si',
    );
    await scalable.prepareImages();
    ui.Picture? picture;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final viewport = scalable.viewport;
      final scale = math.max(
        key.width / viewport.width,
        key.height / viewport.height,
      );
      canvas.clipRect(
        Rect.fromLTWH(0, 0, key.width.toDouble(), key.height.toDouble()),
      );
      canvas.translate(
        (key.width - viewport.width * scale) / 2,
        (key.height - viewport.height * scale) / 2,
      );
      canvas.scale(scale);
      scalable.paint(canvas);
      picture = recorder.endRecording();
      return ImageInfo(image: await picture.toImage(key.width, key.height));
    } finally {
      picture?.dispose();
      scalable.unprepareImages();
    }
  }
}

@immutable
class _FlagImageKey {
  const _FlagImageKey(this.flagCode, this.bundle, this.width, this.height);

  final String flagCode;
  final AssetBundle bundle;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is _FlagImageKey &&
      flagCode == other.flagCode &&
      bundle == other.bundle &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(flagCode, bundle, width, height);
}
