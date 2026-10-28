import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A collection cover is the image shown on collection cards and at the top
/// of the collection page. It is NOT the profile photo: that one is the
/// author picture. Mirrors chessever-frontend's
/// lib/repository/library/collection_cover.dart; keep the two in step.
///
/// Gamebase accepts JPEG/PNG/WebP covers that are a 2:3 portrait of at least
/// 600×900 and stores them as 800×1200. Preparing the exact output here keeps
/// the upload small and makes the preview identical to what gets published.
const collectionCoverWidth = 800;
const collectionCoverHeight = 1200;
const collectionCoverMinWidth = 600;
const collectionCoverMinHeight = 900;
const _maxSourceBytes = 25 * 1024 * 1024;

/// An author photo is the credited author's own square picture, shown with
/// their name in Collections. It is NOT the cover and NOT the profile photo.
/// Gamebase accepts JPEG/PNG/WebP squares of at least 256×256 and stores them
/// as 512×512 WebP; preparing an exact 512×512 here keeps the upload small and
/// the preview faithful. (The client renders PNG, as the cover does; the
/// server re-encodes to WebP.)
const authorPhotoSize = 512;
const authorPhotoMinSize = 256;

/// Opens the system file dialog for one image and returns it untouched, or
/// null on cancel. The cropper then frames it and [prepareCollectionCover]
/// renders the cover.
final collectionCoverSourceProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      dialogTitle: 'Choose a collection cover',
    );
    if (picked == null) return null;
    final source = picked.files.single.bytes;
    if (source == null || source.isEmpty) {
      throw const FormatException(
        'This image could not be read. Choose another one.',
      );
    }
    if (source.length > _maxSourceBytes) {
      throw const FormatException('Choose an image smaller than 25 MB.');
    }
    return source;
  },
);

/// Pixel size of an encoded photo, without decoding it.
Future<Size> collectionCoverSourceSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    return size;
  } catch (_) {
    throw const FormatException(
      'This photo could not be read. Choose another one.',
    );
  } finally {
    buffer.dispose();
  }
}

/// Whether a photo of [size] can give a 2:3 cover of at least 600×900.
bool collectionCoverFits(Size size) =>
    math.min(size.width, size.height * 2 / 3) >= collectionCoverMinWidth;

/// Opens the system file dialog for one author photo and returns it untouched,
/// or null on cancel. Separate from the cover picker only in its dialog title;
/// the cropper then frames it square and [prepareAuthorPhoto] renders it.
final authorPhotoSourceProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      dialogTitle: 'Choose an author photo',
    );
    if (picked == null) return null;
    final source = picked.files.single.bytes;
    if (source == null || source.isEmpty) {
      throw const FormatException(
        'This image could not be read. Choose another one.',
      );
    }
    if (source.length > _maxSourceBytes) {
      throw const FormatException('Choose an image smaller than 25 MB.');
    }
    return source;
  },
);

/// Whether a photo of [size] can give a square author photo of at least
/// 256×256. The limiting dimension is the shorter side.
bool authorPhotoFits(Size size) =>
    math.min(size.width, size.height) >= authorPhotoMinSize;

/// Renders [bytes] as an exactly 800×1200 PNG cover. [crop] is the framed
/// window as fractions of the photo (0..1); omitted, the largest centred 2:3
/// window is used. Refuses a window smaller than 600×900 photo pixels rather
/// than upscaling it into a blurry cover.
Future<Uint8List> prepareCollectionCover(Uint8List bytes, {Rect? crop}) =>
    _prepareFramedImage(
      bytes,
      crop: crop,
      aspectWidth: 2,
      aspectHeight: 3,
      outWidth: collectionCoverWidth,
      outHeight: collectionCoverHeight,
      minWidth: collectionCoverMinWidth,
      minHeight: collectionCoverMinHeight,
      tooSmall:
          'This photo is too small for a cover. Use one at least 600 × 900 pixels.',
    );

/// Renders [bytes] as an exactly 512×512 PNG author photo (the server
/// re-encodes to WebP). [crop] is the framed square as fractions of the photo;
/// omitted, the largest centred square is used. Refuses a window smaller than
/// 256×256 photo pixels rather than upscaling. Does not touch the cover path.
Future<Uint8List> prepareAuthorPhoto(Uint8List bytes, {Rect? crop}) =>
    _prepareFramedImage(
      bytes,
      crop: crop,
      aspectWidth: 1,
      aspectHeight: 1,
      outWidth: authorPhotoSize,
      outHeight: authorPhotoSize,
      minWidth: authorPhotoMinSize,
      minHeight: authorPhotoMinSize,
      tooSmall:
          'This photo is too small for an author photo. Use one at least 256 × 256 pixels.',
    );

/// The shared renderer behind the cover and the author photo. It frames an
/// [aspectWidth]:[aspectHeight] window of the photo and paints it into an
/// [outWidth]×[outHeight] PNG on a white backing, refusing a window below
/// [minWidth]×[minHeight] source pixels. The cover is the 2:3 / 800×1200 case
/// and its output is unchanged by this extraction.
Future<Uint8List> _prepareFramedImage(
  Uint8List bytes, {
  required Rect? crop,
  required int aspectWidth,
  required int aspectHeight,
  required int outWidth,
  required int outHeight,
  required int minWidth,
  required int minHeight,
  required String tooSmall,
}) async {
  if (bytes.length > _maxSourceBytes) {
    throw const FormatException('Choose a photo smaller than 25 MB.');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  late final ui.Codec codec;
  late final Rect window;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    if (w * h > 60000000) {
      throw const FormatException('Choose a photo with smaller dimensions.');
    }
    // The framed window in photo pixels, kept at exactly the target aspect and
    // inside the photo; by default the largest centred one.
    final full = math.min(
      w.toDouble(),
      h * aspectWidth / aspectHeight,
    );
    final cropW =
        crop == null ? full : (crop.width * w).clamp(1.0, full).toDouble();
    final cropH = cropW * aspectHeight / aspectWidth;
    final left =
        crop == null
            ? (w - cropW) / 2
            : (crop.left * w).clamp(0.0, w - cropW).toDouble();
    final top =
        crop == null
            ? (h - cropH) / 2
            : (crop.top * h).clamp(0.0, h - cropH).toDouble();
    if (cropW < minWidth || cropH < minHeight) {
      throw FormatException(tooSmall);
    }
    // Decode only as large as the output needs, to keep memory low.
    final factor = math.min(1.0, outHeight / cropH);
    final dw = math.max(1, (w * factor).round());
    final dh = math.max(1, (h * factor).round());
    codec = await descriptor.instantiateCodec(
      targetWidth: dw,
      targetHeight: dh,
    );
    window = Rect.fromLTWH(
      left * dw / w,
      top * dh / h,
      cropW * dw / w,
      cropH * dh / h,
    );
  } catch (_) {
    descriptor?.dispose();
    rethrow;
  } finally {
    buffer.dispose();
  }
  try {
    final image = (await codec.getNextFrame()).image;
    try {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawColor(Colors.white, BlendMode.src)
        ..drawImageRect(
          image,
          window,
          Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
          Paint()..filterQuality = FilterQuality.high,
        );
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(outWidth, outHeight);
      picture.dispose();
      try {
        final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
        if (data == null || data.lengthInBytes > 8 * 1024 * 1024) {
          throw const FormatException('Choose a simpler or smaller photo.');
        }
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        rendered.dispose();
      }
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
    descriptor.dispose();
  }
}
