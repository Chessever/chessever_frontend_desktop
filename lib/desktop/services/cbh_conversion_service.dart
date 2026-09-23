import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The application installs a navigator-backed consent handler. Non-UI callers
/// cannot silently convert a source or register the original binary database.
class CbhConversionGateway {
  static Future<String?> Function(String source)? handler;

  static Future<String?> convert(String source) async {
    final callback = handler;
    if (callback == null) {
      throw const CbhConversionException(
        'CBH conversion requires the desktop Convert & Open dialog.',
      );
    }
    return callback(source);
  }
}

class CbhConversionException implements Exception {
  const CbhConversionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CbhConversionService {
  CbhConversionService({this.executable, this.destination});
  final String? executable;
  final Directory? destination;
  File? _cancelFile;
  bool _cancelled = false;
  bool _running = false;
  String? _preservationSummary;
  String? get preservationSummary => _preservationSummary;
  String? existingCopyPath;
  bool existingCopyEdited = false;
  String existingCopyChoice = 'ask';
  String? selectedCopyPath;

  static String? describePreservation(Map<String, dynamic> summary) {
    final records = <Object>{
      ...?summary['uninterpretedRecords'] as List?,
      ...?summary['unattachedRecords'] as List?,
    };
    if (records.isEmpty) return null;
    return '${records.length} ${records.length == 1 ? 'record contains' : 'records contain'} '
        'ChessBase fields retained as raw metadata, not displayed.';
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _cancelFile?.writeAsString('cancel', flush: true);
  }

  Future<String?> convert(
    String source, {
    void Function(String)? onProgress,
  }) async {
    if (_running) {
      throw const CbhConversionException('A conversion is already running.');
    }
    _running = true;
    _preservationSummary = null;
    existingCopyPath = null;
    Directory? control;
    try {
      if (!Platform.isWindows && executable == null) {
        throw const CbhConversionException(
          'CBH conversion is currently available in the Windows development build only. Export as PGN on this platform.',
        );
      }
      final helper =
          executable ??
          p.join(
            p.dirname(Platform.resolvedExecutable),
            'cbh_converter',
            'chessever_cbh.exe',
          );
      if (!await File(helper).exists()) {
        throw const CbhConversionException(
          'The CBH converter is not packaged in this build. Use the Windows development builder, or export the database as PGN.',
        );
      }
      const configured = String.fromEnvironment('CHESSEVER_DATA_DIR');
      final root =
          destination ??
          Directory(
            p.join(
              configured.isNotEmpty
                  ? configured
                  : (await getApplicationSupportDirectory()).path,
              'Converted Databases',
            ),
          );
      await root.create(recursive: true);
      control = await Directory.systemTemp.createTemp('chessever_cbh_control_');
      _cancelFile = File(p.join(control.path, 'cancel'));
      if (_cancelled) return null;
      final process = await Process.start(helper, [
        '--source',
        source,
        '--destination',
        root.path,
        '--encoding',
        'windows-1252',
        '--cancel-file',
        _cancelFile!.path,
        '--existing-copy',
        existingCopyChoice,
        if (selectedCopyPath != null) ...['--selected-copy', selectedCopyPath!],
      ]);
      String? path;
      String? failure;
      final errors = process.stderr.drain<void>();
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            try {
              final message = jsonDecode(line) as Map<String, dynamic>;
              switch (message['type']) {
                case 'progress':
                  onProgress?.call(
                    'Converting ${message['done']} of ${message['total']} records…',
                  );
                case 'complete':
                  path = message['path'] as String?;
                  if (message['needsChoice'] == true) {
                    existingCopyPath = path;
                    existingCopyEdited = message['edited'] == true;
                  }
                  _preservationSummary = describePreservation(
                    Map<String, dynamic>.from(
                      message['preservation'] as Map? ?? {},
                    ),
                  );
                case 'error':
                  failure = message['message'] as String?;
              }
            } on Object {
              failure = 'Invalid response from the converter.';
            }
          });
      final finished = Completer<void>();
      output.onDone(() => finished.complete());
      output.onError((Object error) {
        failure = 'Could not read converter output.';
        if (!finished.isCompleted) finished.complete();
      });
      final code = await process.exitCode;
      await finished.future;
      await errors;
      if (_cancelled) return null;
      if (code != 0 || path == null || failure != null) {
        throw CbhConversionException(
          failure ?? 'Conversion failed. No database was opened.',
        );
      }
      final result = File(path!);
      if (!p.isWithin(root.absolute.path, result.absolute.path) ||
          p.extension(result.path).toLowerCase() != '.pgn' ||
          !await result.exists()) {
        throw const CbhConversionException(
          'The converter did not publish a valid PGN copy.',
        );
      }
      return existingCopyPath == null ? result.path : null;
    } finally {
      _cancelFile = null;
      _running = false;
      if (control != null && await control.exists()) {
        await control.delete(recursive: true);
      }
    }
  }
}
