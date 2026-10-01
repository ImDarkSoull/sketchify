import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

import 'support/art.dart' as art;

Future<Uint8List> lettering() => art.renderPng(art.letteringSvg, width: 520);

/// Encodes straight-alpha RGBA filled by [fill] as a PNG.
Future<Uint8List> png(int w, int h, void Function(Uint8List px) fill) async {
  final px = Uint8List(w * h * 4);
  fill(px);
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, completer.complete);
  final image = await completer.future;
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<int> alphaAt(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return data!.getUint8((y * image.width + x) * 4 + 3);
}

/// White background, black ring, white inside the ring.
Future<Uint8List> ringOnWhite() => png(200, 200, (px) {
  for (int y = 0; y < 200; y++) {
    for (int x = 0; x < 200; x++) {
      final d = math.sqrt((x - 100) * (x - 100) + (y - 100) * (y - 100));
      final v = (d > 40 && d < 70) ? 0 : 255;
      final i = (y * 200 + x) * 4;
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
});

void main() {
  testWidgets('an image that is only semi-transparent traces', (tester) async {
    await tester.runAsync(() async {
      final r = math.Random(1);
      final bytes = await png(64, 64, (px) {
        for (int i = 0; i < 64 * 64; i++) {
          px[i * 4] = r.nextInt(256);
          px[i * 4 + 1] = r.nextInt(256);
          px[i * 4 + 2] = r.nextInt(256);
          px[i * 4 + 3] = 200;
        }
      });
      final sketch = await Sketchify.trace(bytes);
      expect(sketch.palette, isNotEmpty);
      expect(sketch.shapes, isNotEmpty);
      sketch.dispose();
    });
  });

  testWidgets('out-of-range options fail with a clear error', (tester) async {
    await tester.runAsync(() async {
      final bytes = await lettering();
      // Constructor asserts catch these in debug; validate() in release.
      for (final SketchOptions Function() bad in [
        () => SketchOptions(maxTraceSize: 0),
        () => SketchOptions(maxColors: 0),
        () => SketchOptions(maxColors: 300),
        () => SketchOptions(curveTolerance: 0),
        () => SketchOptions(minShapeFraction: 1),
      ]) {
        await expectLater(
          () => Sketchify.trace(bytes, options: bad()),
          throwsA(anyOf(isAssertionError, isArgumentError)),
        );
      }
    });
  });

  test('SketchOptions equality', () {
    expect(const SketchOptions().validate, returnsNormally);
    expect(const SketchOptions(), const SketchOptions().copyWith());
    expect(const SketchOptions().hashCode, const SketchOptions().copyWith().hashCode);
    expect(const SketchOptions().copyWith(maxColors: 8), isNot(const SketchOptions()));
  });

  testWidgets('enclosed background is removed by default', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(await ringOnWhite());
      expect(sketch.removedBackground, const Color(0xFFFFFFFF));
      expect(await alphaAt(sketch.image, 5, 5), 0);
      expect(await alphaAt(sketch.image, 100, 100), 0); // inside the ring
      expect(await alphaAt(sketch.image, 155, 100), 255); // the ring
      expect(sketch.shapes.length, 1);
      sketch.dispose();
    });
  });

  testWidgets('removeEnclosedBackground: false keeps enclosed areas', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(
        await ringOnWhite(),
        options: const SketchOptions(removeEnclosedBackground: false),
      );
      expect(sketch.removedBackground, const Color(0xFFFFFFFF));
      expect(await alphaAt(sketch.image, 5, 5), 0); // outside: removed
      expect(await alphaAt(sketch.image, 100, 100), 255); // inside: kept
      expect(await alphaAt(sketch.image, 155, 100), 255);
      // The ring, then the white disc inside it on top.
      expect(sketch.shapes.length, 2);
      expect(sketch.shapes.last.color, const Color(0xFFFFFFFF));
      sketch.dispose();
    });
  });

  testWidgets('single-ink line art does not fragment into blend colours', (tester) async {
    await tester.runAsync(() async {
      // Thin rings in one ink on white: almost no flat pixels, so the
      // palette is sampled from every pixel, anti-aliasing included.
      final svg = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" width="460" height="80">')
        ..write('<rect width="460" height="80" fill="#FFFFFF"/>');
      double x = 10;
      for (int i = 0; i < 8; i++) {
        final r = 5.0 + i * 2.7;
        x += r;
        svg.write('<circle cx="$x" cy="40" r="$r" fill="none" stroke="#383122" stroke-width="2"/>');
        x += r + 14;
      }
      svg.write('</svg>');
      final sketch = await Sketchify.trace(await art.renderPng(svg.toString(), width: 460));
      expect(sketch.palette.length, 1, reason: 'blends of ink and white are not colours of their own');
      expect(sketch.shapes.length, 8);
      for (final ring in sketch.shapes) {
        expect(ring.metrics.length, 2, reason: 'each ring is unbroken');
      }
      sketch.dispose();
    });
  });

  group('format detection', () {
    test('a video file is not mistaken for WBMP', () {
      final mp4 = Uint8List.fromList([0, 0, 0, 24, ...'ftypisom'.codeUnits, 0, 0, 2, 0, ...List.filled(64, 7)]);
      expect(SketchImageFormat.detect(mp4), SketchImageFormat.unknown);
    });

    test('a real WBMP is recognised', () {
      // 8×2 pixels: type 0, header 0, width 8, height 2, one byte per row.
      final wbmp = Uint8List.fromList([0, 0, 8, 2, 0xF0, 0x0F]);
      expect(SketchImageFormat.detect(wbmp), SketchImageFormat.wbmp);
    });

    test('AVIF is identified but not offered to pickers', () {
      final avif = Uint8List.fromList([0, 0, 0, 24, ...'ftypavif'.codeUnits, 0, 0, 0, 0]);
      expect(SketchImageFormat.detect(avif), SketchImageFormat.avif);
      expect(SketchImageFormat.allExtensions, isNot(contains('avif')));
      expect(SketchImageFormat.allMimeTypes, isNot(contains('image/avif')));
    });

    test('SVG with a byte order mark', () {
      final svg = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...'<svg viewBox="0 0 1 1"/>'.codeUnits]);
      expect(SketchImageFormat.detect(svg), SketchImageFormat.svg);
    });
  });

  group('seek', () {
    late Sketch sketch;

    Future<GlobalKey<SketchAnimationState>> pump(
      WidgetTester tester,
      SketchPlayMode mode,
      VoidCallback onCompleted,
    ) async {
      sketch = (await tester.runAsync(() async => Sketchify.trace(await lettering())))!;
      final key = GlobalKey<SketchAnimationState>();
      await tester.pumpWidget(
        Center(
          child: SketchAnimation(
            key: key,
            sketch: sketch,
            width: 100,
            playMode: mode,
            repeatPause: Duration.zero,
            onCompleted: onCompleted,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      return key;
    }

    for (final mode in SketchPlayMode.values) {
      testWidgets('seek(1) and seek(0) stay paused in $mode', (tester) async {
        var completed = 0;
        final key = await pump(tester, mode, () => completed++);
        key.currentState!.seek(1.0);
        await tester.pump(const Duration(milliseconds: 500));
        expect(completed, 0, reason: 'seeking is not finishing a run');
        expect(key.currentState!.isPlaying, isFalse);
        expect(key.currentState!.progress, 1.0);

        key.currentState!.seek(0.0);
        await tester.pump(const Duration(milliseconds: 500));
        expect(key.currentState!.isPlaying, isFalse);
        expect(key.currentState!.progress, 0.0);
        expect(key.currentState!.isPaused, isTrue);
        await tester.pumpWidget(const SizedBox());
        sketch.dispose();
      });
    }

    testWidgets('resume after seek(1) starts the next loop', (tester) async {
      final key = await pump(tester, SketchPlayMode.loop, () {});
      key.currentState!.seek(1.0);
      key.currentState!.resume();
      await tester.pump(const Duration(milliseconds: 100));
      expect(key.currentState!.isPlaying, isTrue);
      expect(key.currentState!.progress, lessThan(0.5));
      key.currentState!.pause();
      await tester.pumpWidget(const SizedBox());
      sketch.dispose();
    });
  });

  testWidgets('switching autoPlay on starts after the delay', (tester) async {
    final sketch = (await tester.runAsync(() async => Sketchify.trace(await lettering())))!;
    final key = GlobalKey<SketchAnimationState>();
    Widget build(bool autoPlay) => Center(
      child: SketchAnimation(
        key: key,
        sketch: sketch,
        width: 100,
        autoPlay: autoPlay,
        delay: const Duration(milliseconds: 300),
      ),
    );
    await tester.pumpWidget(build(false));
    expect(key.currentState!.progress, 1.0);
    await tester.pumpWidget(build(true));
    expect(key.currentState!.progress, 0.0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(key.currentState!.isPlaying, isFalse);
    await tester.pump(const Duration(milliseconds: 200));
    expect(key.currentState!.isPlaying, isTrue);
    await tester.pumpAndSettle();
    sketch.dispose();
  });

  for (final delay in const [Duration.zero, Duration(milliseconds: 200)]) {
    testWidgets('onProgress can rebuild widgets when the sketch changes (delay $delay)', (tester) async {
      final a = (await tester.runAsync(() async => Sketchify.trace(await lettering())))!;
      final b = (await tester.runAsync(
        () => Sketchify.traceSvgString(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="#E91E63"/></svg>',
          options: const SketchOptions(svgRenderSize: 128),
        ),
      ))!;
      final progress = ValueNotifier<double>(0);
      addTearDown(progress.dispose);
      final holder = GlobalKey<_SketchHolderState>();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              // Rebuilds from onProgress, like a timeline slider would. It is
              // not inside the subtree that rebuilds when the sketch changes.
              ValueListenableBuilder<double>(valueListenable: progress, builder: (_, v, _) => Text('$v')),
              _SketchHolder(
                key: holder,
                sketch: a,
                builder: (sketch) => SizedBox(
                  width: 100,
                  height: 100,
                  child: SketchAnimation(sketch: sketch, delay: delay, onProgress: (v) => progress.value = v),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 6));
      expect(progress.value, 1.0);

      holder.currentState!.show(b); // restarts while only that subtree builds
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump();
      expect(progress.value, lessThan(0.1), reason: 'the reset to the start is still reported');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      a.dispose();
      b.dispose();
    });
  }

  testWidgets('pen dots on gradient lines paint', (tester) async {
    final sketch = (await tester.runAsync(() async => Sketchify.trace(await lettering())))!;
    for (final gradient in const <Gradient>[
      LinearGradient(colors: [Color(0xFFFF0066), Color(0xFF3366FF)]),
      RadialGradient(colors: [Color(0xFFFF0066), Color(0xFF3366FF)], stops: [0.2, 0.8]),
      SweepGradient(colors: [Color(0xFFFF0066), Color(0xFF00CC88), Color(0xFF3366FF)]),
    ]) {
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 300,
            height: 120,
            child: CustomPaint(
              painter: SketchPainter(
                sketch: sketch,
                progress: 0.3,
                style: SketchStyle(lineGradient: gradient, showPen: true),
              ),
            ),
          ),
        ),
      );
    }
    expect(tester.takeException(), isNull);
    sketch.dispose();
  });
}

/// Swaps the sketch with its own setState, so only this subtree rebuilds.
class _SketchHolder extends StatefulWidget {
  const _SketchHolder({super.key, required this.sketch, required this.builder});

  final Sketch sketch;
  final Widget Function(Sketch sketch) builder;

  @override
  State<_SketchHolder> createState() => _SketchHolderState();
}

class _SketchHolderState extends State<_SketchHolder> {
  late Sketch _sketch = widget.sketch;

  void show(Sketch sketch) => setState(() => _sketch = sketch);

  @override
  Widget build(BuildContext context) => widget.builder(_sketch);
}
