import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:web/web.dart' as web;

import 'package:chessever/web/web_path_provider.dart';

/// A filesystem for the browser build, so the desktop code that keeps local
/// PGN databases, player workspaces and caches as files runs unchanged.
///
/// Installed through [IOOverrides], so every `File(...)` / `Directory(...)`
/// in the app lands here. The whole tree lives in memory (the desktop code
/// also uses synchronous calls such as `existsSync` and `openSync`) and is
/// written behind to IndexedDB, where [WebFileSystem.mount] reloads it on the
/// next visit.
class WebFileSystem {
  WebFileSystem._();

  static final WebFileSystem instance = WebFileSystem._();

  static const String _dbName = 'chessever-files';
  static const String _store = 'entries';
  static const Duration _flushDelay = Duration(milliseconds: 400);

  final Map<String, _Node> _nodes = {'/': _Node.directory()};
  final Set<String> _dirty = {};
  final Set<String> _deleted = {};
  web.IDBDatabase? _db;
  Timer? _flushTimer;

  /// Opens IndexedDB, loads every stored entry and installs the overrides.
  static Future<void> mount() async {
    final fs = instance;
    try {
      fs._db = await _openDatabase();
      await fs._loadAll();
    } catch (_) {
      // Private windows can refuse IndexedDB; files then last for the tab.
      fs._db = null;
    }
    for (final dir in WebPathProvider.folders) {
      fs._mkdirs(dir);
    }
    IOOverrides.global = _WebIOOverrides();
  }

  static String normalize(String path) {
    final absolute = path.startsWith('/') ? path : '/home/chessever/$path';
    final normalized = p.posix.normalize(absolute);
    return normalized.isEmpty ? '/' : normalized;
  }

  _Node? _nodeAt(String path) => _nodes[normalize(path)];

  // Byte-level access for the SQLite VFS (shims/resqlite_web.dart), so
  // database files live in this filesystem like any other file.

  bool fileExists(String path) => !(_nodeAt(path)?.isDirectory ?? true);

  void ensureFile(String path) => _createFile(path, recursive: true);

  void deleteFile(String path) {
    if (fileExists(path)) delete(path);
  }

  int fileSize(String path) => _nodeAt(path)?.length ?? 0;

  int readFileInto(String path, Uint8List buffer, int offset) {
    final n = _nodeAt(path);
    if (n == null || n.length <= offset) return 0;
    final available =
        buffer.length < n.length - offset ? buffer.length : n.length - offset;
    buffer.setRange(0, available, n.bytes, offset);
    return available;
  }

  void writeFileAt(String path, Uint8List data, int offset) {
    _createFile(path, recursive: true).writeAt(offset, data);
    _markDirty(normalize(path));
  }

  void truncateFile(String path, int size) {
    _createFile(path, recursive: true).truncate(size);
    _markDirty(normalize(path));
  }

  FileSystemEntityType typeOf(String path) {
    final n = _nodeAt(path);
    if (n == null) return FileSystemEntityType.notFound;
    return n.isDirectory
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
  }

  void _mkdirs(String path) {
    var current = '/';
    for (final part in p.posix.split(normalize(path)).skip(1)) {
      current = p.posix.join(current, part);
      final existing = _nodes[current];
      if (existing == null) {
        _nodes[current] = _Node.directory();
        _markDirty(current);
      } else if (!existing.isDirectory) {
        throw FileSystemException('Not a directory', current);
      }
    }
  }

  _Node _createFile(String path, {bool recursive = false, bool exclusive = false}) {
    final key = normalize(path);
    final existing = _nodes[key];
    if (existing != null) {
      if (existing.isDirectory) {
        throw FileSystemException('Is a directory', path);
      }
      if (exclusive) throw FileSystemException('File exists', path);
      return existing;
    }
    final parent = p.posix.dirname(key);
    if (_nodes[parent] == null) {
      if (!recursive) {
        throw FileSystemException('Cannot create file', path, const OSError('No such file or directory', 2));
      }
      _mkdirs(parent);
    }
    final created = _Node.file();
    _nodes[key] = created;
    _markDirty(key);
    return created;
  }

  _Node _requireFile(String path) {
    final n = _nodeAt(path);
    if (n == null) {
      throw FileSystemException('Cannot open file', path, const OSError('No such file or directory', 2));
    }
    if (n.isDirectory) throw FileSystemException('Is a directory', path);
    return n;
  }

  void createDirectory(String path, {bool recursive = false}) {
    final key = normalize(path);
    if (_nodes[key]?.isDirectory ?? false) return;
    if (!recursive && _nodes[p.posix.dirname(key)] == null) {
      throw FileSystemException('Creation failed', path, const OSError('No such file or directory', 2));
    }
    _mkdirs(key);
  }

