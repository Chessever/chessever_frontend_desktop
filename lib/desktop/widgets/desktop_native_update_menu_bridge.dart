import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chessever/desktop/services/desktop_update_command.dart';

/// Receives native macOS/Windows menu commands and routes them into the same
/// Flutter update command used by in-shell controls.
class DesktopNativeUpdateMenuBridge extends StatefulWidget {
  const DesktopNativeUpdateMenuBridge({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<DesktopNativeUpdateMenuBridge> createState() =>
      _DesktopNativeUpdateMenuBridgeState();
}

class _DesktopNativeUpdateMenuBridgeState
    extends State<DesktopNativeUpdateMenuBridge> {
  static const MethodChannel _channel = MethodChannel(
    'chessever.desktop/native_update_menu',
  );

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'checkForUpdates':
        final commandContext = widget.navigatorKey.currentContext ?? context;
        await runDesktopUpdateCommand(commandContext);
      default:
        throw MissingPluginException(
          'No handler for native update menu method ${call.method}',
        );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
