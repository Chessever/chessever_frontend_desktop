import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/auth/desktop_auth_gate.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';

/// Top-level widget for the desktop build of ChessEver.
///
/// Mirrors `MyApp` from the mobile path but ships only the desktop-relevant
/// pieces: dark theme, no native splash, no upgrader dialog, no Material
/// orientation lock. The shell handles navigation; we do not push routes for
/// primary navigation on desktop.
class DesktopApp extends ConsumerWidget {
  const DesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'ChessEver',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      builder: (context, child) {
        // Init ResponsiveHelper so widgets that share with the mobile app
        // (EventCard's tablet grid layout, tablet-style tournament cards,
        // .sp / .br number extensions) pick up the desktop window's size.
        // A desktop window's diagonal > 1100 is treated as DeviceType.tablet,
        // which is exactly the layout we want on a 1440×900 desktop window.
        ResponsiveHelper.init(context);
        return FTheme(
          data: FThemes.zinc.dark,
          child: FToaster(child: child ?? const SizedBox.shrink()),
        );
      },
      home: const DesktopAuthGate(),
    );
  }
}
