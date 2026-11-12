import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/widgets/broadcast_video_toolbar.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

BroadcastVideoStream stream({
  required String id,
  required String label,
  String? countryCode,
}) {
  return BroadcastVideoStream(
    id: id,
    label: label,
    countryCode: countryCode,
    provider: BroadcastVideoProvider.youtube,
    sourceId: id,
    url: 'https://example.com/$id',
  );
}

void main() {
  testWidgets('tapping the selected flag again toggles the video', (
    tester,
  ) async {
    var toggles = 0;
    final selections = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  stream(
                    id: 'en1',
                    label: 'Board · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'es1',
                    label: 'Canal · Spanish',
                    countryCode: 'ES',
                  ),
                ],
                selectedId: 'en1',
                visible: true,
                pins: const <String>[],
                onSelect: (picked) => selections.add(picked.id),
                onToggle: () => toggles++,
                onPin: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final flags = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'desktop-broadcast-video-language-',
          ),
    );
    expect(flags, findsNWidgets(2));

    await tester.tap(flags.at(0));
    await tester.pump();
    expect(toggles, 1, reason: 'the highlighted flag closes its video');
    expect(selections, isEmpty);

    await tester.tap(flags.at(1));
    await tester.pump();
    expect(toggles, 1);
    expect(selections, <String>['es1'], reason: 'other flags still switch');
    // Let the hover tooltip's delay timer run out before teardown.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('opening and closing a stream menu is reported to the panel', (
    tester,
  ) async {
    final menuStates = <bool>[];
    final selections = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  stream(
                    id: 'en1',
                    label: 'Board · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'en2',
                    label: 'Studio · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'es1',
                    label: 'Canal · Spanish',
                    countryCode: 'ES',
                  ),
                ],
                selectedId: 'en1',
                visible: true,
                pins: const <String>[],
                onSelect: (picked) => selections.add(picked.id),
                onToggle: () {},
                onPin: (_) {},
                onMenuVisibilityChanged: menuStates.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The badge opens the English menu. The report must arrive before the
    // entrance animation ends: the web player stops taking clicks at once.
    await tester.tap(find.text('2'));
    await tester.pump();
    expect(menuStates, <bool>[true]);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Studio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(selections, <String>['en2']);
    expect(menuStates.last, isFalse);

    // Let the hover tooltip's delay timer run out before teardown.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('language marks are circular cover-cropped flags', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  stream(
                    id: 'en1',
                    label: 'Board · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'en2',
                    label: 'Studio · English',
                    countryCode: 'US',
                  ),
                  stream(
                    id: 'es1',
                    label: 'Canal · Spanish',
                    countryCode: 'ES',
                  ),
                ],
                selectedId: 'en1',
                visible: true,
                pins: const <String>[],
                onSelect: (_) {},
                onToggle: () {},
                onPin: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CountryFlag), findsNWidgets(3));
    expect(find.byType(ClipOval), findsNWidgets(3));
    final flags = tester.widgetList<CountryFlag>(find.byType(CountryFlag));
    for (final flag in flags) {
      final theme = flag.theme as ImageTheme;
      expect(theme.shape, isA<Rectangle>());
      expect(theme.width, 33);
      expect(theme.height, 22);
    }
  });

  testWidgets('grouped languages keep an overlapping count badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  stream(
                    id: 'en1',
                    label: 'Board · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'en2',
                    label: 'Studio · English',
                    countryCode: 'US',
                  ),
                  stream(
                    id: 'es1',
                    label: 'Canal · Spanish',
                    countryCode: 'ES',
                  ),
                ],
                selectedId: 'en1',
                visible: true,
                pins: const <String>[],
                onSelect: (_) {},
                onToggle: () {},
                onPin: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('video camera leads the rail and the pin menu is gone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  for (final entry in <(String, String, String)>[
                    ('en', 'Board · English', 'GB'),
                    ('za', 'Johannesburg · English', 'ZA'),
                    ('tr', 'Ankara · Turkish', 'TR'),
                    ('ph', 'Manila · English', 'PH'),
                    ('id', 'Jakarta · English', 'ID'),
                    ('ru', 'Moscow · Russian', 'RU'),
                    ('es', 'Madrid · Spanish', 'ES'),
                    ('in', 'Delhi · Hindi', 'IN'),
                    ('pl', 'Warsaw · Polish', 'PL'),
                    ('br', 'Rio · Portuguese', 'BR'),
                    ('fr', 'Paris · French', 'FR'),
                  ])
                    stream(
                      id: entry.$1,
                      label: entry.$2,
                      countryCode: entry.$3,
                    ),
                ],
                selectedId: 'en',
                visible: true,
                pins: const <String>[],
                onSelect: (_) {},
                onToggle: () {},
                onPin: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final scroll = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.clipBehavior, isNot(Clip.none));

    final toggle = tester.getRect(
      find.byKey(const ValueKey<String>('desktop-broadcast-video-toggle')),
    );
    final rail = tester.getRect(
      find.byKey(const ValueKey<String>('desktop-broadcast-video-languages')),
    );
    // Web #890: the camera is a 38px lead-in slot, not a trailing action, so
    // no scrollbar gutter or divider can push it off the flags' centre line.
    expect(toggle.right, lessThanOrEqualTo(rail.left));
    expect(toggle.width, BroadcastVideoToolbar.slot);
    expect(
      find.byKey(const ValueKey<String>('desktop-broadcast-video-actions')),
      findsNothing,
    );
    expect(find.text('⋯'), findsNothing);
  });

  testWidgets('the selected flag keeps a single unboxed cyan ring', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 260,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  stream(
                    id: 'en1',
                    label: 'Board · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'es1',
                    label: 'Canal · Spanish',
                    countryCode: 'ES',
                  ),
                ],
                selectedId: 'en1',
                visible: true,
                pins: const <String>[],
                onSelect: (_) {},
                onToggle: () {},
                onPin: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final decorations = tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byKey(
              const ValueKey<String>(
                'desktop-broadcast-video-language-stream:en1',
              ),
            ),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .toList();
    final primaryRings =
        decorations
            .where(
              (decoration) =>
                  decoration.border != null &&
                  (decoration.border! as Border).top.color == kPrimaryColor,
            )
            .toList();
    expect(primaryRings, hasLength(1), reason: 'no second inset ring');
    final ring = primaryRings.single;
    expect(ring.shape, BoxShape.circle);
    expect(ring.color, isNull, reason: 'the ring is not filled');
    expect((ring.border! as Border).top.width, 1);
    expect(
      decorations.every((decoration) => decoration.color == null),
      isTrue,
      reason: 'the selected circle keeps no primary tint fill',
    );
  });

  testWidgets('grouped counts are plain numerals, not pills', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 180,
              child: BroadcastVideoToolbar(
                streams: <BroadcastVideoStream>[
                  stream(
                    id: 'en1',
                    label: 'Board · English',
                    countryCode: 'GB',
                  ),
                  stream(
                    id: 'en2',
                    label: 'Studio · English',
                    countryCode: 'US',
                  ),
                  stream(
                    id: 'es1',
                    label: 'Canal · Spanish',
                    countryCode: 'ES',
                  ),
                ],
                selectedId: 'en1',
                visible: true,
                pins: const <String>[],
                onSelect: (_) {},
                onToggle: () {},
                onPin: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final badge = tester.widget<Container>(
      find.ancestor(of: find.text('2'), matching: find.byType(Container)).first,
    );
    expect(badge.decoration, isNull, reason: 'no pill fill or edge');
    expect(badge.foregroundDecoration, isNull);
    final numeral = tester.widget<Text>(find.text('2'));
    expect(numeral.style?.color, kPrimaryColor);
    expect(numeral.style?.fontWeight, FontWeight.w800);
  });
}
