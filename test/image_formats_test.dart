import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

import 'support/art.dart';

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

/// A ring with a white disc in it, and a rounded rectangle with a triangle on
/// it, on a transparent background.
const String shapesSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 120">
  <circle cx="58" cy="60" r="42" fill="#2E86AB"/>
  <circle cx="58" cy="60" r="20" fill="#FFFFFF"/>
  <rect x="118" y="18" width="62" height="84" rx="14" fill="#6A4C93"/>
  <path d="M128 92 L149 38 L170 92 Z" fill="#F4D35E"/>
</svg>''';

/// A white star on a solid dark background.
const String badgeSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="300" height="300">
  <rect width="300" height="300" fill="#22223B"/>
  <path d="M150 40 L176 116 L256 116 L192 164 L216 242 L150 196 L84 242 L108 164 L44 116 L124 116 Z" fill="#F2E9E4"/>
  <circle cx="150" cy="150" r="22" fill="#C9184A"/>
</svg>''';

void main() {
  testWidgets('detects formats from contents, not names', (tester) async {
    final png = (await tester.runAsync(() => renderPng(catSvg(), width: 64)))!;
    expect(SketchImageFormat.detect(png), SketchImageFormat.png);
    expect(SketchImageFormat.detect(fixture('formats_cat.jpg')), SketchImageFormat.jpeg);
    expect(SketchImageFormat.detect(fixture('formats_cat.webp')), SketchImageFormat.webp);
    expect(SketchImageFormat.detect(fixture('formats_cat.gif')), SketchImageFormat.gif);
    expect(SketchImageFormat.detect(fixture('formats_cat.bmp')), SketchImageFormat.bmp);
    expect(SketchImageFormat.detect(fixture('formats_cat.ico')), SketchImageFormat.ico);
    expect(SketchImageFormat.detect(utf8.encode(shapesSvg)), SketchImageFormat.svg);
    expect(SketchImageFormat.detect(utf8.encode('<?xml version="1.0"?>\n$badgeSvg')), SketchImageFormat.svg);
    expect(SketchImageFormat.detect(fixture('formats_not_an_image.txt')), SketchImageFormat.unknown);
    // HEIC header: size box, 'ftyp', brand 'heic'.
    final heic = Uint8List.fromList([0, 0, 0, 24, ...'ftypheic'.codeUnits, 0, 0, 0, 0]);
    expect(SketchImageFormat.detect(heic), SketchImageFormat.heic);
  });

  test('lists extensions and MIME types for pickers', () {
    expect(SketchImageFormat.allExtensions, containsAll(['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'heic', 'svg']));
    expect(SketchImageFormat.allMimeTypes, containsAll(['image/png', 'image/jpeg', 'image/svg+xml']));
  });

  for (final (name, width) in [
    ('formats_cat.jpg', 600),
    ('formats_cat.webp', 600),
    ('formats_cat.gif', 600),
    ('formats_cat.bmp', 300),
  ]) {
    testWidgets('traces $name', (tester) async {
      await tester.runAsync(() async {
        final sketch = await Sketchify.trace(fixture(name));
        expect(sketch.removedBackground, isNotNull, reason: 'navy background should be found');
        expect(sketch.palette.length, inInclusiveRange(5, 16));
        expect(sketch.shapes.length, greaterThan(10));
        expect(sketch.image.width, width);
        sketch.dispose();
      });
    });
  }

  testWidgets('traces an ICO', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(fixture('formats_cat.ico'));
      expect(sketch.format, SketchImageFormat.ico);
      expect(sketch.image.width, 128);
      expect(sketch.shapes, isNotEmpty);
      sketch.dispose();
    });
  });

  testWidgets('traces an SVG with a transparent background', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.traceSvgString(shapesSvg);
      expect(sketch.format, SketchImageFormat.svg);
      expect(sketch.removedBackground, isNull);
      // Rendered crisply at the default 2048 px on the longest side.
      expect(sketch.image.width, 2048);
      expect(sketch.image.height, closeTo(2048 * 120 / 200, 1));
      expect(sketch.palette.toSet(), {
        const Color(0xFF2E86AB),
        const Color(0xFFFFFFFF),
        const Color(0xFF6A4C93),
        const Color(0xFFF4D35E),
      });
      // ring, white disc in it, rounded rect, triangle on it
      expect(sketch.shapes.length, 4);
      sketch.dispose();
    });
  });

  testWidgets('traces an SVG with a solid background and removes it', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(utf8.encode(badgeSvg));
      expect(sketch.removedBackground, const Color(0xFF22223B));
      expect(sketch.palette.toSet(), {const Color(0xFFF2E9E4), const Color(0xFFC9184A)});
      sketch.dispose();
    });
  });

  testWidgets('traceSvgString and a custom SVG resolution', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.traceSvgString(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect x="2" y="2" width="6" height="6" fill="#00AA55"/></svg>',
        options: const SketchOptions(svgRenderSize: 512),
      );
      expect(sketch.image.width, 512);
      expect(sketch.palette, [const Color(0xFF00AA55)]);
      expect(sketch.shapes.length, 1);
      sketch.dispose();
    });
  });

  testWidgets('a file that is not an image gives a clear error', (tester) async {
    await tester.runAsync(() async {
      await expectLater(
        Sketchify.trace(fixture('formats_not_an_image.txt')),
        throwsA(
          isA<UnsupportedImageException>()
              .having((e) => e.format, 'format', SketchImageFormat.unknown)
              .having((e) => e.message, 'message', contains('Supported: PNG, JPEG')),
        ),
      );
    });
  });
}
