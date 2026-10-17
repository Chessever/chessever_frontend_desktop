import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/desktop_window_work_area_guard.dart';

/// Trello #1247 QA scenarios, run against a simulated Windows desktop.
///
/// The fake reproduces what the Windows plugins and the OS do, in physical
/// pixels: screen_retriever reports each monitor's work area divided by that
/// monitor's own scale, window_manager reports the window rect divided by the
/// window's scale, WM_DPICHANGED keeps the window's top-left and rescales its
/// size, and a maximized window overhangs the work area by its frame but never
/// shrinks below the minimum size.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWindowsDesktop desktop;
  late DesktopWindowWorkAreaGuard guard;

  void install(_FakeWindowsDesktop fake) {
    desktop = fake;
    guard = DesktopWindowWorkAreaGuard.forTesting(
      windowScale: () => desktop.windowScale,
      perMonitorScaling: true,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      desktop.windowManagerCall,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.leanflutter.plugins/screen_retriever'),
      desktop.screenRetrieverCall,
    );
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.leanflutter.plugins/screen_retriever'),
      null,
    );
  });

  /// Lets the guard's debounce timer fire and its platform calls finish.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 600));

  test('changing Windows scaling 100 % to 150 % refits the window', () async {
    final laptop = _Monitor('laptop', const Rect.fromLTWH(0, 0, 1920, 1032), 1);
    install(
      _FakeWindowsDesktop(
        monitors: [laptop],
        windowLogical: const Rect.fromLTWH(240, 66, 1440, 900),
        windowScale: 1,
      ),
    );
    await guard.debugCheck(environmentChanged: true);
    expect(desktop.calls, isNot(contains('setBounds')));

    // The user picks 150 %: the work area shrinks to 1280x688 logical while
    // WM_DPICHANGED keeps the window at 1440x900 logical.
    laptop.scale = 1.5;
    desktop.settleDpi();
    expect(desktop.fitsWorkArea(), isFalse);

    guard.didChangeMetrics();
    await settle();

    expect(desktop.calls, contains('setBounds'));
    expect(desktop.fitsWorkArea(), isTrue);
    expect(desktop.minimumLogical, const Size(1024, 640));
  });

  test('moving to a laptop with different scaling refits the window after '
      'the drag, never during it', () async {
    final monitor = _Monitor(
      'monitor',
      const Rect.fromLTWH(0, 0, 2560, 1400),
      1,
    );
    final laptop = _Monitor(
      'laptop',
      const Rect.fromLTWH(2560, 0, 1920, 1032),
      1.5,
    );
    install(
      _FakeWindowsDesktop(
        monitors: [monitor, laptop],
        windowLogical: const Rect.fromLTWH(200, 100, 1800, 1000),
        windowScale: 1,
      ),
    );
    await guard.debugCheck(environmentChanged: true);
    expect(desktop.fitsWorkArea(), isTrue);

    // Drag across: the window lands on the laptop mid-drag and Windows
    // gives it the laptop's DPI, making it 2700x1500 physical.
    desktop.windowPhysical = desktop.windowPhysical.translate(2560, 0);
    desktop.settleDpi();
    expect(desktop.windowScale, 1.5);
    expect(desktop.fitsWorkArea(), isFalse);
    desktop.calls.clear();
    for (var i = 0; i < 5; i++) {
      guard.onWindowMove();
      guard.didChangeMetrics();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(desktop.calls, isNot(contains('setBounds')));

    guard.onWindowMoved();
    await settle();

    expect(desktop.calls, contains('setBounds'));
    expect(desktop.monitorOfWindow(), laptop);
    expect(desktop.fitsWorkArea(), isTrue);
  });

  test('a window maximized under a big-monitor minimum re-maximizes into '
      'the laptop work area', () async {
    final laptop = _Monitor(
      'laptop',
      const Rect.fromLTWH(0, 0, 1920, 1032),
      1.5,
    );
    final fake = _FakeWindowsDesktop(
      monitors: [laptop],
      windowLogical: const Rect.fromLTWH(24, 24, 1232, 640),
      windowScale: 1.5,
    );
    // Startup on the big monitor left the old 1024x720 minimum behind;
    // maximizing on the laptop then overshoots its 688 px work area.
    fake.minimumLogical = const Size(1024, 720);
    install(fake);
    await desktop.windowManagerCall(const MethodCall('maximize'));
    expect(desktop.fitsWorkArea(), isFalse);

    await guard.debugCheck(environmentChanged: true);

    expect(desktop.minimumLogical, const Size(1024, 640));
    expect(desktop.calls, containsAllInOrder(['unmaximize', 'maximize']));
    expect(desktop.maximized, isTrue);
    expect(desktop.fitsWorkArea(), isTrue);
  });

  test('a window on the 100 % monitor is not mistaken for the 150 % laptop '
      'whose logical rect overlaps it', () async {
    // EnumDisplayMonitors order is not guaranteed; the laptop comes first.
    // Its per-monitor logical rect (x 1707-2987) overlaps the monitor's
    // (x 0-2560), and the window's centre (x 1800) lies in both.
    final laptop = _Monitor(
      'laptop',
      const Rect.fromLTWH(2560, 0, 1920, 1032),
      1.5,
    );
    final monitor = _Monitor(
      'monitor',
      const Rect.fromLTWH(0, 0, 2560, 1400),
      1,
    );
    install(
      _FakeWindowsDesktop(
        monitors: [laptop, monitor],
        windowLogical: const Rect.fromLTWH(1100, 100, 1400, 900),
        windowScale: 1,
      ),
    );

    guard.onScreenEvent('display-added');
    await settle();

    expect(desktop.calls, isNot(contains('setBounds')));
    expect(desktop.windowPhysical, const Rect.fromLTWH(1100, 100, 1400, 900));
  });

  test('a manual resize on the same display is never fought', () async {
    final laptop = _Monitor('laptop', const Rect.fromLTWH(0, 0, 1366, 728), 1);
    install(
      _FakeWindowsDesktop(
        monitors: [laptop],
        windowLogical: const Rect.fromLTWH(24, 24, 1318, 680),
        windowScale: 1,
      ),
    );
    await guard.debugCheck(environmentChanged: true);

    // The user drags the bottom edge down under the taskbar.
    desktop.windowPhysical = const Rect.fromLTWH(24, 24, 1318, 744);
    desktop.calls.clear();
    guard.onWindowResize();
    guard.onWindowResized();
    await settle();

    expect(desktop.calls, isNot(contains('setBounds')));
    expect(desktop.windowPhysical, const Rect.fromLTWH(24, 24, 1318, 744));
  });

  test(
    'restore and maximize events on the same display change nothing',
    () async {
      final laptop = _Monitor(
        'laptop',
        const Rect.fromLTWH(0, 0, 1920, 1032),
        1.25,
      );
      install(
        _FakeWindowsDesktop(
          monitors: [laptop],
          windowLogical: const Rect.fromLTWH(24, 24, 1440, 760),
          windowScale: 1.25,
        ),
      );
      await guard.debugCheck(environmentChanged: true);
      desktop.calls.clear();

      await desktop.windowManagerCall(const MethodCall('maximize'));
      guard.onWindowMaximize();
      await settle();
      await desktop.windowManagerCall(const MethodCall('unmaximize'));
      guard.onWindowUnmaximize();
      await settle();

      expect(
        desktop.calls.where(
          (call) => call == 'setBounds' || call == 'setMinimumSize',
        ),
        isEmpty,
      );
      expect(desktop.fitsWorkArea(), isTrue);
    },
  );

  test(
    'unplugging the monitor the window was on refits it to the laptop',
    () async {
      final laptop = _Monitor(
        'laptop',
        const Rect.fromLTWH(0, 0, 1920, 1032),
        1.25,
      );
      final monitor = _Monitor(
        'monitor',
        const Rect.fromLTWH(1920, 0, 2560, 1400),
        1,
      );
      install(
        _FakeWindowsDesktop(
          monitors: [laptop, monitor],
          windowLogical: const Rect.fromLTWH(2000, 40, 2200, 1300),
          windowScale: 1,
        ),
      );
      await guard.debugCheck(environmentChanged: true);
      expect(desktop.fitsWorkArea(), isTrue);

      // Windows moves the orphaned window onto the laptop and applies its DPI.
      desktop.monitors.remove(monitor);
      desktop.windowPhysical = Rect.fromLTWH(
        100,
        40,
        desktop.windowPhysical.width,
        desktop.windowPhysical.height,
      );
      desktop.settleDpi();
      expect(desktop.fitsWorkArea(), isFalse);

      guard.onScreenEvent('display-removed');
      await settle();

      expect(desktop.fitsWorkArea(), isTrue);
      expect(desktop.minimumLogical, const Size(1024, 720));
    },
  );
}

