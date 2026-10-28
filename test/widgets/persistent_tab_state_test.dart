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

  testWidgets(
    'PersistentIndexedStack does not re-lay-out or rebuild hidden tabs on resize',
    (tester) async {
      _SizeProbe.reset();
      await tester.pumpWidget(const _ResizeStackHarness(index: 0, width: 500));
      expect(_SizeProbe.layoutWidths['hidden'], [500]);
      expect(_SizeProbe.mediaWidths['hidden'], [500]);

      // A window resize: the visible tab follows, the hidden one stays put.
      await tester.pumpWidget(const _ResizeStackHarness(index: 0, width: 600));
      await tester.pumpWidget(const _ResizeStackHarness(index: 0, width: 700));
      expect(_SizeProbe.layoutWidths['visible'], [500, 600, 700]);
      expect(_SizeProbe.mediaWidths['visible'], [500, 600, 700]);
      expect(_SizeProbe.layoutWidths['hidden'], [500]);
      expect(_SizeProbe.mediaWidths['hidden'], [500]);

      // Showing the hidden tab catches it up to the live size in one frame.
      await tester.pumpWidget(const _ResizeStackHarness(index: 1, width: 700));
      expect(_SizeProbe.layoutWidths['hidden'], [500, 700]);
      expect(_SizeProbe.mediaWidths['hidden'], [500, 700]);
      expect(
        tester.getSize(find.byKey(const ValueKey('probe-hidden'))).width,
        700,
      );
    },
  );
}

class _ResizeStackHarness extends StatelessWidget {
  const _ResizeStackHarness({required this.index, required this.width});

  final int index;
  final double width;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(size: Size(width, 600)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 600,
            child: PersistentIndexedStack(
              index: index,
              sizing: StackFit.expand,
              children: const [
                _SizeProbe(key: ValueKey('probe-visible'), label: 'visible'),
                _SizeProbe(key: ValueKey('probe-hidden'), label: 'hidden'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Records each LayoutBuilder pass and each MediaQuery-driven rebuild.
class _SizeProbe extends StatelessWidget {
  const _SizeProbe({super.key, required this.label});

  final String label;

  static final Map<String, List<double>> layoutWidths = {};
  static final Map<String, List<double>> mediaWidths = {};

  static void reset() {
    layoutWidths.clear();
    mediaWidths.clear();
  }

  @override
  Widget build(BuildContext context) {
    (mediaWidths[label] ??= []).add(MediaQuery.sizeOf(context).width);
    return LayoutBuilder(
      builder: (context, constraints) {
        (layoutWidths[label] ??= []).add(constraints.maxWidth);
        return const SizedBox.expand();
      },
    );
  }
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
