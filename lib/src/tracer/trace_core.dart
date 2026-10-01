import 'dart:math' as math;
import 'dart:typed_data';

import 'contours.dart';
import 'path_commands.dart';

/// Input for [traceImage]. Plain data so it can be sent to an isolate.
class TraceRequest {
  /// Straight-alpha RGBA pixels used for tracing (usually downscaled).
  final Uint8List rgba;
  final int width;
  final int height;

  /// Full-resolution straight-alpha RGBA, used to cut out a solid background.
  final Uint8List? fullRgba;
  final int fullWidth;
  final int fullHeight;

  final bool removeBackground;

  /// Also remove background-coloured areas that don't touch the border.
  final bool removeEnclosedBackground;
  final int maxColors;
  final double colorTolerance;
  final double curveTolerance;
  final double minShapeFraction;

  const TraceRequest({
    required this.rgba,
    required this.width,
    required this.height,
    this.fullRgba,
    this.fullWidth = 0,
    this.fullHeight = 0,
    required this.removeBackground,
    this.removeEnclosedBackground = true,
    required this.maxColors,
    required this.colorTolerance,
    required this.curveTolerance,
    required this.minShapeFraction,
  });
}

class TracedShapeData {
  /// 0xAARRGGBB.
  final int color;
  final Float32List commands;

  const TracedShapeData(this.color, this.commands);
}

class TraceResult {
  final int width;
  final int height;

  /// Shapes bottom to top, in trace-pixel coordinates.
  final List<TracedShapeData> shapes;

  /// Detected colours (0xAARRGGBB), most common first. Excludes the background.
  final List<int> palette;

  /// Solid background colour that was detected and removed, if any.
  final int? backgroundColor;

  /// Full-resolution premultiplied RGBA with the background removed, when a
  /// solid background was cut out. Null means use the original image as is.
  final Uint8List? cutoutRgba;

  const TraceResult({
    required this.width,
    required this.height,
    required this.shapes,
    required this.palette,
    this.backgroundColor,
    this.cutoutRgba,
  });
}

int _dist2(int r1, int g1, int b1, int r2, int g2, int b2) {
  final int dr = r1 - r2, dg = g1 - g2, db = b1 - b2;
  return dr * dr + dg * dg + db * db;
}

/// Traces an image into layered, coloured vector shapes.
TraceResult traceImage(TraceRequest req) {
  final int w = req.width, h = req.height, n = w * h;
  final Uint8List px = req.rgba;
  final int tol2 = (req.colorTolerance * req.colorTolerance).round();

  // ── 1. Background ────────────────────────────────────────────────────────
  int transparent = 0;
  for (int i = 0; i < n; i++) {
    if (px[i * 4 + 3] < 128) transparent++;
  }
  final bool alphaMode = transparent > n * 0.005;
  final int? bg = (!alphaMode && req.removeBackground) ? _detectBorderColor(px, w, h, tol2) : null;
  final int bgR = bg == null ? 0 : (bg >> 16) & 255;
  final int bgG = bg == null ? 0 : (bg >> 8) & 255;
  final int bgB = bg == null ? 0 : bg & 255;

  bool isBackgroundish(int i) {
    if (px[i * 4 + 3] < 128) return true;
    return bg != null && _dist2(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], bgR, bgG, bgB) < tol2;
  }

  // ── 2. Palette from flat (non-edge) pixels ──────────────────────────────
  final List<List<int>> palette = _buildPalette(px, w, h, req.maxColors, tol2, isBackgroundish, bg);
  _addThinLineColors(px, w, h, palette, bg, req.maxColors, tol2, isBackgroundish);
  final int k = palette.length;

  // Label colours: index 0 is the background, 1..k the palette.
  Int32List lr = Int32List(k + 1), lg = Int32List(k + 1), lb = Int32List(k + 1);
  lr[0] = bgR;
  lg[0] = bgG;
  lb[0] = bgB;
  for (int c = 0; c < k; c++) {
    lr[c + 1] = palette[c][0];
    lg[c + 1] = palette[c][1];
    lb[c + 1] = palette[c][2];
  }
  final bool bgHasColor = bg != null;

  // ── 3. Label every pixel ────────────────────────────────────────────────
  Uint8List labels = Uint8List(n);
  for (int i = 0; i < n; i++) {
    if (px[i * 4 + 3] < 128) continue; // transparent → 0
    labels[i] = _nearestLabel(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], lr, lg, lb, bgHasColor);
  }

  // ── 4. Anti-aliased edge pixels → the real colours they blend ───────────
  labels = _fixBlends(px, labels, w, h, lr, lg, lb, bgHasColor);
  // Twice, so gaps up to two pixels long close.
  _bridgeLineGaps(px, labels, w, h, lr, lg, lb, bgHasColor);
  _bridgeLineGaps(px, labels, w, h, lr, lg, lb, bgHasColor);

  // ── 5. Merge specks ──────────────────────────────────────────────────────
  final int minArea = math.max(4, (n * req.minShapeFraction).round());
  var comps = _Components.compute(labels, w, h);
  if (_mergeSmall(labels, comps, w, h, minArea, px, lr, lg, lb, bgHasColor, tol2)) {
    comps = _Components.compute(labels, w, h);
  }

  // ── 5b. Keep enclosed background-coloured areas as artwork ──────────────
  if (bg != null && !req.removeEnclosedBackground) {
    final Set<int> enclosed = {
      for (int c = 0; c < comps.count; c++)
        if (comps.label[c] == 0 &&
            comps.minX[c] > 0 &&
            comps.minY[c] > 0 &&
            comps.maxX[c] < w - 1 &&
            comps.maxY[c] < h - 1)
          c,
    };
    if (enclosed.isNotEmpty) {
      // A label of their own with the background's colour.
      final int keep = lr.length;
      lr = Int32List(keep + 1)
        ..setRange(0, keep, lr)
        ..[keep] = bgR;
      lg = Int32List(keep + 1)
        ..setRange(0, keep, lg)
        ..[keep] = bgG;
      lb = Int32List(keep + 1)
        ..setRange(0, keep, lb)
        ..[keep] = bgB;
      for (int i = 0; i < n; i++) {
        if (enclosed.contains(comps.id[i])) labels[i] = keep;
      }
      for (final int c in enclosed) {
        comps.label[c] = keep;
      }
    }
  }

  // ── 6. Layer order: a shape is drawn after the shape enclosing it ───────
  final Int32List depth = comps.depths(w);
  final List<int> order = [
    for (int c = 0; c < comps.count; c++)
      if (comps.label[c] != 0) c,
  ]..sort((a, b) => depth[a] != depth[b] ? depth[a] - depth[b] : a - b);

  // ── 7. Outline + curve fit each shape ───────────────────────────────────
  final List<TracedShapeData> shapes = [];
  for (final int c in order) {
    final PathCommands cmds = _traceComponent(c, comps, labels, w, req.curveTolerance, px, lr, lg, lb, alphaMode);
    if (cmds.isEmpty) continue;
    final int l = comps.label[c];
    shapes.add(TracedShapeData(0xFF000000 | (lr[l] << 16) | (lg[l] << 8) | lb[l], cmds.build()));
  }

  // ── 8. Cut out a solid background at full resolution ────────────────────
  Uint8List? cutout;
  if (bg != null && req.fullRgba != null) {
    cutout = _cutout(req.fullRgba!, req.fullWidth, req.fullHeight, lr, lg, lb, req.removeEnclosedBackground);
  }

  return TraceResult(
    width: w,
    height: h,
    shapes: shapes,
    palette: [for (final p in palette) 0xFF000000 | (p[0] << 16) | (p[1] << 8) | p[2]],
    backgroundColor: bg == null ? null : 0xFF000000 | bg,
    cutoutRgba: cutout,
  );
}

