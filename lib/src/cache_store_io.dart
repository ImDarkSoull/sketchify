import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'sketch_cache.dart';

SketchCacheStore createDirectoryStore(String path, int maxBytes) => _DirectoryStore(Directory(path), maxBytes);

SketchCacheStore createDefaultStore(int maxBytes) => _AppCacheStore(maxBytes);

/// A [_DirectoryStore] in `<app cache directory>/sketchify`, found on first
/// use. Lasts until the app's cache or data is cleared (or, on iOS and
/// macOS, until the system frees space when storage runs low).
class _AppCacheStore implements SketchCacheStore {
  _AppCacheStore(this._maxBytes);

  final int _maxBytes;
  SketchCacheStore? _store;
  static bool _warned = false;

  Future<SketchCacheStore?> _get() async {
    if (_store != null) return _store;
    try {
      final Directory dir = await getApplicationCacheDirectory();
      return _store = _DirectoryStore(Directory('${dir.path}${Platform.pathSeparator}sketchify'), _maxBytes);
    } catch (e) {
      // E.g. called before the binding is ready, or in a unit test without
      // plugins. Tried again next time; meanwhile memory caching still works.
      if (!_warned) {
        _warned = true;
        debugPrint('sketchify: no app cache directory yet ($e); caching in memory only for now.');
      }
      return null;
    }
  }

  @override
  Future<Uint8List?> read(String key) async => (await _get())?.read(key);

  @override
  Future<void> write(String key, Uint8List data) async => (await _get())?.write(key, data);

  @override
  Future<void> delete(String key) async => (await _get())?.delete(key);

  @override
  Future<void> clear() async => (await _get())?.clear();
}

/// One file per result. Reading a file marks it as recently used, so the
/// size limit deletes the least recently used first.
class _DirectoryStore implements SketchCacheStore {
  _DirectoryStore(this._dir, this._maxBytes);

  static const String _ext = '.sketch';
  final Directory _dir;
  final int _maxBytes;
  final math.Random _random = math.Random();

  File _file(String key) => File('${_dir.path}${Platform.pathSeparator}$key$_ext');

  @override
  Future<Uint8List?> read(String key) async {
    final File file = _file(key);
    if (!await file.exists()) return null;
    final Uint8List data = await file.readAsBytes();
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {} // only affects which files are deleted first
    return data;
  }

  @override
  Future<void> write(String key, Uint8List data) async {
    if (data.length > _maxBytes) return;
    await _dir.create(recursive: true);
    // Write to a temporary file, then rename, so a crash never leaves half
    // a file under the real name.
    final File tmp = File('${_file(key).path}.${_random.nextInt(1 << 32)}.tmp');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(_file(key).path);
    await _trim();
  }

  @override
  Future<void> delete(String key) async {
    final File file = _file(key);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> clear() async {
    for (final File f in await _entries()) {
      await f.delete();
    }
  }

  Future<List<File>> _entries() async {
    if (!await _dir.exists()) return [];
    return [
      await for (final FileSystemEntity e in _dir.list())
        if (e is File && e.path.endsWith(_ext)) e,
    ];
  }

  Future<void> _trim() async {
    final List<(File, FileStat)> files = [for (final File f in await _entries()) (f, await f.stat())];
    int total = files.fold(0, (sum, e) => sum + e.$2.size);
    if (total <= _maxBytes) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (File f, FileStat st) in files) {
      if (total <= _maxBytes) break;
      try {
        await f.delete();
        total -= st.size;
      } catch (_) {}
    }
  }
}
