import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:chessever/repository/sqlite/app_database.dart';

/// Persistent, account-scoped admission state for desktop game reports.
///
/// This is deliberately separate from the bounded
/// report cache. Account-prefixed durable preferences survive logout cache
/// clearing. These small, non-expiring access markers mean evicting a
/// completed report must not forget that the account already spent its one
/// lifetime free successful delivery or that a specific report was explicitly
/// admitted.
class GameReportAllowanceStore {
  GameReportAllowanceStore.sqlite([AppDatabase? database])
    : _database = database,
      _durableMemory = null;

  @visibleForTesting
  GameReportAllowanceStore.memory()
    : _database = null,
      _durableMemory = <String, String>{};

  static GameReportAllowanceStore instance = GameReportAllowanceStore.sqlite();

  final AppDatabase? _database;
  final Map<String, String>? _durableMemory;
  Future<void>? _writeChain;

  static const String _lifetimeSuccessKey =
      'desktop_game_report_lifetime_success_v1';
  static const String _admittedReportPrefix =
      'desktop_game_report_admitted_v1:';

  static String admittedReportKey(String fingerprint) =>
      '$_admittedReportPrefix${sha1.convert(utf8.encode(fingerprint))}';

  Future<bool> hasLifetimeSuccess(String accountId) async {
    if (accountId.isEmpty) return false;
    return await _readRaw(accountId, _lifetimeSuccessKey) != null;
  }

  Future<bool> hasAdmittedReport(String accountId, String fingerprint) async {
    if (accountId.isEmpty || fingerprint.isEmpty) return false;
    if (await _readRaw(accountId, admittedReportKey(fingerprint)) != null) {
      return true;
    }
    final first = await _readRaw(accountId, _lifetimeSuccessKey);
    if (first == null) return false;
    final payload = jsonDecode(first);
    return payload is Map && payload['fingerprint'] == fingerprint;
  }

  /// Records a Premium or otherwise paid admission for [fingerprint].
  ///
  /// This allows reopening that same admitted report later without consuming
  /// the free lifetime success marker if the account is no longer Premium.
  Future<void> markReportAdmitted(String accountId, String fingerprint) {
    if (accountId.isEmpty || fingerprint.isEmpty) return Future<void>.value();
    return _queueWrite(
      accountId,
      admittedReportKey(fingerprint),
      _payload(fingerprint, freeLifetimeSuccess: false),
    );
  }

  /// Records the account's one lifetime free successful report delivery and
  /// admits that report fingerprint for free future reopen.
  Future<void> markFreeSuccess(String accountId, String fingerprint) {
    if (accountId.isEmpty || fingerprint.isEmpty) return Future<void>.value();
    final payload = _payload(fingerprint, freeLifetimeSuccess: true);
    return _queueWriteMany(accountId, <String, String>{
      _lifetimeSuccessKey: payload,
      admittedReportKey(fingerprint): payload,
    });
  }

  Future<void> flush() async {
    final pending = _writeChain;
    if (pending == null) return;
    try {
      await pending;
    } catch (_) {}
  }

  String _payload(String fingerprint, {required bool freeLifetimeSuccess}) {
    return jsonEncode(<String, Object>{
      'v': 1,
      'fingerprint': fingerprint,
      'freeLifetimeSuccess': freeLifetimeSuccess,
      'admittedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _queueWrite(String accountId, String key, String value) =>
      _queueWriteMany(accountId, <String, String>{key: value});

  Future<void> _queueWriteMany(String accountId, Map<String, String> values) {
    final previous = _writeChain ?? Future<void>.value();
    final done = previous.catchError((_) {}).then((_) async {
      final memory = _durableMemory;
      if (memory != null) {
        for (final entry in values.entries) {
          memory[_scopedKey(accountId, entry.key)] = entry.value;
        }
        return;
      }
      final db = _database ?? AppDatabase.instance;
      for (final entry in values.entries) {
        await db.setString(_scopedKey(accountId, entry.key), entry.value);
      }
    });
    _writeChain = done;
    return done;
  }

  Future<String?> _readRaw(String accountId, String key) async {
    final memory = _durableMemory;
    if (memory != null) return memory[_scopedKey(accountId, key)];
    final db = _database ?? AppDatabase.instance;
    return db.getString(_scopedKey(accountId, key));
  }

  static String _scopedKey(String accountId, String key) => '$accountId::$key';
}
