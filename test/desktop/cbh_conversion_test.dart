import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/state/local_chess_library.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:chessever/repository/sqlite/app_database.dart';

void main() {
  test(
    'packaged helper to durable PGN to persistent My Databases',
    () async {
      final fixture = Platform.environment['CBH_TEST_FIXTURE'];
      final executable = Platform.environment['CBH_TEST_HELPER'];
      if (fixture == null || executable == null) return;
      final temp = await Directory.systemTemp.createTemp(
        'cbh_packaged_integration_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final service = CbhConversionService(
        executable: executable,
        destination: temp,
      );
      final database = _MemoryDatabase();
      final registry = LocalLibraryRegistryNotifier(database);
      final notifier = LocalChessLibraryNotifier(registry: registry);
      addTearDown(notifier.dispose);
      addTearDown(registry.dispose);
      addTearDown(() => CbhConversionGateway.handler = null);
      CbhConversionGateway.handler = service.convert;
      expect(
        await notifier.openPaths([fixture]),
        isTrue,
        reason: notifier.state.error,
      );
      final path = notifier.state.source!.paths.single;
      expect(path.endsWith('.pgn'), isTrue);
      expect(p.basename(path), '${p.basenameWithoutExtension(fixture)}.pgn');
      expect(await File(path).exists(), isTrue);
      expect(registry.state.entries.single.path, path);
      final restored = LocalLibraryRegistryNotifier(database);
      addTearDown(restored.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(restored.state.entries.single.path, path);
      final again = await service.convert(fixture);
      expect(again, path);
      final original = await File(path).readAsString();
      await File(path).writeAsString('$original\n{edited copy}\n');
      final newPath = await service.convert(fixture);
      expect(newPath, isNot(path));
      expect(await File(path).readAsString(), contains('{edited copy}'));
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip:
        Platform.environment['CBH_TEST_HELPER'] == null ||
                Platform.environment['CBH_TEST_FIXTURE'] == null
            ? 'Set CBH_TEST_HELPER and CBH_TEST_FIXTURE to exercise the real package'
            : false,
  );

  test(
    'CBH consent result enters normal PGN library; cancel never scans',
    () async {
      final temp = await Directory.systemTemp.createTemp('cbh_intake_');
      addTearDown(() => temp.delete(recursive: true));
      final pgn = File('${temp.path}/converted.pgn');
      await pgn.writeAsString('[Event "Converted"]\n[Result "*"]\n\n1. e4 *\n');
      final notifier = _ScanningLibrary();
      addTearDown(notifier.dispose);
      addTearDown(() => CbhConversionGateway.handler = null);
      CbhConversionGateway.handler = (_) async => null;
      expect(await notifier.openPaths(['${temp.path}/original.cbh']), isFalse);
      expect(notifier.state.source, isNull);
      expect(notifier.state.isScanning, isFalse);
      CbhConversionGateway.handler = (_) async => pgn.path;
      expect(await notifier.openPaths(['${temp.path}/original.cbh']), isTrue);
      expect(notifier.state.source!.paths, [pgn.path]);
    },
  );
}

class _ScanningLibrary extends LocalChessLibraryNotifier {
  _ScanningLibrary() {
    state = state.copyWith(isScanning: true);
  }
}

class _MemoryDatabase implements AppDatabase {
  Object? stored;
  @override
  Future<T?> getJson<T>(String key) async => stored as T?;
  @override
  Future<void> setJson(String key, Object value) async {
    stored = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
