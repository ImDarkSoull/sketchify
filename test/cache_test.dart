import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

import 'support/art.dart';

Future<Uint8List> pixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return data!.buffer.asUint8List();
}

/// Largest difference between two images' straight RGBA, ignoring the colour
/// of fully transparent pixels.
Future<int> maxDifference(ui.Image a, ui.Image b) async {
  expect([a.width, a.height], [b.width, b.height]);
  final pa = await pixels(a), pb = await pixels(b);
  int worst = 0;
  for (int i = 0; i < pa.length; i += 4) {
    if (pa[i + 3] == 0 && pb[i + 3] == 0) continue;
    for (int c = 0; c < 4; c++) {
      final d = (pa[i + c] - pb[i + c]).abs();
      if (d > worst) worst = d;
    }
  }
  return worst;
}

/// Same result, apart from timing and where it came from.
Future<void> expectSameSketch(Sketch a, Sketch b, {int pixelTolerance = 0}) async {
  expect(b.size, a.size);
  expect(b.palette, a.palette);
  expect(b.removedBackground, a.removedBackground);
  expect(b.format, a.format);
  expect(b.shapes.length, a.shapes.length);
  for (int i = 0; i < a.shapes.length; i++) {
    expect(b.shapes[i].color, a.shapes[i].color);
    expect(b.shapes[i].path.getBounds(), a.shapes[i].path.getBounds());
  }
  expect(await maxDifference(a.image, b.image), lessThanOrEqualTo(pixelTolerance));
}

class _FailingStore implements SketchCacheStore {
  @override
  Future<Uint8List?> read(String key) => throw const FileSystemException('disk on fire');
  @override
  Future<void> write(String key, Uint8List data) => throw const FileSystemException('disk on fire');
  @override
  Future<void> delete(String key) => throw const FileSystemException('disk on fire');
  @override
  Future<void> clear() async {}
}

