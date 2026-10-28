import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/local_raw_pgn_catalog.dart';
import 'package:chessever/desktop/services/operation_cancellation.dart';

void main() {
  setUp(debugCloseLocalRawPgnCatalogs);
  tearDown(debugCloseLocalRawPgnCatalogs);
  test('concurrent idle pages both await strong source validation', () async {
    final dir = await Directory.systemTemp.createTemp('catalog-concurrent-idle-');
    try {
      final file = File('${dir.path}/one.pgn');
      final text = '[Event "One"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n1. e4 {${'a' * 100000}OLD${'b' * 1000000}} e5 *\n';
      await file.writeAsString(text);
      final handle = await openLocalRawPgnCatalog(file.path, debugValidationDelay: const Duration(milliseconds:100));
      final query = LocalRawPgnCatalogPageQuery(descriptor:handle.descriptor,pageNumber:0,pageSize:100);
      final modified = (await file.stat()).modified;
      handle.release();
      await file.writeAsString(text.replaceFirst('OLD','NEW'));
      await file.setLastModified(modified);
      final results = await Future.wait([localRawPgnCatalogPage(query), localRawPgnCatalogPage(query)]);
      expect(results,everyElement(isNull),reason:'A temporary pin from another validation is not a validated active owner');
    } finally {await dir.delete(recursive:true);}
  });
  test('canceled stale validation never starts an unowned replacement scan', () async {
    final dir = await Directory.systemTemp.createTemp('catalog-cancel-stale-');
    try {
      final file = File('${dir.path}/one.pgn');
      await file.writeAsString('[Event "One"]\n[White "A"]\n[Black "B"]\n[Result "*"]\n\n1. e4 e5 *\n');
      final handle = await openLocalRawPgnCatalog(file.path,debugValidationDelay:const Duration(milliseconds:100));
      handle.release();
      await file.writeAsString('[Event "Changed"]\n[White "C"]\n[Black "D"]\n[Result "*"]\n\n1. d4 d5 *\n');
      final token=OperationCancellationToken();var progress=0;
      final pending=openLocalRawPgnCatalog(file.path,cancellationToken:token,onProgress:(_)=>progress++);
      token.cancel();
      await expectLater(pending,throwsA(isA<OperationCanceledException>()));
      await Future<void>.delayed(const Duration(milliseconds:250));
      expect(progress,0,reason:'Cancellation must gate worker creation after failed validation');
    } finally {await dir.delete(recursive:true);}
  });
}