int _nearestLabel(int r, int g, int b, Int32List lr, Int32List lg, Int32List lb, bool includeBg) {
  // No colours at all: everything is background.
  if (lr.length < 2 && !includeBg) return 0;
  int best = includeBg ? 0 : 1;
  int bestD = 1 << 30;
  for (int l = includeBg ? 0 : 1; l < lr.length; l++) {
    final int d = _dist2(r, g, b, lr[l], lg[l], lb[l]);
    if (d < bestD) {
      bestD = d;
      best = l;
    }
  }
  return best;
}

/// Dominant border colour (0xRRGGBB) if it covers most of the border.
int? _detectBorderColor(Uint8List px, int w, int h, int tol2) {
  final List<int> border = [];
  for (int x = 0; x < w; x++) {
    border
      ..add(x)
      ..add((h - 1) * w + x);
  }
  for (int y = 1; y < h - 1; y++) {
    border
      ..add(y * w)
      ..add(y * w + w - 1);
  }
  final Map<int, int> bins = {};
  for (final int i in border) {
    final int key = ((px[i * 4] >> 3) << 10) | ((px[i * 4 + 1] >> 3) << 5) | (px[i * 4 + 2] >> 3);
    bins[key] = (bins[key] ?? 0) + 1;
  }
  final int topKey = bins.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  final int cr = ((topKey >> 10) << 3) + 4, cg = (((topKey >> 5) & 31) << 3) + 4, cb = ((topKey & 31) << 3) + 4;

  int count = 0, sr = 0, sg = 0, sb = 0;
  for (final int i in border) {
    if (_dist2(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], cr, cg, cb) < tol2) {
      count++;
      sr += px[i * 4];
      sg += px[i * 4 + 1];
      sb += px[i * 4 + 2];
    }
  }
  if (count < border.length * 0.5) return null;
  return ((sr ~/ count) << 16) | ((sg ~/ count) << 8) | (sb ~/ count);
}

