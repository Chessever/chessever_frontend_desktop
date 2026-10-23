/// Web build stand-in for the slice of `package:resqlite` the local chess
/// database code uses.
///
/// Local databases are PGN and SQLite files on the user's disk, which a
/// browser cannot open. [Database.open] therefore always fails with the same
/// [ResqliteConnectionException] a missing or unwritable file produces on
/// desktop, so the open guard reports it through its normal failure path.
library;

import 'dart:typed_data';

const String _unavailable = 'Local databases are not available on the web.';

class ResqliteException implements Exception {
  ResqliteException(this.message);

  final String message;

  @override
  String toString() => 'ResqliteException: $message';
}

class ResqliteQueryException extends ResqliteException {
  ResqliteQueryException(
    super.message, {
    required this.sql,
    this.parameters,
    this.sqliteCode,
  });

  final String sql;
  final List<Object?>? parameters;
  final int? sqliteCode;
}

class ResqliteTransactionException extends ResqliteException {
  ResqliteTransactionException(
    super.message, {
    required this.operation,
    this.sqliteCode,
  });

  final String operation;
  final int? sqliteCode;
}

class ResqliteConnectionException extends ResqliteException {
  ResqliteConnectionException(super.message);

  ResqliteConnectionException.databaseClosed() : super('Database is closed.');

  @override
  String toString() => 'ResqliteConnectionException: $message';
}

final class WriteResult {
  const WriteResult(this.affectedRows, this.lastInsertId);

  final int affectedRows;
  final int lastInsertId;
}

final class BytesResult {
  const BytesResult(this.bytes, this.rowCount);

  final Uint8List bytes;
  final int rowCount;
}

final class Database {
  Database._();

  static Future<Database> open(
    String path, {
    String? encryptionKey,
    Iterable<Object> extensions = const [],
  }) async {
    throw ResqliteConnectionException(_unavailable);
  }

  Future<void> close() async {}

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) => throw ResqliteConnectionException(_unavailable);

  Future<BytesResult> selectBytes(
    String sql, [
    List<Object?> parameters = const [],
  ]) => throw ResqliteConnectionException(_unavailable);

  Stream<List<Map<String, Object?>>> stream(
    String sql, [
    List<Object?> parameters = const [],
  ]) => Stream.error(ResqliteConnectionException(_unavailable));

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) => throw ResqliteConnectionException(_unavailable);

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) =>
      throw ResqliteConnectionException(_unavailable);

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) =>
      throw ResqliteConnectionException(_unavailable);
}

final class Transaction {
  Transaction._();

  static Transaction? get current => null;

  Future<WriteResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) => throw ResqliteConnectionException(_unavailable);

  Future<List<Map<String, Object?>>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) => throw ResqliteConnectionException(_unavailable);

  Future<void> executeBatch(String sql, List<List<Object?>> paramSets) =>
      throw ResqliteConnectionException(_unavailable);

  Future<T> transaction<T>(Future<T> Function(Transaction tx) body) =>
      throw ResqliteConnectionException(_unavailable);

  void close() {}
}
