import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'sketchify.dart';
import 'sketch_style.dart';

/// Paints a [Sketch] at a given point of its draw-in animation.
///
/// [progress] runs 0 → 1. For the first [SketchStyle.drawPortion] of it the
/// outlines draw in, then the fill is revealed. 1.0 is the finished artwork.
class SketchPainter extends CustomPainter {
  /// The traced image to paint.
  final Sketch sketch;

  /// Point in the animation, 0 (nothing drawn) → 1 (finished artwork).
  final double progress;

  /// How the drawing looks.
  final SketchStyle style;

  /// Creates a painter for [sketch] at [progress].
  SketchPainter({required this.sketch, this.progress = 1.0, this.style = const SketchStyle()});

  @override
  void paint(Canvas canvas, Size size) {
    final Size art = sketch.size;
    if (size.isEmpty || art.isEmpty) return;

    final double scale = math.min(size.width / art.width, size.height / art.height);
    canvas.save();
    canvas.translate((size.width - art.width * scale) / 2, (size.height - art.height * scale) / 2);
    canvas.scale(scale);

    final Rect artRect = Offset.zero & art;
    final double p = progress.clamp(0.0, 1.0);
    final double lineT = (p / style.drawPortion).clamp(0.0, 1.0);
    final double fillT = style.fill == SketchFill.none
        ? 0.0
        : ((p - style.drawPortion) / (1 - style.drawPortion)).clamp(0.0, 1.0);

    if (fillT > 0) _paintFill(canvas, artRect, fillT);

    final double lineOpacity = style.keepLines || style.fill == SketchFill.none ? 1.0 : 1.0 - fillT;
    if (lineOpacity > 0) _paintLines(canvas, artRect, scale, lineT, lineOpacity);

    canvas.restore();
  }

  // ── Fill ───────────────────────────────────────────────────────────────

