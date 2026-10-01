import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';

import 'image_format.dart';
import 'sketch_cache.dart';
import 'sketch_options.dart';
import 'tracer/path_commands.dart';
import 'tracer/trace_core.dart';

/// One coloured layer of a traced image.
class SketchShape {
  /// The layer's outline in [Sketch.size] coordinates, filled even-odd.
  final ui.Path path;

  /// The layer's fill colour.
  final ui.Color color;

  /// The contours of [path], measured once and reused by the animation.
  late final List<ui.PathMetric> metrics = path.computeMetrics().toList();

  /// Creates a layer from a [path] and its [color].
  SketchShape(this.path, this.color);
}

/// The result of tracing: vector layers plus the exact final image.
class Sketch {
  /// Size of the trace space. [shapes] use these coordinates.
  final ui.Size size;

  /// Layers, bottom to top.
  final List<SketchShape> shapes;

  /// The exact final frame: the original image, with the background removed
  /// when one was detected and [SketchOptions.removeBackground] was on.
  final ui.Image image;

  /// Colours found in the artwork, most common first.
  final List<ui.Color> palette;

  /// The solid background colour that was removed, if any.
  final ui.Color? removedBackground;

  /// How long [Sketchify.trace] took, including decoding.
  final Duration elapsed;

  /// The file format that was detected.
  final SketchImageFormat format;

  /// Whether this came from [Sketchify.cache] instead of being traced.
  final bool fromCache;

  const Sketch._({
    required this.size,
    required this.shapes,
    required this.image,
    required this.palette,
    required this.removedBackground,
    required this.elapsed,
    required this.format,
    required this.fromCache,
  });

  /// Width divided by height.
  double get aspectRatio => size.width / size.height;

  /// Frees the decoded image. Call when the traced image is no longer shown.
  void dispose() => image.dispose();
}

/// Turns any image into a [Sketch] that [SketchAnimation] can draw.
class Sketchify {
  Sketchify._();

  /// Where traced results are kept, so tracing the same image with the same
  /// options again is almost instant, also after the app restarts.
  ///
  /// By default results are kept in memory (up to 32 MB) and in
  /// [SketchCacheStore.platformDefault] (up to 100 MB): the app's cache
  /// directory, or IndexedDB on the web. They stay until the app's cache or
  /// data is cleared, or until [SketchCache.clear] is called.
  ///
  /// Set your own [SketchCache] to change the limits or the storage, or null
  /// to turn caching off.
  static SketchCache? cache = SketchCache(store: SketchCacheStore.platformDefault());

