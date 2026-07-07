import 'dart:async';

import 'package:flutter/widgets.dart';

void runAfterPointerEvent(VoidCallback callback) {
  scheduleMicrotask(callback);
}

/// Defers hover/press visual state updates until after Flutter finishes
/// dispatching the current pointer/mouse-tracker update.
mixin DeferredPointerStateMixin<T extends StatefulWidget> on State<T> {
  void setStateAfterPointerEvent(VoidCallback update) {
    runAfterPointerEvent(() {
      if (!mounted) return;
      setState(update);
    });
  }
}
