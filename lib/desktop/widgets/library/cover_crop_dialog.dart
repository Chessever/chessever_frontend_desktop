import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/collection_cover.dart';
import 'package:chessever/desktop/widgets/desktop_dialog_button.dart';
import 'package:chessever/theme/app_theme.dart';

/// Choose an image, let the author frame it, and return the prepared 2:3
/// cover, or null when they cancel at either step. Overridden in tests.
final collectionCoverPickerProvider =
    Provider<Future<Uint8List?> Function(BuildContext context)>(
      (ref) => (context) async {
        final source = await ref.read(collectionCoverSourceProvider)();
        if (source == null || !context.mounted) return null;
        return ref.read(collectionCoverFramerProvider)(context, source);
      },
    );

/// Frame an image that is already in hand (a file dropped on the cover slot)
/// and return the prepared 2:3 cover, or null when the author cancels.
/// Overridden in tests.
final collectionCoverFramerProvider = Provider<
  Future<Uint8List?> Function(BuildContext context, Uint8List source)
>(
  (ref) => (context, source) async {
    final size = await collectionCoverSourceSize(source);
    if (!collectionCoverFits(size)) {
      throw const FormatException(
        'This image is too small for a cover. Use one at least 600 × 900 pixels.',
      );
    }
    if (!context.mounted) return null;
    final crop = await showCoverCropDialog(
      context,
      bytes: source,
      photoSize: size,
    );
    if (crop == null) return null;
    return prepareCollectionCover(source, crop: crop);
  },
);

/// Choose an image, let the author frame it square, and return the prepared
/// 512×512 author photo, or null when they cancel at either step. Reuses the
/// generalized cropper with a 1:1 frame; the cover path is untouched.
/// Overridden in tests.
final authorPhotoPickerProvider =
    Provider<Future<Uint8List?> Function(BuildContext context)>(
      (ref) => (context) async {
        final source = await ref.read(authorPhotoSourceProvider)();
        if (source == null || !context.mounted) return null;
        return ref.read(authorPhotoFramerProvider)(context, source);
      },
    );

/// Frame an image that is already in hand (a file dropped on an author's
/// photo slot) and return the prepared square photo, or null on cancel.
/// Overridden in tests.
final authorPhotoFramerProvider = Provider<
  Future<Uint8List?> Function(BuildContext context, Uint8List source)
>(
  (ref) => (context, source) async {
    final size = await collectionCoverSourceSize(source);
    if (!authorPhotoFits(size)) {
      throw const FormatException(
        'This image is too small for an author photo. Use one at least 256 × 256 pixels.',
      );
    }
    if (!context.mounted) return null;
    final crop = await showCoverCropDialog(
      context,
      bytes: source,
      photoSize: size,
      aspectWidth: 1,
      aspectHeight: 1,
      minSourceWidth: authorPhotoMinSize,
      minSourceHeight: authorPhotoMinSize,
      title: 'Frame the author photo',
      instructions:
          'Drag to move, scroll to zoom. The square frame is exactly what shows with the author’s name.',
    );
    if (crop == null) return null;
    return prepareAuthorPhoto(source, crop: crop);
  },
);

/// The framing step as a desktop card over the editor. Returns the framed
/// window as fractions of the photo, or null on Cancel / Esc / outside click.
///
/// Defaults frame a 2:3 cover (the original behaviour, unchanged). Pass
/// [aspectWidth]/[aspectHeight], [minSourceWidth]/[minSourceHeight] and a
/// [title] to frame a different shape — the author photo uses a 1:1 / 256-min
/// square. The zoom floor is whichever source dimension the output needs most.
Future<Rect?> showCoverCropDialog(
  BuildContext context, {
  required Uint8List bytes,
  required Size photoSize,
  int aspectWidth = 2,
  int aspectHeight = 3,
  int minSourceWidth = collectionCoverMinWidth,
  int minSourceHeight = collectionCoverMinHeight,
  String title = 'Frame your cover',
  String instructions =
      'Drag to move, scroll to zoom. The frame is exactly what the cover shows.',
}) => showGeneralDialog<Rect>(
  context: context,
  barrierDismissible: true,
  barrierLabel: title,
  barrierColor: Colors.black.withValues(alpha: 0.6),
  transitionDuration: const Duration(milliseconds: 140),
  pageBuilder:
      (ctx, _, _) => FTheme(
        data: FThemes.zinc.dark,
        child: Center(
          child: CoverCropCard(
            bytes: bytes,
            photoSize: photoSize,
            aspectWidth: aspectWidth,
            aspectHeight: aspectHeight,
            minSourceWidth: minSourceWidth,
            minSourceHeight: minSourceHeight,
            title: title,
            instructions: instructions,
          ),
        ),
      ),
);

/// The frame stays put; the image moves under it (drag) and scales (scroll,
/// pinch on a trackpad, or the slider). Zoom stops before the framed window
/// drops below the source pixels the output needs, and the image always fills
/// the frame.
class CoverCropCard extends StatefulWidget {
  const CoverCropCard({
    super.key,
    required this.bytes,
    required this.photoSize,
    this.aspectWidth = 2,
    this.aspectHeight = 3,
    this.minSourceWidth = collectionCoverMinWidth,
    this.minSourceHeight = collectionCoverMinHeight,
    this.title = 'Frame your cover',
    this.instructions =
        'Drag to move, scroll to zoom. The frame is exactly what the cover shows.',
  });

