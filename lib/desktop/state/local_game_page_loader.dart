import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/local_chess_database_repository.dart';

/// One query/sort generation. Completions belong to a page, not to the last
/// requested page. Replacing/disposal of this object invalidates old work.
class LocalGamePageLoader extends ChangeNotifier {
  LocalGamePageLoader(this.load, {this.cacheLimit = 24});

  final Future<LocalChessGameQueryPage?> Function(int page) load;
  final int cacheLimit;
  final pages = <int, LocalChessGameQueryPage>{};
  final errors = <int, Object>{};
  final _inFlight = <int>{};
  final _pending = <int>{};
  Set<int> _demand = {};
  bool _disposed = false;
  int? totalCount;

  bool get isLoading => _inFlight.isNotEmpty || _pending.isNotEmpty;

  /// Replace obsolete queued scroll work, while letting the bounded in-flight
  /// reads finish. Every completion drains current demand without another scroll.
  void demand(Iterable<int> pages) {
    if (_disposed) return;
    _demand = pages.where((p) => p >= 0).toSet();
    _pending
      ..clear()
      ..addAll(_demand);
    _drain();
  }

  void request(int page) {
    if (_disposed || page < 0) return;
    _pending.add(page);
    _drain();
  }

  void retry(int page) {
    if (_disposed) return;
    errors.remove(page);
    request(page);
    notifyListeners();
  }

  void _drain() {
    if (_disposed) return;
    _pending.removeWhere(
      (p) =>
          pages.containsKey(p) ||
          errors.containsKey(p) ||
          _inFlight.contains(p),
    );
    while (_inFlight.length < 2 && _pending.isNotEmpty) {
      final page = _pending.first;
      _pending.remove(page);
      _inFlight.add(page);
      unawaited(_fetch(page));
    }
  }

  Future<void> _fetch(int number) async {
    try {
      final result = await load(number);
      if (_disposed) return;
      if (result == null) {
        throw StateError('Local database page is unavailable');
      }
      if (result.pageNumber != number) {
        throw StateError('Unexpected local database page');
      }
      final expected = (result.totalCount - number * result.pageSize).clamp(
        0,
        result.pageSize,
      );
      if (result.games.length < expected) {
        throw StateError('Incomplete local database page');
      }
      pages[number] = result;
      totalCount = result.totalCount;
      while (pages.length > cacheLimit) {
        final candidates = pages.keys.where(
          (p) => !_demand.contains(p) && p != number,
        );
        if (candidates.isEmpty) break;
        pages.remove(candidates.first);
      }
    } catch (error) {
      if (!_disposed) errors[number] = error;
    } finally {
      if (!_disposed) {
        _inFlight.remove(number);
        _drain();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending.clear();
    super.dispose();
  }
}
