import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:chessever/utils/platform/io_platform.dart';

const EdgeInsets desktopWindowSafePadding = EdgeInsets.all(24);

Rect pictureInPictureRectForVisibleBounds({
  required Size size,
  required Rect visibleBounds,
  EdgeInsets padding = desktopWindowSafePadding,
}) {
  final safeBounds = _safeBounds(visibleBounds, padding);
  return Rect.fromLTWH(
    math.max(safeBounds.left, safeBounds.right - size.width),
    safeBounds.top,
    math.min(size.width, safeBounds.width),
    math.min(size.height, safeBounds.height),
  );
}

Rect visibleBoundsForDisplay(Display display) {
  final position = display.visiblePosition ?? Offset.zero;
  final size = display.visibleSize ?? display.size;
  return position & size;
}

/// How much a window's outer bounds may exceed a work area before it counts
/// as not fitting. On Windows the outer bounds include invisible resize
/// borders (window_manager's hidden title bar keeps 8 px on the left, right
/// and bottom) and a maximized window overhangs every edge by its frame, so a
/// window that fits exactly still reports up to ~16 px more than the work
/// area.
const double desktopWindowFrameTolerance = 20;

/// One display's usable work area as screen_retriever reports it.
///
/// Coordinate spaces differ by platform. On macOS and Linux every display and
/// every window share one global logical space. On Windows (per-monitor DPI)
/// screen_retriever divides each monitor's work area by that monitor's own
/// scale while window_manager divides the window rect by the window's current
/// scale, so with two monitors at different scaling the rects only line up on
/// the monitor the window is on. Physical pixels are the one space all
/// Windows monitors share; see [desktopUsesPerMonitorScaling].
@immutable
class DesktopDisplayArea {
  const DesktopDisplayArea({
    required this.visibleBounds,
    this.scaleFactor = 1,
    this.id = '',
  });

  factory DesktopDisplayArea.fromDisplay(Display display) {
    final scale = display.scaleFactor?.toDouble() ?? 1;
    final name = display.name ?? '';
    return DesktopDisplayArea(
      visibleBounds: visibleBoundsForDisplay(display),
      scaleFactor: scale > 0 ? scale : 1,
      id: display.id.isNotEmpty ? display.id : name,
    );
  }

  /// Work area in the display's own logical pixels.
  final Rect visibleBounds;
  final double scaleFactor;
  final String id;

  /// Work area in physical pixels.
  Rect get physicalBounds => _scaleRect(visibleBounds, scaleFactor);

  @override
  bool operator ==(Object other) =>
      other is DesktopDisplayArea &&
      other.visibleBounds == visibleBounds &&
      other.scaleFactor == scaleFactor &&
      other.id == id;

  @override
  int get hashCode => Object.hash(visibleBounds, scaleFactor, id);

  @override
  String toString() =>
      'DesktopDisplayArea($id, $visibleBounds @ ${scaleFactor}x)';
}

/// Whether window and display rects are per-monitor logical pixels that must
/// be compared through physical pixels. See [DesktopDisplayArea].
bool get desktopUsesPerMonitorScaling => Platform.isWindows;

