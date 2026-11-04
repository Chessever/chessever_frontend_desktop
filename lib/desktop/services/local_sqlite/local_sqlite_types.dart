/// Platform-neutral types shared by the local SQLite driver's native
/// implementation (`local_sqlite_native.dart`, package:sqlite3 over FFI) and
/// its browser implementation (`lib/web/shims/local_sqlite_web.dart`,
/// package:sqlite3 over WebAssembly).
///
/// Nothing here imports `dart:ffi` or `dart:io`, so both builds share one
/// exception hierarchy and one result-row type, and code such as the open
/// guard can type-test errors without a conditional import.
library;

import 'dart:collection';

/// What a write statement changed: `sqlite3_changes()` and
/// `sqlite3_last_insert_rowid()` read right after the statement ran.
final class WriteResult {
  const WriteResult(this.affectedRows, this.lastInsertId);

  final int affectedRows;
  final int lastInsertId;
}

/// Base class of every error the driver raises itself.
///
/// [sqliteCode] is SQLite's primary result code (5 = `SQLITE_BUSY`,
/// 14 = `SQLITE_CANTOPEN`, ...) and [extendedCode] the extended one, when the
/// error came from SQLite. `toString` keeps the `SQLite code: N` line the
/// local-cache retry and log classifiers match on.
class LocalSqliteException implements Exception {
  LocalSqliteException(this.message, {this.sqliteCode, this.extendedCode});

  final String message;
  final int? sqliteCode;
  final int? extendedCode;

  /// True for `SQLITE_BUSY` / `SQLITE_LOCKED`: another connection holds the
  /// lock this statement needed for longer than its busy timeout.
  bool get isBusy => sqliteCode == 5 || sqliteCode == 6;

  String get _typeName => 'LocalSqliteException';

  void _writeDetails(StringBuffer buffer) {}

  @override
  String toString() {
    final buffer =
        StringBuffer(_typeName)
          ..write(': ')
          ..write(message);
    _writeDetails(buffer);
    final code = sqliteCode;
    if (code != null) {
      buffer
        ..write('\n  SQLite code: ')
        ..write(code);
      final extended = extendedCode;
      if (extended != null && extended != code) {
        buffer
          ..write(' (extended ')
          ..write(extended)
          ..write(')');
      }
    }
    return buffer.toString();
  }
}

/// A statement the caller sent failed (prepare, bind or step).
class LocalSqliteQueryException extends LocalSqliteException {
  LocalSqliteQueryException(
    super.message, {
    this.sql,
    super.sqliteCode,
    super.extendedCode,
  });

  final String? sql;

  @override
  String get _typeName => 'LocalSqliteQueryException';

  @override
  void _writeDetails(StringBuffer buffer) {
    final statement = sql;
    if (statement == null) return;
    buffer
      ..write('\n  SQL: ')
      ..write(statement);
  }
}

/// A transaction-control statement the driver issued itself failed:
/// `BEGIN IMMEDIATE`, `COMMIT`, `ROLLBACK`, `SAVEPOINT` or `RELEASE`.
///
/// `database is locked` here means another connection held the write lock
/// past the busy timeout.
class LocalSqliteTransactionException extends LocalSqliteException {
  LocalSqliteTransactionException(
    super.message, {
    required this.operation,
    super.sqliteCode,
    super.extendedCode,
  });

  final String operation;

  @override
  String get _typeName => 'LocalSqliteTransactionException';

  @override
  void _writeDetails(StringBuffer buffer) {
    buffer
      ..write('\n  Operation: ')
      ..write(operation);
  }
}

/// The handle cannot be used: it failed to open, it was closed, or its
/// worker stopped.
///
/// Open failures always carry `Failed to open database at "<path>"`, which
/// the open guard's bounded retry keys on.
class LocalSqliteConnectionException extends LocalSqliteException {
  LocalSqliteConnectionException(
    super.message, {
    super.sqliteCode,
    super.extendedCode,
  });

  LocalSqliteConnectionException.databaseClosed()
    : super('Database is closed.');

  LocalSqliteConnectionException.openFailed(
    String path,
    String reason, {
    super.sqliteCode,
    super.extendedCode,
  }) : super('Failed to open database at "$path": $reason');

  @override
  String get _typeName => 'LocalSqliteConnectionException';
}

