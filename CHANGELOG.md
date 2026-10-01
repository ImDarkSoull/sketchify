## 1.0.0

First stable release, published on pub.dev. The public API is now stable.

- Everything from the 0.x development versions below, tested on Android, iOS, web (JavaScript and WebAssembly), macOS, Windows and Linux.
- New showcase app in `example/`. It includes sample illustrations, five looks (Pencil, Neon, Ink, Blueprint and Vector), playback controls, a timeline scrubber, every style option, the palette that was found, and your own images through a file picker.
- Complete README covering installation, recipes, every option, caching, formats, accuracy, performance tips, troubleshooting and limitations.
- API documentation for every public class and member.
- Test and example images are original artwork, released under the package's MIT licence.
- Minimum versions: Dart 3.9 and Flutter 3.35 (the same as `flutter_svg` 2.3).
- The internal `traceImageInBackground` helper is no longer public.

## 0.6.0

Trace caching: an image is traced only once.

- Tracing the same image with the same options again comes from a cache and is almost instant (for example 511 ms → 55 ms), also after the app restarts. It works with no setup.
- Results are kept in memory (`Sketchify.cache`, up to 32 MB) and in `SketchCacheStore.platformDefault()` (up to 100 MB): the app's cache directory on Android, iOS, macOS, Windows and Linux, or IndexedDB on the web. They stay until the app's cache or data is cleared, or until `Sketchify.cache.clear()` is called.
- `SketchCacheStore.directory(path)` keeps results in a directory you choose. You can also implement `SketchCacheStore` for your own storage.
- Images are recognised by their contents and the options used, so an edited image is never served stale. Pass `cacheKey` to name an image yourself instead.
- `useCache: false` skips the cache for one call. `Sketch.fromCache` tells you whether the cache was used. `SketchCache.flush()` waits for results still being saved.
- The cache stores outlines and a compressed final image, never decoded images, so `Sketch.dispose()` still frees memory.
- A failing cache (a full disk, a corrupted file, private browsing) never breaks tracing.
- New dependencies: `path_provider` and `web`.
- `onProgress` is no longer called in the middle of a build. Replacing the `sketch` restarted the drawing during the rebuild. If `onProgress` updated other widgets, Flutter threw "setState() or markNeedsBuild() called during build".
- Pending `delay` and `repeatPause` waits are now cancelled on `pause`, `replay` and dispose, so they never leave a timer running.

## 0.5.0

Stability: fixes found while testing on every platform.

- `SketchAnimation` no longer crashes on web (JavaScript builds). The playback duration was clamped with `1 << 52`, which is `0` on the web.
- Tracing an image that is only semi-transparent (no fully opaque pixels) no longer throws a `RangeError`.
- Line art in one or two inks with few flat areas (for example thin strokes on white) no longer breaks into dozens of fragments.
- `seek()` no longer calls `onCompleted`. It also no longer starts the next loop or ping-pong run while paused.
- Changing `playMode` while paused no longer starts playback.
- Switching `autoPlay` on, or replacing the `sketch`, now starts after `delay`.
- Out-of-range `SketchOptions` now fail clearly: an assert in debug, and an `ArgumentError` in release. Added `SketchOptions.validate()`, `==`, `hashCode` and `toString`.
- Decoded images are now freed if tracing fails partway through.
- Format detection: files that merely start with two zero bytes (such as MP4 videos) are no longer reported as WBMP. AVIF is now identified as `SketchImageFormat.avif`, so its error message is accurate. Added `SketchImageFormat.isSupported`.
- Pen dots on a `lineGradient` now take the gradient's colour at the pen tip.
- The pen glow now uses a radial gradient instead of a blur filter, which is much cheaper with many pens.
- New `SketchOptions.removeEnclosedBackground`. Set it to `false` to remove only the background that touches the image border, so enclosed areas of that colour (such as white eyes on a white background) stay in the artwork.
- New `SketchAnimationState.isPaused`.

## 0.4.0

Any image format.

- Added WebP, GIF, BMP, WBMP and ICO support, plus HEIC/HEIF where the platform can decode it. Animated GIF and WebP use their first frame.
- Added SVG support through `flutter_svg`. SVGs are rendered at `SketchOptions.svgRenderSize`, then traced. Added `Sketchify.traceSvgString`.
- The format is detected from the file's contents, not its name (`SketchImageFormat.detect`).
- `SketchImageFormat.allExtensions` and `allMimeTypes` provide ready-made lists for file pickers.
- Unreadable files throw `UnsupportedImageException`, with a clear message.

## 0.3.0

Playback control.

- `SketchAnimation` gained `speed`, `curve`, `playMode` (`once`, `loop`, `pingPong`), `delay`, `repeatPause`, `autoPlay` and `width`.
- Control from code through a `GlobalKey<SketchAnimationState>`: `replay`, `pause`, `resume`, `seek`, `progress` and `isPlaying`.
- New `onCompleted` and `onProgress` callbacks.

## 0.2.0

Styles.

- New `SketchStyle`:
  - Lines: a line colour or a gradient across the artwork, each shape's own colour, width, caps and joins, and keeping lines on top of the fill.
  - A pen dot with an optional glow.
  - Drawing order: together, staggered or sequential.
  - The fill: the original image, the traced vector layers, or none.
  - Six reveal styles: fade, four wipes and a growing circle.
- New `SketchPainter`, for drawing a sketch at any progress in your own `CustomPaint`.

## 0.1.0

Cleaner traces.

- A solid background is detected from the image border and cut out with soft, fringe-free edges. Real transparency is kept.
- Colours are found from flat areas first, so anti-aliased edges don't become fake colours. Colours that only appear in thin lines are found too.
- Edges are placed to a fraction of a pixel. Circles and ellipses come out exactly round, and real corners stay sharp.
- Specks are merged into their neighbours, and shapes inside other shapes are layered correctly.
- Tracing runs in a background isolate.

## 0.0.1

First working version.

- `Sketchify.trace` and `Sketchify.traceAsset` turn PNG and JPEG images into coloured vector layers with smooth Bézier outlines.
- `SketchAnimation` draws the outlines in, then fades in the original image, so the last frame matches it exactly.
