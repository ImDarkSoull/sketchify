import 'dart:math' as math;
import 'dart:typed_data';

import 'curve_fit.dart';
import 'path_commands.dart';

/// Sub-pixel outlines of a coverage field.
///
/// [field] holds, for each pixel, how much of it belongs to the shape
/// (0 = none, 1 = fully). Values ≥ 0.5 count as inside. The outline is the
/// 0.5 level line between pixel centres, found with marching squares and
/// placed by linear interpolation, so anti-aliased edges give sub-pixel
/// accurate outlines. The field must be 0 along its border.
///
/// Returns closed loops as interleaved `[x0, y0, x1, y1, …]` in field
/// coordinates, where pixel (x, y) has its centre at (x, y).
List<Float64List> traceIsoLoops(Float32List field, int w, int h) {
  const double iso = 0.5;
  final int keys = w * h * 2;
  final Int32List nb1 = Int32List(keys)..fillRange(0, keys, -1);
  final Int32List nb2 = Int32List(keys)..fillRange(0, keys, -1);
  final Float64List ex = Float64List(keys);
  final Float64List ey = Float64List(keys);

  // Edge keys: horizontal edge from (x, y) to (x+1, y) → (y*w+x)*2,
  //            vertical edge from (x, y) to (x, y+1)   → (y*w+x)*2+1.
  int hKey(int x, int y) {
    final int k = (y * w + x) * 2;
    final double a = field[y * w + x], b = field[y * w + x + 1];
    ex[k] = x + (iso - a) / (b - a);
    ey[k] = y.toDouble();
    return k;
  }

  int vKey(int x, int y) {
    final int k = (y * w + x) * 2 + 1;
    final double a = field[y * w + x], b = field[(y + 1) * w + x];
    ex[k] = x.toDouble();
    ey[k] = y + (iso - a) / (b - a);
    return k;
  }

  void link(int a, int b) {
    if (nb1[a] == -1) {
      nb1[a] = b;
    } else {
      nb2[a] = b;
    }
    if (nb1[b] == -1) {
      nb1[b] = a;
    } else {
      nb2[b] = a;
    }
  }

  for (int y = 0; y < h - 1; y++) {
    for (int x = 0; x < w - 1; x++) {
      final int c =
          (field[y * w + x] >= iso ? 8 : 0) |
          (field[y * w + x + 1] >= iso ? 4 : 0) |
          (field[(y + 1) * w + x + 1] >= iso ? 2 : 0) |
          (field[(y + 1) * w + x] >= iso ? 1 : 0);
      if (c == 0 || c == 15) continue;
      int top() => hKey(x, y);
      int bottom() => hKey(x, y + 1);
      int left() => vKey(x, y);
      int right() => vKey(x + 1, y);
      switch (c) {
        case 1 || 14:
          link(left(), bottom());
        case 2 || 13:
          link(bottom(), right());
        case 3 || 12:
          link(left(), right());
        case 4 || 11:
          link(top(), right());
        case 6 || 9:
          link(top(), bottom());
        case 7 || 8:
          link(left(), top());
        case 5 || 10:
          // Saddle: the cell centre decides whether the diagonal inside
          // pixels join (keeps thin diagonal lines continuous).
          final double centre =
              (field[y * w + x] + field[y * w + x + 1] + field[(y + 1) * w + x] + field[(y + 1) * w + x + 1]) / 4;
          final bool joined = centre >= iso;
          if ((c == 5) == joined) {
            link(left(), top());
            link(bottom(), right());
          } else {
            link(top(), right());
            link(left(), bottom());
          }
      }
    }
  }

  final List<Float64List> loops = [];
  final Uint8List seen = Uint8List(keys);
  for (int start = 0; start < keys; start++) {
    if (nb1[start] == -1 || seen[start] == 1) continue;
    final List<double> pts = [];
    int prev = -1, cur = start;
    while (cur != -1 && seen[cur] == 0) {
      seen[cur] = 1;
      pts
        ..add(ex[cur])
        ..add(ey[cur]);
      final int next = nb1[cur] != prev ? nb1[cur] : nb2[cur];
      prev = cur;
      cur = next;
    }
    if (pts.length >= 6) loops.add(Float64List.fromList(pts));
  }
  return loops;
}