List<List<int>> _buildPalette(
  Uint8List px,
  int w,
  int h,
  int maxColors,
  int tol2,
  bool Function(int) isBackgroundish,
  int? bg,
) {
  // 15-bit colour histogram of flat pixels: sumR, sumG, sumB, count.
  Int32List collect({required bool flatOnly, int minAlpha = 250}) {
    final Int32List bins = Int32List(32768 * 4);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int i = y * w + x;
        if (isBackgroundish(i) || px[i * 4 + 3] < minAlpha) continue;
        final int r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
        if (flatOnly) {
          if (x == 0 || y == 0 || x == w - 1 || y == h - 1) continue;
          bool flat = true;
          for (final int j in [i - 1, i + 1, i - w, i + w]) {
            if ((px[j * 4] - r).abs() > 10 ||
                (px[j * 4 + 1] - g).abs() > 10 ||
                (px[j * 4 + 2] - b).abs() > 10 ||
                px[j * 4 + 3] < minAlpha) {
              flat = false;
              break;
            }
          }
          if (!flat) continue;
        }
        final int key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
        bins[key * 4] += r;
        bins[key * 4 + 1] += g;
        bins[key * 4 + 2] += b;
        bins[key * 4 + 3]++;
      }
    }
    return bins;
  }

  Int32List bins = collect(flatOnly: true);
  int total = 0;
  for (int key = 0; key < 32768; key++) {
    total += bins[key * 4 + 3];
  }
  // Few flat pixels (e.g. line art): sample every pixel, which also picks up
  // anti-aliasing blends; those are dropped again below.
  final bool sampledEdges = total < w * h * 0.01;
  if (sampledEdges) {
    bins = collect(flatOnly: false);
    total = 0;
    for (int key = 0; key < 32768; key++) {
      total += bins[key * 4 + 3];
    }
  }
  if (total == 0) {
    // Semi-transparent artwork (e.g. a watermark): use every visible pixel.
    bins = collect(flatOnly: false, minAlpha: 128);
    for (int key = 0; key < 32768; key++) {
      total += bins[key * 4 + 3];
    }
  }
  if (total == 0) return [];

  final List<int> keys = [
    for (int key = 0; key < 32768; key++)
      if (bins[key * 4 + 3] > 0) key,
  ]..sort((a, b) => bins[b * 4 + 3] - bins[a * 4 + 3]);

  // Greedy clustering, biggest bins first.
  final int minCluster = math.max(3, (total * 0.0002).round());
  final List<List<double>> centers = []; // r, g, b, weight
  for (final int key in keys) {
    final double c = bins[key * 4 + 3].toDouble();
    final double r = bins[key * 4] / c, g = bins[key * 4 + 1] / c, b = bins[key * 4 + 2] / c;
    int nearest = -1;
    double nearestD = double.infinity;
    for (int j = 0; j < centers.length; j++) {
      final double dr = centers[j][0] - r, dg = centers[j][1] - g, db = centers[j][2] - b;
      final double d = dr * dr + dg * dg + db * db;
      if (d < nearestD) {
        nearestD = d;
        nearest = j;
      }
    }
    if (nearest >= 0 && nearestD < tol2) {
      final List<double> ct = centers[nearest];
      final double wsum = ct[3] + c;
      ct[0] = (ct[0] * ct[3] + r * c) / wsum;
      ct[1] = (ct[1] * ct[3] + g * c) / wsum;
      ct[2] = (ct[2] * ct[3] + b * c) / wsum;
      ct[3] = wsum;
    } else if (c >= minCluster && centers.length < maxColors) {
      centers.add([r, g, b, c]);
    }
  }

  // A few k-means passes over the histogram to settle the centres.
  for (int iter = 0; iter < 4 && centers.isNotEmpty; iter++) {
    final List<List<double>> acc = [
      for (final _ in centers) [0.0, 0.0, 0.0, 0.0],
    ];
    for (final int key in keys) {
      final double c = bins[key * 4 + 3].toDouble();
      final double r = bins[key * 4] / c, g = bins[key * 4 + 1] / c, b = bins[key * 4 + 2] / c;
      int nearest = 0;
      double nearestD = double.infinity;
      for (int j = 0; j < centers.length; j++) {
        final double dr = centers[j][0] - r, dg = centers[j][1] - g, db = centers[j][2] - b;
        final double d = dr * dr + dg * dg + db * db;
        if (d < nearestD) {
          nearestD = d;
          nearest = j;
        }
      }
      if (nearestD > tol2 * 4) continue; // outliers (blends) don't drag centres
      acc[nearest][0] += bins[key * 4];
      acc[nearest][1] += bins[key * 4 + 1];
      acc[nearest][2] += bins[key * 4 + 2];
      acc[nearest][3] += c;
    }
    for (int j = 0; j < centers.length; j++) {
      if (acc[j][3] == 0) continue;
      centers[j] = [acc[j][0] / acc[j][3], acc[j][1] / acc[j][3], acc[j][2] / acc[j][3], acc[j][3]];
    }
  }

  centers.sort((a, b) => b[3].compareTo(a[3]));
  final List<List<int>> colors = [
    for (final ct in centers)
      if (ct[3] > 0) [ct[0].round().clamp(0, 255), ct[1].round().clamp(0, 255), ct[2].round().clamp(0, 255)],
  ];
  if (!sampledEdges) return colors;

  // Keep a colour only if it isn't a blend of the background and the
  // stronger colours already kept (most common first).
  final List<List<int>> kept = [];
  final List<int>? bgColor = bg == null ? null : [(bg >> 16) & 255, (bg >> 8) & 255, bg & 255];
  for (final List<int> c in colors) {
    if (!_isMixOrOvershoot(c, [?bgColor, ...kept], tol2)) kept.add(c);
  }
  return kept;
}

/// Edge pixels that are a mix of two neighbouring colours get the nearer of
/// those two, instead of an unrelated third colour that happens to be close.
Uint8List _fixBlends(
  Uint8List px,
  Uint8List labels,
  int w,
  int h,
  Int32List lr,
  Int32List lg,
  Int32List lb,
  bool bgHasColor,
) {
  final Uint8List out = Uint8List.fromList(labels);
  final List<int> cand = [];
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final int i = y * w + x;
      final int own = labels[i];
      if (px[i * 4 + 3] < 128) continue;
      cand.clear();
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final int l = labels[i + dy * w + dx];
          if (!cand.contains(l) && (l != 0 || bgHasColor)) cand.add(l);
        }
      }
      if (cand.length < 2) continue;

      final double r = px[i * 4].toDouble(), g = px[i * 4 + 1].toDouble(), b = px[i * 4 + 2].toDouble();
      final double ownD = math.sqrt(_dist2(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], lr[own], lg[own], lb[own]));
      double bestD = double.infinity;
      int bestLabel = own;
      for (int a = 0; a < cand.length; a++) {
        for (int c = a + 1; c < cand.length; c++) {
          final int la = cand[a], lc = cand[c];
          final double ar = lr[la].toDouble(), ag = lg[la].toDouble(), ab = lb[la].toDouble();
          final double vr = lr[lc] - ar, vg = lg[lc] - ag, vb = lb[lc] - ab;
          final double len2 = vr * vr + vg * vg + vb * vb;
          if (len2 == 0) continue;
          // Slightly beyond either end (to 135%) is resampling overshoot of
          // that colour, so it still belongs to it.
          final double t = (((r - ar) * vr + (g - ag) * vg + (b - ab) * vb) / len2).clamp(-0.35, 1.35);
          final double er = ar + vr * t - r, eg = ag + vg * t - g, eb = ab + vb * t - b;
          final double d = math.sqrt(er * er + eg * eg + eb * eb);
          if (d < bestD) {
            bestD = d;
            bestLabel = t < 0.5 ? la : lc;
          }
        }
      }
      if (bestD + 3 < ownD) out[i] = bestLabel;
    }
  }
  return out;
}

