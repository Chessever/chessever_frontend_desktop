import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// Cache the original asset, but decode only the pixels the Inbox can draw.
/// `fit` bounds both axes without stretching a portrait or landscape image.
class InboxImage extends StatelessWidget {
  const InboxImage({
    super.key,
    required this.uri,
    this.width,
    this.height,
    this.fit = BoxFit.fitWidth,
  });

  final Uri uri;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final imageProvider = ResizeImage(
        CachedNetworkImageProvider(uri.toString()),
        width: ((width ?? constraints.maxWidth.clamp(1.0, 640.0)) * dpr)
            .ceil()
            .clamp(1, 2048),
        height: ((height ?? 2048) * dpr).ceil().clamp(1, 4096),
        policy: ResizeImagePolicy.fit,
      );
      return Image(
        image: imageProvider,
        width: width,
        height: height,
        fit: fit,
        frameBuilder:
            (_, child, frame, synchronous) =>
                frame != null || synchronous
                    ? child
                    : width != null && height != null
                    ? SizedBox(width: width, height: height)
                    : const AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ColoredBox(color: kBlack2Color),
                    ),
        errorBuilder: (_, _, _) => SizedBox(width: width, height: height),
      );
    },
  );
}
