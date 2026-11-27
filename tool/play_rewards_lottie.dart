// Writes the Play reward animations in assets/play/lottie/ as Lottie JSON.
//
//   dart run tool/play_rewards_lottie.dart
//
// The animations are drawn in white and tinted in the app (the tier's metal,
// the level colour), so one file serves every tier. Every frame stays inside
// the 2D subset FastLottie compiles (see its doc/supported-ops.md): shape
// layers, groups, ellipses, paths, stars, strokes, fills, trim paths and
// group transforms. Edit the shapes here and run it again; do not edit the
// JSON by hand.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const _fps = 60;

void main() {
  final out = Directory('assets/play/lottie')..createSync(recursive: true);
  final files = {
    'badge_strike.json': _badgeStrike(),
    'badge_glint.json': _badgeGlint(),
    'level_up.json': _levelUp(),
  };
  for (final entry in files.entries) {
    File(
      '${out.path}/${entry.key}',
    ).writeAsStringSync('${jsonEncode(entry.value)}\n');
    stdout.writeln('wrote ${out.path}/${entry.key}');
  }
}

// ---------------------------------------------------------------------------
// Animations
// ---------------------------------------------------------------------------

/// A badge tier struck: a ring is engraved around the badge, opens out and
/// lets go; twelve shards spring off it, and three four-point stars wink
/// in turn. The canvas is twice the badge: the badge fills the middle half.
Map<String, Object?> _badgeStrike() {
  const op = 70;
  final layers = <Map<String, Object?>>[];

  // Stars first: earlier layers paint on top.
  const stars = [
    (x: 152.0, y: 58.0, r: 11.0, at: 26),
    (x: 46.0, y: 82.0, r: 8.0, at: 34),
    (x: 138.0, y: 150.0, r: 7.0, at: 42),
  ];
  for (final (i, s) in stars.indexed) {
    layers.add(
      _layer(
        'star ${i + 1}',
        op: op,
        shapes: [
          _group(
            [_star(points: 4, outer: s.r, inner: s.r * 0.24), _fill()],
            position: _still([s.x, s.y]),
            scale: _keys([
              (s.at, [0.0, 0.0], _easeOut),
              (s.at + 10, [112.0, 112.0], _easeInOut),
              (s.at + 24, [0.0, 0.0], null),
            ]),
            rotation: _keys([(s.at, 0.0, _linear), (s.at + 24, 50.0, null)]),
          ),
        ],
      ),
    );
  }

  // Shards: short strokes along twelve spokes, alternating long and short,
  // each travelling out from the ring and shrinking to its tip.
  final shards = <Map<String, Object?>>[];
  for (var i = 0; i < 12; i++) {
    final long = i.isEven;
    final angle = i * 30.0 + (long ? 0 : 15);
    final length = long ? 13.0 : 8.0;
    final start = long ? 18 : 21;
    final a = (angle - 90) * math.pi / 180;
    final from = 58.0;
    final to = long ? 92.0 : 84.0;
    shards.add(
      _group(
        [
          _line([0, 0], [0, -length]),
          _stroke(width: long ? 3.2 : 2.4),
        ],
        position: _keys([
          (
            start,
            [100 + math.cos(a) * from, 100 + math.sin(a) * from],
            _easeOut,
          ),
          (start + 26, [100 + math.cos(a) * to, 100 + math.sin(a) * to], null),
        ]),
        rotation: _still(angle),
        scale: _keys([
          (start, [0.0, 0.0], _easeOut),
          (start + 6, [100.0, 100.0], _easeIn),
          (start + 26, [0.0, 0.0], null),
        ]),
      ),
    );
  }
  layers.add(_layer('shards', op: op, shapes: shards));

  // The engraved ring: drawn clockwise from the top, then it opens out and
  // fades. A finer second ring draws the other way, a beat behind.
  layers.add(
    _layer(
      'ring',
      op: op,
      shapes: [
        _group(
          [
            _ellipse(116),
            _stroke(width: 3),
            _trim(end: _keys([(0, 0.0, _easeOut), (20, 100.0, null)])),
          ],
          position: _still([100.0, 100.0]),
          rotation: _still(-90.0),
          scale: _keys([
            (18, [100.0, 100.0], _easeOut),
            (46, [124.0, 124.0], null),
          ]),
          opacity: _keys([(22, 100.0, _easeIn), (46, 0.0, null)]),
        ),
        _group(
          [
            _ellipse(100, reversed: true),
            _stroke(width: 1.4, opacity: 70),
            _trim(end: _keys([(4, 0.0, _easeOut), (24, 100.0, null)])),
          ],
          position: _still([100.0, 100.0]),
          rotation: _still(-90.0),
          scale: _keys([
            (22, [100.0, 100.0], _easeOut),
            (50, [116.0, 116.0], null),
          ]),
          opacity: _keys([(26, 100.0, _easeIn), (50, 0.0, null)]),
        ),
      ],
    ),
  );
  return _composition('badge strike', 200, 200, op, layers);
}