/// Closes one-pixel gaps in thin lines. Where a line runs at an angle, some
/// of its pixels are covered less than half and get the background's label,
/// breaking the line. A pixel with the same colour on two opposite sides that
/// is at least partly that colour joins it.
void _bridgeLineGaps(
  Uint8List px,
  Uint8List labels,
  int w,
  int h,
  Int32List lr,
  Int32List lg,
  Int32List lb,
  bool bgHasColor,
) {
  final Uint8List source = Uint8List.fromList(labels);
  // Opposite neighbour pairs: W–E, N–S, NW–SE, NE–SW.
  final List<int> pairs = [-1, 1, -w, w, -w - 1, w + 1, -w + 1, w - 1];
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final int i = y * w + x;
      final int own = source[i];
      if (own == 0 && !bgHasColor) continue;
      for (int p = 0; p < pairs.length; p += 2) {
        final int line = source[i + pairs[p]];
        if (line == own || line != source[i + pairs[p + 1]] || (line == 0 && !bgHasColor)) continue;
        // How much of this pixel is the line's colour.
        final double vr = (lr[line] - lr[own]).toDouble(), vg = (lg[line] - lg[own]).toDouble();
        final double vb = (lb[line] - lb[own]).toDouble();
        final double len2 = vr * vr + vg * vg + vb * vb;
        if (len2 == 0) continue;
        final double t =
            ((px[i * 4] - lr[own]) * vr + (px[i * 4 + 1] - lg[own]) * vg + (px[i * 4 + 2] - lb[own]) * vb) / len2;
        if (t >= 0.3) {
          labels[i] = line;
          break;
        }
      }
    }
  }
}

/// 8-connected components of equal label.
class _Components {
  final Int32List id;
  final int count;
  final List<int> label;
  final List<int> size;
  final List<int> first; // raster-order first pixel = topmost, then leftmost
  final List<int> minX, minY, maxX, maxY;

  _Components(this.id, this.count, this.label, this.size, this.first, this.minX, this.minY, this.maxX, this.maxY);

  static _Components compute(Uint8List labels, int w, int h) {
    final int n = w * h;
    final Int32List id = Int32List(n)..fillRange(0, n, -1);
    final List<int> lab = [], size = [], first = [], minX = [], minY = [], maxX = [], maxY = [];
    final Int32List stack = Int32List(n);
    int count = 0;
    for (int s = 0; s < n; s++) {
      if (id[s] != -1) continue;
      final int l = labels[s];
      int sp = 0, sz = 0;
      int x0 = w, y0 = h, x1 = 0, y1 = 0;
      stack[sp++] = s;
      id[s] = count;
      while (sp > 0) {
        final int i = stack[--sp];
        sz++;
        final int x = i % w, y = i ~/ w;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
        // 8-connected, so thin diagonal lines stay one shape.
        for (int dy = -1; dy <= 1; dy++) {
          final int ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (int dx = -1; dx <= 1; dx++) {
            final int nx = x + dx;
            if ((dx == 0 && dy == 0) || nx < 0 || nx >= w) continue;
            final int j = ny * w + nx;
            if (id[j] == -1 && labels[j] == l) {
              id[j] = count;
              stack[sp++] = j;
            }
          }
        }
      }
      lab.add(l);
      size.add(sz);
      first.add(s);
      minX.add(x0);
      minY.add(y0);
      maxX.add(x1);
      maxY.add(y1);
      count++;
    }
    return _Components(id, count, lab, size, first, minX, minY, maxX, maxY);
  }

  /// Nesting depth via the pixel just above each component's top-left pixel.
  /// Everything inside a shape's hole ends up deeper than that shape.
  Int32List depths(int w) {
    final Int32List depth = Int32List(count)..fillRange(0, count, -1);
    final List<int> chain = [];
    for (int c = 0; c < count; c++) {
      int cur = c;
      chain.clear();
      while (cur != -1 && depth[cur] == -1) {
        chain.add(cur);
        final int f = first[cur];
        cur = f < w ? -1 : id[f - w];
      }
      int d = cur == -1 ? 0 : depth[cur] + 1;
      for (int j = chain.length - 1; j >= 0; j--) {
        depth[chain[j]] = d++;
      }
    }
    return depth;
  }
}

