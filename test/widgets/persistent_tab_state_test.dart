import 'package:chessever/widgets/persistent_tab_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PersistentIndexedStack keeps inactive tab state mounted', (
    tester,
  ) async {
    await tester.pumpWidget(const _PersistentStackHarness(index: 0));

    await tester.enterText(find.byKey(const ValueKey('first-field')), 'kept');
    expect(find.text('kept'), findsOneWidget);

    await tester.pumpWidget(const _PersistentStackHarness(index: 1));
    expect(find.text('second'), findsOneWidget);

    await tester.pumpWidget(const _PersistentStackHarness(index: 0));
    expect(find.text('kept'), findsOneWidget);
  });

  testWidgets(
    'PersistentIndexedStack keeps state when keyed children are reordered',
    (tester) async {
      _KeepProbeState.mounts.clear();
      await tester.pumpWidget(
        const _ReorderStackHarness(order: <String>['first', 'second']),
      );
      expect(_KeepProbeState.mounts['first'], 1);
      expect(_KeepProbeState.mounts['second'], 1);

      await tester.pumpWidget(
        const _ReorderStackHarness(order: <String>['second', 'first']),
      );
      expect(find.text('second:1'), findsOneWidget);
      expect(_KeepProbeState.mounts['first'], 1);
      expect(_KeepProbeState.mounts['second'], 1);
    },
  );

  testWidgets('PersistentTabPage keeps PageView tab field state mounted', (
    tester,
  ) async {
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: controller,
            children: const [
              PersistentTabPage(
                key: PageStorageKey<String>('page-one'),
                child: TextField(key: ValueKey('page-one-field')),
              ),
              PersistentTabPage(
                key: PageStorageKey<String>('page-two'),
                child: Text('page two'),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('page-one-field')), 'abc');
    expect(find.text('abc'), findsOneWidget);

    controller.jumpToPage(1);
    await tester.pumpAndSettle();
    expect(find.text('page two'), findsOneWidget);

    controller.jumpToPage(0);
    await tester.pumpAndSettle();
    expect(find.text('abc'), findsOneWidget);
  });
}

class _PersistentStackHarness extends StatelessWidget {
  const _PersistentStackHarness({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: PersistentIndexedStack(
          index: index,
          children: const [
            TextField(key: ValueKey('first-field')),
            Text('second'),
          ],
        ),
      ),
    );
  }
}

class _ReorderStackHarness extends StatelessWidget {
  const _ReorderStackHarness({required this.order});

  final List<String> order;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: PersistentIndexedStack(
          index: 0,
          children: [
            for (final label in order)
              KeyedSubtree(
                key: ValueKey<String>(label),
                child: _KeepProbe(label: label),
              ),
          ],
        ),
      ),
    );
  }
}

class _KeepProbe extends StatefulWidget {
  const _KeepProbe({required this.label});

  final String label;

  @override
  State<_KeepProbe> createState() => _KeepProbeState();
}

class _KeepProbeState extends State<_KeepProbe> {
  static final Map<String, int> mounts = <String, int>{};

  @override
  void initState() {
    super.initState();
    mounts[widget.label] = (mounts[widget.label] ?? 0) + 1;
  }

  @override
  Widget build(BuildContext context) {
    return Text('${widget.label}:${mounts[widget.label]}');
  }
}