/// Hovering an earned badge: a four-point star winks on its upper rim and
/// a smaller one answers lower down. Same canvas as the strike.
Map<String, Object?> _badgeGlint() {
  const op = 44;
  final layers = <Map<String, Object?>>[];
  const stars = [
    (x: 134.0, y: 64.0, r: 12.0, at: 0, turn: 45.0),
    (x: 146.0, y: 92.0, r: 6.0, at: 9, turn: -40.0),
  ];
  for (final (i, s) in stars.indexed) {
    layers.add(
      _layer(
        'glint ${i + 1}',
        op: op,
        shapes: [
          _group(
            [_star(points: 4, outer: s.r, inner: s.r * 0.22), _fill()],
            position: _still([s.x, s.y]),
            scale: _keys([
              (s.at, [0.0, 0.0], _easeOut),
              (s.at + 11, [110.0, 110.0], _easeInOut),
              (s.at + 30, [0.0, 0.0], null),
            ]),
            rotation: _keys([(s.at, 0.0, _linear), (s.at + 30, s.turn, null)]),
          ),
        ],
      ),
    );
  }
  return _composition('badge glint', 200, 200, op, layers);
}

/// A level reached: three chevrons climb one after another and let go at
/// the top. Square canvas, drawn small beside the level line.
Map<String, Object?> _levelUp() {
  const op = 96;
  final chevrons = <Map<String, Object?>>[];
  for (var i = 0; i < 3; i++) {
    final at = i * 14;
    chevrons.add(
      _group(
        [
          _path([
            [-20, 9],
            [0, -9],
            [20, 9],
          ]),
          _stroke(width: 7),
        ],
        position: _keys([
          (at, [50.0, 88.0], _linear),
          (at + 36, [50.0, 22.0], null),
        ]),
        opacity: _keys([
          (at, 0.0, _easeOut),
          (at + 8, 100.0, _linear),
          (at + 20, 100.0, _easeIn),
          (at + 36, 0.0, null),
        ]),
      ),
    );
  }
  // Last, the mark settles: one chevron rests in the middle.
  chevrons.add(
    _group(
      [
        _path([
          [-20, 9],
          [0, -9],
          [20, 9],
        ]),
        _stroke(width: 7),
      ],
      position: _keys([
        (60, [50.0, 66.0], _easeOut),
        (80, [50.0, 52.0], null),
      ]),
      opacity: _keys([(60, 0.0, _easeOut), (72, 100.0, null)]),
    ),
  );
  return _composition('level up', 100, 100, op, [
    _layer('chevrons', op: op, shapes: chevrons),
  ]);
}

// ---------------------------------------------------------------------------
// Lottie building blocks
// ---------------------------------------------------------------------------

typedef _Ease = ({List<double> o, List<double> i});

const _Ease _linear = (o: [0, 0], i: [1, 1]);
const _Ease _easeOut = (o: [0.16, 0.6], i: [0.3, 1]);
const _Ease _easeIn = (o: [0.6, 0], i: [0.84, 0.4]);
const _Ease _easeInOut = (o: [0.45, 0], i: [0.55, 1]);

Map<String, Object?> _composition(
  String name,
  int w,
  int h,
  int op,
  List<Map<String, Object?>> layers,
) {
  final indexed = [
    for (final (i, layer) in layers.indexed) {...layer, 'ind': i + 1},
  ];
  return {
    'v': '5.7.4',
    'fr': _fps,
    'ip': 0,
    'op': op,
    'w': w,
    'h': h,
    'nm': name,
    'ddd': 0,
    'assets': <Object?>[],
    'layers': indexed,
  };
}