/// Index into [displays] of the display holding [point], or of the nearest
/// display when none holds it; -1 when [displays] is empty.
///
/// [point] is in the window's logical pixels at [windowScale] (window bounds,
/// cursor position).
int displayIndexForPoint({
  required Offset point,
  required double windowScale,
  required List<DesktopDisplayArea> displays,
  required bool perMonitorScaling,
}) {
  if (displays.isEmpty) return -1;
  final probe = perMonitorScaling ? point * windowScale : point;
  Rect boundsOf(DesktopDisplayArea display) =>
      perMonitorScaling ? display.physicalBounds : display.visibleBounds;

  for (var i = 0; i < displays.length; i++) {
    if (boundsOf(displays[i]).contains(probe)) return i;
  }
  var best = 0;
  var bestDistance = double.infinity;
  for (var i = 0; i < displays.length; i++) {
    final distance = (boundsOf(displays[i]).center - probe).distanceSquared;
    if (distance < bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}

/// [display]'s work area in the window's logical pixels at [windowScale],
/// the space window_manager's getBounds / setBounds use.
Rect workAreaInWindowCoordinates({
  required DesktopDisplayArea display,
  required double windowScale,
  required bool perMonitorScaling,
}) {
  if (!perMonitorScaling) return display.visibleBounds;
  return _scaleRect(display.physicalBounds, 1 / windowScale);
}

/// window_manager bounds that place [rect], given in [display]'s own logical
/// pixels, on that display.
///
/// On Windows only the position maps through physical pixels. The size stays
/// in the display's logical pixels because Windows rescales a window by the
/// DPI ratio itself once it lands on a monitor with different scaling;
/// converting the size as well would scale it twice.
Rect windowBoundsForDisplayRect({
  required Rect rect,
  required DesktopDisplayArea display,
  required double windowScale,
  required bool perMonitorScaling,
}) {
  if (!perMonitorScaling) return rect;
  final ratio = display.scaleFactor / windowScale;
  return Rect.fromLTWH(
    rect.left * ratio,
    rect.top * ratio,
    rect.width,
    rect.height,
  );
}

/// Window minimum size: [desiredMinimumSize], lowered until it fits every
/// display's work area.
///
/// window_manager stores the minimum in logical pixels and Windows will not
/// size a window, maximized ones included, below it. A minimum that fits the
/// big monitor the window started on would keep the window taller than a
/// laptop's work area after moving there, hiding its bottom edge under the
/// taskbar. Each work area is in its own display's logical pixels, which is
/// how window_manager applies the minimum on that display.
Size minimumWindowSizeForDisplays({
  required Size desiredMinimumSize,
  required Iterable<Rect> visibleBounds,
  EdgeInsets padding = desktopWindowSafePadding,
}) {
  var width = desiredMinimumSize.width;
  var height = desiredMinimumSize.height;
  for (final bounds in visibleBounds) {
    final fitted = fitWindowSizeToVisibleBounds(
      preferredSize: desiredMinimumSize,
      minimumSize: desiredMinimumSize,
      visibleBounds: bounds,
      padding: padding,
    );
    width = math.min(width, fitted.width);
    height = math.min(height, fitted.height);
  }
  return Size(width, height);
}

/// Whether [windowBounds] reaches outside [workArea] by more than
/// [tolerance] on any edge.
bool windowOverflowsWorkArea({
  required Rect windowBounds,
  required Rect workArea,
  double tolerance = desktopWindowFrameTolerance,
}) {
  return windowBounds.left < workArea.left - tolerance ||
      windowBounds.top < workArea.top - tolerance ||
      windowBounds.right > workArea.right + tolerance ||
      windowBounds.bottom > workArea.bottom + tolerance;
}

Size fitWindowSizeToVisibleBounds({
  required Size preferredSize,
  required Size minimumSize,
  required Rect visibleBounds,
  EdgeInsets padding = desktopWindowSafePadding,
}) {
  final maxWidth = math.max(visibleBounds.width - padding.horizontal, 1.0);
  final maxHeight = math.max(visibleBounds.height - padding.vertical, 1.0);

  return Size(
    _fitDimension(
      preferred: preferredSize.width,
      minimum: minimumSize.width,
      maximum: maxWidth,
    ),
    _fitDimension(
      preferred: preferredSize.height,
      minimum: minimumSize.height,
      maximum: maxHeight,
    ),
  );
}

Rect fitWindowRectToVisibleBounds({
  required Rect preferredRect,
  required Size minimumSize,
  required Rect visibleBounds,
  EdgeInsets padding = desktopWindowSafePadding,
}) {
  final size = fitWindowSizeToVisibleBounds(
    preferredSize: preferredRect.size,
    minimumSize: minimumSize,
    visibleBounds: visibleBounds,
    padding: padding,
  );
  final safeBounds = _safeBounds(visibleBounds, padding);

  final minLeft = safeBounds.left;
  final maxLeft = safeBounds.right - size.width;
  final minTop = safeBounds.top;
  final maxTop = safeBounds.bottom - size.height;

  final left = _clampToRange(
    preferredRect.left,
    minLeft,
    math.max(minLeft, maxLeft),
  );
  final top = _clampToRange(
    preferredRect.top,
    minTop,
    math.max(minTop, maxTop),
  );

  return leftTopSizeToRect(left, top, size);
}

Rect leftTopSizeToRect(double left, double top, Size size) {
  return Rect.fromLTWH(left, top, size.width, size.height);
}

Size effectiveMinimumWindowSize({
  required Size desiredMinimumSize,
  required Size fittedSize,
}) {
  return Size(
    math.min(desiredMinimumSize.width, fittedSize.width),
    math.min(desiredMinimumSize.height, fittedSize.height),
  );
}

double _fitDimension({
  required double preferred,
  required double minimum,
  required double maximum,
}) {
  if (maximum >= minimum) {
    return preferred.clamp(minimum, maximum).toDouble();
  }
  return maximum;
}

Rect _safeBounds(Rect visibleBounds, EdgeInsets padding) {
  final horizontalPadding = math.min(
    padding.horizontal,
    math.max(visibleBounds.width - 1.0, 0.0),
  );
  final verticalPadding = math.min(
    padding.vertical,
    math.max(visibleBounds.height - 1.0, 0.0),
  );

  return Rect.fromLTRB(
    visibleBounds.left + horizontalPadding / 2,
    visibleBounds.top + verticalPadding / 2,
    visibleBounds.right - horizontalPadding / 2,
    visibleBounds.bottom - verticalPadding / 2,
  );
}

double _clampToRange(double value, double minimum, double maximum) {
  return value.clamp(minimum, maximum).toDouble();
}

Rect _scaleRect(Rect rect, double scale) {
  return Rect.fromLTWH(
    rect.left * scale,
    rect.top * scale,
    rect.width * scale,
    rect.height * scale,
  );
}