/// Relabels specks (smaller than [minArea]) and anti-aliasing strips to their
/// most common neighbour. A strip is a hairline (never more than one pixel
/// thick) whose colour is just a mix of the two colours either side of it;
/// real thin lines keep their own colour.
bool _mergeSmall(
  Uint8List labels,
  _Components comps,
  int w,
  int h,
  int minArea,
  Uint8List px,
  Int32List lr,
  Int32List lg,
  Int32List lb,
  bool bgHasColor,
  int tol2,
) {
  final Int32List interior = Int32List(comps.count);
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final int i = y * w + x;
      final int c = comps.id[i];
      if (comps.id[i - 1] == c && comps.id[i + 1] == c && comps.id[i - w] == c && comps.id[i + w] == c) {
        interior[c]++;
      }
    }
  }
  final List<int> candidates = [
    for (int c = 0; c < comps.count; c++)
      if (comps.size[c] < minArea * 50) c,
  ];
  if (candidates.isEmpty) return false;
  final Set<int> candidateSet = candidates.toSet();
  final Map<int, List<int>> pixels = {for (final c in candidates) c: []};
  for (int i = 0; i < w * h; i++) {
    final int c = comps.id[i];
    if (candidateSet.contains(c)) pixels[c]!.add(i);
  }
  bool changed = false;
  for (final int c in candidates) {
    final Map<int, int> votes = {};
    int alphaSum = 0, rSum = 0, gSum = 0, bSum = 0;
    for (final int i in pixels[c]!) {
      alphaSum += px[i * 4 + 3];
      rSum += px[i * 4];
      gSum += px[i * 4 + 1];
      bSum += px[i * 4 + 2];
      final int x = i % w, y = i ~/ w;
      for (final int j in [if (x > 0) i - 1, if (x < w - 1) i + 1, if (y > 0) i - w, if (y < h - 1) i + w]) {
        if (comps.id[j] == c) continue;
        votes[labels[j]] = (votes[labels[j]] ?? 0) + 1;
      }
    }
    if (votes.isEmpty) continue;
    final List<int> ranked = votes.keys.toList()..sort((a, b) => votes[b]! - votes[a]!);
    final int own = comps.label[c];
    final int count = pixels[c]!.length;
    // The piece's actual colour, which may differ from its palette label.
    List<int> ownColor() => [rSum ~/ count, gSum ~/ count, bSum ~/ count];
    List<int> colorOf(int l) => [lr[l], lg[l], lb[l]];
    bool hasColor(int l) => l != 0 || bgHasColor;

    // Resampling overshoot just past a neighbouring colour belongs to that
    // colour, so a line keeps its colour instead of breaking up.
    int? overshootOf;
    if (hasColor(own)) {
      for (final int a in ranked) {
        if (a == own || !hasColor(a)) continue;
        for (final int b in ranked) {
          if (b == a || b == own || !hasColor(b)) continue;
          final List<int> o = ownColor();
          if (_segmentResidual2(o[0], o[1], o[2], colorOf(b), colorOf(a), 1.0, 1.35) < tol2 * 0.36) {
            overshootOf = a;
            break;
          }
        }
        if (overshootOf != null) break;
      }
    }

    // A small piece mostly surrounded by one close colour is a variation of
    // that colour (e.g. a heavier spot on a line), not a detail of its own.
    int? surroundedBy;
    if (overshootOf == null && hasColor(own)) {
      final int totalVotes = votes.values.fold(0, (sum, v) => sum + v);
      // The main colour around it, ignoring the background.
      final int main = ranked.firstWhere((l) => l != 0 && l != own, orElse: () => -1);
      if (main != -1 && votes[main]! * 10 >= totalVotes * 3) {
        final List<int> o = ownColor();
        if (_dist2(o[0], o[1], o[2], lr[main], lg[main], lb[main]) < tol2 * 2.25) surroundedBy = main;
      }
    }

    int to;
    if (overshootOf != null) {
      to = overshootOf;
    } else if (surroundedBy != null) {
      to = surroundedBy;
    } else if (comps.size[c] < minArea) {
      // Specks join the neighbour closest in colour (keeps thin lines whole).
      to = ranked.first;
      if (hasColor(own)) {
        double best = double.infinity;
        final List<int> o = ownColor();
        for (final int l in ranked) {
          if (!hasColor(l)) continue;
          final double d = _dist2(o[0], o[1], o[2], lr[l], lg[l], lb[l]).toDouble();
          if (d < best) {
            best = d;
            to = l;
          }
        }
      }
    } else {
      // A hairline: only merge it if it is anti-aliasing between two colours.
      if (interior[c] > 0) continue;
      to = ranked.first;
      if (ranked.length < 2) continue;
      final int a = ranked[0], b = ranked[1];
      // A blend strip runs between two regions, so it borders both of them
      // along its length — not just a few stray pixels of the second colour.
      final int totalVotes = votes.values.fold(0, (sum, v) => sum + v);
      if (votes[b]! < totalVotes * 0.25) continue;
      final bool isBlend;
      if (!hasColor(a) || !hasColor(b)) {
        isBlend = alphaSum / pixels[c]!.length < 200; // semi-transparent edge
      } else {
        final List<int> o = ownColor();
        isBlend = _segmentResidual2(o[0], o[1], o[2], colorOf(a), colorOf(b), 0.1, 0.9) < tol2 * 0.36;
      }
      if (!isBlend) continue;
    }
    changed = true;
    for (final int i in pixels[c]!) {
      labels[i] = to;
    }
  }
  return changed;
}

