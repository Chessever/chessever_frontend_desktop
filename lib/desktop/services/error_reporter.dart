import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Centralizes error reporting so raw exception details never reach end users
/// or release-mode console output. Always send full diagnostics to Sentry;
/// surface only a generic message to the UI.
class ErrorReporter {
  ErrorReporter._();

  /// Default user-visible message. Localized strings can wrap this if needed.
  static const String genericUserMessage =
      'Something went wrong. Please try again.';

  /// Report an exception. Captures to Sentry unconditionally. Echoes to the
  /// console only in debug builds — release builds never print the raw error
  /// (only an opaque tag, so phase logging still works without leaking).
  static void report(
    Object error, {
    StackTrace? stackTrace,
    String? tag,
  }) {
    try {
      unawaited(
        Sentry.captureException(
          error,
          stackTrace: stackTrace,
          withScope: (scope) {
            if (tag != null) scope.setTag('source', tag);
          },
        ).catchError((_) => SentryId.empty()),
      );
    } catch (_) {
      // Sentry must never be the cause of a crash.
    }

    if (kDebugMode) {
      // ignore: avoid_print
      print('[${tag ?? 'error'}] $error');
      if (stackTrace != null) {
        // ignore: avoid_print
        print(stackTrace);
      }
    }
  }

  /// Convenience: report + return generic message in one call.
  static String reportAndMessage(
    Object error, {
    StackTrace? stackTrace,
    String? tag,
    String? userMessage,
  }) {
    report(error, stackTrace: stackTrace, tag: tag);
    return userMessage ?? genericUserMessage;
  }
}