/// Rows of one `select`: column names shared by every row, values stored as
/// one positional list per row.
///
/// Rows are read-only `Map` views built on access, so a 10,000-row result
/// costs 10,000 small lists, not 10,000 hash maps. Like SQLite's own
/// `sqlite3_column_name` lookup, a name that appears twice resolves to its
/// last occurrence, and a missing name reads as `null`.
final class LocalSqliteRows extends ListBase<Map<String, Object?>> {
  LocalSqliteRows(List<String> columnNames, List<List<Object?>> rows)
    : columnNames = List.unmodifiable(columnNames),
      _rows = rows,
      _indexes = _indexColumns(columnNames);

  final List<String> columnNames;
  final List<List<Object?>> _rows;
  final Map<String, int> _indexes;

  static Map<String, int> _indexColumns(List<String> names) {
    final indexes = HashMap<String, int>();
    for (var i = 0; i < names.length; i++) {
      indexes[names[i]] = i;
    }
    return indexes;
  }

  @override
  int get length => _rows.length;

  @override
  set length(int newLength) {
    throw UnsupportedError('Query results are read-only.');
  }

  @override
  Map<String, Object?> operator [](int index) =>
      LocalSqliteRow._(this, _rows[index]);

  @override
  void operator []=(int index, Map<String, Object?> value) {
    throw UnsupportedError('Query results are read-only.');
  }

  /// The raw values of row [index], in [columnNames] order.
  List<Object?> valuesAt(int index) => List.unmodifiable(_rows[index]);
}

/// One row of [LocalSqliteRows] as a read-only map from column name to value.
final class LocalSqliteRow extends UnmodifiableMapBase<String, Object?> {
  LocalSqliteRow._(this._result, this._values);

  final LocalSqliteRows _result;
  final List<Object?> _values;

  @override
  Object? operator [](Object? key) {
    if (key is! String) return null;
    final index = _result._indexes[key];
    if (index == null) return null;
    return _values[index];
  }

  @override
  bool containsKey(Object? key) =>
      key is String && _result._indexes.containsKey(key);

  @override
  Iterable<String> get keys => _result.columnNames;

  @override
  int get length => _result.columnNames.length;

  /// The value of column [index] (zero based).
  Object? columnAt(int index) => _values[index];
}

/// Shared validation for `executeBatch`: every parameter row must bind the
/// same number of values, as the one prepared statement expects.
void checkUniformLocalSqliteParamSets(
  String sql,
  List<List<Object?>> paramSets,
) {
  if (paramSets.isEmpty) return;
  final expected = paramSets.first.length;
  for (var i = 1; i < paramSets.length; i++) {
    final actual = paramSets[i].length;
    if (actual != expected) {
      throw ArgumentError.value(
        paramSets,
        'paramSets',
        'every row must have the same number of parameters. Row 0 has '
            '$expected, row $i has $actual. SQL: $sql',
      );
    }
  }
}

/// True when [sql] holds more than one statement, ignoring semicolons inside
/// string literals, quoted identifiers and comments, and trailing semicolons,
/// whitespace and comments.
///
/// Multi-statement SQL can only run without parameters (through
/// `sqlite3_exec`), and it is never cached as one prepared statement.
bool localSqliteHasMultipleStatements(String sql) {
  if (!sql.contains(';')) return false;
  final length = sql.length;
  var i = 0;
  var sawStatementEnd = false;
  while (i < length) {
    final c = sql.codeUnitAt(i);
    // Whitespace.
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C) {
      i++;
      continue;
    }
    // -- line comment.
    if (c == 0x2D && i + 1 < length && sql.codeUnitAt(i + 1) == 0x2D) {
      final end = sql.indexOf('\n', i + 2);
      i = end < 0 ? length : end + 1;
      continue;
    }
    // /* block comment */
    if (c == 0x2F && i + 1 < length && sql.codeUnitAt(i + 1) == 0x2A) {
      final end = sql.indexOf('*/', i + 2);
      i = end < 0 ? length : end + 2;
      continue;
    }
    if (c == 0x3B) {
      sawStatementEnd = true;
      i++;
      continue;
    }
    // Any other token after a completed statement starts a second one.
    if (sawStatementEnd) return true;
    if (c == 0x27 || c == 0x22 || c == 0x60) {
      // '...', "..." and `...`; a doubled quote is an escaped quote.
      i++;
      while (i < length) {
        if (sql.codeUnitAt(i) == c) {
          if (i + 1 < length && sql.codeUnitAt(i + 1) == c) {
            i += 2;
            continue;
          }
          break;
        }
        i++;
      }
      i++;
      continue;
    }
    if (c == 0x5B) {
      // [identifier]
      final end = sql.indexOf(']', i + 1);
      i = end < 0 ? length : end + 1;
      continue;
    }
    i++;
  }
  return false;
}