/// Mask of the component plus any holes that hold no background, so the
/// shape sits under the shapes drawn inside it without seams; holes that do
/// show background stay open.
PathCommands _traceComponent(
  int c,
  _Components comps,
  Uint8List labels,
  int w,
  double tolerance,
  Uint8List px,
  Int32List lr,
  Int32List lg,
  Int32List lb,
  bool alphaMode,
) {
  final int x0 = comps.minX[c] - 1, y0 = comps.minY[c] - 1;
  final int lw = comps.maxX[c] - comps.minX[c] + 3, lh = comps.maxY[c] - comps.minY[c] + 3;
  final int ln = lw * lh;
  final int h = labels.length ~/ w;

  // 1 = shape, 0 = unknown, 2 = outside, 3 = hole being visited, 4 = open hole
  final Uint8List m = Uint8List(ln);
  for (int ly = 1; ly < lh - 1; ly++) {
    final int gy = y0 + ly;
    for (int lx = 1; lx < lw - 1; lx++) {
      if (comps.id[gy * w + x0 + lx] == c) m[ly * lw + lx] = 1;
    }
  }

  final Int32List stack = Int32List(ln);
  int flood(int seed, int value, {bool trackBg = false}) {
    int sp = 0, bgSeen = 0;
    stack[sp++] = seed;
    m[seed] = value;
    while (sp > 0) {
      final int i = stack[--sp];
      final int lx = i % lw, ly = i ~/ lw;
      if (trackBg && bgSeen == 0) {
        final int gx = x0 + lx, gy = y0 + ly;
        if (gx >= 0 && gy >= 0 && gx < w && gy < h && labels[gy * w + gx] == 0) bgSeen = 1;
      }
      if (lx > 0 && m[i - 1] == 0) {
        m[i - 1] = value;
        stack[sp++] = i - 1;
      }
      if (lx < lw - 1 && m[i + 1] == 0) {
        m[i + 1] = value;
        stack[sp++] = i + 1;
      }
      if (ly > 0 && m[i - lw] == 0) {
        m[i - lw] = value;
        stack[sp++] = i - lw;
      }
      if (ly < lh - 1 && m[i + lw] == 0) {
        m[i + lw] = value;
        stack[sp++] = i + lw;
      }
    }
    return bgSeen;
  }

  flood(0, 2);
  for (int i = 0; i < ln; i++) {
    if (m[i] != 0) continue;
    final bool open = flood(i, 3, trackBg: true) == 1;
    // Second pass over this hole to settle its final value.
    final int fillValue = open ? 4 : 1;
    int sp = 0;
    stack[sp++] = i;
    m[i] = fillValue;
    while (sp > 0) {
      final int j = stack[--sp];
      final int lx = j % lw, ly = j ~/ lw;
      for (final int q in [if (lx > 0) j - 1, if (lx < lw - 1) j + 1, if (ly > 0) j - lw, if (ly < lh - 1) j + lw]) {
        if (m[q] == 3) {
          m[q] = fillValue;
          stack[sp++] = q;
        }
      }
    }
  }

  final Float32List field = _coverageField(m, lw, lh, x0, y0, comps.label[c], labels, w, h, px, lr, lg, lb, alphaMode);
  final PathCommands cmds = PathCommands();
  for (final loop in traceIsoLoops(field, lw, lh)) {
    // Field cell (lx, ly) is centred on image point (x0 + lx + 0.5, y0 + ly + 0.5).
    isoLoopToCurves(loop, x0 + 0.5, y0 + 0.5, tolerance, cmds);
  }
  return cmds;
}

/// How much of each pixel belongs to the shape, from its anti-aliasing.
///
/// Edge pixels are un-mixed between the shape's colour and the colour on the
/// other side of the edge. Values stay on the correct side of 0.5 so the
/// outline keeps exactly the mask's shape and only moves within a pixel.
Float32List _coverageField(
  Uint8List m,
  int lw,
  int lh,
  int x0,
  int y0,
  int shapeLabel,
  Uint8List labels,
  int w,
  int h,
  Uint8List px,
  Int32List lr,
  Int32List lg,
  Int32List lb,
  bool alphaMode,
) {
  final Float32List field = Float32List(lw * lh);
  final Map<int, int> votes = {};

  double unmix(int g, int other, bool inside) {
    if (other == 0 && alphaMode) return px[g * 4 + 3] / 255.0;
    final double vr = (lr[shapeLabel] - lr[other]).toDouble();
    final double vg = (lg[shapeLabel] - lg[other]).toDouble();
    final double vb = (lb[shapeLabel] - lb[other]).toDouble();
    final double len2 = vr * vr + vg * vg + vb * vb;
    if (len2 < 1) return inside ? 0.75 : 0.25;
    return ((px[g * 4] - lr[other]) * vr + (px[g * 4 + 1] - lg[other]) * vg + (px[g * 4 + 2] - lb[other]) * vb) / len2;
  }

  for (int ly = 1; ly < lh - 1; ly++) {
    for (int lx = 1; lx < lw - 1; lx++) {
      final int i = ly * lw + lx;
      final bool inside = m[i] == 1;
      bool edge = false;
      for (int dy = -1; dy <= 1 && !edge; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if ((m[i + dy * lw + dx] == 1) != inside) {
            edge = true;
            break;
          }
        }
      }
      if (!edge) {
        field[i] = inside ? 1.0 : 0.0;
        continue;
      }
      final int gx = x0 + lx, gy = y0 + ly;
      if (gx < 0 || gy < 0 || gx >= w || gy >= h) continue;
      final int g = gy * w + gx;

      double t;
      if (inside) {
        // The colour across the edge: most common outside neighbour.
        votes.clear();
        for (int dy = -1; dy <= 1; dy++) {
          for (int dx = -1; dx <= 1; dx++) {
            if (m[i + dy * lw + dx] == 1) continue;
            final int nx = gx + dx, ny = gy + dy;
            final int l = (nx < 0 || ny < 0 || nx >= w || ny >= h) ? 0 : labels[ny * w + nx];
            votes[l] = (votes[l] ?? 0) + 1;
          }
        }
        final int other = votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
        t = unmix(g, other, true);
        field[i] = t.clamp(0.5, 1.0);
      } else {
        t = unmix(g, labels[g], false);
        field[i] = t.clamp(0.0, 0.4999);
      }
    }
  }
  return field;
}

