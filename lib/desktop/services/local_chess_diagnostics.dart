import 'package:logger/logger.dart';

import 'package:chessever/desktop/services/error_reporter.dart';

final localChessLog = LocalChessDiagnostics._();

class LocalChessDiagnostics {
  LocalChessDiagnostics._()
    : _logger = Logger(
        filter: DevelopmentFilter(),
        printer: SimplePrinter(printTime: true, colors: false),
        level: Level.debug,
      );

  final Logger _logger;

  void info(String message, {Map<String, Object?> context = const {}}) {
    _logger.i(_format(message, context));
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
