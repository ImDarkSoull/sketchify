import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sketchify/sketchify.dart';

import 'support/art.dart';

/// [smallShapesSvg]: 10 solid dots (r 2–20), 9 rings 2 px thick (r 4–24),
/// 6 rings 1.5 px thick (r 6–24) and 6 small ellipses, anti-aliased.
void main() {
  testWidgets('small circles, thin rings and ellipses trace cleanly', (tester) async {
    await tester.runAsync(() async {
      final sketch = await Sketchify.trace(await renderPng(smallShapesSvg(), width: 640));

      List<SketchShape> row(double from, double to) => sketch.shapes.where((s) {
        final c = s.path.getBounds().center.dy;
        return c > from && c < to;
      }).toList();

      // All four inks found, including the ones that only appear in thin rings.
      int dist(Color a, Color b) {
        int c(double x) => (x * 255).round();
        final dr = c(a.r) - c(b.r), dg = c(a.g) - c(b.g), db = c(a.b) - c(b.b);
        return dr * dr + dg * dg + db * db;
      }

      for (final ink in const [Color(0xFF4699D1), Color(0xFF593E25), Color(0xFFE91E63), Color(0xFF383122)]) {
        expect(sketch.palette.any((p) => dist(p, ink) < 26 * 26), isTrue, reason: 'missing $ink');
      }

      // Solid dots are round and the right size (radius 20 → 40 px across).
      // Exact bounds of the outline itself (Path.getBounds includes control points).
      Rect outlineBounds(SketchShape s) {
        Rect? r;
        for (final m in s.metrics) {
          for (double d = 0; d <= m.length; d += 0.25) {
            final p = m.getTangentForOffset(d)!.position;
            r = r == null ? Rect.fromLTWH(p.dx, p.dy, 0, 0) : r.expandToInclude(Rect.fromLTWH(p.dx, p.dy, 0, 0));
          }
        }
        return r!;
      }

      final dots = row(0, 70);
      expect(dots.length, 10);
      final biggest = dots.map(outlineBounds).reduce((a, b) => a.width > b.width ? a : b);
      expect(biggest.width, closeTo(40, 1.0));
      expect(biggest.height, closeTo(40, 1.0));

      // Each 2 px ring is one closed shape with an outer and an inner outline.
      final rings = row(90, 150);
      expect(rings.length, 9);
      for (final ring in rings) {
        expect(ring.metrics.length, 2, reason: 'ring at ${ring.path.getBounds().center} should be unbroken');
      }

      // 1.5 px rings are at the limit: dark ones may split, but only a little.
      final thinRings = row(170, 240);
      expect(thinRings.length, inInclusiveRange(6, 8));

      final ellipses = row(260, 330);
      expect(ellipses.length, 6);
      for (final e in ellipses) {
        expect(e.metrics.length, 1);
      }
      sketch.dispose();
    });
  });
}
