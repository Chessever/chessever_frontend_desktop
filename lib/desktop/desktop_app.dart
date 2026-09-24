import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/widgets/cbh_convert_dialog.dart';
import 'package:chessever/desktop/auth/desktop_auth_gate.dart';
import 'package:chessever/desktop/auth/desktop_guest_gate.dart';
import 'package:chessever/desktop/services/desktop_build_identity.dart';
import 'package:chessever/desktop/services/engine/macos_chip_guard.dart';
import 'package:chessever/desktop/widgets/desktop_native_update_menu_bridge.dart';
import 'package:chessever/desktop/widgets/desktop_paywall_dialog.dart';
import 'package:chessever/desktop/widgets/desktop_window_frame.dart';
import 'package:chessever/services/analytics/analytics_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';

final _desktopNavigatorKey = GlobalKey<NavigatorState>();

/// Root navigator of the desktop app. Services without a widget context
/// (the deep link router) use it to present dialogs and toasts.
GlobalKey<NavigatorState> get desktopRootNavigatorKey => _desktopNavigatorKey;

/// Top-level widget for the desktop build of ChessEver.
///
/// Mirrors `MyApp` from the mobile path but ships only the desktop-relevant
/// pieces: dark theme, no native splash, no upgrader dialog, no Material
/// orientation lock. The shell handles navigation; we do not push routes for
/// primary navigation on desktop.
class DesktopApp extends ConsumerStatefulWidget {
  const DesktopApp({super.key});

  @override
  ConsumerState<DesktopApp> createState() => _DesktopAppState();
}

class _DesktopAppState extends ConsumerState<DesktopApp> {
  @override
  void initState() {
    super.initState();
    CbhConversionGateway.handler = _convertCbh;
    // Silicon package on Intel (or the reverse) gets a recovery dialog with
    // the correct download link — silent dead Stockfish is not acceptable.
    scheduleMacOsWrongChipCheck(navigatorKey: _desktopNavigatorKey);
  }

  Future<String?> _convertCbh(String source) async {
    final dialogContext = _desktopNavigatorKey.currentContext;
    if (!mounted || dialogContext == null) {
      throw const CbhConversionException('Desktop is not ready. Open the CBH again after startup.');
    }
    return showCbhConvertDialog(dialogContext, source);
  }

  @override
  void dispose() {
    if (CbhConversionGateway.handler == _convertCbh) CbhConversionGateway.handler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: DesktopBuildIdentity.current.displayName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      navigatorKey: _desktopNavigatorKey,
      navigatorObservers: [
        AnalyticsService.instance.routeObserver,
        // Lets the guest reminder see open dialogs so it never stacks on one.
        DesktopGuestGateObserver.instance,
      ],
      builder: (context, child) {
        // Init ResponsiveHelper so widgets that share with the mobile app
        // (EventCard's tablet grid layout, tablet-style tournament cards,
        // .sp / .br number extensions) pick up the desktop window's size.
        // A desktop window's diagonal > 1100 is treated as DeviceType.tablet,
        // which is exactly the layout we want on a 1440×900 desktop window.
        ResponsiveHelper.init(context);
        return FTheme(
          data: FThemes.zinc.dark,
          child: FToaster(
            child: DesktopNativeUpdateMenuBridge(
              navigatorKey: _desktopNavigatorKey,
              child: DesktopPaywallHost(
                navigatorKey: _desktopNavigatorKey,
                child: DesktopWindowFrame(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      },
      home: const DesktopAuthGate(),
    );
  }
}