  void _paintFill(Canvas canvas, Rect artRect, double t) {
    canvas.save();
    double opacity = 1.0;
    switch (style.reveal) {
      case SketchReveal.fade:
        opacity = t;
      case SketchReveal.wipeDown:
        canvas.clipRect(Rect.fromLTWH(artRect.left, artRect.top, artRect.width, artRect.height * t));
      case SketchReveal.wipeUp:
        canvas.clipRect(
          Rect.fromLTRB(artRect.left, artRect.bottom - artRect.height * t, artRect.right, artRect.bottom),
        );
      case SketchReveal.wipeRight:
        canvas.clipRect(Rect.fromLTWH(artRect.left, artRect.top, artRect.width * t, artRect.height));
      case SketchReveal.wipeLeft:
        canvas.clipRect(Rect.fromLTRB(artRect.right - artRect.width * t, artRect.top, artRect.right, artRect.bottom));
      case SketchReveal.circle:
        final double radius = artRect.size.longestSide * 0.75 * t;
        canvas.clipPath(Path()..addOval(Rect.fromCircle(center: artRect.center, radius: radius)));
    }

    final Paint layerPaint = Paint()..color = Color.fromRGBO(0, 0, 0, opacity);
    if (style.fill == SketchFill.image) {
      final ui.Image image = sketch.image;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        artRect,
        layerPaint..filterQuality = FilterQuality.high,
      );
    } else {
      canvas.saveLayer(artRect.inflate(2), layerPaint);
      for (final SketchShape shape in sketch.shapes) {
        canvas.drawPath(shape.path, Paint()..color = shape.color);
        // A hairline in the same colour closes anti-aliasing seams between neighbours.
        canvas.drawPath(
          shape.path,
          Paint()
            ..color = shape.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  // ── Lines ──────────────────────────────────────────────────────────────

  /// Each shape's own 0 → 1 drawing progress, honouring [SketchStyle.order].
  double _shapeT(int index, int count, double lineT) {
    final double stagger = switch (style.order) {
      SketchOrder.together => 0.0,
      SketchOrder.staggered => 0.6,
      SketchOrder.sequential => 1.0,
    };
    if (stagger == 0 || count <= 1) return lineT;
    final double window = 1.0 / (1.0 + stagger * (count - 1));
    final double start = index * stagger * window;
    return ((lineT - start) / window).clamp(0.0, 1.0);
  }

  void _paintLines(Canvas canvas, Rect artRect, double scale, double lineT, double opacity) {
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.lineWidth / scale
      ..strokeCap = style.lineCap
      ..strokeJoin = style.lineJoin;
    final Gradient? gradient = style.lineGradient;
    final Shader? shader = gradient != null && !style.useShapeColors ? gradient.createShader(artRect) : null;
    if (shader != null) {
      line.shader = shader;
      if (opacity < 1) line.color = Color.fromRGBO(0, 0, 0, opacity);
    }

    final List<SketchShape> shapes = sketch.shapes;
    final List<Offset> penTips = [];
    final List<Color?> penTipColors = []; // null: take the line gradient's colour

    for (int i = 0; i < shapes.length; i++) {
      final SketchShape shape = shapes[i];
      final double t = _shapeT(i, shapes.length, lineT);
      if (t <= 0) continue;

      final Color base = style.useShapeColors ? shape.color : style.lineColor;
      if (line.shader == null) line.color = base.withValues(alpha: base.a * opacity);

      if (t >= 1.0) {
        canvas.drawPath(shape.path, line);
        continue;
      }
      final Path partial = Path();
      for (final ui.PathMetric metric in shape.metrics) {
        final double length = metric.length * t;
        partial.addPath(metric.extractPath(0.0, length), Offset.zero);
        if (style.showPen) {
          final ui.Tangent? tip = metric.getTangentForOffset(length);
          if (tip != null) {
            penTips.add(tip.position);
            penTipColors.add(style.penColor ?? (shader != null ? null : base));
          }
        }
      }
      canvas.drawPath(partial, line);
    }

    if (penTips.isEmpty) return;
    final double radius = style.penRadius / scale;
    final Paint dot = Paint();
    final Paint glow = Paint();
    for (int i = 0; i < penTips.length; i++) {
      final Offset tip = penTips[i];
      // Dots on a gradient line take the gradient's colour at the tip.
      final Color c = penTipColors[i] ?? _gradientColorAt(gradient!, artRect, tip);
      if (style.penGlow) {
        // A radial fade is much cheaper than a blur filter for many pens.
        final double glowRadius = radius * 3.2;
        glow.shader = ui.Gradient.radial(tip, glowRadius, [
          c.withValues(alpha: c.a * 0.35 * opacity),
          c.withValues(alpha: 0),
        ]);
        canvas.drawCircle(tip, glowRadius, glow);
      }
      dot.color = c.withValues(alpha: c.a * opacity);
      canvas.drawCircle(tip, radius, dot);
    }
  }

  /// Approximate colour of [gradient] at [point]: exact for linear
  /// gradients, by distance from the centre for radial ones, and by angle
  /// for sweep gradients.
  static Color _gradientColorAt(Gradient gradient, Rect rect, Offset point) {
    final List<Color> colors = gradient.colors;
    if (colors.length == 1) return colors.first;
    double t;
    if (gradient is LinearGradient) {
      final Offset a = gradient.begin.resolve(null).withinRect(rect);
      final Offset b = gradient.end.resolve(null).withinRect(rect);
      final Offset ab = b - a;
      final double len2 = ab.distanceSquared;
      t = len2 == 0 ? 0 : ((point - a).dx * ab.dx + (point - a).dy * ab.dy) / len2;
    } else if (gradient is RadialGradient) {
      final Offset centre = gradient.center.resolve(null).withinRect(rect);
      t = (point - centre).distance / (gradient.radius * rect.shortestSide);
    } else if (gradient is SweepGradient) {
      final Offset centre = gradient.center.resolve(null).withinRect(rect);
      final double angle = math.atan2(point.dy - centre.dy, point.dx - centre.dx) % (2 * math.pi);
      final double span = gradient.endAngle - gradient.startAngle;
      t = span == 0 ? 0 : (angle - gradient.startAngle) / span;
    } else {
      t = 0.5;
    }
    t = t.clamp(0.0, 1.0);

    final List<double> stops = gradient.stops ?? [for (int i = 0; i < colors.length; i++) i / (colors.length - 1)];
    if (t <= stops.first) return colors.first;
    for (int i = 1; i < stops.length; i++) {
      if (t <= stops[i]) {
        final double span = stops[i] - stops[i - 1];
        return Color.lerp(colors[i - 1], colors[i], span == 0 ? 1 : (t - stops[i - 1]) / span)!;
      }
    }
    return colors.last;
  }

  @override
  bool shouldRepaint(covariant SketchPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.sketch != sketch || oldDelegate.style != style;
  }
}
