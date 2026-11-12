import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

/// Interpolates discrete wheel steps at the display's refresh rate. Touch and
/// native trackpad drags keep Flutter's gesture physics; fine pixel deltas and
/// browser trackpad scrolls keep their direct response instead of acquiring a
/// second layer of momentum.
class DesktopScrollController extends ScrollController {
  DesktopScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
    super.onAttach,
    super.onDetach,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _DesktopScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

/// Hook-owned equivalent of [DesktopScrollController].
ScrollController useDesktopScrollController({
  double initialScrollOffset = 0,
  bool keepScrollOffset = true,
  String? debugLabel,
}) {
  final controller = useMemoized(
    () => DesktopScrollController(
      initialScrollOffset: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      debugLabel: debugLabel,
    ),
  );
  useEffect(() => controller.dispose, [controller]);
  return controller;
}

class _DesktopScrollPosition extends ScrollPositionWithSingleContext {
  _DesktopScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  }) {
    _ScrollInputKind.ensureRecording();
  }

  @override
  void pointerScroll(double delta) {
    if (_ScrollInputKind.lastWasTrackpad) {
      // The direct path below drops any wheel step still easing. The web
      // engine can tag the first wheel event of a trackpad swipe as a mouse
      // wheel, so a step may be in flight when the swipe's trackpad deltas
      // begin; carry its unplayed distance when it runs the same way.
      final current = activity;
      if (current is _WheelScrollActivity) {
        final remaining = current.target - pixels;
        if (remaining * delta > 0) delta += remaining;
      }
      super.pointerScroll(delta);
      return;
    }
    if (delta.abs() < 24 ||
        MediaQuery.maybeDisableAnimationsOf(context.storageContext) == true) {
      super.pointerScroll(delta);
      return;
    }
    final current = activity;
    final pending = current is _WheelScrollActivity ? current.target : pixels;
    // Reversal responds immediately, without first finishing the old direction.
    final base = (pending - pixels) * delta < 0 ? pixels : pending;
    final target = (base + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == pixels) {
      goIdle();
      return;
    }
    updateUserScrollDirection(
      delta > 0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );
    beginActivity(_WheelScrollActivity(this, target: target));
  }
}

/// The device kind of the scroll event being delivered.
///
/// [ScrollPosition.pointerScroll] receives only a delta. In the browser a
/// trackpad does not produce pan/zoom gestures: Chromium and Safari send its
/// swipes, momentum included, as wheel events that Flutter's web engine tags
/// [PointerDeviceKind.trackpad], often with deltas well over a wheel step's
/// threshold. Easing each of those over 120 ms restarted an animation on every
/// event of a fling, so the page trailed the fingers and stuttered. The
/// browser has already smoothed these deltas, so they apply directly.
///
/// A global pointer route sees each event before Flutter resolves the pointer
/// signal that calls [ScrollPosition.pointerScroll], so the recorded kind
/// always belongs to the delta being applied.
abstract final class _ScrollInputKind {
  static bool _recording = false;
  static bool lastWasTrackpad = false;

  static void ensureRecording() {
    if (_recording) return;
    _recording = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_record);
  }

  static void _record(PointerEvent event) {
    if (event is PointerScrollEvent) {
      lastWasTrackpad = event.kind == PointerDeviceKind.trackpad;
    }
  }
}

class _WheelScrollActivity extends DrivenScrollActivity {
  _WheelScrollActivity(
    _DesktopScrollPosition super.position, {
    required this.target,
  }) : super(
         from: position.pixels,
         to: target,
         duration: const Duration(milliseconds: 120),
         curve: Curves.easeOutCubic,
         vsync: position.context.vsync,
       );

  final double target;

  // Wheel events, links and scrollbar drags remain available while settling.
  @override
  bool get shouldIgnorePointer => false;

  @override
  bool applyMoveTo(double value) {
    final position = delegate as ScrollPosition;
    final bounded = value.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    return super.applyMoveTo(bounded) && bounded == value;
  }
}

/// Gives an otherwise controller-free scroll view its own wheel-aware primary
/// controller. Each nested view gets an independent controller, so wheel input
/// still belongs to Flutter's innermost scrollable and chains at its edges.
/// Explicit controllers and explicit primary-controller policies are preserved.
class DesktopScrollHost extends StatefulWidget {
  const DesktopScrollHost({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopScrollHost> createState() => _DesktopScrollHostState();
}

class _DesktopScrollHostState extends State<DesktopScrollHost> {
  final _controller = DesktopScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.child;
    final Axis axis;
    if (view is ScrollView) {
      if (view.controller != null || view.primary != null) return view;
      axis = view.scrollDirection;
    } else if (view is SingleChildScrollView) {
      if (view.controller != null || view.primary != null) return view;
      axis = view.scrollDirection;
    } else {
      return view;
    }
    return PrimaryScrollController(
      controller: _controller,
      scrollDirection: axis,
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: view,
    );
  }
}
