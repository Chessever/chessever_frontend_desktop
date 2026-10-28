import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show PathMetric;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import 'package:chessever/theme/app_theme.dart';

/// The largest image a picture slot reads, the same cap the file dialog uses.
const imageDropMaxBytes = 25 * 1024 * 1024;

/// File endings a picture slot takes. Anything else is refused by name, before
/// the file is read.
const _imageEndings = {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
  'heic',
  'heif',
  'tif',
  'tiff',
};

/// Why a dropped file cannot be a picture, in words for the person who
/// dropped it. Null when [name] and [bytes] are worth reading.
String? imageDropRefusal({required String name, required int bytes}) {
  final dot = name.lastIndexOf('.');
  final ending = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (!_imageEndings.contains(ending)) return 'Use a JPEG, PNG or WebP image.';
  if (bytes > imageDropMaxBytes) return 'Choose an image smaller than 25 MB.';
  if (bytes == 0) return 'This image could not be read. Choose another one.';
  return null;
}

/// What a picture slot is doing, for the content drawn inside it.
enum ImageDropPhase { idle, hovered, dragging }

/// A picture slot that takes its image two ways: a file dropped on it, or a
/// click anywhere on it that opens the file dialog.
///
/// The whole slot is the target, so a drop never has to hit a small thumbnail.
/// While a file is held over it the dashed edge closes into the accent line
/// the Library's own drop targets use.
class ImageDropZone extends StatefulWidget {
  const ImageDropZone({
    super.key,
    required this.enabled,
    required this.semanticsLabel,
    required this.onChoose,
    required this.onDropped,
    required this.onRefused,
    required this.builder,
    this.padding = const EdgeInsets.all(14),
    this.tapToChoose = true,
    this.restingEdge = true,
    this.edgeOutset = 0,
  });

  /// False while the slot cannot change (saving, frozen): no drop, no click.
  final bool enabled;
  final String semanticsLabel;

  /// A click on the slot: open the file dialog.
  final VoidCallback onChoose;

  /// A dropped image, read and within the size cap.
  final ValueChanged<Uint8List> onDropped;

  /// A drop that cannot be used, with the reason to show.
  final ValueChanged<String> onRefused;

  final Widget Function(BuildContext context, ImageDropPhase phase) builder;
  final EdgeInsets padding;

  /// Whether a click anywhere on the slot opens the file dialog. Off for a
  /// row that holds other controls; the row still takes a dropped image.
  final bool tapToChoose;

  /// Whether the slot shows its dashed edge at rest. Off, it is drawn only
  /// while a file is held over it.
  final bool restingEdge;

  /// How far outside the slot's left and right the edge is drawn, for a slot
  /// whose content keeps the edges of the form around it.
  final double edgeOutset;

  @override
  State<ImageDropZone> createState() => _ImageDropZoneState();
}

class _ImageDropZoneState extends State<ImageDropZone> {
  bool _hovered = false;
  bool _dragging = false;
  bool _reading = false;

  Future<void> _onDone(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (!widget.enabled || _reading || details.files.isEmpty) return;
    final file = details.files.first;
    if (file is DropItemDirectory) {
      widget.onRefused('Drop an image file, not a folder.');
      return;
    }
    _reading = true;
    try {
      final refusal = imageDropRefusal(
        name: file.name.isEmpty ? file.path : file.name,
        bytes: await file.length(),
      );
      if (!mounted) return;
      if (refusal != null) {
        widget.onRefused(refusal);
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      widget.onDropped(bytes);
    } catch (_) {
      if (mounted) {
        widget.onRefused('This image could not be read. Choose another one.');
      }
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final phase =
        _dragging && enabled
            ? ImageDropPhase.dragging
            : _hovered && enabled
            ? ImageDropPhase.hovered
            : ImageDropPhase.idle;
    final still = MediaQuery.disableAnimationsOf(context);
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) => unawaited(_onDone(details)),
      child: Semantics(
        container: true,
        label: widget.semanticsLabel,
        child: MouseRegion(
          cursor:
              enabled && widget.tapToChoose
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior:
                widget.tapToChoose
                    ? HitTestBehavior.opaque
                    : HitTestBehavior.deferToChild,
            onTap: enabled && widget.tapToChoose ? widget.onChoose : null,
            child: TweenAnimationBuilder<double>(
              // 0 at rest, 1 while a file is held over the slot.
              tween: Tween(end: phase == ImageDropPhase.dragging ? 1 : 0),
              duration:
                  still ? Duration.zero : const Duration(milliseconds: 140),
              curve: const Cubic(0.23, 1, 0.32, 1),
              builder:
                  (context, held, child) => CustomPaint(
                    painter: _SlotPainter(
                      held: held,
                      hovered:
                          widget.tapToChoose && phase == ImageDropPhase.hovered,
                      enabled: enabled,
                      resting: widget.restingEdge,
                      outset: widget.edgeOutset,
                    ),
                    child: child,
                  ),
              child: Padding(
                padding: widget.padding,
                child: widget.builder(context, phase),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The slot's surface: a faint tonal fill inside a dashed edge with round
/// caps, which becomes the solid accent edge as a file is held over it.
class _SlotPainter extends CustomPainter {
  const _SlotPainter({
    required this.held,
    required this.hovered,
    required this.enabled,
    required this.resting,
    required this.outset,
  });

  final double held;
  final bool hovered;
  final bool enabled;
  final bool resting;
  final double outset;

  static const _radius = Radius.circular(10);
  static const _dash = 5.0;
  static const _gap = 5.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      -outset,
      0,
      size.width + outset,
      size.height,
    ).deflate(0.75);
    final shape = RRect.fromRectAndRadius(rect, _radius);
    if (!resting && held == 0) return;
    final rest =
        resting
            ? kWhiteColor.withValues(alpha: hovered ? 0.06 : 0.035)
            : kWhiteColor.withValues(alpha: 0);
    canvas.drawRRect(
      shape,
      Paint()
        ..color =
            Color.lerp(rest, kPrimaryColor.withValues(alpha: 0.10), held)!,
    );
    final edge = Path()..addRRect(shape);
    if (resting && held < 1) {
      final dashed =
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..strokeCap = StrokeCap.round
            ..color = kWhiteColor.withValues(
              alpha: (enabled ? (hovered ? 0.30 : 0.18) : 0.10) * (1 - held),
            );
      for (final PathMetric metric in edge.computeMetrics()) {
        // Whole dashes only, so the pattern closes on itself with no stub.
        final count = (metric.length / (_dash + _gap)).floor();
        if (count == 0) continue;
        final step = metric.length / count;
        for (var i = 0; i < count; i++) {
          final start = i * step;
          canvas.drawPath(metric.extractPath(start, start + _dash), dashed);
        }
      }
    }
    if (held > 0) {
      canvas.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = kPrimaryColor.withValues(alpha: 0.70 * held),
      );
    }
  }

  @override
  bool shouldRepaint(_SlotPainter old) =>
      old.held != held ||
      old.hovered != hovered ||
      old.enabled != enabled ||
      old.resting != resting ||
      old.outset != outset;
}
