import 'package:chessever/desktop/services/broadcast_video_streams.dart';
import 'package:chessever/desktop/widgets/broadcast_video_toolbar.dart';
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
              width: 220,
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
}
