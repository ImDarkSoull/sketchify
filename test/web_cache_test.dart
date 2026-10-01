@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

const String svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
    '<rect width="10" height="10" fill="#22223B"/><circle cx="5" cy="5" r="3" fill="#E91E63"/></svg>';

void main() {
  setUp(() => SketchCacheStore.platformDefault().clear());

  testWidgets('on the web, traced images stay cached in IndexedDB across reloads', (tester) async {
    await tester.runAsync(() async {
      const options = SketchOptions(svgRenderSize: 256);
      final first = await Sketchify.traceSvgString(svg, options: options);
      expect(first.fromCache, isFalse);
      await Sketchify.cache!.flush();

      // A page reload: memory is gone, IndexedDB is not.
      final previous = Sketchify.cache;
      Sketchify.cache = SketchCache(store: SketchCacheStore.platformDefault());
      addTearDown(() => Sketchify.cache = previous);
      final afterReload = await Sketchify.traceSvgString(svg, options: options);
      expect(afterReload.fromCache, isTrue);
      expect(afterReload.shapes.length, first.shapes.length);
      expect(afterReload.removedBackground, first.removedBackground);

      await Sketchify.cache!.clear();
      Sketchify.cache = SketchCache(store: SketchCacheStore.platformDefault());
      final afterClear = await Sketchify.traceSvgString(svg, options: options);
      expect(afterClear.fromCache, isFalse);
    });
  });

  testWidgets('the IndexedDB store reads, deletes and keeps within its limit', (tester) async {
    await tester.runAsync(() async {
      final store = SketchCacheStore.platformDefault(maxBytes: 10000);
      Uint8List blob(int fill) => Uint8List(4000)..fillRange(0, 4000, fill);
      expect(await store.read('missing'), isNull);
      for (final key in ['a', 'b', 'c']) {
        await store.write(key, blob(key.codeUnitAt(0)));
        await Future<void>.delayed(const Duration(milliseconds: 5)); // distinct "last used" times
      }
      // 12000 bytes > 10000: the least recently used ('a') was dropped.
      expect(await store.read('a'), isNull);
      expect((await store.read('b'))!.first, 'b'.codeUnitAt(0));
      expect((await store.read('c'))!.length, 4000);
      await store.delete('b');
      expect(await store.read('b'), isNull);
      await store.clear();
      expect(await store.read('c'), isNull);
    });
  });
}
