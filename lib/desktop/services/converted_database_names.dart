import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// These are display hints, never replacements for source/cache/save paths.
final _convertedNames = <String, String>{};
final _convertedDirectories = <String>{};
final _legacyConvertedName = RegExp(
  r'^(.+)-(\d{16})\.pgn$',
  caseSensitive: false,
);

p.Context _context(String path) => p.Context(
  style:
      RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path) ||
              path.startsWith(r'\\') ||
              (path.contains('\\') && !path.startsWith('/'))
          ? p.Style.windows
          : path.startsWith('/')
          ? p.Style.posix
          : p.style,
);

String _pathKey(String path) {
  final context = _context(path);
  final normalized = context.normalize(
    context.isAbsolute(path) ? path : context.absolute(path),
  );
  return context.style == p.Style.windows
      ? normalized.toLowerCase()
      : normalized;
}

/// Only conversion-owned destinations may opt into the old timestamp layout.
/// Ordinary PGN paths elsewhere never have numeric suffixes interpreted.
void registerConvertedDatabaseDirectory(String directory) {
  _convertedDirectories.add(_pathKey(directory));
}

/// The converter knows the original name exactly for newly published copies.
void registerConvertedDatabaseName(String path, String originalName) {
  if (originalName.isNotEmpty) {
    _convertedNames[_pathKey(path)] = originalName;
  }
}

/// Populate the trusted app-owned directory before restored tabs are rendered.
/// No profile, source file or database is created or changed here.
Future<void> initializeConvertedDatabaseNames({String? dataDirectory}) async {
  const configured = String.fromEnvironment('CHESSEVER_DATA_DIR');
  try {
    final directory =
        dataDirectory ??
        (configured.isNotEmpty
            ? configured
            : (await getApplicationSupportDirectory()).path);
    registerConvertedDatabaseDirectory(
      p.join(directory, 'Converted Databases'),
    );
  } on Object {
    // Optional label projection must not turn path-provider failure into a
    // startup failure. Fresh conversions still register their exact names.
  }
}

/// Return an original name only when a converter recorded it or the file is
/// in its trusted legacy destination. Never infer from a bare label alone.
String? convertedDatabaseOriginalName(String path) {
  final key = _pathKey(path);
  final known = _convertedNames[key];
  if (known != null) {
    return known;
  }
  final context = _context(path);
  if (!_convertedDirectories.contains(_pathKey(context.dirname(path)))) {
    return null;
  }
  return _legacyConvertedName.firstMatch(context.basename(path))?.group(1);
}

/// Preserve custom titles. Only a caption still mirroring the generated file
/// name is projected; genuine digits in the original prefix remain untouched.
String convertedDatabaseDisplayLabel(String path, String label) {
  final original = convertedDatabaseOriginalName(path);
  if (original == null) {
    return label;
  }
  final context = _context(path);
  final base = context.basename(path);
  final stem = context.basenameWithoutExtension(path);
  final trimmed = label.trim();
  if (trimmed.toLowerCase() != base.toLowerCase() &&
      trimmed.toLowerCase() != stem.toLowerCase()) {
    return label;
  }
  final withoutExtension =
      trimmed.toLowerCase().endsWith('.pgn')
          ? trimmed.substring(0, trimmed.length - 4)
          : trimmed;
  final suffix = RegExp(r'-\d{16}$').firstMatch(withoutExtension);
  if (suffix == null) {
    return original;
  }
  return withoutExtension.substring(0, suffix.start);
}