class _Monitor {
  _Monitor(this.id, this.workPhysical, this.scale);

  final String id;

  /// rcWork: the monitor minus its taskbar, in physical pixels.
  final Rect workPhysical;
  double scale;
}

class _FakeWindowsDesktop {
  _FakeWindowsDesktop({
    required this.monitors,
    required Rect windowLogical,
    required this.windowScale,
  }) : windowPhysical = _scale(windowLogical, windowScale);

  final List<_Monitor> monitors;
  Rect windowPhysical;
  double windowScale;
  bool maximized = false;
  Rect? _restoreRect;
  Size minimumLogical = const Size(1024, 720);
  final List<String> calls = [];

  /// Windows sizes the maximized frame past each work-area edge by this many
  /// logical pixels.
  static const double _maximizedOverhang = 8;

  _Monitor monitorOfWindow() => monitors.firstWhere(
    (monitor) => monitor.workPhysical.contains(windowPhysical.center),
    orElse: () => monitors.first,
  );

  /// Whether the window sits inside its monitor's work area, allowing the
  /// maximized frame overhang Windows always adds.
  bool fitsWorkArea() {
    final monitor = monitorOfWindow();
    final slack = (_maximizedOverhang + 1) * monitor.scale;
    final work = monitor.workPhysical.inflate(slack);
    return work.contains(windowPhysical.topLeft) &&
        windowPhysical.right <= work.right &&
        windowPhysical.bottom <= work.bottom;
  }

