/// @docImport 'sketchify.dart';
library;

/// Settings for [Sketchify.trace].
class SketchOptions {
  /// Highest allowed [maxColors]. Each pixel's layer is stored in one byte,
  /// with room kept for the background.
  static const int maxColorsLimit = 250;

  /// Remove a solid background (detected from the image border) so only the
  /// artwork remains. Images with real transparency always keep it.
  final bool removeBackground;

  /// When removing a background, also remove areas of the background colour
  /// that are enclosed by the artwork, such as the inside of an "o" or the
  /// gap between a logo's parts.
  ///
  /// Set it to false to remove only the background that touches the image's
  /// border. Enclosed areas of that colour, such as white eyes on a character
  /// with a white background, then stay as part of the artwork.
  final bool removeEnclosedBackground;

  /// The image is traced at most this many pixels on its longest side.
  /// The final frame always uses the full-resolution image.
  final int maxTraceSize;

  /// SVGs are rendered at this many pixels on their longest side. This is
  /// also the resolution of the final frame for SVG input.
  final int svgRenderSize;

  /// Upper limit on the number of colour layers (1 to [maxColorsLimit]).
  final int maxColors;

  /// Colours closer than this (RGB distance, 0–441) count as the same colour.
  final double colorTolerance;

  /// Allowed curve deviation from the traced outline, in trace pixels.
  final double curveTolerance;

  /// Shapes smaller than this fraction of the image are merged into their
  /// neighbours (removes specks).
  final double minShapeFraction;

  /// Creates tracing settings. Every field has a default.
  const SketchOptions({
    this.removeBackground = true,
    this.removeEnclosedBackground = true,
    this.maxTraceSize = 800,
    this.svgRenderSize = 2048,
    this.maxColors = 16,
    this.colorTolerance = 26,
    this.curveTolerance = 0.9,
    this.minShapeFraction = 0.00003,
  }) : assert(maxTraceSize >= 1, 'maxTraceSize must be at least 1'),
       assert(svgRenderSize >= 1, 'svgRenderSize must be at least 1'),
       assert(maxColors >= 1 && maxColors <= maxColorsLimit, 'maxColors must be between 1 and $maxColorsLimit'),
       assert(colorTolerance >= 0, 'colorTolerance must not be negative'),
       assert(curveTolerance > 0, 'curveTolerance must be greater than 0'),
       assert(minShapeFraction >= 0 && minShapeFraction < 1, 'minShapeFraction must be in [0, 1)');

  /// Throws an [ArgumentError] if a setting is out of range. Called by
  /// [Sketchify.trace], so bad settings also fail clearly in release builds.
  void validate() {
    if (maxTraceSize < 1) throw RangeError.range(maxTraceSize, 1, null, 'maxTraceSize');
    if (svgRenderSize < 1) throw RangeError.range(svgRenderSize, 1, null, 'svgRenderSize');
    if (maxColors < 1 || maxColors > maxColorsLimit) throw RangeError.range(maxColors, 1, maxColorsLimit, 'maxColors');
    if (colorTolerance.isNaN || colorTolerance < 0) {
      throw ArgumentError.value(colorTolerance, 'colorTolerance', 'must not be negative');
    }
    if (curveTolerance.isNaN || curveTolerance <= 0) {
      throw ArgumentError.value(curveTolerance, 'curveTolerance', 'must be greater than 0');
    }
    if (minShapeFraction.isNaN || minShapeFraction < 0 || minShapeFraction >= 1) {
      throw ArgumentError.value(minShapeFraction, 'minShapeFraction', 'must be in [0, 1)');
    }
  }

  /// A copy with the given fields replaced.
  SketchOptions copyWith({
    bool? removeBackground,
    bool? removeEnclosedBackground,
    int? maxTraceSize,
    int? svgRenderSize,
    int? maxColors,
    double? colorTolerance,
    double? curveTolerance,
    double? minShapeFraction,
  }) {
    return SketchOptions(
      removeBackground: removeBackground ?? this.removeBackground,
      removeEnclosedBackground: removeEnclosedBackground ?? this.removeEnclosedBackground,
      maxTraceSize: maxTraceSize ?? this.maxTraceSize,
      svgRenderSize: svgRenderSize ?? this.svgRenderSize,
      maxColors: maxColors ?? this.maxColors,
      colorTolerance: colorTolerance ?? this.colorTolerance,
      curveTolerance: curveTolerance ?? this.curveTolerance,
      minShapeFraction: minShapeFraction ?? this.minShapeFraction,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SketchOptions &&
        other.removeBackground == removeBackground &&
        other.removeEnclosedBackground == removeEnclosedBackground &&
        other.maxTraceSize == maxTraceSize &&
        other.svgRenderSize == svgRenderSize &&
        other.maxColors == maxColors &&
        other.colorTolerance == colorTolerance &&
        other.curveTolerance == curveTolerance &&
        other.minShapeFraction == minShapeFraction;
  }

  @override
  int get hashCode => Object.hash(
    removeBackground,
    removeEnclosedBackground,
    maxTraceSize,
    svgRenderSize,
    maxColors,
    colorTolerance,
    curveTolerance,
    minShapeFraction,
  );

  @override
  String toString() =>
      'SketchOptions(removeBackground: $removeBackground, removeEnclosedBackground: $removeEnclosedBackground, '
      'maxTraceSize: $maxTraceSize, svgRenderSize: $svgRenderSize, maxColors: $maxColors, '
      'colorTolerance: $colorTolerance, curveTolerance: $curveTolerance, minShapeFraction: $minShapeFraction)';
}