/// Converts a sub-pixel outline into smooth Bézier curves.
///
/// Round loops that match a circle or ellipse closely are drawn as an exact
/// ellipse. Otherwise the loop is lightly smoothed, split at real corners and
/// fitted with cubics. Coordinates are offset by ([ox], [oy]).
void isoLoopToCurves(Float64List loop, double ox, double oy, double tolerance, PathCommands out) {
  final int n = loop.length ~/ 2;
  if (n < 3) return;
  final List<Vec> raw = [for (int i = 0; i < n; i++) Vec(loop[i * 2] + ox, loop[i * 2 + 1] + oy)];

  if (_tryEllipse(raw, out)) return;

  if (n < 6) {
    out.addMoveTo(raw[0].x, raw[0].y);
    for (int i = 1; i < n; i++) {
      out.addLineTo(raw[i].x, raw[i].y);
    }
    out.addClose();
    return;
  }

  // Light [1 2 1] smoothing takes out the remaining pixel-grid ripple.
  List<Vec> pts = raw;
  for (int pass = 0; pass < 2; pass++) {
    pts = [for (int i = 0; i < n; i++) (pts[(i - 1 + n) % n] + pts[i] * 2.0 + pts[(i + 1) % n]) * 0.25];
  }

  double turnAt(int i, int k) {
    final Vec a = (pts[i] - pts[(i - k + n) % n]).normalized();
    final Vec b = (pts[(i + k) % n] - pts[i]).normalized();
    return 1.0 - a.dot(b); // 0 straight … 2 reversal
  }

  // A real corner turns sharply even over a short window; on a curve the turn
  // keeps growing as the window widens. Requiring both keeps small circles and
  // tight curves smooth.
  final int k = math.max(2, math.min(4, n ~/ 8));
  final List<double> turn = [for (int i = 0; i < n; i++) turnAt(i, k)];
  const double cornerThreshold = 0.5; // ≈ 60° turn
  final List<int> corners = [];
  for (int i = 0; i < n; i++) {
    if (turn[i] < cornerThreshold) continue;
    bool isMax = true;
    for (int j = 1; j <= k && isMax; j++) {
      if (turn[(i + j) % n] > turn[i] || turn[(i - j + n) % n] >= turn[i]) isMax = false;
    }
    if (!isMax) continue;
    if (n >= 4 * k && turn[i] < 0.6 * turnAt(i, 2 * k)) continue; // gradual curve, not a corner
    corners.add(i);
  }

  // Snap each corner to the sharpest unsmoothed point nearby so it stays crisp.
  final Map<int, Vec> cornerPoint = {};
  for (final int c in corners) {
    final Vec before = pts[(c - k + n) % n];
    final Vec after = pts[(c + k) % n];
    Vec best = pts[c];
    double bestTurn = -1;
    for (int j = c - 2; j <= c + 2; j++) {
      final Vec candidate = raw[(j % n + n) % n];
      final double t = 1.0 - (candidate - before).normalized().dot((after - candidate).normalized());
      if (t > bestTurn) {
        bestTurn = t;
        best = candidate;
      }
    }
    cornerPoint[c] = best;
  }

  final double errorSq = tolerance * tolerance;

  if (corners.isEmpty) {
    final List<Vec> run = [...pts, pts.first];
    final Vec tangent = (pts[1] - pts[n - 1]).normalized();
    out.addMoveTo(run.first.x, run.first.y);
    fitCubics(run, tangent, tangent * -1.0, errorSq, out);
    out.addClose();
    return;
  }

  out.addMoveTo(cornerPoint[corners.first]!.x, cornerPoint[corners.first]!.y);
  for (int ci = 0; ci < corners.length; ci++) {
    final int a = corners[ci];
    final int b = corners[(ci + 1) % corners.length];
    final int len = ((b - a) % n + n) % n;
    final List<Vec> run = [cornerPoint[a]!];
    for (int j = 1; j < (len == 0 ? n : len); j++) {
      run.add(pts[(a + j) % n]);
    }
    run.add(cornerPoint[b]!);
    if (run.length <= 3) {
      out.addLineTo(run.last.x, run.last.y);
      continue;
    }
    final Vec t1 = (run[math.min(2, run.length - 1)] - run.first).normalized();
    final Vec t2 = (run[math.max(0, run.length - 3)] - run.last).normalized();
    fitCubics(run, t1, t2, errorSq, out);
  }
  out.addClose();
}

