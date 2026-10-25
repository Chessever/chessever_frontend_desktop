/// Web stand-in for `package:resqlite`, a native SQLite binding the browser
/// cannot load. The local chess library is a desktop feature, so every open
/// fails with [ResqliteConnectionException] and the callers' existing
/// "database unavailable" paths take over.
class ResqliteException implements Exception {
  ResqliteException(this.message);

  final String message;

  @override
  String toString() => 'ResqliteException: $message';
}

class ResqliteConnectionException extends ResqliteException {
  ResqliteConnectionException(super.message);

  ResqliteConnectionException.databaseClosed() : super('Database is closed.');
}

class ResqliteQueryException extends ResqliteException {
  ResqliteQueryException(super.message);
}

class ResqliteTransactionException extends ResqliteException {
  ResqliteTransactionException(super.message);
}

final class WriteResult {
  const WriteResult(this.affectedRows, this.lastInsertId);

  final int affectedRows;
  final int lastInsertId;
}

Never _unavailable() => throw ResqliteConnectionException(
  'Local databases are not available on the web.',
);

final class Database {
  Database._();

  static Future<Database> open(
    String path, {
    String? encryptionKey,
    Iterable<Object> extensions = const [],
  }) async => _unavailable();

  Future<void> close() async {}

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => _unavailable();

  Stream<List<Map<String, Object?>>> stream(
    String sql, [
    List<Object?> parameters = const [],
  ]) => Stream.error(_unavailableError());

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => _unavailable();

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) async =>
      _unavailable();

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) async =>
      _unavailable();
}

ResqliteConnectionException _unavailableError() =>
    ResqliteConnectionException('Local databases are not available on the web.');

final class Transaction {
  Transaction._();

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => _unavailable();

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) async => _unavailable();

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) async =>
      _unavailable();

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) async =>
      _unavailable();

  void close() {}
}
