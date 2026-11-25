import 'dart:collection';

import 'package:flutter/widgets.dart';

/// The size [text] takes on one line in [style], laid out as a [Text] in
/// [context] would lay it out: over the inherited text style, at the
/// reader's text scale, in bold when the platform asks for bold text.
///
/// Remembered per text, effective style, scale and direction, because the
/// widgets that ask (the engine header, Toby's rows) ask on every rebuild
/// and the paragraph layout is the expensive part, in the browser above
/// all. Forgotten whenever the system's fonts change, so a font that loads
/// late is measured again.
Size desktopTextLineSize(BuildContext context, String text, TextStyle style) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  return _TextLineCache.instance.sizeOf(text, effective, scaler, direction);
}

/// The width of [desktopTextLineSize].
double desktopTextLineWidth(
  BuildContext context,
  String text,
  TextStyle style,
) => desktopTextLineSize(context, text, style).width;

typedef _Key = (String, TextStyle, TextScaler, TextDirection);

class _TextLineCache {
  _TextLineCache._() {
    PaintingBinding.instance.systemFonts.addListener(_sizes.clear);
  }

  static final _TextLineCache instance = _TextLineCache._();

  /// Enough for every label and figure a few panes show at once; the oldest
  /// entry goes first.
  static const int _capacity = 512;

  final LinkedHashMap<_Key, Size> _sizes = LinkedHashMap<_Key, Size>();

  Size sizeOf(
    String text,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    final key = (text, style, scaler, direction);
    final cached = _sizes.remove(key);
    if (cached != null) {
      _sizes[key] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    if (_sizes.length >= _capacity) _sizes.remove(_sizes.keys.first);
    _sizes[key] = size;
    return size;
  }
}
