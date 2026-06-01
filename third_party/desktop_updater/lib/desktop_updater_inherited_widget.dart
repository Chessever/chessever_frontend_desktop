import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";

class DesktopUpdaterInheritedNotifier
    extends InheritedNotifier<DesktopUpdaterController> {
  const DesktopUpdaterInheritedNotifier({
    super.key,
    required Widget child,
    required DesktopUpdaterController controller,
  }) : super(child: child, notifier: controller);

  static DesktopUpdaterInheritedNotifier? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<DesktopUpdaterInheritedNotifier>();
  }
}
