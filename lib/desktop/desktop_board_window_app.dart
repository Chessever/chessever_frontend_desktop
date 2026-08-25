import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'package:chessever/desktop/shell/desktop_shell.dart';
import 'package:chessever/desktop/services/desktop_board_window_payload.dart';
import 'package:chessever/desktop/state/desktop_tabs.dart';
import 'package:chessever/desktop/widgets/desktop_window_frame.dart';
import 'package:chessever/services/analytics/analytics_service.dart';
import 'package:chessever/theme/app_theme.dart';
import 'package:chessever/utils/responsive_helper.dart';

class DesktopBoardWindowApp extends ConsumerWidget {
  const DesktopBoardWindowApp({
    super.key,
    required this.payload,
    required this.tabId,
  });

  final DesktopBoardWindowPayload payload;
  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: payload.title,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      navigatorObservers: [AnalyticsService.instance.routeObserver],
      builder: (context, child) {
        ResponsiveHelper.init(context);
        return FTheme(
          data: FThemes.zinc.dark,
          child: FToaster(
            child: DesktopWindowFrame(
              allowMaximize: !payload.pictureInPicture,
              framelessContent: payload.pictureInPicture,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
      home: _BoardWindowHome(payload: payload, tabId: tabId),
    );
  }
}

class _BoardWindowHome extends StatelessWidget {
  const _BoardWindowHome({required this.payload, required this.tabId});

  final DesktopBoardWindowPayload payload;
  final String tabId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackgroundColor,
      body: DesktopStandaloneWindowChrome(
        framelessContent: payload.pictureInPicture,
        child: SafeArea(
          top: false,
          child: resolveDesktopTabContent(
            DesktopTab(
              id: tabId,
              kind: payload.kind,
              title: payload.title,
              subtitle: payload.subtitle,
            ),
          ),
        ),
      ),
    );
  }
}
