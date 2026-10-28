import 'package:web/web.dart' as web;

/// `navigator.hardwareConcurrency`, or null when the browser hides it.
int? browserHardwareConcurrency() {
  final count = web.window.navigator.hardwareConcurrency;
  return count > 0 ? count : null;
}