/// Adds colours that only appear in thin lines (no flat pixels of their own).
///
/// Repeatedly finds pixels that match neither a known colour nor a mix of the
/// colours around them, and adds the largest group as a new colour. Added
/// colours that turn out to be just a mix of two others, or resampling
/// overshoot just past another colour, are dropped at the end.
void _addThinLineColors(
  Uint8List px,
  int w,
  int h,
  List<List<int>> palette,
  int? bg,
  int maxColors,
  int tol2,
  bool Function(int) isBackgroundish,
) {
  final int n = w * h;
  final int minCluster = math.max(6, (n * 0.00005).round());
  final List<int>? bgColor = bg == null ? null : [(bg >> 16) & 255, (bg >> 8) & 255, bg & 255];
  final int flatCount = palette.length;
  final List<List<int>> rejected = [];

  for (int iter = 0; iter < 8 && palette.length < maxColors; iter++) {
    final List<List<int>> colors = [?bgColor, ...palette, ...rejected];
    if (colors.isEmpty) return;
    final Int32List bins = _unexplainedHistogram(px, w, h, colors, tol2, isBackgroundish);

    // Largest group of unexplained colours.
    final List<int> keys = [
      for (int key = 0; key < 32768; key++)
        if (bins[key * 4 + 3] > 0) key,
    ]..sort((a, b) => bins[b * 4 + 3] - bins[a * 4 + 3]);
    if (keys.isEmpty) break;
    final int k0 = keys.first;
    double sr = 0, sg = 0, sb = 0, sc = 0;
    final double cr = bins[k0 * 4] / bins[k0 * 4 + 3], cg = bins[k0 * 4 + 1] / bins[k0 * 4 + 3];
    final double cb = bins[k0 * 4 + 2] / bins[k0 * 4 + 3];
    for (final int key in keys) {
      final double c = bins[key * 4 + 3].toDouble();
      final double r = bins[key * 4] / c, g = bins[key * 4 + 1] / c, b = bins[key * 4 + 2] / c;
      if ((r - cr) * (r - cr) + (g - cg) * (g - cg) + (b - cb) * (b - cb) >= tol2) continue;
      sr += bins[key * 4];
      sg += bins[key * 4 + 1];
      sb += bins[key * 4 + 2];
      sc += c;
    }
    if (sc < minCluster) break;
    final List<int> color = [(sr / sc).round(), (sg / sc).round(), (sb / sc).round()];
    if (_isMixOrOvershoot(color, [?bgColor, ...palette], tol2)) {
      rejected.add(color); // counts as explained from now on
    } else {
      palette.add(color);
    }
  }

  // Drop added colours that are explained by the others.
  for (int i = palette.length - 1; i >= flatCount; i--) {
    final List<List<int>> others = [
      ?bgColor,
      for (int j = 0; j < palette.length; j++)
        if (j != i) palette[j],
    ];
    if (_isMixOrOvershoot(palette[i], others, tol2)) palette.removeAt(i);
  }
}

/// Histogram (sumR, sumG, sumB, count per 15-bit colour) of pixels that are
/// neither close to one of [colors] nor a mix of two colours around them.
Int32List _unexplainedHistogram(
  Uint8List px,
  int w,
  int h,
  List<List<int>> colors,
  int tol2,
  bool Function(int) isBackgroundish,
) {
  final int n = w * h;
  final Uint8List near = Uint8List(n);
  final Int32List nearD = Int32List(n);
  for (int i = 0; i < n; i++) {
    int best = 0, bestD = 1 << 30;
    for (int c = 0; c < colors.length; c++) {
      final int d = _dist2(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], colors[c][0], colors[c][1], colors[c][2]);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    near[i] = best;
    nearD[i] = bestD;
  }

  final Int32List bins = Int32List(32768 * 4);
  final List<int> cand = [];
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final int i = y * w + x;
      if (nearD[i] < tol2 || px[i * 4 + 3] < 250 || isBackgroundish(i)) continue;
      final int r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
      cand.clear();
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final int l = near[i + dy * w + dx];
          if (!cand.contains(l)) cand.add(l);
        }
      }
      bool explained = false;
      for (int a = 0; a < cand.length && !explained; a++) {
        for (int c = a + 1; c < cand.length && !explained; c++) {
          // Real anti-aliasing lies almost exactly between the two colours.
          explained = _segmentResidual2(r, g, b, colors[cand[a]], colors[cand[c]], 0.0, 1.0) < tol2 * 0.36;
        }
      }
      if (explained) continue;
      final int key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      bins[key * 4] += r;
      bins[key * 4 + 1] += g;
      bins[key * 4 + 2] += b;
      bins[key * 4 + 3]++;
    }
  }
  return bins;
}

/// Squared distance from colour (r, g, b) to the line from [a] to [c],
/// limited to parameters in [tMin, tMax]. Returns a huge value if outside.
double _segmentResidual2(int r, int g, int b, List<int> a, List<int> c, double tMin, double tMax) {
  final double vr = (c[0] - a[0]).toDouble(), vg = (c[1] - a[1]).toDouble(), vb = (c[2] - a[2]).toDouble();
  final double len2 = vr * vr + vg * vg + vb * vb;
  if (len2 == 0) return double.infinity;
  final double t = ((r - a[0]) * vr + (g - a[1]) * vg + (b - a[2]) * vb) / len2;
  if (t < tMin || t > tMax) return double.infinity;
  final double er = a[0] + vr * t - r, eg = a[1] + vg * t - g, eb = a[2] + vb * t - b;
  return er * er + eg * eg + eb * eb;
}

