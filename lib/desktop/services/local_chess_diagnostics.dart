import 'dart:async';

import 'package:logger/logger.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:chessever/desktop/services/error_reporter.dart';

final localChessLog = LocalChessDiagnostics._();

class LocalChessDiagnostics {
  LocalChessDiagnostics._()
    : _logger = Logger(
        filter: ProductionFilter(),
        printer: SimplePrinter(printTime: true, colors: false),
        level: Level.info,
      );

  final Logger _logger;

  void info(String message, {Map<String, Object?> context = const {}}) {
    _logger.i(_format(message, context));
  }

  /// Adds structured, non-fatal timing context to a later Sentry event.
  /// Callers are responsible for passing only non-identifying values.
  void breadcrumb(
    String message, {
    required String category,
    Map<String, Object?> context = const {},
  }) {
    _logger.i(_format(message, context));
    try {
      unawaited(
        Sentry.addBreadcrumb(
          Breadcrumb(
            message: message,
            category: category,
            level: SentryLevel.warning,
            data: context,
          ),
        ).catchError((Object _) {}),
      );
    } catch (_) {
      // Diagnostics must never interfere with application work.
    }
  }

  void warning(
    String message, {
    Map<String, Object?> context = const {},
    Object? error,
    StackTrace? stackTrace,
    String? tag,
    bool report = false,
  }) {
    _logger.w(_format(message, context), error: error, stackTrace: stackTrace);
    if (report && error != null) {
      ErrorReporter.report(error, stackTrace: stackTrace, tag: tag);
    }
  }

  void error(
    String message,
    Object error,
    StackTrace stackTrace, {
    Map<String, Object?> context = const {},
    String? tag,
  }) {
    _logger.e(_format(message, context), error: error, stackTrace: stackTrace);
    ErrorReporter.report(error, stackTrace: stackTrace, tag: tag);
  }
}

String _format(String message, Map<String, Object?> context) {
  if (context.isEmpty) return '[local-chess] $message';
  final details = context.entries
      .where((entry) => entry.value != null)
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  if (details.isEmpty) return '[local-chess] $message';
  return '[local-chess] $message $details';
}
