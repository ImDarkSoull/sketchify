import 'dart:math' as math;

import 'path_commands.dart';

class Vec {
  final double x;
  final double y;

  const Vec(this.x, this.y);

  Vec operator +(Vec o) => Vec(x + o.x, y + o.y);
  Vec operator -(Vec o) => Vec(x - o.x, y - o.y);
  Vec operator *(double s) => Vec(x * s, y * s);

  double dot(Vec o) => x * o.x + y * o.y;
  double get length => math.sqrt(x * x + y * y);
  double dist2(Vec o) => (x - o.x) * (x - o.x) + (y - o.y) * (y - o.y);

  Vec normalized() {
    final double l = length;
    return l == 0 ? this : Vec(x / l, y / l);
  }
}

/// Least-squares cubic Bézier fitting (Schneider, "An Algorithm for
/// Automatically Fitting Digitized Curves", Graphics Gems, 1990).
///
/// Fits [points] with as few cubics as possible so that no point is further
/// than `sqrt(errorSq)` from the curve. Appends cubicTo commands to [out];
/// the caller is responsible for the initial moveTo/lineTo to `points.first`.
/// [tHat1] points from the first point into the curve, [tHat2] from the last
/// point back into the curve.
void fitCubics(List<Vec> points, Vec tHat1, Vec tHat2, double errorSq, PathCommands out) {
  if (points.length < 2) return;
  _fitCubic(points, 0, points.length - 1, tHat1, tHat2, errorSq, out, 0);
}

void _emit(List<Vec> bez, PathCommands out) {
  out.addCubicTo(bez[1].x, bez[1].y, bez[2].x, bez[2].y, bez[3].x, bez[3].y);
}

void _fitCubic(List<Vec> d, int first, int last, Vec tHat1, Vec tHat2, double errorSq, PathCommands out, int depth) {
  final int nPts = last - first + 1;
  if (nPts == 2 || depth > 24) {
    final double dist = (d[last] - d[first]).length / 3.0;
    _emit([d[first], d[first] + tHat1 * dist, d[last] + tHat2 * dist, d[last]], out);
    return;
  }

  List<double>? u = _chordLengthParameterize(d, first, last);
  if (u == null) {
    out.addLineTo(d[last].x, d[last].y);
    return;
  }
  List<Vec> bez = _generateBezier(d, first, last, u, tHat1, tHat2);
  var (maxError, split) = _computeMaxError(d, first, last, bez, u);
  if (maxError < errorSq) {
    _emit(bez, out);
    return;
  }

  if (maxError < errorSq * 4.0) {
    for (int i = 0; i < 4; i++) {
      final List<double> uPrime = _reparameterize(d, first, last, u!, bez);
      bez = _generateBezier(d, first, last, uPrime, tHat1, tHat2);
      (maxError, split) = _computeMaxError(d, first, last, bez, uPrime);
      if (maxError < errorSq) {
        _emit(bez, out);
        return;
      }
      u = uPrime;
    }
  }

  Vec tCenter = (d[split - 1] - d[split + 1]).normalized();
  if (tCenter.x == 0 && tCenter.y == 0) {
    tCenter = (d[split - 1] - d[split]).normalized();
  }
  _fitCubic(d, first, split, tHat1, tCenter, errorSq, out, depth + 1);
  _fitCubic(d, split, last, tCenter * -1.0, tHat2, errorSq, out, depth + 1);
}

List<Vec> _generateBezier(List<Vec> d, int first, int last, List<double> u, Vec tHat1, Vec tHat2) {
  final Vec p0 = d[first];
  final Vec p3 = d[last];
  double c00 = 0, c01 = 0, c11 = 0, x0 = 0, x1 = 0;

  for (int i = 0; i < u.length; i++) {
    final double t = u[i];
    final double mt = 1 - t;
    final double b0 = mt * mt * mt;
    final double b1 = 3 * t * mt * mt;
    final double b2 = 3 * t * t * mt;
    final double b3 = t * t * t;
    final Vec a0 = tHat1 * b1;
    final Vec a1 = tHat2 * b2;
    c00 += a0.dot(a0);
    c01 += a0.dot(a1);
    c11 += a1.dot(a1);
    final Vec tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3));
    x0 += a0.dot(tmp);
    x1 += a1.dot(tmp);
  }

  final double det = c00 * c11 - c01 * c01;
  double alphaL = det == 0 ? 0 : (x0 * c11 - x1 * c01) / det;
  double alphaR = det == 0 ? 0 : (c00 * x1 - c01 * x0) / det;

  final double segLength = (p3 - p0).length;
  final double epsilon = 1.0e-6 * segLength;
  if (alphaL < epsilon || alphaR < epsilon) {
    alphaL = segLength / 3.0;
    alphaR = segLength / 3.0;
  }
  return [p0, p0 + tHat1 * alphaL, p3 + tHat2 * alphaR, p3];
}

Vec _bezierPoint(List<Vec> b, double t) {
  final double mt = 1 - t;
  final double b0 = mt * mt * mt;
  final double b1 = 3 * t * mt * mt;
  final double b2 = 3 * t * t * mt;
  final double b3 = t * t * t;
  return Vec(
    b[0].x * b0 + b[1].x * b1 + b[2].x * b2 + b[3].x * b3,
    b[0].y * b0 + b[1].y * b1 + b[2].y * b2 + b[3].y * b3,
  );
}

(double, int) _computeMaxError(List<Vec> d, int first, int last, List<Vec> bez, List<double> u) {
  int split = (last - first + 1) ~/ 2 + first;
  double maxDist = 0;
  for (int i = first + 1; i < last; i++) {
    final double dist = _bezierPoint(bez, u[i - first]).dist2(d[i]);
    if (dist >= maxDist) {
      maxDist = dist;
      split = i;
    }
  }
  split = split.clamp(first + 1, last - 1);
  return (maxDist, split);
}

List<double>? _chordLengthParameterize(List<Vec> d, int first, int last) {
  final List<double> u = List<double>.filled(last - first + 1, 0);
  for (int i = first + 1; i <= last; i++) {
    u[i - first] = u[i - first - 1] + (d[i] - d[i - 1]).length;
  }
  final double total = u.last;
  if (total == 0) return null;
  for (int i = 1; i < u.length; i++) {
    u[i] /= total;
  }
  return u;
}

List<double> _reparameterize(List<Vec> d, int first, int last, List<double> u, List<Vec> bez) {
  return [for (int i = first; i <= last; i++) _newtonRaphson(bez, d[i], u[i - first])];
}

double _newtonRaphson(List<Vec> q, Vec p, double u) {
  final Vec qu = _bezierPoint(q, u);
  final List<Vec> q1 = [for (int i = 0; i < 3; i++) (q[i + 1] - q[i]) * 3.0];
  final List<Vec> q2 = [for (int i = 0; i < 2; i++) (q1[i + 1] - q1[i]) * 2.0];

  final double mt = 1 - u;
  final Vec q1u = q1[0] * (mt * mt) + q1[1] * (2 * u * mt) + q1[2] * (u * u);
  final Vec q2u = q2[0] * mt + q2[1] * u;

  final Vec diff = qu - p;
  final double numerator = diff.dot(q1u);
  final double denominator = q1u.dot(q1u) + diff.dot(q2u);
  if (denominator == 0) return u;
  return (u - numerator / denominator).clamp(0.0, 1.0);
}