Map<String, Object?> _layer(
  String name, {
  required int op,
  required List<Map<String, Object?>> shapes,
}) => {
  'ddd': 0,
  'ty': 4,
  'nm': name,
  'sr': 1,
  'ks': _transform(),
  'ao': 0,
  'shapes': shapes,
  'ip': 0,
  'op': op,
  'st': 0,
  'bm': 0,
};

Map<String, Object?> _transform({
  Map<String, Object?>? position,
  Map<String, Object?>? scale,
  Map<String, Object?>? rotation,
  Map<String, Object?>? opacity,
}) => {
  'o': opacity ?? _still(100.0),
  'r': rotation ?? _still(0.0),
  'p': position ?? _still([0.0, 0.0]),
  'a': _still([0.0, 0.0]),
  's': scale ?? _still([100.0, 100.0]),
};

Map<String, Object?> _group(
  List<Map<String, Object?>> items, {
  Map<String, Object?>? position,
  Map<String, Object?>? scale,
  Map<String, Object?>? rotation,
  Map<String, Object?>? opacity,
}) => {
  'ty': 'gr',
  'it': [
    ...items,
    {
      'ty': 'tr',
      ..._transform(
        position: position,
        scale: scale,
        rotation: rotation,
        opacity: opacity,
      ),
      'sk': _still(0.0),
      'sa': _still(0.0),
    },
  ],
};

Map<String, Object?> _ellipse(double diameter, {bool reversed = false}) => {
  'ty': 'el',
  'd': reversed ? 3 : 1,
  'p': _still([0.0, 0.0]),
  's': _still([diameter, diameter]),
};

Map<String, Object?> _star({
  required int points,
  required double outer,
  required double inner,
}) => {
  'ty': 'sr',
  'sy': 1,
  'd': 1,
  'pt': _still(points.toDouble()),
  'p': _still([0.0, 0.0]),
  'r': _still(0.0),
  'ir': _still(inner),
  'is': _still(0.0),
  'or': _still(outer),
  'os': _still(0.0),
};

Map<String, Object?> _line(List<double> from, List<double> to) =>
    _path([from, to]);

/// An open polyline with straight segments.
Map<String, Object?> _path(List<List<double>> points) => {
  'ty': 'sh',
  'd': 1,
  'ks': _still({
    'c': false,
    'v': points,
    'i': [
      for (final _ in points) [0.0, 0.0],
    ],
    'o': [
      for (final _ in points) [0.0, 0.0],
    ],
  }),
};

Map<String, Object?> _stroke({required double width, double opacity = 100}) => {
  'ty': 'st',
  'c': _still([1.0, 1.0, 1.0, 1.0]),
  'o': _still(opacity),
  'w': _still(width),
  'lc': 2,
  'lj': 2,
  'ml': 4,
};

Map<String, Object?> _fill() => {
  'ty': 'fl',
  'c': _still([1.0, 1.0, 1.0, 1.0]),
  'o': _still(100.0),
  'r': 1,
};

Map<String, Object?> _trim({required Map<String, Object?> end}) => {
  'ty': 'tm',
  's': _still(0.0),
  'e': end,
  'o': _still(0.0),
  'm': 1,
};

Map<String, Object?> _still(Object value) => {'a': 0, 'k': value};

/// Keyframes as (frame, value, ease to the next key). The last key carries
/// no ease. Scalars and vectors both work: a scalar is written as `[v]`.
Map<String, Object?> _keys(List<(int, Object, _Ease?)> keys) {
  List<double> asList(Object v) =>
      v is List
          ? [for (final x in v) (x as num).toDouble()]
          : [(v as num).toDouble()];
  return {
    'a': 1,
    'k': [
      for (final (frame, value, ease) in keys)
        {
          't': frame,
          's': asList(value),
          if (ease != null) ...{
            'o': {
              'x': [ease.o[0]],
              'y': [ease.o[1]],
            },
            'i': {
              'x': [ease.i[0]],
              'y': [ease.i[1]],
            },
          },
        },
    ],
  };
}