/// Draws [pts] as an exact (possibly rotated) ellipse if they fit one well.
bool _tryEllipse(List<Vec> pts, PathCommands out) {
  final int n = pts.length;
  if (n < 4) return false;

  double cx = 0, cy = 0;
  for (final p in pts) {
    cx += p.x;
    cy += p.y;
  }
  cx /= n;
  cy /= n;

  double sxx = 0, syy = 0, sxy = 0;
  for (final p in pts) {
    final double dx = p.x - cx, dy = p.y - cy;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  sxx /= n;
  syy /= n;
  sxy /= n;
  final double angle = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final double cosA = math.cos(angle), sinA = math.sin(angle);

  // Least squares for A = 1/a², B = 1/b² in A·u² + B·v² = 1.
  double s40 = 0, s22 = 0, s04 = 0, s20 = 0, s02 = 0;
  final List<double> us = List<double>.filled(n, 0), vs = List<double>.filled(n, 0);
  for (int i = 0; i < n; i++) {
    final double dx = pts[i].x - cx, dy = pts[i].y - cy;
    final double u = dx * cosA + dy * sinA;
    final double v = -dx * sinA + dy * cosA;
    us[i] = u;
    vs[i] = v;
    s40 += u * u * u * u;
    s22 += u * u * v * v;
    s04 += v * v * v * v;
    s20 += u * u;
    s02 += v * v;
  }
  final double det = s40 * s04 - s22 * s22;
  if (det.abs() < 1e-12) return false;
  final double aInv = (s20 * s04 - s02 * s22) / det;
  final double bInv = (s40 * s02 - s22 * s20) / det;
  if (aInv <= 0 || bInv <= 0) return false;
  final double a = 1 / math.sqrt(aInv), b = 1 / math.sqrt(bInv);
  final double minor = math.min(a, b), major = math.max(a, b);
  if (minor < 0.5 || major / minor > 8) return false;

  // Every point must sit within a small distance of the ellipse.
  final double allowed = math.max(0.3, 0.035 * minor);
  for (int i = 0; i < n; i++) {
    final double rho = math.sqrt(us[i] * us[i] * aInv + vs[i] * vs[i] * bInv);
    if (rho == 0) return false;
    final double r = math.sqrt(us[i] * us[i] + vs[i] * vs[i]);
    if ((rho - 1).abs() * r / rho > allowed) return false;
  }
  // Points must go all the way round, not just cover an arc.
  final List<double> angles = [for (int i = 0; i < n; i++) math.atan2(vs[i] / b, us[i] / a)]..sort();
  double gap = angles.first + 2 * math.pi - angles.last;
  for (int i = 1; i < n; i++) {
    gap = math.max(gap, angles[i] - angles[i - 1]);
  }
  if (gap > math.pi / 2) return false;

  const double kappa = 0.5522847498;
  Vec at(double t) {
    final double x = a * math.cos(t), y = b * math.sin(t);
    return Vec(cx + x * cosA - y * sinA, cy + x * sinA + y * cosA);
  }

  Vec dir(double t) {
    final double x = -a * math.sin(t), y = b * math.cos(t);
    return Vec(x * cosA - y * sinA, x * sinA + y * cosA);
  }

  final Vec start = at(0);
  out.addMoveTo(start.x, start.y);
  for (int q = 0; q < 4; q++) {
    final double t0 = q * math.pi / 2, t1 = (q + 1) * math.pi / 2;
    final Vec p0 = at(t0), p1 = at(t1);
    final Vec c1 = p0 + dir(t0) * kappa, c2 = p1 - dir(t1) * kappa;
    out.addCubicTo(c1.x, c1.y, c2.x, c2.y, p1.x, p1.y);
  }
  out.addClose();
  return true;
}
