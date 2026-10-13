import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:chessever/desktop/services/editorial/discovery_dots_provider.dart';
import 'package:chessever/desktop/widgets/editorial/nudge_anchor.dart';

class Source implements DiscoveryDotsSource {
  Source(this.raw);
  String raw;
  final controller = StreamController<String>.broadcast();
  @override
  Future<String> initialize() async => raw;
  @override
  Future<String> fetch() async => raw;
  @override
  Stream<String> get updates => controller.stream;
  void update(List<Map<String, Object>> dots) {
    raw = jsonEncode({'dots': dots});
    controller.add(raw);
  }
}

class Seen extends DiscoveryDotsSeenStore {
  final Map<String, int> seen = {};
  @override
  Map<String, int> read() => seen;
  @override
  Future<void> write(Map<String, int> value) async {
    seen.addAll(value);
  }
}

const a = {
  'id': 'a',
  'rev': 1,
  'target': 'desktop.nav.library',
  'trail': ['desktop.nav.inbox'],
  'label': 'NEW',
  'messages': [
    {'body': 'First tip', 'action_url': ''},
    {'body': 'Second tip', 'action_url': ''},
  ],
};
const b = {
  'id': 'b',
  'rev': 1,
  'target': 'desktop.nav.library',
  'trail': ['desktop.nav.inbox'],
  'message': 'Another tip',
};
Widget subject(Source source, Seen seen) {
  final surface = DesktopNudgeAnchor(
    ids: const ['desktop.nav.library'],
    child: const SizedBox(
      width: 240,
      height: 50,
      child: Center(child: Text('Library')),
    ),
  );
  final app = MaterialApp(home: Scaffold(body: Center(child: surface)));
  return ProviderScope(
    overrides: [
      discoveryDotsSourceProvider.overrideWithValue(source),
      discoveryDotsSeenStoreProvider.overrideWithValue(seen),
    ],
    child: FTheme(data: FThemes.zinc.dark, child: app),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'individual removal clears only its campaign, then the last marker without moving the UI',
    (tester) async {
      final source = Source(
        jsonEncode({
          'dots': [a, b],
        }),
      );
      await tester.pumpWidget(subject(source, Seen()));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('Library'));
      expect(find.text('NEW'), findsOneWidget);
      source.update([b]);
      await tester.pumpAndSettle();
      expect(find.text('NEW'), findsNothing);
      expect(find.bySemanticsLabel('New feature'), findsOneWidget);
      expect(tester.getRect(find.text('Library')), rect);
      source.update([]);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('New feature'), findsNothing);
      expect(tester.getRect(find.text('Library')), rect);
      await tester.pumpWidget(const SizedBox.shrink());
      await source.controller.close();
    },
  );
  testWidgets('stack pages work and a removal dismisses the open tooltip', (
    tester,
  ) async {
    final source = Source(
      jsonEncode({
        'dots': [a],
      }),
    );
    await tester.pumpWidget(subject(source, Seen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NEW'));
    await tester.pumpAndSettle();
    expect(find.text('First tip'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Second tip'), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    source.update([]);
    await tester.pumpAndSettle();
    expect(find.text('Second tip'), findsNothing);
    expect(find.text('NEW'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await source.controller.close();
  });
}
