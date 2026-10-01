@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

import 'support/art.dart';

const MethodChannel pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory appCache;

  setUp(() async {
    appCache = await Directory.systemTemp.createTemp('sketchify_app_cache');
    // Stand-in for the platform's path_provider: the "app cache directory".
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => call.method == 'getApplicationCacheDirectory' ? appCache.path : null,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    await appCache.delete(recursive: true);
  });

  testWidgets('by default, traced images stay cached across app restarts', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderPng(catSvg(), width: 600);

      // First launch: the default cache, with no setup at all.
      final first = await Sketchify.trace(bytes);
      expect(first.fromCache, isFalse);
      await Sketchify.cache!.flush();
      final saved = Directory('${appCache.path}/sketchify').listSync().whereType<File>().toList();
      expect(saved, hasLength(1), reason: 'saved in <app cache directory>/sketchify');

      // Restart: memory is gone, a fresh default cache reads from disk.
      final previous = Sketchify.cache;
      Sketchify.cache = SketchCache(store: SketchCacheStore.platformDefault());
      addTearDown(() => Sketchify.cache = previous);
      final afterRestart = await Sketchify.trace(bytes);
      expect(afterRestart.fromCache, isTrue);
      expect(afterRestart.shapes.length, first.shapes.length);
      expect(afterRestart.removedBackground, first.removedBackground);

      // Until the cache is cleared.
      await Sketchify.cache!.clear();
      Sketchify.cache = SketchCache(store: SketchCacheStore.platformDefault());
      final afterClear = await Sketchify.trace(bytes);
      expect(afterClear.fromCache, isFalse);

      for (final s in [first, afterRestart, afterClear]) {
        s.dispose();
      }
    });
  });

  testWidgets('without path_provider (e.g. plain unit tests) it falls back to memory', (tester) async {
    await tester.runAsync(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
      final previous = Sketchify.cache;
      Sketchify.cache = SketchCache(store: SketchCacheStore.platformDefault());
      addTearDown(() => Sketchify.cache = previous);

      final bytes = await renderPng(letteringSvg, width: 520);
      final first = await Sketchify.trace(bytes);
      await Sketchify.cache!.flush();
      final second = await Sketchify.trace(bytes);
      expect([first.fromCache, second.fromCache], [false, true]);
      first.dispose();
      second.dispose();
    });
  });
}
