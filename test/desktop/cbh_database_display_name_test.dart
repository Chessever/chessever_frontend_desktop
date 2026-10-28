import 'dart:io';
import 'dart:typed_data';

import 'package:chessever/desktop/panes/library_pane.dart';
import 'package:chessever/desktop/services/cbh_conversion_service.dart';
import 'package:chessever/desktop/services/cbh_move_tables.dart';
import 'package:chessever/desktop/services/converted_database_names.dart';
import 'package:chessever/desktop/services/local_chess_file_scanner.dart';
import 'package:chessever/desktop/state/local_library_registry.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real converted database shows only its name in workspace header tab and cloud default without changing file identity',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-display-name-');
      addTearDown(() => root.delete(recursive: true));
      final source = await _plainGame(root, 'MY Games');
      final out = Directory(p.join(root.path, 'converted'));
      final result = await CbhConversionService(
        destination: out,
      ).convert(source.path);
      expect(result, isNotNull);
      final file = File(result!);
      final content = await file.readAsBytes();
      final hash = sha256.convert(content).toString();
      expect(
        p.basename(file.path),
        matches(r'^MY Games-\d{16}\.pgn$'),
        reason: 'The unique internal path must remain collision-safe',
      );
      final scanned = await scanLocalChessPaths([
        file.path,
      ], buildOpeningTree: false);
      expect(localChessDatabaseDisplayNameForPath(file.path), 'MY Games');
      expect(scanned.label, 'MY Games');
      expect(scanned.nodeForPath(file.path)!.name, 'MY Games');
      expect(localDatabaseWorkspaceTitle(scanned, file.path), 'MY Games');
      expect(
        DatabaseWorkspaceArgs.local(
          localPath: file.path,
          title: p.basename(file.path),
        ).title,
        'MY Games',
      );
      expect(
        LocalLibraryEntry(path: file.path, addedAt: DateTime(2026)).displayName,
        'MY Games',
      );
      expect(
        localChessDatabaseStemForPath(file.path),
        'MY Games',
        reason: 'This seeds the actual cloud-save database-name field',
      );
      expect(scanned.paths.single, file.path);
      expect(scanned.games.length, 1);
      expect(sha256.convert(await file.readAsBytes()).toString(), hash);

      // A pre-fix converted copy can be reopened without renaming its real file.
      final legacy = await file.copy(
        p.join(out.path, 'Previous Games-1700000000000000.pgn'),
      );
      final reopened = await scanLocalChessPaths([
        legacy.path,
      ], buildOpeningTree: false);
      expect(
        localDatabaseWorkspaceTitle(reopened, legacy.path),
        'Previous Games',
      );
      expect(localChessDatabaseStemForPath(legacy.path), 'Previous Games');
      expect(await legacy.exists(), isTrue);
      expect(sha256.convert(await legacy.readAsBytes()).toString(), hash);
    },
  );
  test(
    'relative Windows conversion directory resolves to the same absolute caption namespace',
    () {
      const root = r'name-fixture\Converted Databases';
      registerConvertedDatabaseDirectory(root);
      final path = p.windows.absolute(
        p.windows.join(root, 'Games-1700000000000000.pgn'),
      );
      expect(convertedDatabaseOriginalName(path), 'Games');
    },
  );

  test(
    'cold-start app-owned legacy copy cleans persisted labels without altering the real path',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-name-cold-');
      addTearDown(() => root.delete(recursive: true));
      await initializeConvertedDatabaseNames(dataDirectory: root.path);
      final path = p.join(
        root.path,
        'Converted Databases',
        'Old Games-1700000000000000.pgn',
      );
      const label = 'Old Games-1700000000000000.pgn';
      expect(convertedDatabaseOriginalName(path), 'Old Games');
      expect(
        DatabaseWorkspaceArgs.local(localPath: path, title: label).title,
        'Old Games',
      );
      expect(
        LocalLibraryEntry(path: path, addedAt: DateTime(2026)).displayName,
        'OLD Games',
      );
      expect(localChessDatabaseStemForPath(path), 'Old Games');
    },
  );

  test(
    'ordinary names and genuine year or numeric suffixes are not stripped',
    () {
      // Paths are split by the host's rules, so each host checks its own
      // style; the Windows runner covers drive-letter paths.
      final context = p.context;
      for (final root in [
        context.style == p.Style.windows ? r'C:\ordinary' : '/ordinary',
      ]) {
        for (final name in [
          'World Championship 2026.pgn',
          'FIDE-1700000000000000.pgn',
          '1700000000000000.pgn',
        ]) {
          final path = context.join(root, name);
          expect(convertedDatabaseOriginalName(path), isNull);
          expect(
            localChessDatabaseStemForPath(path),
            context.basenameWithoutExtension(path),
          );
        }
      }
      registerConvertedDatabaseDirectory('/owned/Converted Databases');
      expect(
        convertedDatabaseOriginalName(
          '/owned/Converted Databases/World Championship 2026.pgn',
        ),
        isNull,
      );
      expect(
        convertedDatabaseOriginalName(
          '/owned/Converted Databases/Study-1700000000000000-1700000000000001.pgn',
        ),
        'Study-1700000000000000',
      );
      expect(
        convertedDatabaseOriginalName(
          '/owned/Converted Databases backup/Study-1700000000000000.pgn',
        ),
        isNull,
      );
    },
  );

  test(
    'Windows case and separator differences do not leak IDs and POSIX case remains significant',
    () {
      registerConvertedDatabaseDirectory(r'C:\Data\Converted Databases');
      expect(
        convertedDatabaseOriginalName(
          'c:/DATA/Converted Databases/Study-1700000000000000.pgn',
        ),
        'Study',
      );
      registerConvertedDatabaseDirectory('/case/Converted Databases');
      expect(
        convertedDatabaseOriginalName(
          '/CASE/Converted Databases/Study-1700000000000000.pgn',
        ),
        isNull,
      );
    },
  );

  test('custom local titles and all cloud titles remain authoritative', () {
    const path = '/owned/Converted Databases/Study-1700000000000000.pgn';
    registerConvertedDatabaseDirectory('/owned/Converted Databases');
    expect(
      DatabaseWorkspaceArgs.local(
        localPath: path,
        title: 'My own title 2026',
      ).title,
      'My own title 2026',
    );
    expect(
      const DatabaseWorkspaceArgs.folder(
        folderId: 'folder',
        title: 'Cloud-1700000000000000',
        isSubscribed: false,
      ).title,
      'Cloud-1700000000000000',
    );
    expect(const DatabaseWorkspaceArgs.twic().title, 'ChessEver');
  });

  test(
    'separate converted copies keep separate source identity and never overwrite an edited PGN',
    () async {
      final root = await Directory.systemTemp.createTemp('cbh-name-identity-');
      addTearDown(() => root.delete(recursive: true));
      final input = await _plainGame(root, 'Study-1700000000000000');
      final out = Directory(p.join(root.path, 'converted'));
      final service = CbhConversionService(destination: out);
      final first = (await service.convert(input.path))!;
      final previous = await File(
        first,
      ).rename(p.join(out.path, 'User renamed 2026.pgn'));
      await previous.writeAsString(
        '${await previous.readAsString()}\n{user-owned edit}\n',
      );
      final previousHash =
          sha256.convert(await previous.readAsBytes()).toString();
      final second = (await service.convert(input.path))!;
      final third = (await service.convert(input.path))!;
      expect(second, isNot(third));
      expect(localChessDatabaseStemForPath(second), 'Study-1700000000000000');
      expect(localChessDatabaseStemForPath(third), 'Study-1700000000000000');
      final a = await scanLocalChessPaths([second], buildOpeningTree: false);
      final b = await scanLocalChessPaths([third], buildOpeningTree: false);
      expect(a.id, isNot(b.id));
      expect(
        DatabaseWorkspaceArgs.local(
          localPath: second,
          title: 'Study',
        ).sameDatabase(
          DatabaseWorkspaceArgs.local(localPath: third, title: 'Study'),
        ),
        isFalse,
      );
      expect(localChessDatabaseStemForPath(previous.path), 'User renamed 2026');
      expect(
        sha256.convert(await previous.readAsBytes()).toString(),
        previousHash,
      );
    },
  );
}