  void delete(String path, {bool recursive = false}) {
    final key = normalize(path);
    final n = _nodes[key];
    if (n == null) {
      throw FileSystemException('Deletion failed', path, const OSError('No such file or directory', 2));
    }
    final children = _childrenOf(key, recursive: true).toList();
    if (n.isDirectory && children.isNotEmpty && !recursive) {
      throw FileSystemException('Directory not empty', path);
    }
    for (final child in children) {
      _nodes.remove(child);
      _markDeleted(child);
    }
    _nodes.remove(key);
    _markDeleted(key);
  }

  void rename(String from, String to) {
    final source = normalize(from);
    final target = normalize(to);
    final n = _nodes[source];
    if (n == null) {
      throw FileSystemException('Cannot rename file', from, const OSError('No such file or directory', 2));
    }
    if (_nodes[p.posix.dirname(target)] == null) {
      throw FileSystemException('Cannot rename file', to, const OSError('No such file or directory', 2));
    }
    final moves = <String, _Node>{target: n};
    for (final child in _childrenOf(source, recursive: true)) {
      moves[target + child.substring(source.length)] = _nodes[child]!;
    }
    for (final child in _childrenOf(source, recursive: true).toList()) {
      _nodes.remove(child);
      _markDeleted(child);
    }
    _nodes.remove(source);
    _markDeleted(source);
    for (final entry in moves.entries) {
      _nodes[entry.key] = entry.value;
      _markDirty(entry.key);
    }
  }

  Iterable<String> _childrenOf(String dir, {required bool recursive}) {
    final prefix = dir == '/' ? '/' : '$dir/';
    return _nodes.keys.where((key) {
      if (key == dir || !key.startsWith(prefix)) return false;
      return recursive || !key.substring(prefix.length).contains('/');
    });
  }

  List<String> list(String dir, {bool recursive = false}) {
    final key = normalize(dir);
    if (!(_nodes[key]?.isDirectory ?? false)) {
      throw FileSystemException('Directory listing failed', dir, const OSError('No such file or directory', 2));
    }
    return _childrenOf(key, recursive: recursive).toList()..sort();
  }

  void touch(String path) {
    final key = normalize(path);
    _nodes[key]?.modified = DateTime.now();
    _markDirty(key);
  }

  void _markDirty(String key) {
    _deleted.remove(key);
    _dirty.add(key);
    _scheduleFlush();
  }

  void _markDeleted(String key) {
    _dirty.remove(key);
    _deleted.add(key);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_db == null) return;
    _flushTimer ??= Timer(_flushDelay, () {
      _flushTimer = null;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    final db = _db;
    if (db == null || (_dirty.isEmpty && _deleted.isEmpty)) return;
    final writes = _dirty.toList();
    final deletes = _deleted.toList();
    _dirty.clear();
    _deleted.clear();
    final tx = db.transaction(_store.toJS, 'readwrite');
    final store = tx.objectStore(_store);
    for (final key in deletes) {
      store.delete(key.toJS);
    }
    for (final key in writes) {
      final n = _nodes[key];
      if (n == null) continue;
      store.put(n.toJs(), key.toJS);
    }
    await _complete(tx);
  }

  Future<void> _loadAll() async {
    final db = _db!;
    final tx = db.transaction(_store.toJS, 'readonly');
    final store = tx.objectStore(_store);
    final keys = await _request<JSArray<JSAny?>>(store.getAllKeys());
    final values = await _request<JSArray<JSAny?>>(store.getAll());
    final keyList = keys.toDart;
    final valueList = values.toDart;
    for (var i = 0; i < keyList.length; i++) {
      final key = (keyList[i] as JSString).toDart;
      final value = valueList[i];
      if (value == null) continue;
      _nodes[key] = _Node.fromJs(value as JSObject);
    }
  }

  static Future<web.IDBDatabase> _openDatabase() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_dbName, 1);
    request.onupgradeneeded =
        ((web.Event _) {
          final db = request.result as web.IDBDatabase;
          if (!db.objectStoreNames.contains(_store)) {
            db.createObjectStore(_store);
          }
        }).toJS;
    request.onsuccess =
        ((web.Event _) => completer.complete(request.result as web.IDBDatabase))
            .toJS;
    request.onerror =
        ((web.Event _) => completer.completeError(
          StateError('IndexedDB unavailable'),
        )).toJS;
    return completer.future;
  }

  static Future<T> _request<T extends JSAny?>(web.IDBRequest request) {
    final completer = Completer<T>();
    request.onsuccess =
        ((web.Event _) => completer.complete(request.result as T)).toJS;
    request.onerror =
        ((web.Event _) => completer.completeError(
          StateError('IndexedDB request failed'),
        )).toJS;
    return completer.future;
  }

  static Future<void> _complete(web.IDBTransaction tx) {
    final completer = Completer<void>();
    tx.oncomplete = ((web.Event _) => completer.complete()).toJS;
    tx.onerror = ((web.Event _) => completer.complete()).toJS;
    tx.onabort = ((web.Event _) => completer.complete()).toJS;
    return completer.future;
  }
}