/// Whether [x] is a mix of two of [others], or overshoot slightly beyond one
/// of them as seen from another (resampling ringing).
bool _isMixOrOvershoot(List<int> x, List<List<int>> others, int tol2) {
  final double strict = tol2 * 0.36; // within 60% of the colour tolerance
  for (int a = 0; a < others.length; a++) {
    for (int c = 0; c < others.length; c++) {
      if (a == c) continue;
      if (c > a && _segmentResidual2(x[0], x[1], x[2], others[a], others[c], 0.05, 0.95) < strict) return true;
      if (_segmentResidual2(x[0], x[1], x[2], others[a], others[c], 1.0, 1.35) < strict) return true;
    }
  }
  return false;
}

/// Removes a solid background with soft, fringe-free edges by un-mixing each
/// edge pixel into "foreground colour over background" with partial alpha.
///
/// Unless [removeEnclosed] is set, only background connected to the image
/// border is removed; enclosed areas of that colour stay opaque.
Uint8List _cutout(Uint8List px, int w, int h, Int32List lr, Int32List lg, Int32List lb, bool removeEnclosed) {
  final int n = w * h;
  final Uint8List labels = Uint8List(n);
  for (int i = 0; i < n; i++) {
    labels[i] = _nearestLabel(px[i * 4], px[i * 4 + 1], px[i * 4 + 2], lr, lg, lb, true);
  }

  // 1 = background to remove.
  final Uint8List isBg = Uint8List(n);
  if (removeEnclosed) {
    for (int i = 0; i < n; i++) {
      if (labels[i] == 0) isBg[i] = 1;
    }
  } else {
    // 4-connected flood from the border, so thin diagonal lines keep it out.
    final Int32List stack = Int32List(n);
    int sp = 0;
    void push(int i) {
      if (labels[i] == 0 && isBg[i] == 0) {
        isBg[i] = 1;
        stack[sp++] = i;
      }
    }

    for (int x = 0; x < w; x++) {
      push(x);
      push((h - 1) * w + x);
    }
    for (int y = 0; y < h; y++) {
      push(y * w);
      push(y * w + w - 1);
    }
    while (sp > 0) {
      final int i = stack[--sp];
      final int x = i % w;
      if (x > 0) push(i - 1);
      if (x < w - 1) push(i + 1);
      if (i >= w) push(i - w);
      if (i < n - w) push(i + w);
    }
  }

  final Uint8List out = Uint8List(n * 4);
  final int bR = lr[0], bG = lg[0], bB = lb[0];
  final Map<int, int> votes = {};

  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int i = y * w + x;
      final int r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];

      bool nearBg = isBg[i] == 1;
      bool nearFg = isBg[i] == 0;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          final int xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
          if (isBg[yy * w + xx] == 1) {
            nearBg = true;
          } else {
            nearFg = true;
          }
        }
      }

      double alpha;
      double cr = r.toDouble(), cg = g.toDouble(), cb = b.toDouble();
      if (!nearBg) {
        alpha = 1;
      } else if (!nearFg) {
        alpha = 0;
      } else {
        // Candidate foreground colours, most common in a 5×5 window first.
        votes.clear();
        for (int dy = -2; dy <= 2; dy++) {
          for (int dx = -2; dx <= 2; dx++) {
            final int xx = x + dx, yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
            final int j = yy * w + xx;
            final int l = labels[j];
            if (isBg[j] == 0) votes[l] = (votes[l] ?? 0) + 1;
          }
        }
        final List<int> fgs = votes.keys.toList()..sort((a, c) => votes[c]! - votes[a]!);
        alpha = isBg[i] == 1 ? 0 : 1;
        for (final int f in fgs) {
          final double vr = (lr[f] - bR).toDouble(), vg = (lg[f] - bG).toDouble(), vb = (lb[f] - bB).toDouble();
          final double len2 = vr * vr + vg * vg + vb * vb;
          if (len2 == 0) continue;
          final double t = ((r - bR) * vr + (g - bG) * vg + (b - bB) * vb) / len2;
          final double tc = t.clamp(0.0, 1.0);
          final double er = bR + vr * tc - r, eg = bG + vg * tc - g, eb = bB + vb * tc - b;
          final double residual = math.sqrt(er * er + eg * eg + eb * eb);
          if (residual < math.max(14.0, 0.2 * math.sqrt(len2))) {
            alpha = tc > 0.96 ? 1.0 : (tc < 0.04 ? 0.0 : tc);
            if (alpha > 0 && alpha < 1) {
              cr = ((r - (1 - alpha) * bR) / alpha).clamp(0.0, 255.0);
              cg = ((g - (1 - alpha) * bG) / alpha).clamp(0.0, 255.0);
              cb = ((b - (1 - alpha) * bB) / alpha).clamp(0.0, 255.0);
            }
            break;
          }
        }
      }

      final double srcA = px[i * 4 + 3] / 255.0;
      final double a = alpha * srcA;
      // Premultiplied output, as ui.decodeImageFromPixels expects.
      out[i * 4] = (cr * a).round();
      out[i * 4 + 1] = (cg * a).round();
      out[i * 4 + 2] = (cb * a).round();
      out[i * 4 + 3] = (a * 255).round();
    }
  }
  return out;
}