  final Uint8List bytes;
  final Size photoSize;
  final int aspectWidth;
  final int aspectHeight;
  final int minSourceWidth;
  final int minSourceHeight;
  final String title;
  final String instructions;

  @override
  State<CoverCropCard> createState() => _CoverCropCardState();
}

class _CoverCropCardState extends State<CoverCropCard> {
  /// The on-screen frame, sized to the aspect with a stable long edge of 450
  /// (so the cover's 300×450 is unchanged and a square comes out 450×450).
  late final Size _frame = _frameFor(widget.aspectWidth, widget.aspectHeight);

  static Size _frameFor(int aw, int ah) {
    const long = 450.0;
    return aw >= ah ? Size(long, long * ah / aw) : Size(long * aw / ah, long);
  }

  final _transform = TransformationController();

  double get _cover => math.max(
    _frame.width / widget.photoSize.width,
    _frame.height / widget.photoSize.height,
  );
  Size get _child => widget.photoSize * _cover;

  /// Zoom may grow until the framed window reaches the smaller of the two
  /// source-pixel floors the output needs. The width floor governs when the
  /// frame is wider than tall relative to the source and vice-versa; taking
  /// the tighter cap keeps both dimensions above their minimum.
  double get _maxZoom {
    final widthCap = _frame.width / _cover / widget.minSourceWidth;
    final heightCap = _frame.height / _cover / widget.minSourceHeight;
    return math.max(1.0, math.min(widthCap, heightCap));
  }

  double get _zoom => _transform.value.getMaxScaleOnAxis();

  @override
  void initState() {
    super.initState();
    final dx = (_child.width - _frame.width) / 2;
    final dy = (_child.height - _frame.height) / 2;
    _transform.value = Matrix4.translationValues(-dx, -dy, 0);
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform
      ..removeListener(_onTransform)
      ..dispose();
    super.dispose();
  }

  void _onTransform() => setState(() {});

  /// Slider zoom keeps the frame's centre on the same point of the image,
  /// then keeps the image covering the frame.
  void _zoomTo(double k) {
    final m = _transform.value;
    final old = _zoom;
    final cx = (_frame.width / 2 - m.storage[12]) / old;
    final cy = (_frame.height / 2 - m.storage[13]) / old;
    final tx = (_frame.width / 2 - cx * k).clamp(
      _frame.width - _child.width * k,
      0.0,
    );
    final ty = (_frame.height / 2 - cy * k).clamp(
      _frame.height - _child.height * k,
      0.0,
    );
    _transform.value =
        Matrix4.identity()
          ..translateByDouble(tx, ty, 0, 1)
          ..scaleByDouble(k, k, 1, 1);
  }

  void _use() {
    final m = _transform.value;
    final k = _zoom;
    Navigator.of(context).pop(
      Rect.fromLTWH(
        -m.storage[12] / k / _child.width,
        -m.storage[13] / k / _child.height,
        _frame.width / k / _child.width,
        _frame.height / k / _child.height,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canZoom = _maxZoom > 1.0001;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter): _use},
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: math.max(380, _frame.width + 40),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            decoration: BoxDecoration(
              color: kBlack2Color,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kDividerColor),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    color: kWhiteColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.instructions,
                  style: const TextStyle(
                    color: kWhiteColor70,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      width: _frame.width,
                      height: _frame.height,
                      foregroundDecoration: BoxDecoration(
                        border: Border.all(
                          color: kWhiteColor.withValues(alpha: 0.5),
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          minScale: 1,
                          maxScale: _maxZoom,
                          boundaryMargin: EdgeInsets.zero,
                          child: Image.memory(
                            widget.bytes,
                            width: _child.width,
                            height: _child.height,
                            fit: BoxFit.fill,
                            cacheWidth:
                                math.min(widget.photoSize.width, 1600).round(),
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(
                      Icons.photo_size_select_small,
                      size: 16,
                      color: kWhiteColor70,
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: kPrimaryColor,
                          inactiveTrackColor: kDividerColor,
                          thumbColor: kWhiteColor,
                          overlayShape: SliderComponentShape.noOverlay,
                          trackHeight: 2,
                        ),
                        child: Slider(
                          key: const ValueKey('cover_crop_zoom'),
                          value: _zoom.clamp(1.0, _maxZoom),
                          min: 1,
                          max: canZoom ? _maxZoom : 1.0001,
                          semanticFormatterCallback:
                              (v) => 'Zoom ${(v * 100).round()}%',
                          onChanged: canZoom ? _zoomTo : null,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.photo_size_select_large,
                      size: 16,
                      color: kWhiteColor70,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    DesktopDialogButton(
                      label: 'Cancel',
                      tone: DesktopDialogButtonTone.ghost,
                      onPress: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    DesktopDialogButton(
                      key: const ValueKey('cover_crop_use'),
                      label: 'Use image',
                      tone: DesktopDialogButtonTone.primary,
                      onPress: _use,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
