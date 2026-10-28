/// Collect one complete MultiPV iteration before exposing score/lines/depth.
/// Each instance belongs to exactly one UCI search, never a FEN cache.
class CompletePvBatch<T> {
  CompletePvBatch(this.expectedCount) : assert(expectedCount > 0);

  final int expectedCount;
  int _collectingDepth = 0;
  final Map<int, T> _pending = {};
  List<T> lines = const [];
  int depth = 0;

  List<T>? add({required int rank, required int depth, required T value}) {
    if (rank < 1 ||
        rank > expectedCount ||
        depth < _collectingDepth ||
        depth < 1) {
      return null;
    }
    if (depth > _collectingDepth) {
      _collectingDepth = depth;
      _pending.clear();
    }
    _pending[rank] = value;
    if (_pending.length != expectedCount) return null;
    lines = List<T>.unmodifiable([
      for (var rank = 1; rank <= expectedCount; rank++) _pending[rank] as T,
    ]);
    this.depth = depth;
    return lines;
  }
}
