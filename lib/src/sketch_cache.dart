/// @docImport 'sketchify.dart';
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'cache_store_stub.dart'
    if (dart.library.io) 'cache_store_io.dart'
    if (dart.library.js_interop) 'cache_store_web.dart';
import 'sketch_options.dart';

/// Bump when the tracer's output changes, so old cached results are ignored.
const int _traceVersion = 1;

/// Keeps traced results so the same image never has to be traced twice.
///
/// [Sketchify.trace] uses [Sketchify.cache]. By default that keeps results
/// in memory and in [SketchCacheStore.platformDefault], so they survive app
/// restarts until the app's cache or data is cleared.
///
/// Entries are keyed by the image's contents and the [SketchOptions], so an
/// edited image or different options are traced afresh. The cache holds the
/// traced outlines and a compressed copy of a cut-out final image, never
/// decoded images, so [Sketch.dispose] still frees memory.
class SketchCache {
  /// Creates a cache that keeps up to [maxMemoryBytes] of results in memory,
  /// backed by an optional persistent [store]. Without a store, results last
  /// only until the app stops; use [SketchCacheStore.platformDefault] to
  /// keep them across restarts.
  SketchCache({this.maxMemoryBytes = 32 * 1024 * 1024, this.store})
    : assert(maxMemoryBytes >= 0, 'maxMemoryBytes must not be negative');

  /// Most bytes of results kept in memory. The least recently used are
  /// dropped first. 0 keeps nothing in memory (only in [store]).
  final int maxMemoryBytes;

  /// Where results are kept between app launches, if anywhere.
  final SketchCacheStore? store;

  final LinkedHashMap<String, Uint8List> _memory = LinkedHashMap();
  int _memoryBytes = 0;
  final Set<Future<void>> _pending = {};

  /// Number of results held in memory.
  int get memoryEntries => _memory.length;

  /// Bytes of results held in memory.
  int get memoryBytes => _memoryBytes;

  /// Forgets everything held in memory. The [store] is left alone.
  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }

  /// Forgets everything, in memory and in the [store].
  Future<void> clear() async {
    await flush();
    clearMemory();
    await store?.clear();
  }

  /// Completes when results that are still being saved have been saved.
  /// Saving happens in the background after [Sketchify.trace] returns.
  Future<void> flush() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  Future<Uint8List?> _read(String key) async {
    final Uint8List? hit = _memory.remove(key);
    if (hit != null) {
      _memory[key] = hit; // most recently used
      return hit;
    }
    final SketchCacheStore? s = store;
    if (s == null) return null;
    try {
      final Uint8List? data = await s.read(key);
      if (data != null) _remember(key, data);
      return data;
    } catch (e) {
      debugPrint('sketchify: could not read the sketch cache: $e');
      return null; // a broken store is just a miss
    }
  }

  void _remember(String key, Uint8List data) {
    final Uint8List? old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    if (data.length > maxMemoryBytes) return;
    _memory[key] = data;
    _memoryBytes += data.length;
    while (_memoryBytes > maxMemoryBytes && _memory.isNotEmpty) {
      final String oldest = _memory.keys.first;
      _memoryBytes -= _memory.remove(oldest)!.length;
    }
  }

  void _write(String key, Future<Uint8List?> Function() produce) {
    late final Future<void> job;
    job = () async {
      try {
        final Uint8List? data = await produce();
        if (data == null) return;
        _remember(key, data);
        await store?.write(key, data);
      } catch (e) {
        // Caching is best effort; tracing already succeeded.
        debugPrint('sketchify: could not cache a traced image: $e');
      } finally {
        _pending.remove(job);
      }
    }();
    _pending.add(job);
  }

  Future<void> _remove(String key) async {
    final Uint8List? old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    try {
      await store?.delete(key);
    } catch (_) {}
  }
}

/// Persistent storage for [SketchCache]: a simple key → bytes store.
///
/// Implement it to keep results somewhere of your own (a database, or
/// IndexedDB on the web). Keys are short strings of letters, digits and
/// underscores. Errors thrown by a store are treated as cache misses.
abstract interface class SketchCacheStore {
  /// The app's own persistent storage, ready to use with no setup:
  ///
  /// * Android, iOS, macOS, Windows and Linux: files in
  ///   `<app cache directory>/sketchify` (from `path_provider`). They stay
  ///   until the app's cache or data is cleared; on iOS and macOS the system
  ///   may also clear app caches when storage runs very low.
  /// * Web: the browser's IndexedDB, until the site's data is cleared.
  ///
  /// At most [maxBytes] are used; the least recently used results go first.
  factory SketchCacheStore.platformDefault({int maxBytes = 100 * 1024 * 1024}) => createDefaultStore(maxBytes);

  /// Keeps each result as a file in the directory at [path] (created when
  /// needed), using at most [maxBytes] of disk; the least recently used
  /// files are deleted first.
  ///
  /// Use it to choose the directory yourself, for example the app support
  /// directory, which the system never clears on its own. Not available on
  /// the web, which has no file system; use [platformDefault] there.
  factory SketchCacheStore.directory(String path, {int maxBytes = 100 * 1024 * 1024}) =>
      createDirectoryStore(path, maxBytes);

  /// The bytes stored under [key], or null if there are none.
  Future<Uint8List?> read(String key);

  /// Stores [data] under [key], replacing what was there.
  Future<void> write(String key, Uint8List data);

