import 'dart:typed_data';

import 'sketch_cache.dart';

/// Platforms with neither `dart:io` nor the browser: no persistent storage.
SketchCacheStore createDirectoryStore(String path, int maxBytes) =>
    throw UnsupportedError('SketchCacheStore.directory needs a file system.');

SketchCacheStore createDefaultStore(int maxBytes) => _NoStore();

class _NoStore implements SketchCacheStore {
  @override
  Future<Uint8List?> read(String key) async => null;
  @override
  Future<void> write(String key, Uint8List data) async {}
  @override
  Future<void> delete(String key) async {}
  @override
  Future<void> clear() async {}
}