void main() {
  late SketchCache? previous;
  setUp(() {
    previous = Sketchify.cache;
    Sketchify.cache = SketchCache();
  });
  tearDown(() => Sketchify.cache = previous);

  testWidgets('tracing the same image again comes from the cache, identical and fast', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderPng(catSvg(), width: 1200);
      final first = await Sketchify.trace(bytes);
      expect(first.fromCache, isFalse);
      expect(first.removedBackground, isNotNull, reason: 'exercises the cut-out image path');
      await Sketchify.cache!.flush();
      expect(Sketchify.cache!.memoryEntries, 1);

      final second = await Sketchify.trace(bytes);
      expect(second.fromCache, isTrue);
      // The cut-out is stored as PNG: equal up to premultiplied rounding.
      await expectSameSketch(first, second, pixelTolerance: 2);
      expect(second.elapsed, lessThan(first.elapsed ~/ 2));

      // Each Sketch owns its image: disposing one leaves the other usable.
      first.dispose();
      expect(second.image.width, 1200);
      second.dispose();
    });
  });

  testWidgets('without a cut-out the cached final image is the exact original', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderPng(letteringSvg, width: 520);
      const options = SketchOptions(removeBackground: false);
      final first = await Sketchify.trace(bytes, options: options);
      await Sketchify.cache!.flush();
      final second = await Sketchify.trace(bytes, options: options);
      expect(second.fromCache, isTrue);
      await expectSameSketch(first, second);
      first.dispose();
      second.dispose();
    });
  });

  testWidgets('SVGs are cached too', (tester) async {
    await tester.runAsync(() async {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="#E91E63"/></svg>';
      final first = await Sketchify.traceSvgString(svg, options: const SketchOptions(svgRenderSize: 256));
      await Sketchify.cache!.flush();
      final second = await Sketchify.traceSvgString(svg, options: const SketchOptions(svgRenderSize: 256));
      expect(second.fromCache, isTrue);
      await expectSameSketch(first, second);
      first.dispose();
      second.dispose();
    });
  });

  testWidgets('different options, an edited image or useCache: false trace afresh', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderPng(letteringSvg, width: 520);
      (await Sketchify.trace(bytes)).dispose();
      await Sketchify.cache!.flush();

      final otherOptions = await Sketchify.trace(bytes, options: const SketchOptions(maxColors: 8));
      expect(otherOptions.fromCache, isFalse);

      final edited = Uint8List.fromList(await renderPng(letteringSvg, width: 521));
      final editedSketch = await Sketchify.trace(edited);
      expect(editedSketch.fromCache, isFalse);

      await Sketchify.cache!.flush();
      final entries = Sketchify.cache!.memoryEntries;
      final uncached = await Sketchify.trace(bytes, useCache: false);
      expect(uncached.fromCache, isFalse);
      await Sketchify.cache!.flush();
      expect(Sketchify.cache!.memoryEntries, entries, reason: 'useCache: false neither reads nor writes');

      for (final s in [otherOptions, editedSketch, uncached]) {
        s.dispose();
      }
    });
  });

  testWidgets('Sketchify.cache = null turns caching off', (tester) async {
    await tester.runAsync(() async {
      Sketchify.cache = null;
      final bytes = await renderPng(letteringSvg, width: 520);
      (await Sketchify.trace(bytes)).dispose();
      final again = await Sketchify.trace(bytes);
      expect(again.fromCache, isFalse);
      again.dispose();
    });
  });

  testWidgets('cacheKey names the image instead of hashing it', (tester) async {
    await tester.runAsync(() async {
      final a = await renderPng(letteringSvg, width: 520);
      final b = await renderPng(catSvg(), width: 300);
      (await Sketchify.trace(a, cacheKey: 'logo-v1')).dispose();
      await Sketchify.cache!.flush();
      // Same key: the cached result is used, whatever the bytes.
      final hit = await Sketchify.trace(b, cacheKey: 'logo-v1');
      expect(hit.fromCache, isTrue);
      expect(hit.shapes.length, 6);
      // A new key traces again.
      final miss = await Sketchify.trace(b, cacheKey: 'logo-v2');
      expect(miss.fromCache, isFalse);
      hit.dispose();
      miss.dispose();
    });
  });

  testWidgets('the memory cache stays within its size limit', (tester) async {
    await tester.runAsync(() async {
      final cache = Sketchify.cache = SketchCache(maxMemoryBytes: 64 * 1024);
      for (int w = 300; w < 340; w += 8) {
        (await Sketchify.trace(await renderPng(catSvg(), width: w))).dispose();
        await cache.flush();
        expect(cache.memoryBytes, lessThanOrEqualTo(64 * 1024));
      }
      expect(cache.memoryEntries, greaterThan(0));
      expect(cache.memoryEntries, lessThan(5), reason: 'older entries were dropped');
      cache.clearMemory();
      expect(cache.memoryBytes, 0);
    });
  });

  testWidgets('a directory store keeps results across app launches', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('sketchify_cache_test');
      addTearDown(() => dir.delete(recursive: true));
      final bytes = await renderPng(catSvg(), width: 600);

      Sketchify.cache = SketchCache(store: SketchCacheStore.directory(dir.path));
      final first = await Sketchify.trace(bytes);
      await Sketchify.cache!.flush();
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.sketch')).toList();
      expect(files.length, 1);

      // A new cache object over the same directory: like a fresh app launch.
      Sketchify.cache = SketchCache(store: SketchCacheStore.directory(dir.path));
      final relaunched = await Sketchify.trace(bytes);
      expect(relaunched.fromCache, isTrue);
      await expectSameSketch(first, relaunched, pixelTolerance: 2);

      // A corrupted file is ignored, traced afresh and replaced.
      files.single.writeAsBytesSync([1, 2, 3]);
      Sketchify.cache = SketchCache(store: SketchCacheStore.directory(dir.path));
      final retraced = await Sketchify.trace(bytes);
      expect(retraced.fromCache, isFalse);
      await Sketchify.cache!.flush();
      Sketchify.cache = SketchCache(store: SketchCacheStore.directory(dir.path));
      final repaired = await Sketchify.trace(bytes);
      expect(repaired.fromCache, isTrue);

      await Sketchify.cache!.clear();
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.sketch')), isEmpty);
      for (final s in [first, relaunched, retraced, repaired]) {
        s.dispose();
      }
    });
  });

  testWidgets('the directory store keeps within its disk limit', (tester) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('sketchify_cache_limit');
      addTearDown(() => dir.delete(recursive: true));
      final cache = Sketchify.cache = SketchCache(
        maxMemoryBytes: 0,
        store: SketchCacheStore.directory(dir.path, maxBytes: 80 * 1024),
      );
      for (int w = 300; w < 340; w += 8) {
        (await Sketchify.trace(await renderPng(catSvg(), width: w))).dispose();
        await cache.flush();
      }
      final total = dir.listSync().whereType<File>().fold<int>(0, (sum, f) => sum + f.lengthSync());
      expect(total, lessThanOrEqualTo(80 * 1024));
      expect(total, greaterThan(0));
    });
  });

  testWidgets('a failing store never breaks tracing', (tester) async {
    await tester.runAsync(() async {
      Sketchify.cache = SketchCache(maxMemoryBytes: 0, store: _FailingStore());
      final bytes = await renderPng(letteringSvg, width: 520);
      final a = await Sketchify.trace(bytes);
      await Sketchify.cache!.flush();
      final b = await Sketchify.trace(bytes);
      expect([a.fromCache, b.fromCache], [false, false]);
      expect(b.shapes.length, 6);
      a.dispose();
      b.dispose();
    });
  });

  testWidgets('disposing a sketch straight away does not stop it being cached', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderPng(catSvg(), width: 600);
      (await Sketchify.trace(bytes)).dispose(); // before the PNG is encoded
      await Sketchify.cache!.flush();
      final again = await Sketchify.trace(bytes);
      expect(again.fromCache, isTrue);
      expect(await pixels(again.image), isNotEmpty);
      again.dispose();
    });
  });
}
