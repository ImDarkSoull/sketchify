import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

import 'support/art.dart';

Future<Uint8List> lettering() => renderPng(letteringSvg, width: 520);

Future<Uint8List> pixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('finds the colours and removes a solid background', (tester) async {
    await tester.runAsync(() async {
      // 1200 px, so tracing works on a downscaled copy.
      final sketch = await Sketchify.trace(await renderPng(catSvg(), width: 1200));
      expect(sketch.removedBackground, const Color(0xFF1E2A44));
      expect(sketch.palette.length, 7);
      expect(sketch.palette.first, const Color(0xFFE8914A)); // fur is the largest colour
      expect(sketch.shapes.length, greaterThan(15));
      expect(sketch.size, const Size(800, 800));

      // Final frame is full resolution with the background cut out.
      expect(sketch.image.width, 1200);
      expect(sketch.image.height, 1200);
      final px = await pixels(sketch.image);
      int alphaAt(int x, int y) => px[(y * 1200 + x) * 4 + 3];
      expect(alphaAt(10, 10), 0); // background
      expect(alphaAt(600, 420), 255); // fur
      sketch.dispose();
    });
  });

  testWidgets('keeps real transparency', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(await renderPng(catSvg(background: false), width: 600));
      expect(sketch.removedBackground, isNull);
      expect(sketch.shapes, isNotEmpty);
      sketch.dispose();
    });
  });

  testWidgets('removeBackground: false keeps the background as a layer', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(await lettering(), options: const SketchOptions(removeBackground: false));
      expect(sketch.removedBackground, isNull);
      expect(sketch.palette.length, 2); // background + letters
      final px = await pixels(sketch.image);
      expect(px[3], 255); // original, opaque image
      sketch.dispose();
    });
  });

  testWidgets('lettering traces one shape per letter', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(await lettering());
      expect(sketch.palette, [const Color(0xFF3A2E1F)]);
      expect(sketch.shapes.length, 6); // S K E T C H
      sketch.dispose();
    });
  });

  testWidgets('animation plays once, can replay, then stops', (tester) async {
    final sketch = (await tester.runAsync(() async => Sketchify.trace(await lettering())))!;
    final key = GlobalKey<SketchAnimationState>();
    var completed = 0;
    await tester.pumpWidget(
      Center(
        child: SketchAnimation(key: key, sketch: sketch, width: 300, onCompleted: () => completed++),
      ),
    );
    await tester.pumpAndSettle();
    expect(completed, 1);
    expect(tester.getSize(find.byType(SketchAnimation)).width, 300);

    key.currentState!.replay();
    await tester.pumpAndSettle();
    expect(completed, 2);
    sketch.dispose();
  });

  group('playback', () {
    late Sketch sketch;

    Future<GlobalKey<SketchAnimationState>> pump(
      WidgetTester tester, {
      double speed = 1.0,
      SketchPlayMode playMode = SketchPlayMode.once,
      VoidCallback? onCompleted,
    }) async {
      sketch = (await tester.runAsync(() async => Sketchify.trace(await lettering())))!;
      final key = GlobalKey<SketchAnimationState>();
      await tester.pumpWidget(
        Center(
          child: SketchAnimation(
            key: key,
            sketch: sketch,
            width: 300,
            speed: speed,
            playMode: playMode,
            repeatPause: Duration.zero,
            curve: Curves.linear,
            onCompleted: onCompleted,
          ),
        ),
      );
      return key;
    }

    testWidgets('speed 2.0 finishes in half the time', (tester) async {
      var completed = 0;
      final key = await pump(tester, speed: 2.0, onCompleted: () => completed++);
      await tester.pump(const Duration(milliseconds: 2200));
      expect(key.currentState!.progress, closeTo(2200 / 2250, 0.01));
      await tester.pump(const Duration(milliseconds: 100));
      expect(completed, 1);
      sketch.dispose();
    });

    testWidgets('loop keeps restarting', (tester) async {
      var completed = 0;
      final key = await pump(tester, speed: 10, playMode: SketchPlayMode.loop, onCompleted: () => completed++);
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(completed, greaterThanOrEqualTo(3));
      key.currentState!.pause();
      await tester.pumpAndSettle();
      sketch.dispose();
    });

    testWidgets('pingPong draws in and back out', (tester) async {
      final key = await pump(tester, speed: 10, playMode: SketchPlayMode.pingPong);
      await tester.pump(const Duration(milliseconds: 460));
      expect(key.currentState!.progress, 1.0);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(key.currentState!.progress, lessThan(0.5));
      key.currentState!.pause();
      await tester.pumpAndSettle();
      sketch.dispose();
    });

    testWidgets('pause, seek and resume', (tester) async {
      var completed = 0;
      final key = await pump(tester, onCompleted: () => completed++);
      await tester.pump(const Duration(milliseconds: 1000));
      key.currentState!.pause();
      final double paused = key.currentState!.progress;
      await tester.pump(const Duration(seconds: 2));
      expect(key.currentState!.progress, paused);
      expect(key.currentState!.isPlaying, isFalse);

      key.currentState!.seek(0.9);
      await tester.pump();
      expect(key.currentState!.progress, 0.9);

      key.currentState!.resume();
      await tester.pumpAndSettle();
      expect(key.currentState!.progress, 1.0);
      expect(completed, 1);

      key.currentState!.resume(); // already finished, plays once → nothing happens
      await tester.pumpAndSettle();
      expect(completed, 1);
      sketch.dispose();
    });
  });

  testWidgets('every style option paints without errors', (tester) async {
    final sketch = (await tester.runAsync(() async => Sketchify.trace(await renderPng(catSvg(), width: 600))))!;
    final styles = [
      const SketchStyle(),
      const SketchStyle(useShapeColors: true, showPen: true, order: SketchOrder.sequential),
      const SketchStyle(
        lineGradient: LinearGradient(colors: [Color(0xFFFF0066), Color(0xFF3366FF)]),
        lineWidth: 4,
        keepLines: true,
        order: SketchOrder.staggered,
      ),
      const SketchStyle(
        fill: SketchFill.vector,
        reveal: SketchReveal.circle,
        penColor: Color(0xFFFFAA00),
        showPen: true,
      ),
      const SketchStyle(fill: SketchFill.none, drawPortion: 0.9),
      for (final reveal in SketchReveal.values) SketchStyle(reveal: reveal),
    ];
    for (final style in styles) {
      for (final p in [0.0, 0.3, 0.7, 1.0]) {
        await tester.pumpWidget(
          Center(
            child: SizedBox(
              width: 300,
              height: 220,
              child: CustomPaint(
                painter: SketchPainter(sketch: sketch, progress: p, style: style),
              ),
            ),
          ),
        );
      }
    }
    expect(tester.takeException(), isNull);
    sketch.dispose();
  });
}