class _Node {
  _Node.directory() : isDirectory = true, modified = DateTime.now();
  _Node.file() : isDirectory = false, modified = DateTime.now();

  final bool isDirectory;
  DateTime modified;
  Uint8List _buffer = Uint8List(0);
  int length = 0;

  Uint8List get bytes => Uint8List.sublistView(_buffer, 0, length);

  void setBytes(List<int> data) {
    _buffer = Uint8List.fromList(data);
    length = _buffer.length;
    modified = DateTime.now();
  }

  void ensureCapacity(int size) {
    if (size <= _buffer.length) return;
    var capacity = _buffer.isEmpty ? 1024 : _buffer.length;
    while (capacity < size) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity)..setRange(0, length, _buffer);
    _buffer = grown;
  }

  void writeAt(int position, List<int> data, [int start = 0, int? end]) {
    final stop = end ?? data.length;
    final count = stop - start;
    ensureCapacity(position + count);
    _buffer.setRange(position, position + count, data, start);
    if (position + count > length) length = position + count;
    modified = DateTime.now();
  }

  void truncate(int size) {
    if (size > length) {
      ensureCapacity(size);
      _buffer.fillRange(length, size, 0);
    }
    length = size;
    modified = DateTime.now();
  }

  JSObject toJs() {
    final object = JSObject();
    object['dir'] = isDirectory.toJS;
    object['mtime'] = modified.millisecondsSinceEpoch.toJS;
    if (!isDirectory) object['data'] = bytes.toJS;
    return object;
  }

  static _Node fromJs(JSObject object) {
    final isDir = (object['dir'] as JSBoolean?)?.toDart ?? false;
    final n = isDir ? _Node.directory() : _Node.file();
    final mtime = (object['mtime'] as JSNumber?)?.toDartInt;
    if (mtime != null) {
      n.modified = DateTime.fromMillisecondsSinceEpoch(mtime);
    }
    final data = object['data'];
    if (!isDir && data != null) {
      n.setBytes((data as JSUint8Array).toDart);
      if (mtime != null) {
        n.modified = DateTime.fromMillisecondsSinceEpoch(mtime);
      }
    }
    return n;
  }
}

WebFileSystem get _fs => WebFileSystem.instance;

final class _WebIOOverrides extends IOOverrides {
  @override
  File createFile(String path) => _WebFile(path);

  @override
  Directory createDirectory(String path) => _WebDirectory(path);

  @override
  Directory getCurrentDirectory() => _WebDirectory('/home/chessever');

  @override
  void setCurrentDirectory(String path) {}

  @override
  Directory getSystemTempDirectory() => _WebDirectory('/tmp');

  @override
  Future<FileStat> stat(String path) async => _stat(path);

  @override
  FileStat statSync(String path) => _stat(path);

  @override
  Future<bool> fseIdentical(String path1, String path2) async =>
      WebFileSystem.normalize(path1) == WebFileSystem.normalize(path2);

  @override
  bool fseIdenticalSync(String path1, String path2) =>
      WebFileSystem.normalize(path1) == WebFileSystem.normalize(path2);

  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) async =>
      _fs.typeOf(path);

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      _fs.typeOf(path);
}

FileStat _stat(String path) => _WebFileStat(_fs._nodeAt(path));

class _WebFileStat implements FileStat {
  _WebFileStat(this._node);

  final _Node? _node;

  @override
  DateTime get changed => _node?.modified ?? DateTime(0);

  @override
  DateTime get modified => _node?.modified ?? DateTime(0);

  @override
  DateTime get accessed => _node?.modified ?? DateTime(0);

  @override
  FileSystemEntityType get type =>
      _node == null
          ? FileSystemEntityType.notFound
          : _node.isDirectory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file;

  @override
  int get mode => _node == null ? 0 : 420;

  @override
  int get size => _node == null ? -1 : _node.length;

  @override
  String modeString() => 'rw-r--r--';
}

abstract class _WebEntity implements FileSystemEntity {
  _WebEntity(this.path);

  @override
  final String path;

