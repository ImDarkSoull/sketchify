import 'dart:convert';
import 'dart:typed_data';

/// Image file formats the tracer recognises.
enum SketchImageFormat {
  /// Portable Network Graphics.
  png,

  /// JPEG photos.
  jpeg,

  /// WebP (animated WebP uses its first frame).
  webp,

  /// GIF (animated GIF uses its first frame).
  gif,

  /// Windows bitmap.
  bmp,

  /// Wireless bitmap (1-bit black and white).
  wbmp,

  /// Windows icon.
  ico,

  /// HEIC/HEIF (iPhone photos). Decoded by the platform: iOS, macOS and
  /// Android 9+; not available on web, Windows or Linux.
  heic,

  /// AVIF. Recognised so the error can say what it is, but Flutter's
  /// decoders can't read it on most platforms; convert to PNG, JPEG or WebP.
  avif,

  /// Scalable Vector Graphics. Rendered at high resolution, then traced.
  svg,

  /// Not a recognised image file.
  unknown;

  /// File extensions for this format, without the dot.
  List<String> get extensions => switch (this) {
    png => ['png'],
    jpeg => ['jpg', 'jpeg', 'jfif'],
    webp => ['webp'],
    gif => ['gif'],
    bmp => ['bmp'],
    wbmp => ['wbmp'],
    ico => ['ico'],
    heic => ['heic', 'heif'],
    avif => ['avif'],
    svg => ['svg'],
    unknown => const [],
  };

  /// MIME types for this format.
  List<String> get mimeTypes => switch (this) {
    png => ['image/png'],
    jpeg => ['image/jpeg'],
    webp => ['image/webp'],
    gif => ['image/gif'],
    bmp => ['image/bmp'],
    wbmp => ['image/vnd.wap.wbmp'],
    ico => ['image/x-icon', 'image/vnd.microsoft.icon'],
    heic => ['image/heic', 'image/heif'],
    avif => ['image/avif'],
    svg => ['image/svg+xml'],
    unknown => const [],
  };

  /// Whether the tracer can read this format (on at least some platforms).
  bool get isSupported => this != avif && this != unknown;

  /// Every extension the tracer accepts, for file pickers.
  static List<String> get allExtensions => [
    for (final f in values)
      if (f.isSupported) ...f.extensions,
  ];

  /// Every MIME type the tracer accepts, for file pickers.
  static List<String> get allMimeTypes => [
    for (final f in values)
      if (f.isSupported) ...f.mimeTypes,
  ];

  /// Works out the format from the file's contents (not its name).
  static SketchImageFormat detect(Uint8List b) {
    bool at(int offset, List<int> sig) {
      if (b.length < offset + sig.length) return false;
      for (int i = 0; i < sig.length; i++) {
        if (b[offset + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return png;
    if (at(0, const [0xFF, 0xD8, 0xFF])) return jpeg;
    if (at(0, ascii.encode('GIF8'))) return gif;
    if (at(0, ascii.encode('RIFF')) && at(8, ascii.encode('WEBP'))) return webp;
    if (at(0, ascii.encode('BM'))) return bmp;
    if (at(0, const [0x00, 0x00, 0x01, 0x00])) return ico;
    if (at(4, ascii.encode('ftyp'))) {
      final String brand = b.length >= 12 ? ascii.decode(b.sublist(8, 12), allowInvalid: true) : '';
      if (const ['avif', 'avis'].contains(brand)) return avif;
      if (const ['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'].contains(brand)) return heic;
    }
    if (_looksLikeSvg(b)) return svg;
    if (_looksLikeWbmp(b)) return wbmp;
    return unknown;
  }

  /// WBMP has no magic number: type 0, a zero header byte, then width and
  /// height as variable-length integers and exactly one bit per pixel.
  static bool _looksLikeWbmp(Uint8List b) {
    if (b.length < 4 || b[0] != 0 || b[1] != 0) return false;
    int pos = 2;
    int? readInt() {
      int value = 0;
      for (int i = 0; i < 4 && pos < b.length; i++) {
        final int byte = b[pos++];
        value = (value << 7) | (byte & 0x7F);
        if (byte & 0x80 == 0) return value;
      }
      return null;
    }

    final int? width = readInt(), height = readInt();
    if (width == null || height == null || width == 0 || height == 0) return false;
    return b.length - pos == ((width + 7) ~/ 8) * height;
  }

  static bool _looksLikeSvg(Uint8List b) {
    final int n = b.length < 4096 ? b.length : 4096;
    final String head = utf8.decode(b.sublist(0, n), allowMalformed: true).replaceFirst('\uFEFF', '').trimLeft();
    return head.startsWith('<') && head.contains('<svg');
  }
}

/// Thrown when an image can't be read.
class UnsupportedImageException implements Exception {
  /// What the file looked like ([SketchImageFormat.unknown] if not an image).
  final SketchImageFormat format;

  /// A readable explanation, suitable for showing to the user.
  final String message;

  /// Creates the exception.
  const UnsupportedImageException(this.format, this.message);

  @override
  String toString() => message;
}
