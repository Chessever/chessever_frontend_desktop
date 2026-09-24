import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';

void main() {
  test('summary counts unique unrendered records, not all raw frames', () {
    expect(
      CbhConversionService.describePreservation({
        'uninterpretedRecords': [1, 2],
        'unattachedRecords': [2, 3],
        'rawAnnotationRecords': 100,
      }),
      '3 records contain ChessBase fields retained as raw metadata, not displayed.',
    );
    expect(
      CbhConversionService.describePreservation({
        'unattachedRecords': [1],
      }),
      '1 record contains ChessBase fields retained as raw metadata, not displayed.',
    );
    expect(
      CbhConversionService.describePreservation({'rawAnnotationRecords': 100}),
      isNull,
    );
  });
  final helper = Platform.environment['CBH_TEST_HELPER'];
  final fixture = Platform.environment['CBH_TEST_FIXTURE'];
  final destination = Platform.environment['CBH_TEST_DESTINATION'];
  test(
    'actual Son helper completion exposes preservation on fresh conversion and reuse',
    () async {
      final service = CbhConversionService(
        executable: helper,
        destination: Directory(destination!),
      );
      final result = await service.convert(fixture!);
      expect(result, isNotNull);
      expect(
        service.preservationSummary,
        '137 records contain ChessBase fields retained as raw metadata, not displayed.',
      );
      final catalog = await scanLocalChessPgnCatalog(result!);
      expect(catalog.root.files.single.gameCount, 1436);
      expect(await service.convert(fixture), result);
      expect(
        service.preservationSummary,
        '137 records contain ChessBase fields retained as raw metadata, not displayed.',
      );
      // ignore: avoid_print
      print(
        'Delivered helper -> service -> catalog: $result; ${service.preservationSummary}',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip:
        helper == null || fixture == null || destination == null
            ? 'Set CBH_TEST_HELPER/FIXTURE/DESTINATION'
            : false,
  );
}
