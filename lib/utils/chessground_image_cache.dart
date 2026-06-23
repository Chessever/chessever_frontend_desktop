import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:flutter/widgets.dart';

/// Coordinates chessground's decoded piece image cache for app-level startup
/// preloads and runtime piece-set switches.
class ChessgroundImageCache {
  ChessgroundImageCache._();

  static PieceSet? _loadedPieceSet;
  static int _generation = 0;

  static Future<void> preloadDefaultPieceSet() {
    return preloadPieceSet(PieceSet.cburnett);
  }

  static Future<void> preloadPieceSet(PieceSet pieceSet) async {
    final assets = pieceSet.assets;
    if (_loadedPieceSet == pieceSet &&
        ChessgroundImages.instance.isAllLoaded(assets)) {
      return;
    }

    final generation = ++_generation;
    final devicePixelRatio =
        WidgetsBinding
            .instance
            .platformDispatcher
            .implicitView
            ?.devicePixelRatio;
    await ChessgroundImages.instance.loadAll(
      assets,
      devicePixelRatio: devicePixelRatio,
    );
    if (generation == _generation) {
      _loadedPieceSet = pieceSet;
    }
  }

  static void evictPieceSetAfterNextFrame(PieceSet pieceSet) {
    unawaited(() async {
      await WidgetsBinding.instance.endOfFrame;
      if (_loadedPieceSet == pieceSet) return;

      final activeAssets =
          _loadedPieceSet?.assets.values.toSet() ?? <AssetImage>{};
      for (final asset in pieceSet.assets.values.toSet()) {
        if (activeAssets.contains(asset)) continue;
        ChessgroundImages.instance.evict(asset);
      }
    }());
  }

  static void clear() {
    _generation += 1;
    _loadedPieceSet = null;
    ChessgroundImages.instance.clear();
  }
}