  String get _key => WebFileSystem.normalize(path);

  @override
  Uri get uri => Uri.file(path);

  @override
  bool get isAbsolute => path.startsWith('/');

  @override
  Directory get parent => _WebDirectory(p.posix.dirname(_key));

  @override
  Future<FileStat> stat() async => _stat(path);

  @override
  FileStat statSync() => _stat(path);

  @override
  Future<String> resolveSymbolicLinks() async => _key;

  @override
  String resolveSymbolicLinksSync() => _key;

  @override
  Stream<FileSystemEvent> watch({
    int events = FileSystemEvent.all,
    bool recursive = false,
  }) => const Stream.empty();

  @override
  String toString() => "${runtimeType == _WebFile ? 'File' : 'Directory'}: '$path'";
}

class _WebFile extends _WebEntity implements File {
  _WebFile(super.path);

  @override
  File get absolute => _WebFile(_key);

  @override
  Future<bool> exists() async => existsSync();

  @override
  bool existsSync() => _fs.typeOf(path) == FileSystemEntityType.file;

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    createSync(recursive: recursive, exclusive: exclusive);
    return this;
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _fs._createFile(path, recursive: recursive, exclusive: exclusive);

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    deleteSync(recursive: recursive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) {
    _fs._requireFile(path);
    _fs.delete(path);
  }

  @override
  Future<File> rename(String newPath) async => renameSync(newPath);

  @override
  File renameSync(String newPath) {
    _fs._requireFile(path);
    if (_fs._nodeAt(newPath)?.isDirectory ?? false) {
      throw FileSystemException('Is a directory', newPath);
    }
    if (_fs._nodeAt(newPath) != null) _fs.delete(newPath);
    _fs.rename(path, newPath);
    return _WebFile(newPath);
  }

  @override
  Future<File> copy(String newPath) async => copySync(newPath);

  @override
  File copySync(String newPath) {
    final data = _fs._requireFile(path).bytes;
    _fs._createFile(newPath).setBytes(data);
    _fs.touch(newPath);
    return _WebFile(newPath);
  }

  @override
  Future<int> length() async => lengthSync();

  @override
  int lengthSync() => _fs._requireFile(path).length;

  @override
  Future<DateTime> lastAccessed() async => lastModifiedSync();

  @override
  DateTime lastAccessedSync() => lastModifiedSync();

  @override
  Future<void> setLastAccessed(DateTime time) async {}

  @override
  void setLastAccessedSync(DateTime time) {}

  @override
  Future<DateTime> lastModified() async => lastModifiedSync();

  @override
  DateTime lastModifiedSync() => _fs._requireFile(path).modified;

  @override
  Future<void> setLastModified(DateTime time) async =>
      setLastModifiedSync(time);

  @override
  void setLastModifiedSync(DateTime time) {
    _fs._requireFile(path).modified = time;
    _fs._markDirty(_key);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      openSync(mode: mode);

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    final writes =
        mode == FileMode.write ||
        mode == FileMode.writeOnly ||
        mode == FileMode.append ||
        mode == FileMode.writeOnlyAppend;
    final node =
        writes ? _fs._createFile(path) : _fs._requireFile(path);
    if (mode == FileMode.write || mode == FileMode.writeOnly) {
      node.truncate(0);
      _fs._markDirty(_key);
    }
    final appends =
        mode == FileMode.append || mode == FileMode.writeOnlyAppend;
    return _WebRandomAccessFile(path, node, appends ? node.length : 0);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    final bytes = _fs._requireFile(path).bytes;
    final from = start ?? 0;
    final to = end ?? bytes.length;
    const chunk = 1 << 16;
    for (var i = from; i < to; i += chunk) {
      yield Uint8List.fromList(
        bytes.sublist(i, i + chunk > to ? to : i + chunk),
      );
    }
  }

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    final file = openSync(mode: mode);
    return IOSink(_RandomAccessConsumer(file), encoding: encoding);
  }

  @override
  Future<Uint8List> readAsBytes() async => readAsBytesSync();

  @override
  Uint8List readAsBytesSync() =>
      Uint8List.fromList(_fs._requireFile(path).bytes);

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      readAsStringSync(encoding: encoding);

  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      encoding.decode(_fs._requireFile(path).bytes);

  @override
  Future<List<String>> readAsLines({Encoding encoding = utf8}) async =>
      readAsLinesSync(encoding: encoding);

  @override
  List<String> readAsLinesSync({Encoding encoding = utf8}) =>
      const LineSplitter().convert(readAsStringSync(encoding: encoding));

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    writeAsBytesSync(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    final node = _fs._createFile(path);
    if (mode == FileMode.append || mode == FileMode.writeOnlyAppend) {
      node.writeAt(node.length, bytes);
    } else {
      node.setBytes(bytes);
    }
    _fs._markDirty(_key);
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    writeAsStringSync(contents, mode: mode, encoding: encoding, flush: flush);
    return this;
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => writeAsBytesSync(encoding.encode(contents), mode: mode);
}

