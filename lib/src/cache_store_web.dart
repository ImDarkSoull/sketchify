import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'sketch_cache.dart';

SketchCacheStore createDirectoryStore(String path, int maxBytes) => throw UnsupportedError(
  'SketchCacheStore.directory needs a file system, which the web does not have. '
  'SketchCacheStore.platformDefault() keeps results in IndexedDB instead.',
);

SketchCacheStore createDefaultStore(int maxBytes) => IndexedDbStore(maxBytes);

/// Keeps results in the browser's IndexedDB, until the site's data is
/// cleared. Each result is one record in `traces`; `meta` holds its size and
/// when it was last used, so the size limit drops the least recently used.
class IndexedDbStore implements SketchCacheStore {
  IndexedDbStore(this._maxBytes, {String databaseName = 'sketchify'}) : _name = databaseName;

  static const String _data = 'traces';
  static const String _meta = 'meta';
  final int _maxBytes;
  final String _name;
  Future<web.IDBDatabase>? _db;

  Future<web.IDBDatabase> _open() => _db ??= () {
    final Completer<web.IDBDatabase> done = Completer();
    final web.IDBOpenDBRequest request = web.window.indexedDB.open(_name, 1);
    request.onupgradeneeded = (web.Event _) {
      final web.IDBDatabase db = request.result as web.IDBDatabase;
      db.createObjectStore(_data);
      db.createObjectStore(_meta);
    }.toJS;
    request.onsuccess = (web.Event _) {
      done.complete(request.result as web.IDBDatabase);
    }.toJS;
    request.onerror = (web.Event _) {
      done.completeError(StateError('IndexedDB unavailable: ${request.error?.message}'));
    }.toJS;
    return done.future;
  }();

  static Future<JSAny?> _result(web.IDBRequest request) {
    final Completer<JSAny?> done = Completer();
    request.onsuccess = (web.Event _) {
      done.complete(request.result);
    }.toJS;
    request.onerror = (web.Event _) {
      done.completeError(StateError('IndexedDB: ${request.error?.message}'));
    }.toJS;
    return done.future;
  }

  static Future<void> _committed(web.IDBTransaction tx) {
    final Completer<void> done = Completer();
    tx.oncomplete = (web.Event _) {
      done.complete();
    }.toJS;
    tx.onerror = (web.Event _) {
      if (!done.isCompleted) done.completeError(StateError('IndexedDB: ${tx.error?.message}'));
    }.toJS;
    tx.onabort = (web.Event _) {
      if (!done.isCompleted) done.completeError(StateError('IndexedDB transaction aborted'));
    }.toJS;
    return done.future;
  }

  static JSObject _metaRecord(int size) => JSObject()
    ..['s'] = size.toJS
    ..['t'] = DateTime.now().millisecondsSinceEpoch.toJS;

  web.IDBTransaction _both(web.IDBDatabase db) => db.transaction([_data.toJS, _meta.toJS].toJS, 'readwrite');

  @override
  Future<Uint8List?> read(String key) async {
    final web.IDBDatabase db = await _open();
    final JSAny? value = await _result(db.transaction(_data.toJS, 'readonly').objectStore(_data).get(key.toJS));
    if (value == null) return null;
    final Uint8List data = (value as JSUint8Array).toDart;
    // Mark as recently used; failing that only affects what is dropped first.
    final web.IDBTransaction touch = db.transaction(_meta.toJS, 'readwrite');
    touch.objectStore(_meta).put(_metaRecord(data.length), key.toJS);
    unawaited(_committed(touch).catchError((Object _) {}));
    return data;
  }

  @override
  Future<void> write(String key, Uint8List data) async {
    if (data.length > _maxBytes) return;
    final web.IDBDatabase db = await _open();
    final web.IDBTransaction tx = _both(db);
    tx.objectStore(_data).put(data.toJS, key.toJS);
    tx.objectStore(_meta).put(_metaRecord(data.length), key.toJS);
    await _committed(tx);
    await _trim(db);
  }

  @override
  Future<void> delete(String key) async {
    final web.IDBDatabase db = await _open();
    final web.IDBTransaction tx = _both(db);
    tx.objectStore(_data).delete(key.toJS);
    tx.objectStore(_meta).delete(key.toJS);
    await _committed(tx);
  }

  @override
  Future<void> clear() async {
    final web.IDBDatabase db = await _open();
    final web.IDBTransaction tx = _both(db);
    tx.objectStore(_data).clear();
    tx.objectStore(_meta).clear();
    await _committed(tx);
  }

  /// Drops the least recently used results until within [_maxBytes].
  Future<void> _trim(web.IDBDatabase db) async {
    final List<(String key, int size, int used)> entries = [];
    final Completer<void> listed = Completer();
    final web.IDBRequest cursorRequest = db.transaction(_meta.toJS, 'readonly').objectStore(_meta).openCursor();
    cursorRequest.onsuccess = (web.Event _) {
      final web.IDBCursorWithValue? cursor = cursorRequest.result as web.IDBCursorWithValue?;
      if (cursor == null) {
        listed.complete();
        return;
      }
      final JSObject meta = cursor.value as JSObject;
      entries.add((
        (cursor.key as JSString).toDart,
        (meta['s'] as JSNumber).toDartInt,
        (meta['t'] as JSNumber).toDartInt,
      ));
      cursor.continue_();
    }.toJS;
    cursorRequest.onerror = (web.Event _) {
      listed.completeError(StateError('IndexedDB: ${cursorRequest.error?.message}'));
    }.toJS;
    await listed.future;

    int total = entries.fold(0, (sum, e) => sum + e.$2);
    if (total <= _maxBytes) return;
    entries.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (String key, int size, int _) in entries) {
      if (total <= _maxBytes) break;
      await delete(key);
      total -= size;
    }
  }
}