Future<File> _plainGame(Directory root, String stem) async {
  final index = Uint8List(92);
  index[2] = 0x2c;
  index[4] = 0x2e;
  index[5] = 1;
  index[9] = index.length ~/ 46;
  index[50] = 26;
  index[60] = 1;
  index[73] = 2;
  final source = File(p.join(root.path, '$stem.cbh'));
  await source.writeAsBytes(index);
  final players = Uint8List(28 + 67 * 2);
  players.setRange(37, 42, 'White'.codeUnits);
  players.setRange(104, 109, 'Black'.codeUnits);
  await File(p.join(root.path, '$stem.cbp')).writeAsBytes(players);
  final event = Uint8List(28 + 99);
  event[37] = 69;
  await File(p.join(root.path, '$stem.cbt')).writeAsBytes(event);
  await File(p.join(root.path, '$stem.cbc')).writeAsBytes(Uint8List(28 + 62));
  await File(p.join(root.path, '$stem.cbs')).writeAsBytes(Uint8List(28 + 68));
  final game = Uint8List(32);
  game[29] = 6;
  game[30] = cbhMoveLookup.indexOf(0x80);
  game[31] = (cbhMoveLookup.indexOf(0x80) + 1) & 255;
  await File(p.join(root.path, '$stem.cbg')).writeAsBytes(game);
  await File(p.join(root.path, '$stem.cba')).writeAsBytes(Uint8List(26));
  return source;
}