class _WebDirectory extends _WebEntity implements Directory {
  _WebDirectory(super.path);

  @override
  Directory get absolute => _WebDirectory(_key);

  @override
  Future<bool> exists() async => existsSync();

  @override
  bool existsSync() => _fs.typeOf(path) == FileSystemEntityType.directory;

  @override
  Future<Directory> create({bool recursive = false}) async {
    createSync(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) =>
      _fs.createDirectory(path, recursive: recursive);

  static int _tempCounter = 0;

  @override
  Future<Directory> createTemp([String? prefix]) async => createTempSync(prefix);

  @override
  Directory createTempSync([String? prefix]) {
    final name =
        '${prefix ?? ''}${DateTime.now().microsecondsSinceEpoch}${_tempCounter++}';
    final dir = _WebDirectory(p.posix.join(_key, name));
    dir.createSync(recursive: true);
    return dir;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    deleteSync(recursive: recursive);
    return this;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      _fs.delete(path, recursive: recursive);

  @override
  Future<Directory> rename(String newPath) async => renameSync(newPath);

  @override
  Directory renameSync(String newPath) {
    _fs.rename(path, newPath);
    return _WebDirectory(newPath);
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => Stream.fromIterable(listSync(recursive: recursive));

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => [
    for (final key in _fs.list(path, recursive: recursive))
      if (_fs._nodeAt(key)!.isDirectory) _WebDirectory(key) else _WebFile(key),
  ];
}

class _WebRandomAccessFile implements RandomAccessFile {
  _WebRandomAccessFile(this.path, this._node, this._position);

  @override
  final String path;
  final _Node _node;
  int _position;
  bool _closed = false;

  String get _key => WebFileSystem.normalize(path);

  void _dirty() => _fs._markDirty(_key);

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() => _closed = true;

  @override
  Future<RandomAccessFile> flush() async => this;

  @override
  void flushSync() {}

  @override
  Future<int> length() async => _node.length;

  @override
  int lengthSync() => _node.length;

  @override
  Future<int> position() async => _position;

  @override
  int positionSync() => _position;

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    setPositionSync(position);
    return this;
  }

  @override
  void setPositionSync(int position) => _position = position;

  @override
  Future<Uint8List> read(int count) async => readSync(count);

  @override
  Uint8List readSync(int count) {
    final end = (_position + count).clamp(0, _node.length);
    final start = _position.clamp(0, _node.length);
    final out = Uint8List.fromList(_node.bytes.sublist(start, end));
    _position = end;
    return out;
  }

  @override
  Future<int> readByte() async => readByteSync();

  @override
  int readByteSync() {
    if (_position >= _node.length) return -1;
    return _node.bytes[_position++];
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async =>
      readIntoSync(buffer, start, end);

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    final want = (end ?? buffer.length) - start;
    final data = readSync(want);
    buffer.setRange(start, start + data.length, data);
    return data.length;
  }

  @override
  Future<RandomAccessFile> writeByte(int value) async {
    writeByteSync(value);
    return this;
  }

  @override
  int writeByteSync(int value) {
    _node.writeAt(_position, [value]);
    _position++;
    _dirty();
    return 1;
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    writeFromSync(buffer, start, end);
    return this;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    final stop = end ?? buffer.length;
    _node.writeAt(_position, buffer, start, stop);
    _position += stop - start;
    _dirty();
  }

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) async {
    writeStringSync(string, encoding: encoding);
    return this;
  }

  @override
  void writeStringSync(String string, {Encoding encoding = utf8}) =>
      writeFromSync(encoding.encode(string));

  @override
  Future<RandomAccessFile> truncate(int length) async {
    truncateSync(length);
    return this;
  }

  @override
  void truncateSync(int length) {
    _node.truncate(length);
    if (_position > length) _position = length;
    _dirty();
  }

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async => this;

  @override
  void lockSync([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) {}

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async => this;

  @override
  void unlockSync([int start = 0, int end = -1]) {}

  @override
  String toString() => "RandomAccessFile: '$path'${_closed ? ' (closed)' : ''}";
}

class _RandomAccessConsumer implements StreamConsumer<List<int>> {
  _RandomAccessConsumer(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(_file.writeFromSync);

  @override
  Future<void> close() => _file.close();
}
