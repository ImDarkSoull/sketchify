/// Test artwork, drawn for this package and released with it under the MIT
/// licence. Everything is plain SVG so tests can render it on the fly.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/svg.dart';

const String navy = '#1E2A44';

/// A cat's face in flat colours. With [background] it sits on solid navy.
String catSvg({bool background = true}) =>
    '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">
  ${background ? '<rect width="400" height="400" fill="$navy"/>' : ''}
  <path d="M110 400 C110 320 150 285 200 285 C250 285 290 320 290 400 Z" fill="#E8914A"/>
  <path d="M160 400 C160 340 178 318 200 318 C222 318 240 340 240 400 Z" fill="#FCE8D2"/>
  <path d="M98 150 L112 52 L182 108 Z" fill="#E8914A"/>
  <path d="M302 150 L288 52 L218 108 Z" fill="#E8914A"/>
  <path d="M116 132 L123 78 L162 110 Z" fill="#F6B8B8"/>
  <path d="M284 132 L277 78 L238 110 Z" fill="#F6B8B8"/>
  <ellipse cx="200" cy="190" rx="122" ry="105" fill="#E8914A"/>
  <path d="M188 88 C192 105 192 118 200 128 C208 118 208 105 212 88 C204 86 196 86 188 88 Z" fill="#C96F2E"/>
  <path d="M150 96 C160 108 166 118 168 130 C156 124 146 112 140 100 Z" fill="#C96F2E"/>
  <path d="M250 96 C240 108 234 118 232 130 C244 124 254 112 260 100 Z" fill="#C96F2E"/>
  <ellipse cx="200" cy="232" rx="58" ry="40" fill="#FCE8D2"/>
  <ellipse cx="150" cy="182" rx="26" ry="30" fill="#FFFFFF"/>
  <ellipse cx="250" cy="182" rx="26" ry="30" fill="#FFFFFF"/>
  <ellipse cx="154" cy="188" rx="15" ry="20" fill="#4A2C1D"/>
  <ellipse cx="246" cy="188" rx="15" ry="20" fill="#4A2C1D"/>
  <circle cx="160" cy="178" r="6" fill="#FFFFFF"/>
  <circle cx="252" cy="178" r="6" fill="#FFFFFF"/>
  <path d="M186 214 L214 214 L200 230 Z" fill="#E86A7A"/>
  <path d="M200 230 C200 246 186 252 176 244 M200 230 C200 246 214 252 224 244" fill="none" stroke="#4A2C1D" stroke-width="5" stroke-linecap="round"/>
  <path d="M138 226 L78 214 M138 240 L76 246 M262 226 L322 214 M262 240 L324 246" stroke="#FCE8D2" stroke-width="4" stroke-linecap="round"/>
</svg>''';

/// The word SKETCH in one ink on cream: six letters, each one connected
/// stroke with no enclosed holes.
const String letteringSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 140">
  <rect width="520" height="140" fill="#FFF6E5"/>
  <g fill="none" stroke="#3A2E1F" stroke-width="14" stroke-linecap="round" stroke-linejoin="round">
    <path d="M86 40 C78 28 40 26 38 48 C36 70 88 66 86 92 C84 116 44 116 34 100"/>
    <path d="M118 30 L118 110 M168 30 L120 74 L170 110"/>
    <path d="M246 30 L200 30 L200 110 L246 110 M200 70 L238 70"/>
    <path d="M272 30 L332 30 M302 30 L302 110"/>
    <path d="M410 42 C396 24 356 26 352 66 C350 106 392 118 412 96"/>
    <path d="M440 30 L440 110 M492 30 L492 110 M440 70 L492 70"/>
  </g>
</svg>''';

/// Small details on white: 10 solid dots (r 2–20), 9 rings 2 px thick
/// (r 4–24), 6 rings 1.5 px thick (r 6–24) and 6 small ellipses, in four
/// inks. Drawn 1:1, so everything is anti-aliased at real pixel sizes.
String smallShapesSvg() {
  const inks = ['#4699D1', '#593E25', '#E91E63', '#383122'];
  final b = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" width="640" height="330" viewBox="0 0 640 330">')
    ..write('<rect width="640" height="330" fill="#FFFFFF"/>');
  double x = 20;
  for (int i = 0; i < 10; i++) {
    final double r = 2 + i * 2;
    x += r;
    b.write('<circle cx="$x" cy="40" r="$r" fill="${inks[i % 4]}"/>');
    x += r + 12;
  }
  x = 20;
  for (int i = 0; i < 9; i++) {
    final double r = 4.0 + i * 2.5;
    x += r;
    b.write('<circle cx="$x" cy="120" r="$r" fill="none" stroke="${inks[(i + 1) % 4]}" stroke-width="2"/>');
    x += r + 14;
  }
  x = 20;
  for (int i = 0; i < 6; i++) {
    final double r = 6.0 + i * 3.6;
    x += r;
    b.write('<circle cx="$x" cy="200" r="$r" fill="none" stroke="${inks[(i + 2) % 4]}" stroke-width="1.5"/>');
    x += r + 16;
  }
  x = 20;
  for (int i = 0; i < 6; i++) {
    final double rx = 5.0 + i * 2.5, ry = 3.0 + i * 1.2;
    x += rx;
    b.write('<ellipse cx="$x" cy="290" rx="$rx" ry="$ry" fill="${inks[(i + 3) % 4]}"/>');
    x += rx + 16;
  }
  b.write('</svg>');
  return b.toString();
}

/// Renders [svg] to PNG bytes, [width] pixels wide.
Future<Uint8List> renderPng(String svg, {required int width}) async {
  final PictureInfo info = await vg.loadPicture(SvgStringLoader(svg), null);
  final double scale = width / info.size.width;
  final int height = (info.size.height * scale).round();
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..scale(scale)
    ..drawPicture(info.picture);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  picture.dispose();
  info.picture.dispose();
  image.dispose();
  return data!.buffer.asUint8List();
}
