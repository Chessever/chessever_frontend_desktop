import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';

const EdgeInsets desktopWindowSafePadding = EdgeInsets.all(24);

Rect visibleBoundsForDisplay(Display display) {
  final position = display.visiblePosition ?? Offset.zero;
  final size = display.visibleSize ?? display.size;
  return position & size;
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

Rect pickVisibleBoundsForRect({
  required Rect preferredRect,
  required Rect primaryBounds,
  required Iterable<Rect> allBounds,
}) {
  final center = preferredRect.center;
  for (final bounds in allBounds) {
    if (bounds.contains(center)) {
      return bounds;
    }
  }

  Rect? bestBounds;
  var bestDistance = double.infinity;
  for (final bounds in allBounds) {
    final distance = (bounds.center - center).distanceSquared;
    if (distance < bestDistance) {
      bestBounds = bounds;
      bestDistance = distance;
    }
  }

  return bestBounds ?? primaryBounds;
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