  /// Traces image file bytes. The format is detected from the contents:
  /// PNG, JPEG, WebP, GIF, BMP, WBMP, ICO, HEIC/HEIF (platform permitting)
  /// and SVG. Animated GIF/WebP use their first frame.
  ///
  /// Results are kept in [cache] unless [useCache] is false. The cache
  /// recognises an image by its contents; pass [cacheKey] to name it
  /// yourself and skip hashing the bytes (the key must change whenever the
  /// image does). [Sketch.fromCache] says whether the cache was used.
  ///
  /// Throws [UnsupportedImageException] if the image can't be read, and an
  /// [ArgumentError] if [options] are out of range.
  static Future<Sketch> trace(
    Uint8List bytes, {
    SketchOptions options = const SketchOptions(),
    bool useCache = true,
    String? cacheKey,
  }) async {
    options.validate();
    final Stopwatch watch = Stopwatch()..start();
    final SketchImageFormat format = SketchImageFormat.detect(bytes);

    final SketchCache? store = useCache ? cache : null;
    final String? key = store == null ? null : cacheKeyFor(bytes, options, cacheKey);
    if (store != null) {
      final Uint8List? entry = await cacheRead(store, key!);
      if (entry != null) {
        try {
          return await _fromCache(decodeTrace(entry), bytes, format, options, watch);
        } catch (_) {
          // Unreadable entry: forget it and trace afresh below.
          await cacheRemove(store, key);
        }
      }
    }

    ui.Image? full, traceImage, kept;
    try {
      if (format == SketchImageFormat.svg) {
        full = await _renderSvg(bytes, options.svgRenderSize);
        traceImage = await _fitWithin(full, options.maxTraceSize);
      } else {
        full = await _decodeOrThrow(bytes, format);
        final int longest = full.width > full.height ? full.width : full.height;
        if (longest > options.maxTraceSize) {
          final double s = options.maxTraceSize / longest;
          traceImage = await _decode(
            bytes,
            targetWidth: (full.width * s).round().clamp(1, options.maxTraceSize),
            targetHeight: (full.height * s).round().clamp(1, options.maxTraceSize),
          );
        } else {
          traceImage = full;
        }
      }

      final Uint8List traceRgba = await _rgba(traceImage);
      final Uint8List? fullRgba = options.removeBackground ? await _rgba(full) : null;

      final TraceResult result = await compute(
        _traceInBackground,
        TraceRequest(
          rgba: traceRgba,
          width: traceImage.width,
          height: traceImage.height,
          fullRgba: fullRgba,
          fullWidth: full.width,
          fullHeight: full.height,
          removeBackground: options.removeBackground,
          removeEnclosedBackground: options.removeEnclosedBackground,
          maxColors: options.maxColors,
          colorTolerance: options.colorTolerance,
          curveTolerance: options.curveTolerance,
          minShapeFraction: options.minShapeFraction,
        ),
      );

      final ui.Image finalImage = result.cutoutRgba == null
          ? full
          : await _fromPixels(result.cutoutRgba!, full.width, full.height);
      // The final image belongs to the Sketch; everything else is freed below.
      kept = finalImage;

      if (store != null) _save(store, key!, result, finalImage);

      watch.stop();
      return Sketch._(
        size: ui.Size(result.width.toDouble(), result.height.toDouble()),
        shapes: [for (final s in result.shapes) SketchShape(_buildPath(s.commands), ui.Color(s.color))],
        image: finalImage,
        palette: [for (final c in result.palette) ui.Color(c)],
        removedBackground: result.backgroundColor == null ? null : ui.Color(result.backgroundColor!),
        elapsed: watch.elapsed,
        format: format,
        fromCache: false,
      );
    } finally {
      if (traceImage != null && !identical(traceImage, full) && !identical(traceImage, kept)) traceImage.dispose();
      if (full != null && !identical(full, kept)) full.dispose();
    }
  }

  /// Traces SVG markup. See [trace] for [useCache] and [cacheKey].
  static Future<Sketch> traceSvgString(
    String svg, {
    SketchOptions options = const SketchOptions(),
    bool useCache = true,
    String? cacheKey,
  }) {
    return trace(Uint8List.fromList(utf8.encode(svg)), options: options, useCache: useCache, cacheKey: cacheKey);
  }

