import 'package:flutter/painting.dart';

/// What appears once the outlines have been drawn.
enum SketchFill {
  /// The original image itself, so the last frame is pixel-exact.
  image,

  /// The traced vector colour layers.
  vector,

  /// Nothing — the animation ends as line art.
  none,
}

/// How the fill appears.
enum SketchReveal {
  /// Fades in everywhere at once.
  fade,

  /// Sweeps in from the top.
  wipeDown,

  /// Sweeps in from the bottom.
  wipeUp,

  /// Sweeps in from the left.
  wipeRight,

  /// Sweeps in from the right.
  wipeLeft,

  /// Grows as a circle from the centre.
  circle,
}

/// The order in which the shapes' outlines are drawn.
enum SketchOrder {
  /// Every outline draws at the same time.
  together,

  /// Each shape starts a little after the previous one, overlapping.
  staggered,

  /// One shape after another, bottom layer first.
  sequential,
}

/// How a traced image looks while it draws itself in.
///
/// Every field has a default, so `const SketchStyle()` reproduces the standard
/// look and you only set what you want to change:
///
/// ```dart
/// const SketchStyle(lineColor: Colors.indigo, showPen: true, reveal: SketchReveal.wipeDown)
/// ```
class SketchStyle {
  // ── Lines ────────────────────────────────────────────────────────────────

  /// Colour of the drawing lines. Ignored when [lineGradient] is set or
  /// [useShapeColors] is true.
  final Color lineColor;

  /// Paints the lines with a gradient spread across the whole artwork.
  final Gradient? lineGradient;

  /// Draws each outline in its own layer's colour.
  final bool useShapeColors;

  /// Line thickness in logical pixels (constant at any size).
  final double lineWidth;

  /// Shape of the line ends.
  final StrokeCap lineCap;

  /// Shape of the line corners.
  final StrokeJoin lineJoin;

  /// Keep the lines on top of the fill instead of fading them out.
  final bool keepLines;

  // ── Pen ──────────────────────────────────────────────────────────────────

  /// Shows a dot at the tip of each line while it is being drawn.
  final bool showPen;

  /// Pen colour. Defaults to the line colour, or the gradient's colour at the
  /// pen when [lineGradient] is set.
  final Color? penColor;

  /// Pen dot radius in logical pixels.
  final double penRadius;

  /// Adds a soft glow around the pen dot.
  final bool penGlow;

  // ── Timing within one run ────────────────────────────────────────────────

  /// Share of the animation spent drawing lines (0.05–0.95). The rest
  /// reveals the fill.
  final double drawPortion;

  /// The order in which the shapes' outlines are drawn.
  final SketchOrder order;

  // ── Fill ─────────────────────────────────────────────────────────────────

  /// What appears once the outlines are drawn.
  final SketchFill fill;

  /// How [fill] appears.
  final SketchReveal reveal;

  /// Creates a style. Every field has a default.
  const SketchStyle({
    this.lineColor = const Color(0xFF2C2C2C),
    this.lineGradient,
    this.useShapeColors = false,
    this.lineWidth = 1.5,
    this.lineCap = StrokeCap.round,
    this.lineJoin = StrokeJoin.round,
    this.keepLines = false,
    this.showPen = false,
    this.penColor,
    this.penRadius = 3.0,
    this.penGlow = true,
    this.drawPortion = 0.6,
    this.order = SketchOrder.together,
    this.fill = SketchFill.image,
    this.reveal = SketchReveal.fade,
  }) : assert(drawPortion >= 0.05 && drawPortion <= 0.95, 'drawPortion must be between 0.05 and 0.95'),
       assert(lineWidth >= 0),
       assert(penRadius >= 0);

  /// A copy with the given fields replaced. Pass [clearLineGradient] or
  /// [clearPenColor] to reset those to null.
  SketchStyle copyWith({
    Color? lineColor,
    Gradient? lineGradient,
    bool clearLineGradient = false,
    bool? useShapeColors,
    double? lineWidth,
    StrokeCap? lineCap,
    StrokeJoin? lineJoin,
    bool? keepLines,
    bool? showPen,
    Color? penColor,
    bool clearPenColor = false,
    double? penRadius,
    bool? penGlow,
    double? drawPortion,
    SketchOrder? order,
    SketchFill? fill,
    SketchReveal? reveal,
  }) {
    return SketchStyle(
      lineColor: lineColor ?? this.lineColor,
      lineGradient: clearLineGradient ? null : (lineGradient ?? this.lineGradient),
      useShapeColors: useShapeColors ?? this.useShapeColors,
      lineWidth: lineWidth ?? this.lineWidth,
      lineCap: lineCap ?? this.lineCap,
      lineJoin: lineJoin ?? this.lineJoin,
      keepLines: keepLines ?? this.keepLines,
      showPen: showPen ?? this.showPen,
      penColor: clearPenColor ? null : (penColor ?? this.penColor),
      penRadius: penRadius ?? this.penRadius,
      penGlow: penGlow ?? this.penGlow,
      drawPortion: drawPortion ?? this.drawPortion,
      order: order ?? this.order,
      fill: fill ?? this.fill,
      reveal: reveal ?? this.reveal,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SketchStyle &&
        other.lineColor == lineColor &&
        other.lineGradient == lineGradient &&
        other.useShapeColors == useShapeColors &&
        other.lineWidth == lineWidth &&
        other.lineCap == lineCap &&
        other.lineJoin == lineJoin &&
        other.keepLines == keepLines &&
        other.showPen == showPen &&
        other.penColor == penColor &&
        other.penRadius == penRadius &&
        other.penGlow == penGlow &&
        other.drawPortion == drawPortion &&
        other.order == order &&
        other.fill == fill &&
        other.reveal == reveal;
  }

  @override
  int get hashCode => Object.hash(
    lineColor,
    lineGradient,
    useShapeColors,
    lineWidth,
    lineCap,
    lineJoin,
    keepLines,
    showPen,
    penColor,
    penRadius,
    penGlow,
    drawPortion,
    order,
    fill,
    reveal,
  );
}
