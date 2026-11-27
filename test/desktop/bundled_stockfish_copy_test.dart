import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chessever/desktop/services/engine/stockfish_version.dart';
import 'package:chessever/desktop/services/engine/uci_engine.dart';

void main() {
  group('the bundled Stockfish copy in app support', () {
    test('is named for the bundled release', () {
      expect(kBundledStockfishVersion, '19');
      expect(bundledStockfishFileName(windows: false), 'stockfish-19');
      expect(bundledStockfishFileName(windows: true), 'stockfish-19.exe');
    });

    test('older copies are cleaned up', () {
      const keep = 'stockfish-19';
      expect(isStaleBundledStockfishName('stockfish', keep: keep), isTrue);
      expect(isStaleBundledStockfishName('stockfish.exe', keep: keep), isTrue);
      expect(isStaleBundledStockfishName('stockfish-18', keep: keep), isTrue);
      expect(
        isStaleBundledStockfishName('stockfish-17.1.exe', keep: keep),
        isTrue,
      );
      expect(
        isStaleBundledStockfishName('stockfish-18.1732.partial', keep: keep),
        isTrue,
      );
    });

    test('the current copy, its partial write and other files stay', () {
      const keep = 'stockfish-19';
      expect(isStaleBundledStockfishName('stockfish-19', keep: keep), isFalse);
      expect(
        isStaleBundledStockfishName('stockfish-19.1732.partial', keep: keep),
        isFalse,
      );
      expect(isStaleBundledStockfishName('lc0', keep: keep), isFalse);
      expect(isStaleBundledStockfishName('weights.pb.gz', keep: keep), isFalse);
      expect(
        isStaleBundledStockfishName('stockfish-notes.txt', keep: keep),
        isFalse,
      );
    });
  });

  group('the engine label', () {
    test('reads SF and the bundled version, as Lichess writes it', () {
      expect(kStockfishShortLabel, 'SF 19');
    });

    test('follows a UCI id name', () {
      expect(stockfishShortLabelFromUciName('Stockfish 19'), 'SF 19');
      expect(stockfishShortLabelFromUciName('Stockfish 17.1'), 'SF 17.1');
      expect(
        stockfishShortLabelFromUciName('Stockfish dev-20261127-5bdfd3e1'),
        'SF dev',
      );
      expect(stockfishShortLabelFromUciName(null), 'SF 19');
      expect(stockfishShortLabelFromUciName('Lc0 v0.32.0'), 'SF 19');
    });

    test('matches the engine every distribution ships', () {
      const v = kBundledStockfishVersion;
      for (final path in [
        'lib/web/web_engine_process.dart',
        'lib/web/shims/stockfish_upstream_web.dart',
      ]) {
        expect(
          File(path).readAsStringSync(),
          contains('stockfish/stockfish-$v-lite-single.js'),
          reason: '$path must load the Stockfish $v browser worker',
        );
      }
      expect(
        File('web/stockfish/stockfish-$v-lite-single.wasm').existsSync(),
        isTrue,
      );
      expect(
        File('scripts/fetch_stockfish.sh').readAsStringSync(),
        contains('VERSION="\${STOCKFISH_VERSION:-$v}"'),
      );
      expect(
        File('scripts/prepare_mac_app_store_engines.py').readAsStringSync(),
        contains('releases/download/sf_$v/'),
      );
      expect(
        File(
          'lib/desktop/services/play/engine_catalog.dart',
        ).readAsStringSync(),
        contains("version: '$v'"),
      );
    });
  });
}