  /// Saves a fresh result to [store] in the background. A cut-out final
  /// image is kept as PNG; otherwise it is decoded again from the original.
  static void _save(SketchCache store, String key, TraceResult result, ui.Image finalImage) {
    // Our own handle, so the caller can dispose the Sketch straight away.
    final ui.Image? cutout = result.cutoutRgba == null ? null : finalImage.clone();
    cacheWrite(store, key, () async {
      Uint8List? png;
      if (cutout != null) {
        try {
          final ByteData? data = await cutout.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) return null;
          png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        } finally {
          cutout.dispose();
        }
      }
      return encodeTrace(
        CachedTrace(
          width: result.width,
          height: result.height,
          palette: result.palette,
          backgroundColor: result.backgroundColor,
          shapeColors: [for (final s in result.shapes) s.color],
          shapeCommands: [for (final s in result.shapes) s.commands],
          cutoutPng: png,
        ),
      );
    });
  }

  /// Rebuilds a [Sketch] from a cached result: only the final image needs
  /// decoding.
  static Future<Sketch> _fromCache(
    CachedTrace t,
    Uint8List bytes,
    SketchImageFormat format,
    SketchOptions options,
    Stopwatch watch,
  ) async {
    final ui.Image image;
    if (t.cutoutPng != null) {
      image = await _decode(t.cutoutPng!);
    } else if (format == SketchImageFormat.svg) {
      image = await _renderSvg(bytes, options.svgRenderSize);
    } else {
      image = await _decodeOrThrow(bytes, format);
    }
    watch.stop();
    return Sketch._(
      size: ui.Size(t.width.toDouble(), t.height.toDouble()),
      shapes: [
        for (int i = 0; i < t.shapeColors.length; i++)
          SketchShape(_buildPath(t.shapeCommands[i]), ui.Color(t.shapeColors[i])),
      ],
      image: image,
      palette: [for (final c in t.palette) ui.Color(c)],
      removedBackground: t.backgroundColor == null ? null : ui.Color(t.backgroundColor!),
      elapsed: watch.elapsed,
      format: format,
      fromCache: true,
    );
  }

  static Future<ui.Image> _decodeOrThrow(Uint8List bytes, SketchImageFormat format) async {
    try {
      return await _decode(bytes);
    } catch (e) {
      final String what = format == SketchImageFormat.unknown ? 'This file' : 'This ${format.name.toUpperCase()} image';
      final String hint = switch (format) {
        SketchImageFormat.heic => ' HEIC needs iOS, macOS or Android 9+; on other platforms convert it to JPEG or PNG.',
        SketchImageFormat.avif =>
          ' AVIF is not supported by Flutter on this platform; convert it to PNG, JPEG or WebP.',
        _ => ' Supported: PNG, JPEG, WebP, GIF, BMP, WBMP, ICO, HEIC and SVG.',
      };
      throw UnsupportedImageException(format, '$what could not be decoded.$hint');
    }
  }

  /// Renders an SVG so its longest side is [longestSide] pixels.
  static Future<ui.Image> _renderSvg(Uint8List bytes, int longestSide) async {
    final PictureInfo info;
    try {
      info = await vg.loadPicture(SvgBytesLoader(bytes), null);
    } catch (e) {
      throw UnsupportedImageException(SketchImageFormat.svg, 'This SVG could not be read: $e');
    }
    try {
      final ui.Size size = info.size;
      if (size.isEmpty) {
        throw const UnsupportedImageException(
          SketchImageFormat.svg,
          'This SVG has no size. Give it a viewBox or width and height.',
        );
      }
      final double scale = longestSide / (size.width > size.height ? size.width : size.height);
      final int w = (size.width * scale).round().clamp(1, longestSide);
      final int h = (size.height * scale).round().clamp(1, longestSide);
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder)..scale(scale);
      canvas.drawPicture(info.picture);
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(w, h);
      picture.dispose();
      return image;
    } finally {
      info.picture.dispose();
    }
  }

  /// A copy of [image] scaled down to fit within [maxSide], or the image itself.
  static Future<ui.Image> _fitWithin(ui.Image image, int maxSide) async {
    final int longest = image.width > image.height ? image.width : image.height;
    if (longest <= maxSide) return image;
    final double s = maxSide / longest;
    final int w = (image.width * s).round().clamp(1, maxSide);
    final int h = (image.height * s).round().clamp(1, maxSide);
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      image,
      ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image scaled = await picture.toImage(w, h);
    picture.dispose();
    return scaled;
  }

  /// Traces an image bundled as a Flutter asset.
  ///
  /// See [trace] for [useCache] and [cacheKey].
  static Future<Sketch> traceAsset(
    String assetName, {
    AssetBundle? bundle,
    SketchOptions options = const SketchOptions(),
    bool useCache = true,
    String? cacheKey,
  }) async {
    final ByteData data = await (bundle ?? rootBundle).load(assetName);
    return trace(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      options: options,
      useCache: useCache,
      cacheKey: cacheKey,
    );
  }

  static Future<ui.Image> _decode(Uint8List bytes, {int? targetWidth, int? targetHeight}) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth, targetHeight: targetHeight);
    final ui.FrameInfo frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static Future<Uint8List> _rgba(ui.Image image) async {
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) throw StateError('Could not read image pixels');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static Future<ui.Image> _fromPixels(Uint8List premultipliedRgba, int width, int height) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(premultipliedRgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  static ui.Path _buildPath(Float32List c) {
    final ui.Path path = ui.Path()..fillType = ui.PathFillType.evenOdd;
    int i = 0;
    while (i < c.length) {
      final double op = c[i];
      if (op == PathCommands.moveTo) {
        path.moveTo(c[i + 1], c[i + 2]);
        i += 3;
      } else if (op == PathCommands.lineTo) {
        path.lineTo(c[i + 1], c[i + 2]);
        i += 3;
      } else if (op == PathCommands.cubicTo) {
        path.cubicTo(c[i + 1], c[i + 2], c[i + 3], c[i + 4], c[i + 5], c[i + 6]);
        i += 7;
      } else {
        path.close();
        i += 1;
      }
    }
    return path;
  }
}

/// Top-level so it can run in a background isolate.
TraceResult _traceInBackground(TraceRequest request) => traceImage(request);
