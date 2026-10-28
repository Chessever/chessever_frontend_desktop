import 'package:flutter/widgets.dart';

/// A [LayoutBuilder] that rebuilds its subtree only when a coarse layout
/// decision changes, such as a column count or a wide/narrow breakpoint.
///
/// A plain LayoutBuilder re-runs its builder on every constraint change, so a
/// window resize or sidebar animation rebuilds everything it returns on every
/// frame. Here [bucket] maps the constraints to a small value. While that value
/// stays the same, the previously built subtree is returned as the identical
/// widget instance, so Flutter only re-lays it out.
///
/// [builder] must depend on the bucket alone, never on the exact constraints.
/// It runs inside its own [Builder], so inherited lookups through its context
/// (Theme, MediaQuery, providers) still rebuild it when they change.
class BucketedLayoutBuilder<K> extends StatefulWidget {
  const BucketedLayoutBuilder({
    super.key,
    required this.bucket,
    required this.builder,
  });

  final K Function(BoxConstraints constraints) bucket;
  final Widget Function(BuildContext context, K bucket) builder;

  @override
  State<BucketedLayoutBuilder<K>> createState() =>
      _BucketedLayoutBuilderState<K>();
}

class _BucketedLayoutBuilderState<K> extends State<BucketedLayoutBuilder<K>> {
  late K _bucket;
  Widget? _child;

  @override
  void didUpdateWidget(covariant BucketedLayoutBuilder<K> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent rebuilt, so the builder's captured inputs may have changed.
    _child = null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, constraints) {
      final next = widget.bucket(constraints);
      if (_child == null || next != _bucket) {
        _bucket = next;
        _child = Builder(
          builder: (context) => widget.builder(context, _bucket),
        );
      }
      return _child!;
    },
  );
}