  /// Removes what is stored under [key], if anything.
  Future<void> delete(String key);

  /// Removes everything.
  Future<void> clear();
}

// ── Package-internal access (not exported) ────────────────────────────────

Future<Uint8List?> cacheRead(SketchCache cache, String key) => cache._read(key);

void cacheWrite(SketchCache cache, String key, Future<Uint8List?> Function() produce) => cache._write(key, produce);

Future<void> cacheRemove(SketchCache cache, String key) => cache._remove(key);

/// The cache key for an image: its contents (or [customKey]) plus every
/// option that changes the result.
String cacheKeyFor(Uint8List bytes, SketchOptions options, String? customKey) {
  final String id = customKey == null
      ? 'b${_hashHex(bytes)}${bytes.length.toRadixString(16)}'
      : 'k${_hashHex(Uint8List.fromList(utf8.encode(customKey)))}';
  final String settings = _hashHex(Uint8List.fromList(utf8.encode(options.toString())));
  return 'v${_traceVersion}_${id}_$settings';
}

/// 32-bit multiply that gives the same result on native and web.
int _mul32(int a, int b) => (((a & 0xFFFF) * b) + ((((a >>> 16) * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;

/// 64 bits of hash as 16 hex digits: FNV-1a and a murmur-style mix.
String _hashHex(Uint8List data) {
  int h1 = 0x811C9DC5, h2 = 0x9747B28C;
  for (int i = 0; i < data.length; i++) {
    final int b = data[i];
    h1 = _mul32(h1 ^ b, 0x01000193);
    h2 = _mul32(h2 ^ b, 0x5BD1E995);
    h2 = (h2 ^ (h2 >>> 15)) & 0xFFFFFFFF;
  }
  return h1.toRadixString(16).padLeft(8, '0') + h2.toRadixString(16).padLeft(8, '0');
}

/// A traced result in plain data, ready to store.
class CachedTrace {
  final int width;
  final int height;
  final List<int> palette;
  final int? backgroundColor;
  final List<int> shapeColors;
  final List<Float32List> shapeCommands;

  /// PNG of the final image when a background was cut out; otherwise null
  /// and the final image is decoded from the original bytes.
  final Uint8List? cutoutPng;

  const CachedTrace({
    required this.width,
    required this.height,
    required this.palette,
    required this.backgroundColor,
    required this.shapeColors,
    required this.shapeCommands,
    required this.cutoutPng,
  });
}

const int _magic = 0x48434B53; // 'SKCH'

Uint8List encodeTrace(CachedTrace t) {
  // Nine u32 fields: magic, version, width, height, has-background,
  // background, palette length, shape count and PNG length.
  int size = 4 * 9 + t.palette.length * 4 + (t.cutoutPng?.length ?? 0);
  for (final Float32List c in t.shapeCommands) {
    size += 8 + c.length * 4;
  }
  final ByteData d = ByteData(size);
  int o = 0;
  void u32(int v) {
    d.setUint32(o, v, Endian.little);
    o += 4;
  }

  u32(_magic);
  u32(_traceVersion);
  u32(t.width);
  u32(t.height);
  u32(t.backgroundColor == null ? 0 : 1);
  u32(t.backgroundColor ?? 0);
  u32(t.palette.length);
  t.palette.forEach(u32);
  u32(t.shapeColors.length);
  for (int i = 0; i < t.shapeColors.length; i++) {
    u32(t.shapeColors[i]);
    final Float32List c = t.shapeCommands[i];
    u32(c.length);
    for (int j = 0; j < c.length; j++) {
      d.setFloat32(o, c[j], Endian.little);
      o += 4;
    }
  }
  final Uint8List? png = t.cutoutPng;
  u32(png?.length ?? 0);
  final Uint8List out = d.buffer.asUint8List();
  if (png != null) out.setRange(o, o + png.length, png);
  return out;
}

/// Reads [encodeTrace] output. Throws [FormatException] if it isn't valid.
CachedTrace decodeTrace(Uint8List data) {
  try {
    final ByteData d = ByteData.sublistView(data);
    int o = 0;
    int u32() {
      final int v = d.getUint32(o, Endian.little);
      o += 4;
      return v;
    }

    if (u32() != _magic || u32() != _traceVersion) throw const FormatException('Not a current sketch cache entry');
    final int width = u32(), height = u32();
    final bool hasBg = u32() == 1;
    final int bg = u32();
    final List<int> palette = List<int>.generate(u32(), (_) => u32());
    final int shapeCount = u32();
    final List<int> colors = [];
    final List<Float32List> commands = [];
    for (int i = 0; i < shapeCount; i++) {
      colors.add(u32());
      final Float32List c = Float32List(u32());
      for (int j = 0; j < c.length; j++) {
        c[j] = d.getFloat32(o, Endian.little);
        o += 4;
      }
      commands.add(c);
    }
    final int pngLength = u32();
    if (o + pngLength != data.length) throw const FormatException('Truncated sketch cache entry');
    return CachedTrace(
      width: width,
      height: height,
      palette: palette,
      backgroundColor: hasBg ? bg : null,
      shapeColors: colors,
      shapeCommands: commands,
      cutoutPng: pngLength == 0 ? null : Uint8List.sublistView(data, o, o + pngLength),
    );
  } on RangeError {
    throw const FormatException('Truncated sketch cache entry');
  }
}
