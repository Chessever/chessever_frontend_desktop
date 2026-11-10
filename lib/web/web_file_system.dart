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
  static const Duration _longestFlushDelay = Duration(seconds: 5);

  /// How long the last save held the page's thread. A database being
  /// imported into is rewritten all over, so each save copies most of it;
  /// the wait before the next one grows with that cost, to keep saving a
  /// small share of the work instead of a pause every 400 ms.
  Duration _lastFlushCost = Duration.zero;

  /// Scratch files: the system temp folder and the `.build-<time>` files and
  /// folders the opening-tree builders write beside a database and delete or
  /// rename when done. They are never saved; one renamed to a lasting name
  /// is saved under that name.
  static final RegExp _buildScratch = RegExp(r'\.build-\d+');

  static bool _isScratch(String key) =>
      key.startsWith('/tmp/') || _buildScratch.hasMatch(key);

  final Map<String, _Node> _nodes = {'/': _Node.directory()};
  final Set<String> _dirty = {};
  /// Removed paths and how many chunk records each had in IndexedDB.
  final Map<String, int> _deleted = {};

  /// Files persist as 256 KB chunks, so a small write (an SQLite page) saves
  /// only the chunk it touched instead of the whole file.
  static const int _chunkSize = 256 * 1024;

  static String _chunkKey(String path, int index) => '$path\u0000$index';
  web.IDBDatabase? _db;
  Timer? _flushTimer;

  /// Opens IndexedDB, loads every stored entry and installs the overrides.
  static Future<void> mount() async {
    final fs = instance;
    try {
      fs._db = await _openDatabase();
      await fs._loadAll();
    } catch (e) {
      // Private windows can refuse IndexedDB; files then last for the tab.
      // ignore: avoid_print
      print('[web] file storage unavailable, keeping files in memory: $e');
      fs._db = null;
    }
    for (final dir in WebPathProvider.folders) {
      fs._mkdirs(dir);
    }
    IOOverrides.global = _WebIOOverrides();
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'hidden') fs._flushNow();
      }).toJS,
    );
  }

  static String normalize(String path) {
    final absolute = path.startsWith('/') ? path : '/home/chessever/$path';
    final normalized = p.posix.normalize(absolute);
    return normalized.isEmpty ? '/' : normalized;
  }

  _Node? _nodeAt(String path) => _nodes[normalize(path)];

  // Byte-level access for the SQLite VFS (shims/local_sqlite_web.dart), so
  // database files live in this filesystem like any other file.

  bool fileExists(String path) => !(_nodeAt(path)?.isDirectory ?? true);

  void ensureFile(String path) => _createFile(path, recursive: true);

  void deleteFile(String path) {
    if (fileExists(path)) delete(path);
  }

  /// An open file, resolved once. SQLite reads and writes a page at a time,
  /// so going back through the path for each call would cost more than the
  /// copy itself. Like a POSIX descriptor it keeps addressing the same file
  /// after the path is renamed or deleted.
  WebFileHandle openFile(String path) {
    final key = normalize(path);
    return WebFileHandle._(this, key, _createFile(key, recursive: true));
  }

  /// Identifies the file now at [path], or null when there is none. A path
  /// that was deleted and created again gives a different identity.
  Object? fileIdentity(String path) {
    final n = _nodeAt(path);
    return n == null || n.isDirectory ? null : n;
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
    final children =
        n.isDirectory
            ? _childrenOf(key, recursive: true).toList()
            : const <String>[];
    if (n.isDirectory && children.isNotEmpty && !recursive) {
      throw FileSystemException('Directory not empty', path);
    }
    for (final child in children) {
      _markDeleted(child, _nodes.remove(child));
    }
    _markDeleted(key, _nodes.remove(key));
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
      _markDeleted(child, _nodes.remove(child));
    }
    _markDeleted(source, _nodes.remove(source));
    for (final entry in moves.entries) {
      _nodes[entry.key] = entry.value..markAllDirty();
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

  /// Called with each path whose contents or metadata change, so a file
  /// linked to one on the user's disk can be written back there.
  void Function(String path)? onFileChanged;

  void _markDirty(String key) {
    if (!_isScratch(key)) {
      _dirty.add(key);
      _scheduleFlush();
    }
    onFileChanged?.call(key);
  }

  /// [removed] gives the chunk records the path had; they move with it on a
  /// rename, so the node then starts again from no stored chunks.
  void _markDeleted(String key, _Node? removed) {
    _dirty.remove(key);
    final stored = removed?.storedChunks ?? 0;
    if (stored == 0 && _isScratch(key)) return;
    _deleted[key] = (_deleted[key] ?? 0) > stored ? _deleted[key]! : stored;
    removed?.storedChunks = 0;
    _scheduleFlush();
  }

  /// SQLite transactions in progress (shims/local_sqlite_web.dart). Nothing
  /// is saved while one is open, so IndexedDB never holds a database caught
  /// between two of a transaction's page writes.
  int _saveHolds = 0;

  void holdSaves() => _saveHolds++;

  void releaseSaves() {
    if (_saveHolds > 0) _saveHolds--;
    if (_saveHolds == 0 && (_dirty.isNotEmpty || _deleted.isNotEmpty)) {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    if (_db == null) return;
    final wait = _lastFlushCost * 15;
    _flushTimer ??= Timer(
      wait < _flushDelay
          ? _flushDelay
          : (wait > _longestFlushDelay ? _longestFlushDelay : wait),
      () {
        _flushTimer = null;
        unawaited(_flush());
      },
    );
  }

  /// Saves what is pending without waiting for the timer: the page is being
  /// hidden, which is the last moment a tab is sure to get before it closes.
  void _flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    unawaited(_flush());
  }

  Future<void> _flush() async {
    final db = _db;
    if (db == null || (_dirty.isEmpty && _deleted.isEmpty)) return;
    // releaseSaves() schedules the next attempt.
    if (_saveHolds > 0) return;
    final cost = Stopwatch()..start();
    final writes = _dirty.toList();
    final deletes = Map.of(_deleted);
    _dirty.clear();
    _deleted.clear();
    final tx = db.transaction(_store.toJS, 'readwrite');
    final store = tx.objectStore(_store);
    deletes.forEach((key, chunks) {
      if (_nodes.containsKey(key) && !writes.contains(key)) return;
      store.delete(key.toJS);
      for (var i = 0; i < chunks; i++) {
        store.delete(_chunkKey(key, i).toJS);
      }
    });
    for (final key in writes) {
      final n = _nodes[key];
      if (n == null) continue;
      final previous = deletes[key] ?? 0;
      if (previous > n.storedChunks) n.storedChunks = previous;
      store.put(n.metaJs(), key.toJS);
      if (n.isDirectory) continue;
      final count = (n.length + _chunkSize - 1) ~/ _chunkSize;
      final indices =
          n.allDirty
              ? List<int>.generate(count, (i) => i)
              : (n.dirtyChunks.where((i) => i < count).toList()..sort());
      for (final i in indices) {
        final start = i * _chunkSize;
        final end = start + _chunkSize > n.length ? n.length : start + _chunkSize;
        store.put(
          Uint8List.fromList(
            Uint8List.sublistView(n._buffer, start, end),
          ).toJS,
          _chunkKey(key, i).toJS,
        );
      }
      for (var i = count; i < n.storedChunks; i++) {
        store.delete(_chunkKey(key, i).toJS);
      }
      n
        ..storedChunks = count
        ..allDirty = false
        ..dirtyChunks.clear();
    }
    _lastFlushCost = cost.elapsed;
    if (await _complete(tx)) return;
    // Nothing of a failed transaction is stored (the browser's quota for the
    // site is the usual cause). Keep the files marked so that a later save
    // writes them whole, rather than believing they are stored.
    for (final key in writes) {
      final n = _nodes[key];
      if (n == null) continue;
      n.markAllDirty();
      _dirty.add(key);
    }
    deletes.forEach((key, chunks) {
      if ((_deleted[key] ?? 0) < chunks) _deleted[key] = chunks;
    });
    if (!_reportedSaveFailure) {
      _reportedSaveFailure = true;
      // ignore: avoid_print
      print('[web] could not save files to browser storage; '
          'changes last until the page is closed');
    }
  }

  bool _reportedSaveFailure = false;

  Future<void> _loadAll() async {
    final db = _db!;
    final tx = db.transaction(_store.toJS, 'readonly');
    final store = tx.objectStore(_store);
    final keys = await _request<JSArray<JSAny?>>(store.getAllKeys());
    final values = await _request<JSArray<JSAny?>>(store.getAll());
    final keyList = keys.toDart;
    final valueList = values.toDart;
    final chunks = <String, Map<int, Uint8List>>{};
    for (var i = 0; i < keyList.length; i++) {
      final key = (keyList[i] as JSString).toDart;
      final value = valueList[i];
      if (value == null) continue;
      final split = key.indexOf('\u0000');
      if (split < 0) {
        _nodes[key] = _Node.fromMetaJs(value as JSObject);
      } else {
        (chunks[key.substring(0, split)] ??= {})[int.parse(
              key.substring(split + 1),
            )] =
            (value as JSUint8Array).toDart;
      }
    }
    for (final entry in chunks.entries) {
      final node = _nodes[entry.key];
      if (node == null || node.isDirectory) continue;
      node.loadChunks(entry.value, _chunkSize);
    }
    // Scratch files an earlier version saved, or a build the last visit
    // left unfinished.
    for (final key in _nodes.keys.where(_isScratch).toList()) {
      _deleted[key] = _nodes.remove(key)?.storedChunks ?? 0;
    }
    if (_deleted.isNotEmpty) _scheduleFlush();
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

  /// Whether the transaction committed.
  static Future<bool> _complete(web.IDBTransaction tx) {
    final completer = Completer<bool>();
    void finish(bool committed) {
      if (!completer.isCompleted) completer.complete(committed);
    }

    tx.oncomplete = ((web.Event _) => finish(true)).toJS;
    tx.onerror = ((web.Event _) => finish(false)).toJS;
    tx.onabort = ((web.Event _) => finish(false)).toJS;
    return completer.future;
  }
}

/// See [WebFileSystem.openFile].
final class WebFileHandle {
  WebFileHandle._(this._fs, this._key, this._node);

  final WebFileSystem _fs;
  final String _key;
  final _Node _node;

  int get length => _node.length;

  int readInto(Uint8List buffer, int offset) {
    final available = _node.length - offset;
    if (available <= 0) return 0;
    final count = buffer.length < available ? buffer.length : available;
    buffer.setRange(0, count, _node._buffer, offset);
    return count;
  }

  void writeAt(Uint8List data, int offset) {
    _node.writeAt(offset, data);
    _changed();
  }

  void truncate(int size) {
    _node.truncate(size);
    _changed();
  }

  /// A file that was renamed or deleted while open is saved under its new
  /// path by the rename, or not at all.
  void _changed() {
    if (identical(_fs._nodes[_key], _node)) _fs._markDirty(_key);
  }
}

class _Node {
  _Node.directory() : isDirectory = true, modified = DateTime.now();
  _Node.file() : isDirectory = false, modified = DateTime.now();

  final bool isDirectory;
  DateTime modified;
  Uint8List _buffer = Uint8List(0);
  int length = 0;

  /// Persistence bookkeeping: chunks changed since the last flush (or all of
  /// them), and how many chunk records IndexedDB holds for this node.
  bool allDirty = true;
  final Set<int> dirtyChunks = {};
  int storedChunks = 0;

  void markAllDirty() => allDirty = true;

  void _markRange(int start, int end) {
    if (allDirty || end <= start) return;
    const size = WebFileSystem._chunkSize;
    for (var i = start ~/ size; i <= (end - 1) ~/ size; i++) {
      dirtyChunks.add(i);
    }
  }

  Uint8List get bytes => Uint8List.sublistView(_buffer, 0, length);

  void setBytes(List<int> data) {
    _buffer = Uint8List.fromList(data);
    length = _buffer.length;
    modified = DateTime.now();
    allDirty = true;
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
    final previousLength = length;
    if (position + count > length) length = position + count;
    _markRange(
      position < previousLength ? position : previousLength,
      position + count,
    );
    modified = DateTime.now();
  }

  void truncate(int size) {
    if (size > length) {
      ensureCapacity(size);
      _buffer.fillRange(length, size, 0);
      _markRange(length, size);
    } else if (size > 0) {
      _markRange(size - 1, size);
    }
    length = size;
    modified = DateTime.now();
  }

  void loadChunks(Map<int, Uint8List> chunks, int chunkSize) {
    _buffer = Uint8List(length);
    chunks.forEach((index, data) {
      final start = index * chunkSize;
      final end = start + data.length > length ? length : start + data.length;
      if (start < end) _buffer.setRange(start, end, data);
    });
    storedChunks = (length + chunkSize - 1) ~/ chunkSize;
    allDirty = false;
  }

  JSObject metaJs() {
    final object = JSObject();
    object['dir'] = isDirectory.toJS;
    object['mtime'] = modified.millisecondsSinceEpoch.toJS;
    object['length'] = length.toJS;
    return object;
  }

  static _Node fromMetaJs(JSObject object) {
    final isDir = (object['dir'] as JSBoolean?)?.toDart ?? false;
    final n = isDir ? _Node.directory() : _Node.file();
    final mtime = (object['mtime'] as JSNumber?)?.toDartInt;
    if (mtime != null) {
      n.modified = DateTime.fromMillisecondsSinceEpoch(mtime);
    }
    n
      ..length = (object['length'] as JSNumber?)?.toDartInt ?? 0
      ..allDirty = false;
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
        Uint8List.sublistView(bytes, i, i + chunk > to ? to : i + chunk),
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
    final out = Uint8List(end - start)
      ..setRange(0, end - start, _node._buffer, start);
    _position = end;
    return out;
  }

  @override
  Future<int> readByte() async => readByteSync();

  @override
  int readByteSync() {
    if (_position >= _node.length) return -1;
    return _node._buffer[_position++];
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
