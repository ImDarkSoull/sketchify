import 'dart:typed_data';

/// Compact, isolate-friendly path description.
///
/// Stream of commands: `0 x y` moveTo, `1 x y` lineTo,
/// `2 x1 y1 x2 y2 x y` cubicTo, `3` close.
class PathCommands {
  static const double moveTo = 0;
  static const double lineTo = 1;
  static const double cubicTo = 2;
  static const double close = 3;

  final List<double> _data = [];

  bool get isEmpty => _data.isEmpty;

  void addMoveTo(double x, double y) => _data
    ..add(moveTo)
    ..add(x)
    ..add(y);

  void addLineTo(double x, double y) => _data
    ..add(lineTo)
    ..add(x)
    ..add(y);

  void addCubicTo(double x1, double y1, double x2, double y2, double x, double y) => _data
    ..add(cubicTo)
    ..add(x1)
    ..add(y1)
    ..add(x2)
    ..add(y2)
    ..add(x)
    ..add(y);

  void addClose() => _data.add(close);

  Float32List build() => Float32List.fromList(_data);
}