  /// WM_DPICHANGED: keep the top-left, rescale by the DPI ratio.
  void settleDpi() {
    final scale = monitorOfWindow().scale;
    if (scale == windowScale) return;
    final ratio = scale / windowScale;
    windowPhysical = Rect.fromLTWH(
      windowPhysical.left,
      windowPhysical.top,
      windowPhysical.width * ratio,
      windowPhysical.height * ratio,
    );
    windowScale = scale;
  }

  void _maximize() {
    final monitor = monitorOfWindow();
    final frame = monitor.workPhysical.inflate(
      _maximizedOverhang * monitor.scale,
    );
    windowPhysical = Rect.fromLTWH(
      frame.left,
      frame.top,
      math.max(frame.width, minimumLogical.width * windowScale),
      math.max(frame.height, minimumLogical.height * windowScale),
    );
  }

  Future<Object?> windowManagerCall(MethodCall call) async {
    calls.add(call.method);
    final args = (call.arguments as Map?)?.cast<String, Object?>();
    switch (call.method) {
      case 'getBounds':
        return {
          'x': windowPhysical.left / windowScale,
          'y': windowPhysical.top / windowScale,
          'width': windowPhysical.width / windowScale,
          'height': windowPhysical.height / windowScale,
        };
      case 'setBounds':
        double value(String key, double current) =>
            ((args![key] as num?)?.toDouble() ?? current / windowScale) *
            windowScale;
        windowPhysical = Rect.fromLTWH(
          value('x', windowPhysical.left),
          value('y', windowPhysical.top),
          value('width', windowPhysical.width),
          value('height', windowPhysical.height),
        );
        settleDpi();
        return null;
      case 'setMinimumSize':
        minimumLogical = Size(
          (args!['width']! as num).toDouble(),
          (args['height']! as num).toDouble(),
        );
        return null;
      case 'isMaximized':
        return maximized;
      case 'isMinimized':
      case 'isFullScreen':
        return false;
      case 'maximize':
        _restoreRect = windowPhysical;
        maximized = true;
        _maximize();
        return null;
      case 'unmaximize':
        maximized = false;
        windowPhysical = _restoreRect ?? windowPhysical;
        return null;
    }
    return null;
  }

  Future<Object?> screenRetrieverCall(MethodCall call) async {
    switch (call.method) {
      case 'getAllDisplays':
        return {
          'displays': [for (final monitor in monitors) _displayJson(monitor)],
        };
      case 'getPrimaryDisplay':
        return _displayJson(monitors.first);
    }
    return null;
  }

  /// screen_retriever_windows: rcWork divided by the monitor's own scale.
  Map<String, Object?> _displayJson(_Monitor monitor) {
    final logical = _scale(monitor.workPhysical, 1 / monitor.scale);
    return {
      'id': monitor.id,
      'name': monitor.id,
      'size': {
        'width': logical.width.roundToDouble(),
        'height': logical.height.roundToDouble(),
      },
      'visiblePosition': {
        'dx': logical.left.roundToDouble(),
        'dy': logical.top.roundToDouble(),
      },
      'visibleSize': {
        'width': logical.width.roundToDouble(),
        'height': logical.height.roundToDouble(),
      },
      'scaleFactor': monitor.scale,
    };
  }
}

Rect _scale(Rect rect, double scale) => Rect.fromLTWH(
  rect.left * scale,
  rect.top * scale,
  rect.width * scale,
  rect.height * scale,
);
